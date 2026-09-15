////////////////////////////////////////////////////////////////////////////////
//
// PadHome — Blink 鸿蒙平板版，界面仿 macOS 版（Jack/blink mac/BlinkMac）：
//
//   ┌ TopBar：机器 › cc-会话 · tailscale 徽章 · 团队/重连/设置 ─────────────────┐
//   │ MachineRail │ SessionSidebar │ TerminalColumn（终端 / 对话记录）│ TeamInspector │
//   │    64       │      280       │  快捷栏 · 语音条 · 状态栏        │   296 / 抽屉  │
//   └──────────────────────────────────────────────────────────────────────────┘
//
// 底层全部沿用手机版（entry/pages/BlinkTerminal.ets）验证过的链路：
//   • Tailscale VPN 扩展 + 看门狗 + 长时任务保活
//   • 每 tab 一条 blinkd 连接（ConnPool），hterm 多图层终端（rawfile/term）
//   • 配置经 Mac 文件双向同步（CfgSync）
//   • 对话记录增量拉取 + 本地缓存（ChatHtml，暗色皮肤）
// 平板新增：会话状态探测（PadProbe，同 macOS probeScript）、团队分组、外接键盘按键映射。
//
////////////////////////////////////////////////////////////////////////////////

import { common, wantAgent, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { vpnExtension, http } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util, buffer } from '@kit.ArkTS';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { BlinkdClient, BlinkdState, TailscaleCore, StatusStore } from 'tsvpn';
import { BlinkStore, Machine, WorkDir, TabModel, SeedConfig } from '../model/BlinkStores';
import { ConnPool, SessionConn, ConnUiState } from '../model/SessionConn';
import { GlmClient, VoiceRecorder, Uploader, CLAUDE_COMMANDS } from '../model/GlmVoice';
import { CfgSync } from '../model/CfgSync';
import { PadExec, Endpoint } from '../model/PadExec';
import { PadProbe, PROBE_SCRIPT, WorkStatus } from '../model/PadProbe';
import { buildChatHtml, ChatBridge, TranscriptCacheH } from '../model/ChatHtml';

const DOMAIN: number = 0x0B12;
const TAG: string = 'BlinkPad';
const BUNDLE: string = 'com.douwantech.blink';

// ---- macOS Theme（mac/Sources/BlinkMac/Theme.swift）----
const BG: string = '#0B0C0E';
const TERM: string = '#101010';
const PANEL: string = '#14161B';
const PANEL2: string = '#16191D';
const PANEL3: string = '#1A1D23';
const HAIR: string = '#14FFFFFF';     // 白 8%
const HAIR2: string = '#24FFFFFF';    // 白 14%
const FILL: string = '#0BFFFFFF';     // 白 4.5%
const FILL2: string = '#14FFFFFF';    // 白 8%
const FG: string = '#D4DAE0';
const DIM: string = '#6B7683';
const SUB: string = '#8B95A5';
const GREEN: string = '#33E0A1';
const TEAL: string = '#63D3E8';
const RED: string = '#FF5A5C';
const STAR: string = '#F5C451';
const C_WAIT: string = '#F5A83D';
const C_WORK: string = '#40D68C';
const C_REST: string = '#8F8CFF';
const MONO: string = 'monospace';

// 头像渐变（Model.swift Grad）
const GRADS: string[][] = [
  ['#4EA8FF', '#8F8CFF'],
  ['#F5A83D', '#FF5A5C'],
  ['#40D68C', '#63D3E8'],
  ['#8F8CFF', '#5A57C9'],
];

const FONT_SIZES: number[] = [10, 11, 12, 13, 14, 15, 16];

// 对话记录暗色皮肤：盖在 buildChatHtml 的浅色样式之上（mac ChatBubbleRow 配色）
const CHAT_DARK_CSS: string =
  'body{background:#101216;color:#d4dae0;}' +
  '.mb-claude .card{background:#1a1d23;border-color:rgba(255,255,255,.08);box-shadow:none;}' +
  '.mb-claude .msg-head{background:#16191d;border-bottom-color:rgba(255,255,255,.06);}' +
  '.mb-user .card{background:rgba(63,220,151,.14);color:#d8f6e8;border:1px solid rgba(63,220,151,.28);}' +
  '.role{color:#8b95a5;}.copy-btn{color:#63d3e8;border-color:rgba(99,211,232,.35);}' +
  '.copy-btn.copied{color:#40d68c;border-color:rgba(64,214,140,.4);}' +
  'code{background:#23272e;color:#e6edf3;}pre{background:#0b0c0e;}' +
  'th,td{border-color:rgba(255,255,255,.1);}th{background:#16191d;}a{color:#4ea8ff;}' +
  'blockquote{border-left-color:#3a4048;color:#8b95a5;}hr{border-top-color:rgba(255,255,255,.1);}' +
  '.meta{color:#6b7683;}.ava-user{background:#3a4048;}' +
  '.ava-claude{background:linear-gradient(135deg,#4ea8ff,#8f8cff);}.ava.has-img{background:#23272e;}';

type Sheet = 'none' | 'settings' | 'newTab' | 'favorites' | 'claude' | 'history' | 'aiConfig' | 'machines' | 'workDirs';
type Mode = 'terminal' | 'chat';
type Inspector = 'employee' | 'project' | 'machine';

interface MachineVM {
  id: string;
  name: string;
  initials: string;
  g1: string;
  g2: string;
  waiting: number;
}

interface SessRow {
  tabId: string;
  machineId: string;
  workDirId: string;
  name: string;        // 侧栏显示名（tabTitle）
  cc: string;          // tmux 外层会话 cc-<TITLE>
  owner: string;       // 员工 = 工作目录名
  project: string;     // 项目 = 会话段
  dir: string;
  status: WorkStatus;
  statusLabel: string;
  resting: boolean;
  unread: boolean;
}

interface TeamGroupVM {
  key: string;
  title: string;
  sub: string;
  avatarWorkDirId: string;   // 按员工分组时用员工头像，其它为空
  rows: SessRow[];
}

class JsBridge {
  private cb: (op: string, data: string) => void;
  constructor(cb: (op: string, data: string) => void) {
    this.cb = cb;
  }
  post(op: string, data: string): void {
    this.cb(op, data);
  }
}

@Entry
@Component
struct PadHome {
  // tailscale
  @State tsState: string = '';
  @State tsIP: string = '';
  @State tsConnected: boolean = false;
  @State authKey: string = '';
  @State hostname: string = 'harmony-pad';
  // 布局
  @State winW: number = 1200;
  @State topInset: number = 0;
  @State botInset: number = 0;
  @State kbHeight: number = 0;
  @State kbWanted: boolean = false;     // 软键盘只在点「键盘」时弹；外接键盘始终可打字
  // 选择 / 视图模型（store 是普通 class，ArkUI 观察不到，改完一律走 refreshAll）
  @State tick: number = 0;
  @State storeReady: boolean = false;
  @State activeTabId: string = '';
  @State activeMachineId: string = '';
  @State machinesVM: MachineVM[] = [];
  @State sideRows: SessRow[] = [];
  @State teamGroups: TeamGroupVM[] = [];
  @State statWait: number = 0;
  @State statWork: number = 0;
  @State statIdle: number = 0;
  @State statRest: number = 0;
  @State showTeam: boolean = false;   // 团队栏默认关，顶栏人像按钮打开
  @State inspector: Inspector = 'employee';
  @State mode: Mode = 'terminal';
  @State sheet: Sheet = 'none';
  @State probing: boolean = false;
  // 终端
  @State cols: number = 80;
  @State rows: number = 24;
  @State fontSize: number = 12;
  @State inputBuf: string = '';
  // 语音条（沿用手机版 dock 的按住说话 / 轻点打字）
  @State toolsGroup: number = 0;        // 0 = 功能, 1 = 键盘（iOS groupSeg）
  @State fieldMode: string = 'idle';    // idle | recording | busy | review
  @State reviewText: string = '';
  @State recording: boolean = false;
  @State showManualInput: boolean = false;
  @State manualText: string = '';
  // 对话记录
  @State chatName: string = '';
  @State chatRefreshing: boolean = false;
  // 新建会话
  @State ntMachineId: string = '';
  @State ntWorkDirId: string = '';
  @State ntSession: string = '';

  private store: BlinkStore = new BlinkStore();
  private pool: ConnPool = new ConnPool();
  private sync: CfgSync = new CfgSync(this.store, (): boolean => this.tsState === 'Running',
    (cfg: SeedConfig, stamp: number): Promise<void> => this.applySyncedConfig(cfg, stamp));
  private b64: util.Base64Helper = new util.Base64Helper();
  private win: window.Window | null = null;
  private webCtl: webview.WebviewController = new webview.WebviewController();
  private jsBridge: JsBridge = new JsBridge((op: string, data: string): void => { this.onBridge(op, data); });
  private tsPrefs: preferences.Preferences | null = null;
  private uiPrefs: preferences.Preferences | null = null;
  private timer: number = -1;
  private lastVpnKick: number = 0;
  private tsError: string = '';       // VPN 扩展写进状态文件的失败原因
  private lastTsNote: string = '';
  private termReady: boolean = false;
  private pendingNotes: string[] = [];
  private lastLen: number = 0;
  private skipNext: boolean = false;
  private panMode: string = '';
  private lastPanY: number = 0;
  private lastTabPerMachine: Record<string, string> = {};
  private recorder: VoiceRecorder = new VoiceRecorder();
  private avatarCache: Map<string, image.PixelMap> = new Map();
  private avatarB64Cache: Map<string, string> = new Map();
  // 状态探测
  private probeByMachine: Map<string, Map<string, WorkStatus>> = new Map();
  private lastProbe: number = 0;
  private probeBusy: boolean = false;
  // 对话记录
  private chatWebCtl: webview.WebviewController = new webview.WebviewController();
  private chatUrl: string = 'about:blank';
  private chatSeq: number = 0;
  private chatTabId: string = '';
  private chatAvatarURI: string = '';
  private chatBridge: ChatBridge = new ChatBridge();
  private chatFetchToken: number = 0;

  // ===========================================================================
  // lifecycle
  // ===========================================================================

  aboutToAppear(): void {
    try {
      TailscaleCore.version();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'core self-test: %{public}s', `${e}`);
    }
    this.setupWindow();
    this.boot();
  }

  aboutToDisappear(): void {
    this.sync.close();
    this.pool.closeAll();
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.win !== null) {
      try {
        this.win.off('keyboardHeightChange');
      } catch (e) {
      }
    }
  }

  onPageShow(): void {
    this.sync.forcePull();
    this.lastProbe = 0;
  }

  private async boot(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.tsPrefs = await preferences.getPreferences(ctx, 'ts_prefs');
    this.uiPrefs = await preferences.getPreferences(ctx, 'ui_prefs');
    this.sync.uiPrefs = this.uiPrefs;
    this.authKey = await this.tsPrefs.get('authKey', '') as string;
    this.hostname = await this.tsPrefs.get('hostname', 'harmony-pad') as string;
    this.fontSize = await this.uiPrefs.get('fontSize', 12) as number;
    this.showTeam = await this.uiPrefs.get('showTeam', false) as boolean;
    await this.store.load(ctx);
    this.store.onLocalChange = (): void => {
      this.sync.notifyChanged();
    };
    // 当前机器：store 里记的筛选机器，没有就第一台
    let mid: string = this.store.filterMachineId;
    if (this.store.machineById(mid) === null) {
      mid = this.store.machines.length > 0 ? this.store.machines[0].id : '';
    }
    this.activeMachineId = mid;
    const cur = this.store.tabById(this.store.currentTabId);
    if (cur !== null && cur.machineId === mid) {
      this.activeTabId = cur.id;
    } else {
      const rows = this.rowsForMachine(mid);
      this.activeTabId = rows.length > 0 ? rows[0].id : '';
    }
    this.storeReady = true;
    this.refreshAll();
    this.preloadAvatars(ctx);
    this.appendLocal('Blink Pad · ' + this.store.machines.length + ' 台机器 · ' + this.store.tabs.length + ' 个会话');
    if (this.authKey.length > 0) {
      this.appendLocal('\u001b[90m· 正在连接 tailscale …\u001b[0m');
      this.tsConnect();
    } else {
      this.appendLocal('\u001b[33m⚙ 右上角设置里填 tailscale auth key，之后自动连接\u001b[0m');
    }
  }

  private setupWindow(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    window.getLastWindow(this.getUIContext().getHostContext()).then((w: window.Window) => {
      this.win = w;
      w.on('keyboardHeightChange', (h: number) => {
        this.kbHeight = px2vp(h);
        if (h === 0 && this.kbWanted) {
          // 软键盘收起：回到「聚焦但不弹键盘」，外接键盘继续能打字
          this.kbWanted = false;
        }
      });
      w.setWindowLayoutFullScreen(true).catch((): void => {});
      w.setWindowSystemBarProperties({ statusBarContentColor: '#F2F2F2' }).catch((): void => {});
      const sys = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInset = px2vp(sys.topRect.height);
      const nav = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.botInset = px2vp(nav.bottomRect.height);
    }).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'window: %{public}s', JSON.stringify(e));
    });
  }

  // ===========================================================================
  // 视图模型
  // ===========================================================================

  private rowsForMachine(mid: string): TabModel[] {
    const out: TabModel[] = [];
    for (let i = 0; i < this.store.tabs.length; i++) {
      const t = this.store.tabs[i];
      if (t.machineId !== mid) {
        continue;
      }
      // 侧栏只放在岗会话（同 mac sidebarSessions）；当前选中的即使在休息也留着，不让终端悬空
      if (this.store.isResting(t.id) && t.id !== this.activeTabId) {
        continue;
      }
      out.push(t);
    }
    // 排序跟 macOS 侧栏 / iOS tab 栏一致：按 (项目, 员工)，完全相同保持原序
    const keyed: TabModel[] = out.slice();
    keyed.sort((a: TabModel, b: TabModel) => {
      const ka: string[] = this.projectOwner(a);
      const kb: string[] = this.projectOwner(b);
      if (ka[0] !== kb[0]) {
        return ka[0] < kb[0] ? -1 : 1;
      }
      if (ka[1] !== kb[1]) {
        return ka[1] < kb[1] ? -1 : 1;
      }
      return out.indexOf(a) - out.indexOf(b);
    });
    return keyed;
  }

  /// [项目, 员工]：cc 标题按 iOS BlinkMachineStore.ccTitle 的规则算（工作目录显示名小写 + 会话名），
  /// 再在第一个 "-" 处切开，同 mac Session.owner / project。
  private projectOwner(t: TabModel): string[] {
    const m = this.store.machineById(t.machineId);
    const w = this.store.workDirById(t.workDirId);
    let session: string = t.tmuxSession.length > 0 ? t.tmuxSession
      : (t.workDirId.length > 0 ? 'blink-' + t.workDirId.substring(0, 8) : 'blink');
    session = session.toLowerCase();
    let dir: string;
    if (w !== null && w.name.length > 0) {
      dir = w.name.toLowerCase().replace(new RegExp('"', 'g'), '').replace(new RegExp(' ', 'g'), '-');
    } else if (w !== null && w.path.length > 0) {
      const parts: string[] = w.path.split('/');
      dir = parts[parts.length - 1].toLowerCase().replace(new RegExp('"', 'g'), '').replace(new RegExp(' ', 'g'), '-');
    } else {
      dir = m !== null ? m.user.toLowerCase() : '';
    }
    const name: string = (session === dir || session.startsWith(dir + '-')) ? session : (dir + '-' + session);
    const i: number = name.indexOf('-');
    return i >= 0 ? [name.substring(i + 1), name.substring(0, i)] : [name, name];
  }

  private ccFor(t: TabModel): string {
    const m = this.store.machineById(t.machineId);
    const w = this.store.workDirById(t.workDirId);
    return 'cc-' + BlinkStore.titleFor(w !== null ? w.path : '', t.tmuxSession, m !== null ? m.user : '');
  }

  private tabStatus(t: TabModel): WorkStatus {
    if (this.store.isResting(t.id)) {
      return 'rest';
    }
    const mm = this.probeByMachine.get(t.machineId);
    if (mm === undefined) {
      return 'none';
    }
    const st = mm.get(this.ccFor(t));
    return st !== undefined ? st : 'none';
  }

  private rowFor(t: TabModel): SessRow {
    const w = this.store.workDirById(t.workDirId);
    const st: WorkStatus = this.tabStatus(t);
    let project: string = t.tmuxSession;
    const idx: number = project.lastIndexOf('-');
    if (idx >= 0) {
      project = project.substring(idx + 1);
    }
    const owner: string = w !== null && w.name.length > 0 ? w.name : '其他';
    if (project === owner || project.length === 0) {
      project = owner;
    }
    const conn = this.pool.get(t.id);
    let label: string = PadProbe.label(st);
    if (st === 'none' && !this.probeByMachine.has(t.machineId)) {
      label = '—';
    }
    const r: SessRow = {
      tabId: t.id,
      machineId: t.machineId,
      workDirId: t.workDirId,
      name: this.store.tabTitle(t),
      cc: this.ccFor(t),
      owner: owner,
      project: project,
      dir: w !== null ? w.path.replace(new RegExp('^/Users/[^/]+'), '~') : '',
      status: st,
      statusLabel: label,
      resting: this.store.isResting(t.id),
      unread: conn !== null && conn.unread && t.id !== this.activeTabId,
    };
    return r;
  }

  private groupSummary(rows: SessRow[]): string {
    let w: number = 0;
    let r: number = 0;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].status === 'wait') {
        w++;
      } else if (rows[i].status === 'rest') {
        r++;
      }
    }
    let s: string = rows.length + ' 会话';
    if (w > 0) {
      s += ' · ' + w + ' 等你';
    }
    if (r > 0) {
      s += ' · ' + r + ' 休息';
    }
    return s;
  }

  private buildGroups(): TeamGroupVM[] {
    const order: string[] = [];
    const map: Map<string, SessRow[]> = new Map();
    const titles: Map<string, string> = new Map();
    const avatars: Map<string, string> = new Map();
    for (let i = 0; i < this.store.tabs.length; i++) {
      const t = this.store.tabs[i];
      if (this.inspector !== 'machine' && t.machineId !== this.activeMachineId) {
        continue;
      }
      const row: SessRow = this.rowFor(t);
      let key: string;
      if (this.inspector === 'employee') {
        key = row.owner;
        if (!avatars.has(key)) {
          avatars.set(key, row.workDirId);
        }
      } else if (this.inspector === 'project') {
        key = row.project;
      } else {
        key = t.machineId;
        const m = this.store.machineById(t.machineId);
        titles.set(key, m !== null ? this.store.machineDisplayName(m) : t.machineId);
      }
      if (!map.has(key)) {
        order.push(key);
        map.set(key, []);
      }
      map.get(key)!.push(row);
    }
    const out: TeamGroupVM[] = [];
    for (let i = 0; i < order.length; i++) {
      const k: string = order[i];
      const rows: SessRow[] = map.get(k)!;
      rows.sort((a: SessRow, b: SessRow) => a.name.localeCompare(b.name));
      const title: string = titles.has(k) ? titles.get(k)! : k;
      out.push({
        key: k,
        title: title,
        sub: this.groupSummary(rows),
        avatarWorkDirId: avatars.has(k) ? avatars.get(k)! : '',
        rows: rows,
      });
    }
    if (this.inspector !== 'machine') {
      out.sort((a: TeamGroupVM, b: TeamGroupVM) => a.title.localeCompare(b.title));
    }
    return out;
  }

  private machineInitials(name: string): string {
    const parts: string[] = name.trim().split(new RegExp('\\s+'));
    if (parts.length >= 2 && parts[1].length > 0) {
      return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
    }
    return name.substring(0, 1).toUpperCase();
  }

  /// store / 连接 / 探测结果变了之后统一刷新所有 @State 视图模型
  private refreshAll(): void {
    const ms: MachineVM[] = [];
    for (let i = 0; i < this.store.machines.length; i++) {
      const m = this.store.machines[i];
      let waiting: number = 0;
      for (let j = 0; j < this.store.tabs.length; j++) {
        const t = this.store.tabs[j];
        if (t.machineId === m.id && this.tabStatus(t) === 'wait') {
          waiting++;
        }
      }
      const g: string[] = GRADS[i % GRADS.length];
      ms.push({
        id: m.id,
        name: this.store.machineDisplayName(m),
        initials: this.machineInitials(this.store.machineDisplayName(m)),
        g1: g[0],
        g2: g[1],
        waiting: waiting,
      });
    }
    this.machinesVM = ms;
    const side: SessRow[] = [];
    const tabs: TabModel[] = this.rowsForMachine(this.activeMachineId);
    for (let i = 0; i < tabs.length; i++) {
      side.push(this.rowFor(tabs[i]));
    }
    this.sideRows = side;
    let w: number = 0;
    let k: number = 0;
    let d: number = 0;
    let r: number = 0;
    for (let i = 0; i < this.store.tabs.length; i++) {
      const t = this.store.tabs[i];
      if (t.machineId !== this.activeMachineId) {
        continue;
      }
      const st: WorkStatus = this.tabStatus(t);
      if (st === 'wait') {
        w++;
      } else if (st === 'work') {
        k++;
      } else if (st === 'rest') {
        r++;
      } else {
        d++;
      }
    }
    this.statWait = w;
    this.statWork = k;
    this.statIdle = d;
    this.statRest = r;
    this.teamGroups = this.buildGroups();
    this.tick++;
  }

  // ===========================================================================
  // 终端 I/O
  // ===========================================================================

  private appendLocal(s: string): void {
    if (this.activeTabId.length === 0) {
      return;
    }
    if (!this.termReady) {
      this.pendingNotes.push(s);   // hterm 页面还没加载完，写进去会丢
      return;
    }
    this.writeText(this.activeTabId, s + '\r\n');
  }

  private writeText(tabId: string, s: string): void {
    const b64: string = buffer.from(s, 'utf-8').toString('base64');
    this.webCtl.runJavaScript(`term_write_b64('${tabId}','${b64}')`);
  }

  private writeBytes(tabId: string, bytes: Uint8Array): void {
    this.webCtl.runJavaScript(`term_write_b64('${tabId}','${this.b64.encodeToStringSync(bytes)}')`);
  }

  private note(tabId: string, conn: SessionConn | null, s: string, dedupe: boolean): void {
    if (dedupe && conn !== null && conn.lastNote === s) {
      return;
    }
    if (conn !== null) {
      conn.lastNote = s;
    }
    this.writeText(tabId, s + '\r\n');
  }

  private briefReason(st: BlinkdState, detail: string): string {
    if (st === 'error' && detail.length > 0 && detail.charAt(0) === '{') {
      try {
        const j = JSON.parse(detail) as Record<string, Object>;
        const msg: string = j['message'] !== undefined ? (j['message'] as string) : '';
        const code: number = j['code'] !== undefined ? (j['code'] as number) : -1;
        if (msg.length > 0) {
          return code >= 0 ? (msg + '（code ' + code + '）') : msg;
        }
      } catch (e) {
      }
    }
    return detail;
  }

  private noteTsState(state: string): void {
    let line: string;
    if (state === 'Running') {
      line = '\u001b[32m✓ tailscale 已连接' + (this.tsIP.length > 0 ? ('（' + this.tsIP + '）') : '') + '\u001b[0m';
    } else if (state === 'Stopped') {
      line = '\u001b[33m⚠ tailscale 已停止，正在重连…\u001b[0m';
    } else if (state === 'NeedsLogin' || state === 'NoState') {
      line = '\u001b[33m⚠ tailscale 需要登录，去设置里填 auth key\u001b[0m';
    } else if (state === 'VpnFailed') {
      line = '\u001b[31m✗ ' + (this.tsError.length > 0 ? this.tsError : 'VPN 启动失败') + '，正在重试…\u001b[0m';
    } else if (state === 'start failed') {
      line = '\u001b[31m✗ tailscale 启动失败\u001b[0m';
    } else {
      line = '\u001b[90m· tailscale ' + state + ' …\u001b[0m';
    }
    if (line === this.lastTsNote) {
      return;
    }
    this.lastTsNote = line;
    this.appendLocal(line);
  }

  private onBridge(op: string, dataStr: string): void {
    if (op === 'sigwinch') {
      try {
        const d = JSON.parse(dataStr) as Record<string, number>;
        const c: number = d.cols as number;
        const r: number = d.rows as number;
        if (c > 0 && r > 0 && (c !== this.cols || r !== this.rows)) {
          this.cols = c;
          this.rows = r;
          // 所有图层共用一个几何尺寸：侧栏/团队栏开合时每条已连接会话都要跟着 resize
          this.pool.all().forEach((conn: SessionConn) => {
            if (conn.state === 'connected') {
              conn.client.sendResize(r, c);
            }
          });
        }
      } catch (e) {
      }
    } else if (op === 'ready') {
      this.webCtl.runJavaScript(`term_set_colors('${TERM}','#F0F0F0','rgba(63,222,233,0.55)')`);
      this.webCtl.runJavaScript(`term_setFontSize(${this.fontSize})`);
      if (this.activeTabId.length > 0) {
        this.webCtl.runJavaScript(`term_show('${this.activeTabId}')`);
      }
      this.termReady = true;
      const q: string[] = this.pendingNotes;
      this.pendingNotes = [];
      for (let i = 0; i < q.length; i++) {
        this.appendLocal(q[i]);
      }
      this.focusTerm();
    } else if (op === 'error') {
      hilog.error(DOMAIN, TAG, 'hterm: %{public}s', dataStr);
    } else if (op === 'wheel') {
      this.sendWheel(dataStr);
    }
  }

  private sendWheel(dataStr: string): void {
    const client = this.activeClient();
    if (client === null) {
      return;
    }
    try {
      const d = JSON.parse(dataStr) as Record<string, number>;
      const btn: number = d.btn as number;
      const lines: number = Math.min(d.lines as number, 8);
      let s: string = '';
      for (let i = 0; i < lines; i++) {
        s += `\x1b[<${btn};40;10M`;
      }
      client.sendInput(s);
    } catch (e) {
    }
  }

  // ===========================================================================
  // tailscale
  // ===========================================================================

  private filesDir(): string {
    return (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir;
  }

  private buildWant(): Want {
    return {
      deviceId: '',
      bundleName: BUNDLE,
      abilityName: 'PadVpnAbility',
      parameters: {
        stateDir: this.filesDir(),
        hostname: this.hostname.length > 0 ? this.hostname : 'harmony-pad',
        controlURL: '',
        authKey: this.authKey,
      },
    };
  }

  private tsConnect(): void {
    vpnExtension.startVpnExtensionAbility(this.buildWant()).then(() => {
      this.tsConnected = true;
      this.tsState = 'Starting';
      this.startPolling();
      this.startKeepAlive();
    }).catch((e: Object) => {
      this.tsState = 'start failed';
      hilog.error(DOMAIN, TAG, 'startVpn: %{public}s', JSON.stringify(e));
    });
  }

  private tsDisconnect(): void {
    vpnExtension.stopVpnExtensionAbility(this.buildWant()).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'stopVpn: %{public}s', JSON.stringify(e));
    });
    this.stopKeepAlive();
    this.tsConnected = false;
    this.tsState = '';
    this.tsIP = '';
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private async startKeepAlive(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: BUNDLE, abilityName: 'PadAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      const wa = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, wa);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startKeepAlive: %{public}s', `${e}`);
    }
  }

  private async stopKeepAlive(): Promise<void> {
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.getUIContext().getHostContext() as common.UIAbilityContext);
    } catch (e) {
    }
  }

  private startPolling(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
    }
    this.timer = setInterval(() => {
      this.vpnWatchdog();
      const s: string = StatusStore.read(this.filesDir());
      try {
        const j = JSON.parse(s) as Record<string, Object>;
        const state = j['backendState'] as string;
        this.tsState = state ? state : 'Starting';
        const ips = j['tailscaleIPs'] as string[];
        this.tsIP = (ips && ips.length > 0) ? ips[0] : '';
        const errS = j['error'] as string;
        this.tsError = errS ? errS : '';
        this.noteTsState(this.tsState);
        if (state === 'Running') {
          if (this.activeTabId.length > 0) {
            this.attach(this.activeTabId, false);
          }
          this.sync.tick();
          if (Date.now() - this.lastProbe > 12000) {
            this.probeAll();
          }
        }
      } catch (e) {
      }
    }, 1500);
  }

  // 息屏/省电时系统会杀 :vpn 扩展进程，status 文件停更但内容还是旧 Running：8s 没动即重拉扩展
  private vpnWatchdog(): void {
    if (this.authKey.length === 0) {
      return;
    }
    try {
      const st = fs.statSync(StatusStore.path(this.filesDir()));
      const age: number = Date.now() - st.mtime * 1000;
      // 扩展报告了启动失败（VpnFailed）时它自己在退避重试（最长 60s 一轮），别当成卡死去重拉
      const staleMs: number = this.tsState === 'VpnFailed' ? 90000 : 8000;
      if (age > staleMs && Date.now() - this.lastVpnKick > 15000) {
        this.lastVpnKick = Date.now();
        this.tsState = 'Restarting VPN';
        hilog.warn(DOMAIN, TAG, 'ts status stale %{public}d ms, restarting vpn ext', age);
        // 先 stop 再 start：扩展进程若还活着（比如 onCreate 里失败了），单纯 start 只会触发
        // onRequest，onCreate 不会重跑，状态文件永远不更新 → 每 15s 误判一次死循环。
        const want: Want = this.buildWant();
        vpnExtension.stopVpnExtensionAbility(want).catch((): void => {}).finally((): void => {
          setTimeout(() => {
            vpnExtension.startVpnExtensionAbility(this.buildWant()).catch((e: Object) => {
              hilog.error(DOMAIN, TAG, 'vpn rekick: %{public}s', JSON.stringify(e));
            });
          }, 800);
        });
        this.pool.all().forEach((c: SessionConn) => {
          c.failCount = 0;
          c.cooldownUntil = 0;
          c.client.close();
        });
        this.sync.dropWatcher();
      }
    } catch (e) {
    }
  }

  // ===========================================================================
  // 状态探测
  // ===========================================================================

  private probeAll(): void {
    if (this.probeBusy || this.tsState !== 'Running') {
      return;
    }
    this.probeBusy = true;
    this.probing = true;
    this.lastProbe = Date.now();
    const jobs: Promise<void>[] = [];
    for (let i = 0; i < this.store.machines.length; i++) {
      const m: Machine = this.store.machines[i];
      const ep: Endpoint | null = PadExec.endpointFor(this.store, m);
      if (ep === null) {
        continue;
      }
      const mid: string = m.id;
      jobs.push(PadExec.run(ep, PadExec.wrapForMachine(m, PROBE_SCRIPT), 20000, '@TSB64E@')
        .then((raw: string): void => {
          const map = PadProbe.parse(raw);
          if (map !== null) {
            this.probeByMachine.set(mid, map);
          }
        }));
    }
    Promise.all(jobs).then((): void => {
      this.probeBusy = false;
      this.probing = false;
      this.refreshAll();
    }).catch((): void => {
      this.probeBusy = false;
      this.probing = false;
    });
  }

  private probeNow(): void {
    if (this.tsState !== 'Running') {
      this.toast('tailscale 还没连上');
      return;
    }
    this.lastProbe = 0;
    this.probeAll();
  }

  // ===========================================================================
  // 连接
  // ===========================================================================

  private attach(tabId: string, force: boolean): void {
    const tab = this.store.tabById(tabId);
    if (tab === null) {
      return;
    }
    const conn = this.pool.getOrCreate(tabId);
    const m = this.store.machineById(tab.machineId);
    const ep = this.store.blinkdEndpoint(m);
    if (ep === null || ep.blinkdHost === undefined || ep.blinkdToken === undefined) {
      this.note(tabId, conn, '\u001b[33m⚠ 这台机器没配 blinkd 端点，去设置里填 host / token\u001b[0m', true);
      return;
    }
    if (!force && (conn.state === 'connected' || conn.state === 'connecting')) {
      return;
    }
    if (!force && Date.now() < conn.cooldownUntil) {
      return;
    }
    const port: number = ep.blinkdPort !== undefined ? ep.blinkdPort : 7777;
    this.note(tabId, conn, '\u001b[90m[blink] 连接 ' + ep.blinkdHost + ':' + port + ' …\u001b[0m', false);
    conn.client.onData = (bytes: Uint8Array) => {
      this.writeBytes(tabId, bytes);
      if (tabId !== this.activeTabId && !conn.unread) {
        conn.unread = true;
        this.refreshAll();
      }
    };
    conn.client.onState = (st: BlinkdState, detail: string) => {
      this.onConnState(tabId, st, detail);
    };
    this.webCtl.runJavaScript(`term_create('${tabId}')`);
    conn.state = 'connecting';
    this.tick++;
    conn.client.connect(ep.blinkdHost, port, ep.blinkdToken, this.rows, this.cols, this.store.execForTab(tab));
  }

  private onConnState(tabId: string, st: BlinkdState, detail: string): void {
    const conn = this.pool.get(tabId);
    if (conn === null) {
      return;
    }
    if (st === 'connecting') {
      conn.state = 'connecting';
    } else if (st === 'connected') {
      conn.state = 'connected';
      conn.connectedAt = Date.now();
      conn.everConnected = true;
      this.note(tabId, conn, '\u001b[32m✓ 已连接\u001b[0m', false);
    } else if (st === 'closed' || st === 'error') {
      const lasted: number = conn.connectedAt > 0 ? (Date.now() - conn.connectedAt) : 0;
      conn.connectedAt = 0;
      conn.state = st;
      let reason: string = this.briefReason(st, detail);
      if (reason === '连接已关闭' || reason === '已连上 blinkd') {
        reason = '';
      }
      const why: string = reason.length > 0 ? ('：' + reason) : '';
      const verb: string = conn.everConnected ? '连接断开' : '连接失败';
      if (this.store.autoReconnect) {
        if (lasted > 10000) {
          conn.failCount = 0;
          conn.cooldownUntil = 0;
          this.note(tabId, conn, '\u001b[33m⚠ ' + verb + why + '，正在重连…\u001b[0m', false);
        } else {
          conn.failCount++;
          const wait: number = Math.min(1500 * Math.pow(2, conn.failCount), 30000);
          conn.cooldownUntil = Date.now() + wait;
          this.note(tabId, conn, '\u001b[33m⚠ ' + verb + why + '，' + Math.round(wait / 1000) +
            ' 秒后自动重连（第 ' + conn.failCount + ' 次）\u001b[0m', false);
        }
      } else {
        this.note(tabId, conn, '\u001b[33m⚠ ' + verb + why + '（自动重连已关，点刷新重连）\u001b[0m', false);
      }
    }
    this.tick++;
  }

  private connState(tabId: string): ConnUiState {
    const c = this.pool.get(tabId);
    return c !== null ? c.state : 'idle';
  }

  private activeClient(): BlinkdClient | null {
    const c = this.pool.get(this.activeTabId);
    return (c !== null && c.state === 'connected') ? c.client : null;
  }

  // ===========================================================================
  // 选择 / 会话操作
  // ===========================================================================

  private selectMachine(mid: string): void {
    if (mid === this.activeMachineId) {
      return;
    }
    if (this.activeTabId.length > 0) {
      const cur = this.store.tabById(this.activeTabId);
      if (cur !== null) {
        this.lastTabPerMachine[cur.machineId] = this.activeTabId;
      }
    }
    this.activeMachineId = mid;
    this.store.filterMachineId = mid;
    this.store.saveFilter();
    // 记住上次在这台机器点的会话（同 mac selectMachine），没了才回第一个
    const tabs: TabModel[] = this.rowsForMachine(mid);
    const remembered: string | undefined = this.lastTabPerMachine[mid];
    let target: string = '';
    if (remembered !== undefined && tabs.some((t: TabModel) => t.id === remembered)) {
      target = remembered;
    } else if (tabs.length > 0) {
      target = tabs[0].id;
    }
    if (target.length > 0) {
      this.switchTab(target);
    } else {
      this.activeTabId = '';
      this.refreshAll();
    }
  }

  private switchTab(tabId: string): void {
    const tab = this.store.tabById(tabId);
    if (tab === null) {
      return;
    }
    if (tab.machineId !== this.activeMachineId) {
      this.activeMachineId = tab.machineId;
      this.store.filterMachineId = tab.machineId;
      this.store.saveFilter();
    }
    this.lastTabPerMachine[tab.machineId] = tabId;
    if (this.mode === 'chat') {
      this.closeChat();
    }
    if (tabId !== this.activeTabId) {
      this.activeTabId = tabId;
      this.store.currentTabId = tabId;
      this.store.saveCurrent();
      this.inputBuf = '';
      this.lastLen = 0;
      this.webCtl.runJavaScript(`term_show('${tabId}')`);
      const conn = this.pool.get(tabId);
      if (conn !== null) {
        conn.unread = false;
        if (conn.state !== 'connected' && conn.state !== 'connecting') {
          conn.failCount = 0;
          conn.cooldownUntil = 0;
        }
      }
      if (this.tsState === 'Running') {
        this.attach(tabId, false);
      }
    }
    this.refreshAll();
    this.focusTerm();
  }

  private newTab(): void {
    if (this.ntMachineId.length === 0 || this.ntWorkDirId.length === 0) {
      this.toast('先选机器和工作目录');
      return;
    }
    const t: TabModel = {
      id: BlinkStore.newId(),
      machineId: this.ntMachineId,
      workDirId: this.ntWorkDirId,
      tmuxSession: this.ntSession.trim().length > 0 ? this.ntSession.trim() : 'new',
      useTmux: true,
    };
    this.store.tabs.push(t);
    this.store.saveTabs();
    this.sheet = 'none';
    this.switchTab(t.id);
  }

  private openNewTab(): void {
    this.ntMachineId = this.activeMachineId.length > 0 ? this.activeMachineId
      : (this.store.machines.length > 0 ? this.store.machines[0].id : '');
    this.ntWorkDirId = this.store.workDirs.length > 0 ? this.store.workDirs[0].id : '';
    this.ntSession = '';
    this.sheet = 'newTab';
  }

  private confirmClose(tabId: string): void {
    const t = this.store.tabById(tabId);
    if (t === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '关闭标签',
      message: '关闭「' + this.store.tabTitle(t) + '」？（只关本机标签，远端 tmux 会话仍在）',
      primaryButton: { value: '关闭', fontColor: RED, action: () => this.closeTab(tabId) },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private closeTab(tabId: string): void {
    const t = this.store.tabById(tabId);
    const mid: string = t !== null ? t.machineId : this.activeMachineId;
    this.pool.remove(tabId);
    this.webCtl.runJavaScript(`term_dispose('${tabId}')`);
    const idx: number = this.store.tabs.findIndex((x: TabModel) => x.id === tabId);
    if (idx >= 0) {
      this.store.tabs.splice(idx, 1);
    }
    if (this.store.closedIds.indexOf(tabId) < 0) {
      this.store.closedIds.push(tabId);
      while (this.store.closedIds.length > 500) {
        this.store.closedIds.shift();
      }
      this.store.saveClosed();
    }
    this.store.saveTabs();
    if (this.activeTabId === tabId) {
      this.activeTabId = '';
      const rest: TabModel[] = this.rowsForMachine(mid);
      if (rest.length > 0) {
        this.switchTab(rest[0].id);
        return;
      }
    }
    this.refreshAll();
  }

  private toggleRest(tabId: string): void {
    const nowResting: boolean = this.store.toggleResting(tabId);
    this.toast(nowResting ? '已标记休息' : '已唤醒（在岗）');
    if (nowResting && tabId === this.activeTabId) {
      // 当前会话去休息：落到同机器下一个在岗会话（没有就留在原地）
      const t = this.store.tabById(tabId);
      if (t !== null) {
        const tabs = this.store.tabs;
        const pos: number = tabs.findIndex((x: TabModel) => x.id === tabId);
        for (let step = 1; step < tabs.length; step++) {
          const cand = tabs[(pos + step) % tabs.length];
          if (cand.machineId === t.machineId && !this.store.isResting(cand.id)) {
            this.switchTab(cand.id);
            return;
          }
        }
      }
    }
    this.refreshAll();
  }

  private reconnectActive(): void {
    if (this.activeTabId.length === 0) {
      return;
    }
    const conn = this.pool.get(this.activeTabId);
    if (conn !== null) {
      conn.failCount = 0;
      conn.cooldownUntil = 0;
      conn.client.close();
    }
    this.webCtl.runJavaScript(`term_clear('${this.activeTabId}')`);
    if (this.tsState === 'Running') {
      this.attach(this.activeTabId, true);
    } else {
      this.toast('tailscale 还没连上');
    }
  }

  private async applySyncedConfig(cfg: SeedConfig, stamp: number): Promise<void> {
    await this.store.applySync(cfg);
    this.pool.all().forEach((c: SessionConn) => {
      if (this.store.tabById(c.tabId) === null) {
        this.pool.remove(c.tabId);
        this.webCtl.runJavaScript(`term_dispose('${c.tabId}')`);
      }
    });
    if (this.store.machineById(this.activeMachineId) === null) {
      this.activeMachineId = this.store.machines.length > 0 ? this.store.machines[0].id : '';
    }
    if (this.store.tabById(this.activeTabId) === null) {
      this.activeTabId = '';
      const rows = this.rowsForMachine(this.activeMachineId);
      if (rows.length > 0) {
        this.switchTab(rows[0].id);
      }
    }
    this.refreshAll();
    this.preloadAvatars(this.getUIContext().getHostContext() as common.UIAbilityContext);
    hilog.info(DOMAIN, TAG, 'cfg synced (stamp %{public}d): %{public}d machines %{public}d tabs',
      stamp, cfg.machines.length, cfg.tabs.length);
    this.toast('配置已同步');
  }

  // ===========================================================================
  // 输入
  // ===========================================================================

  private focusTerm(): void {
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('termInput');
      } catch (e) {
      }
    }, 80);
  }

  private hideKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
    }
    this.kbWanted = false;
    this.focusTerm();
  }

  private onInput(v: string): void {
    if (this.skipNext) {
      this.skipNext = false;
      this.lastLen = v.length;
      return;
    }
    const client = this.activeClient();
    if (client === null) {
      this.lastLen = v.length;
      return;
    }
    if (v.length > this.lastLen) {
      client.sendInput(v.substring(this.lastLen));
    } else if (v.length < this.lastLen) {
      const dels = new Uint8Array(this.lastLen - v.length);
      dels.fill(0x7f);
      client.sendBytes(dels);
    }
    this.lastLen = v.length;
  }

  private submitLine(): void {
    const client = this.activeClient();
    if (client !== null) {
      client.sendInput('\r');
    }
    this.skipNext = true;
    this.inputBuf = '';
    this.lastLen = 0;
  }

  // 外接键盘：方向键 / Esc / Tab / Shift-Tab / Ctrl+字母 / 空行退格 直接转 VT 字节。
  // 可打印字符仍走输入法 → onChange，回车走 onSubmit。
  private onHwKey(e: KeyEvent): void {
    if (e.type !== KeyType.Down) {
      return;
    }
    const client = this.activeClient();
    if (client === null) {
      return;
    }
    const k: number = e.keyCode;
    let ctrl: boolean = false;
    let shift: boolean = false;
    if (e.getModifierKeyState !== undefined) {
      try {
        ctrl = e.getModifierKeyState!(['Ctrl']);
        shift = e.getModifierKeyState!(['Shift']);
      } catch (err) {
      }
    }
    let seq: number[] = [];
    if (k === 2012) {
      seq = [0x1b, 0x5b, 0x41];
    } else if (k === 2013) {
      seq = [0x1b, 0x5b, 0x42];
    } else if (k === 2015) {
      seq = [0x1b, 0x5b, 0x43];
    } else if (k === 2014) {
      seq = [0x1b, 0x5b, 0x44];
    } else if (k === 2070) {
      seq = [0x1b];
    } else if (k === 2049) {
      seq = shift ? [0x1b, 0x5b, 0x5a] : [0x09];
    } else if (ctrl && k >= 2017 && k <= 2042) {
      seq = [k - 2017 + 1];
    } else if (k === 2055 && this.lastLen === 0) {
      seq = [0x7f];
    }
    if (seq.length > 0) {
      client.sendBytes(new Uint8Array(seq));
      e.stopPropagation();
    }
  }

  private sendKey(bytes: number[]): void {
    const client = this.activeClient();
    if (client !== null) {
      client.sendBytes(new Uint8Array(bytes));
    }
  }

  // 发一整行 + 回车：回车延迟一拍，避免 claude 把紧跟的回车并进粘贴内容
  private sendLine(text: string): void {
    const client = this.activeClient();
    if (client === null) {
      this.toast('当前会话未连接');
      return;
    }
    client.sendInput(text);
    setTimeout(() => {
      const c = this.activeClient();
      if (c !== null) {
        c.sendInput('\r');
      }
    }, 180);
  }

  private commitLine(text: string): void {
    const t: string = text.trim();
    if (t.length === 0) {
      return;
    }
    this.sendLine(t);
    setTimeout(() => {
      const c = this.activeClient();
      if (c !== null) {
        c.sendInput('\r');
      }
    }, 400);
    this.store.history.push(t);
    if (this.store.history.length > 40) {
      this.store.history.shift();
    }
    this.store.saveHistory();
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1600 });
    } catch (e) {
    }
  }

  private useFavorite(text: string): void {
    this.sendLine(text);
    const c = this.store.favoriteCounts[text];
    this.store.favoriteCounts[text] = (c !== undefined ? c : 0) + 1;
    this.store.saveFavorites();
    this.sheet = 'none';
    this.focusTerm();
  }

  private sortedFavorites(): string[] {
    const out: string[] = this.store.favorites.slice();
    out.sort((a: string, b: string) => {
      const ca = this.store.favoriteCounts[a];
      const cb = this.store.favoriteCounts[b];
      return (cb !== undefined ? cb : 0) - (ca !== undefined ? ca : 0);
    });
    return out;
  }

  private reversedHistory(): string[] {
    const out: string[] = [];
    for (let i = this.store.history.length - 1; i >= 0; i--) {
      out.push(this.store.history[i]);
    }
    return out;
  }

  private async pasteClipboard(): Promise<void> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const text: string = data.getPrimaryText();
      if (text && text.length > 0) {
        const c = this.activeClient();
        if (c !== null) {
          c.sendInput(text);
        }
      } else {
        this.toast('剪贴板没有文本');
      }
    } catch (e) {
      this.toast('粘贴失败');
    }
  }

  private async pickAndUploadImage(): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const res = await picker.select({ MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: 1 });
      if (res.photoUris.length === 0) {
        return;
      }
      this.toast('上传图片中…');
      const url: string = await Uploader.uploadImage(res.photoUris[0], 'image.png');
      const c = this.activeClient();
      if (c !== null) {
        c.sendInput(url);
      }
    } catch (e) {
      this.toast('图片上传失败: ' + e);
    }
  }

  private applyFont(px: number): void {
    this.fontSize = px;
    this.webCtl.runJavaScript(`term_setFontSize(${px})`);
    const p = this.uiPrefs;
    if (p !== null) {
      p.put('fontSize', px).then((): Promise<void> => p.flush()).catch(() => {});
    }
  }

  private toggleTeam(): void {
    this.showTeam = !this.showTeam;
    const p = this.uiPrefs;
    if (p !== null) {
      p.put('showTeam', this.showTeam).then((): Promise<void> => p.flush()).catch(() => {});
    }
  }

  // ===========================================================================
  // 语音（按住说话 → GLM 转写 → AI 整理 → review；同手机版）
  // ===========================================================================

  private async holdStart(): Promise<void> {
    if (this.fieldMode === 'busy' || this.fieldMode === 'review' || this.recording) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
      await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(ctx, perms);
      await this.recorder.start();
      this.recording = true;
      this.fieldMode = 'recording';
    } catch (e) {
      this.recording = false;
      this.fieldMode = 'idle';
      this.toast('录音启动失败: ' + e);
    }
  }

  private async holdEnd(): Promise<void> {
    if (!this.recording) {
      return;
    }
    this.recording = false;
    this.fieldMode = 'busy';
    try {
      const wav: Uint8Array = await this.recorder.stop();
      if (wav.length <= 44) {
        this.fieldMode = 'idle';
        return;
      }
      const raw: string = await GlmClient.transcribe(wav, this.store.voice.apiKey);
      let out: string = raw;
      if (this.store.voice.enabled && this.store.voice.apiKey.length > 0 && raw.length > 0) {
        try {
          out = await GlmClient.polish(raw, this.store.voice.apiKey, this.store.voice.baseURL,
            this.store.voice.model, this.store.history, GlmClient.termEntries(this.store.terms), this.store.corrections);
          if (out !== raw) {
            this.store.corrections.push([raw, out]);
            if (this.store.corrections.length > 60) {
              this.store.corrections.shift();
            }
            this.store.saveCorrections();
          }
        } catch (e) {
          out = raw;
        }
      }
      const text: string = out.trim();
      if (text.length > 0) {
        this.reviewText = text;
        this.fieldMode = 'review';
      } else {
        this.fieldMode = 'idle';
      }
    } catch (e) {
      this.fieldMode = 'idle';
      this.toast('识别失败: ' + e);
    }
  }

  private openManualInput(prefill: string): void {
    this.manualText = prefill;
    this.showManualInput = true;
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('manualInput');
      } catch (e) {
      }
    }, 120);
  }

  private sendManual(): void {
    this.commitLine(this.manualText);
    this.manualText = '';
    this.showManualInput = false;
    if (this.fieldMode === 'review') {
      this.reviewText = '';
      this.fieldMode = 'idle';
    }
    this.hideKeyboard();
  }

  // ===========================================================================
  // 对话记录（终端列内切换，同 mac Cmd-D；暗色卡片流 + 增量缓存）
  // ===========================================================================

  private toggleChat(): void {
    if (this.mode === 'chat') {
      this.closeChat();
    } else {
      this.openChat();
    }
  }

  private chatCachePath(tabId: string): string {
    return this.filesDir() + '/transcript_' + tabId + '.json';
  }

  private loadChatCache(tabId: string): TranscriptCacheH | null {
    try {
      const c: TranscriptCacheH = JSON.parse(fs.readTextSync(this.chatCachePath(tabId))) as TranscriptCacheH;
      if (c.body === undefined || c.file === undefined) {
        return null;
      }
      return c;
    } catch (e) {
      return null;
    }
  }

  private saveChatCache(tabId: string, file: string, lines: number, body: string): void {
    try {
      let b: string = body;
      if (b.length > 300000) {
        const tail: string = b.substring(b.length - 300000);
        const i1: number = tail.indexOf('\n▶');
        const i2: number = tail.indexOf('\n◆');
        const cutAt: number = (i1 >= 0 && i2 >= 0) ? Math.min(i1, i2) : Math.max(i1, i2);
        b = cutAt >= 0 ? tail.substring(cutAt + 1) : tail;
      }
      const c: TranscriptCacheH = { file: file, lines: lines, body: b };
      const f = fs.openSync(this.chatCachePath(tabId), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(c));
      fs.closeSync(f);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'chat cache save: %{public}s', `${e}`);
    }
  }

  private async avatarDataURI(workDirId: string): Promise<string> {
    const hit = this.avatarB64Cache.get(workDirId);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const raw: Uint8Array = await ctx.resourceManager.getRawFileContent('avatars/' + workDirId + '.png');
      const uri: string = 'data:image/png;base64,' + this.b64.encodeToStringSync(raw);
      this.avatarB64Cache.set(workDirId, uri);
      return uri;
    } catch (e) {
      return '';
    }
  }

  private async openChat(): Promise<void> {
    const tab = this.store.tabById(this.activeTabId);
    if (tab === null) {
      this.toast('先选一个会话');
      return;
    }
    const m = this.store.machineById(tab.machineId);
    const ep: Endpoint | null = PadExec.endpointFor(this.store, m);
    if (m === null || ep === null) {
      this.toast('机器未配置 blinkd');
      return;
    }
    const w = this.store.workDirById(tab.workDirId);
    this.chatName = (w !== null && w.name.length > 0) ? w.name : tab.tmuxSession;
    this.chatAvatarURI = (w !== null && w.hasIcon === true) ? await this.avatarDataURI(w.id) : '';
    this.chatTabId = tab.id;
    this.chatBridge.onCopy = (t: string): void => {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, t);
      pasteboard.getSystemPasteboard().setData(data).then(() => this.toast('已复制')).catch(() => {});
    };
    this.chatBridge.onFetchImage = (url: string, id: string): void => {
      this.fetchChatImage(url, id);
    };
    const cached = this.loadChatCache(tab.id);
    this.chatRefreshing = true;
    this.renderChat(cached !== null ? cached.body : '');
    this.mode = 'chat';
    const script: string | null = this.store.transcriptDeltaScriptForTab(tab,
      cached !== null ? cached.file : '', cached !== null ? cached.lines : 0);
    if (script === null) {
      this.chatRefreshing = false;
      return;
    }
    this.chatFetchToken++;
    const token: number = this.chatFetchToken;
    const tabId: string = tab.id;
    PadExec.run(ep, PadExec.wrapForMachine(m, script), 25000, '@TSB64E@').then((raw: string): void => {
      if (token !== this.chatFetchToken) {
        return;
      }
      this.chatRefreshing = false;
      this.handleChatPayload(tabId, raw);
    });
  }

  private closeChat(): void {
    this.mode = 'terminal';
    this.chatFetchToken++;
    this.chatRefreshing = false;
    this.focusTerm();
  }

  private handleChatPayload(tabId: string, raw: string): void {
    const payload: string | null = PadExec.decodeTsb64(raw);
    if (payload === null) {
      const old = this.loadChatCache(tabId);
      if (old === null || old.body.length === 0) {
        this.renderChat('◆ Claude\n拉取失败，请稍后重试');
      }
      return;
    }
    const nl: number = payload.indexOf('\n');
    const meta: string[] = (nl >= 0 ? payload.substring(0, nl) : payload).split('\t');
    const body: string = nl >= 0 ? payload.substring(nl + 1) : '';
    if (meta.length < 4 || meta[0] !== 'META') {
      return;
    }
    const file: string = meta[1];
    const lineCount: number = Number.parseInt(meta[2], 10) > 0 ? Number.parseInt(meta[2], 10) : 0;
    const isFull: boolean = meta[3] === '1';
    if (file === 'NOTFOUND') {
      this.renderChat(body.length > 0 ? '◆ Claude\n' + body : '◆ Claude\n（无内容）');
      return;
    }
    const cached = this.loadChatCache(tabId);
    let merged: string;
    if (isFull || cached === null) {
      merged = body;
    } else if (body.length === 0) {
      merged = cached.body;
    } else {
      merged = cached.body + '\n\n' + body;
    }
    this.saveChatCache(tabId, file, lineCount, merged);
    const hadCache: boolean = cached !== null && cached.body.length > 0;
    if ((isFull || body.length > 0 || !hadCache) && this.chatTabId === tabId && this.mode === 'chat') {
      this.renderChat(merged);
    }
  }

  private renderChat(body: string): void {
    try {
      const enc = new util.TextEncoder();
      const payload: string = this.b64.encodeToStringSync(
        enc.encodeInto(body.length > 0 ? body : '◆ Claude\n正在拉取最新对话…'));
      const html: string = buildChatHtml(payload, this.chatAvatarURI, this.chatName)
        .replace('</style>', CHAT_DARK_CSS + '</style>');
      this.chatSeq++;
      const p: string = this.filesDir() + (this.chatSeq % 2 === 0 ? '/chat_a.html' : '/chat_b.html');
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, html);
      fs.closeSync(f);
      this.chatUrl = 'file://' + p;
      try {
        this.chatWebCtl.loadUrl(this.chatUrl);
      } catch (e) {
        // Web 还没挂载：构建时 src 直接用 chatUrl
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'chat render: %{public}s', `${e}`);
    }
  }

  private pinnedAuthFor(host: string): string[] | null {
    for (let i = 0; i < this.store.pinned.length; i++) {
      const t = this.store.pinned[i];
      if (t.authUser === undefined || t.authUser.length === 0 || t.authPassword === undefined) {
        continue;
      }
      const m = t.url.match(new RegExp('^https?://([^/]+)'));
      if (m !== null && (m[1] === host || m[1].split(':')[0] === host)) {
        return [t.authUser, t.authPassword];
      }
    }
    return null;
  }

  private fetchChatImage(url: string, id: string): void {
    const header: Record<string, string> = {};
    const mh = url.match(new RegExp('^https?://([^/:]+)'));
    const cred: string[] | null = this.pinnedAuthFor(mh !== null ? mh[1] : '');
    if (cred !== null) {
      header['Authorization'] = 'Basic ' + this.b64.encodeToStringSync(new util.TextEncoder().encodeInto(cred[0] + ':' + cred[1]));
    }
    const req = http.createHttp();
    req.request(url, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 10000,
      readTimeout: 25000,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
    }).then((rsp: http.HttpResponse) => {
      req.destroy();
      const bytes = rsp.result as ArrayBuffer;
      if (rsp.responseCode !== 200 || bytes.byteLength === 0 || bytes.byteLength > 6000000) {
        this.chatWebCtl.runJavaScript(`imgGiveUp('${id}')`);
        return;
      }
      let mime: string = 'image/png';
      const ct = rsp.header as Record<string, string>;
      if (ct !== undefined && typeof ct['content-type'] === 'string') {
        mime = ct['content-type'].split(';')[0];
      }
      this.chatWebCtl.runJavaScript(`imgReady('${id}','data:${mime};base64,${this.b64.encodeToStringSync(new Uint8Array(bytes))}')`);
    }).catch(() => {
      req.destroy();
      try {
        this.chatWebCtl.runJavaScript(`imgGiveUp('${id}')`);
      } catch (e) {
      }
    });
  }

  // ===========================================================================
  // 头像
  // ===========================================================================

  private async preloadAvatars(ctx: common.UIAbilityContext): Promise<void> {
    for (let i = 0; i < this.store.workDirs.length; i++) {
      const w = this.store.workDirs[i];
      if (w.hasIcon !== true || this.avatarCache.has(w.id)) {
        continue;
      }
      try {
        const raw: Uint8Array = await ctx.resourceManager.getRawFileContent('avatars/' + w.id + '.png');
        const pm = await image.createImageSource(raw.buffer as ArrayBuffer).createPixelMap();
        this.avatarCache.set(w.id, pm);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'avatar %{public}s: %{public}s', w.id, `${e}`);
      }
    }
    this.refreshAll();
  }

  // ===========================================================================
  // UI：通用小件
  // ===========================================================================

  @Builder
  wdAvatar(workDirId: string, label: string, size: number, radius: number) {
    if (this.avatarCache.has(workDirId)) {
      Image(this.avatarCache.get(workDirId))
        .width(size).height(size).borderRadius(radius).objectFit(ImageFit.Cover)
    } else {
      Stack() {
        Text(label.length > 0 ? label.substring(0, 1).toUpperCase() : '?')
          .fontSize(size * 0.45).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      }
      .width(size).height(size).borderRadius(radius)
      .linearGradient({ angle: 135, colors: [[GRADS[2][0], 0], [GRADS[2][1], 1]] })
    }
  }

  @Builder
  statusPill(st: WorkStatus, label: string) {
    Row({ space: 5 }) {
      Circle().width(5).height(5).fill(PadProbe.color(st))
      Text(label).fontSize(10).fontWeight(FontWeight.Bold).fontColor(PadProbe.color(st))
    }
    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
    .borderRadius(6)
    .backgroundColor(this.tint(PadProbe.color(st), '29'))
  }

  // #RRGGBB + alpha → #AARRGGBB（ArkUI 颜色字符串 alpha 在前）
  private tint(hex: string, alpha: string): string {
    return '#' + alpha + hex.substring(1);
  }

  @Builder
  iconBtn(sym: Resource, color: string, size: number, action: () => void) {
    Stack() {
      SymbolGlyph(sym).fontSize(size).fontColor([color])
    }
    .width(34).height(34).borderRadius(8)
    .stateStyles({ pressed: { .backgroundColor(FILL2) }, normal: { .backgroundColor(Color.Transparent) } })
    .onClick(action)
  }

  // ===========================================================================
  // UI：TopBar
  // ===========================================================================

  private activeTitle(): string {
    const t = this.store.tabById(this.activeTabId);
    return t !== null ? this.ccFor(t) : '未选择会话';
  }

  private activeMachineName(): string {
    const m = this.store.machineById(this.activeMachineId);
    return m !== null ? this.store.machineDisplayName(m) : 'Blink';
  }

  @Builder
  topBar() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.rectangle_split_3x1')).fontSize(18).fontColor([TEAL])
      Text(this.activeMachineName()).fontSize(13).fontColor(SUB)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(11).fontColor(['#3A4048'])
      Text(this.activeTitle()).fontSize(13).fontFamily(MONO).fontWeight(FontWeight.Medium).fontColor(FG)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 360 })
      Row({ space: 5 }) {
        Circle().width(6).height(6).fill(this.tsState === 'Running' ? TEAL : C_WAIT)
        Text(this.tsState === 'Running' ? 'tailscale' : (this.tsState.length > 0 ? this.tsState : '未连接'))
          .fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.tsState === 'Running' ? TEAL : C_WAIT)
      }
      .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(6)
      .backgroundColor(this.tint(this.tsState === 'Running' ? TEAL : C_WAIT, '1F'))
      Blank()
      if (this.probing) {
        LoadingProgress().width(16).height(16).color(DIM)
      }
      this.iconBtn($r('sys.symbol.person_2'), this.showTeam ? TEAL : SUB, 17, () => this.toggleTeam())
      this.iconBtn($r('sys.symbol.arrow_clockwise'), C_WORK, 16, () => this.reconnectActive())
      this.iconBtn($r('sys.symbol.gearshape'), SUB, 17, () => { this.sheet = 'settings'; })
    }
    .width('100%').height(48).padding({ left: 16, right: 12 })
    .backgroundColor('#05FFFFFF')
  }

  // ===========================================================================
  // UI：MachineRail
  // ===========================================================================

  @Builder
  machineRail() {
    Column({ space: 12 }) {
      List({ space: 12 }) {
        ForEach(this.machinesVM, (m: MachineVM) => {
          ListItem() {
            Stack({ alignContent: Alignment.BottomEnd }) {
              Stack() {
                Text(m.initials).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              }
              .width(40).height(40).borderRadius(12)
              .linearGradient({ angle: 135, colors: [[m.g1, 0], [m.g2, 1]] })
              .border(m.id === this.activeMachineId ? { width: 2.5, color: '#E6FFFFFF' } : { width: 0 })
              .opacity(m.id === this.activeMachineId ? 1 : 0.72)
              Circle().width(11).height(11)
                .fill(this.tsState === 'Running' ? C_WORK : '#4A515C')
                .stroke(BG).strokeWidth(2)
                .margin({ right: -2, bottom: -2 })
              if (m.waiting > 0) {
                Text(m.waiting.toString()).fontSize(9).fontWeight(FontWeight.Bold).fontColor('#1A1206')
                  .height(15).constraintSize({ minWidth: 15 }).textAlign(TextAlign.Center)
                  .padding({ left: 3, right: 3 }).borderRadius(8).backgroundColor(C_WAIT)
                  .position({ x: 28, y: -4 })
              }
            }
            .width(40).height(40)
            .onClick(() => this.selectMachine(m.id))
          }
        }, (m: MachineVM) => m.id + '_' + m.waiting + '_' + (m.id === this.activeMachineId ? 1 : 0) + '_' + this.tsState)
      }
      .layoutWeight(1).width('100%').alignListItem(ListItemAlign.Center).scrollBar(BarState.Off)
      .padding({ top: 12 })

      Stack() {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(16).fontColor([DIM])
      }
      .width(40).height(40).borderRadius(12)
      .border({ width: 1.5, color: '#3A4048', style: BorderStyle.Dashed })
      .onClick(() => { this.sheet = 'machines'; })

      this.iconBtn($r('sys.symbol.message'), this.mode === 'chat' ? TEAL : SUB, 18, () => this.toggleChat())
      this.iconBtn($r('sys.symbol.gearshape'), SUB, 18, () => { this.sheet = 'settings'; })
    }
    .width(64).height('100%').padding({ bottom: 14 })
    .backgroundColor('#08FFFFFF')
  }

  // ===========================================================================
  // UI：SessionSidebar
  // ===========================================================================

  private sidebarSub(): string {
    let resting: number = 0;
    for (let i = 0; i < this.store.tabs.length; i++) {
      const t = this.store.tabs[i];
      if (t.machineId === this.activeMachineId && this.store.isResting(t.id)) {
        resting++;
      }
    }
    return (this.sideRows.length - (this.store.isResting(this.activeTabId) ? 1 : 0)) + ' 在岗 · ' + resting + ' 休息';
  }

  @Builder
  sessionMenu(tabId: string) {
    Menu() {
      MenuItem({ content: this.store.isResting(tabId) ? '唤醒（在岗）' : '让 TA 休息' })
        .onClick(() => this.toggleRest(tabId))
      MenuItem({ content: '关闭标签' })
        .onClick(() => this.confirmClose(tabId))
    }
  }

  @Builder
  sessionSidebar(width: number) {
    Column() {
      Column({ space: 3 }) {
        Text(this.activeMachineName()).fontSize(17).fontWeight(FontWeight.Bold).fontColor(FG)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.sidebarSub()).fontSize(11).fontFamily(MONO).fontColor(DIM)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start).width('100%').padding({ left: 16, right: 16, top: 14, bottom: 10 })

      if (this.sideRows.length === 0) {
        Column({ space: 8 }) {
          Text('这台机器还没有会话').fontSize(13).fontColor(DIM)
          Text('点下方「新会话」开一个').fontSize(12).fontColor('#4A515C')
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          ForEach(this.sideRows, (r: SessRow) => {
            ListItem() {
              this.sessionRow(r)
            }
            .bindContextMenu(this.sessionMenu(r.tabId), ResponseType.LongPress)
          }, (r: SessRow) => r.tabId + '_' + r.status + '_' + r.statusLabel + '_' + r.unread + '_' +
            (r.tabId === this.activeTabId ? 1 : 0) + '_' + this.connState(r.tabId) + '_' + this.avatarCache.size)
        }
        .layoutWeight(1).width('100%').padding({ left: 8, right: 8 }).scrollBar(BarState.Off)
      }

      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(14).fontColor([TEAL])
        Text('新会话').fontSize(13).fontWeight(FontWeight.Medium).fontColor(TEAL)
      }
      .width('100%').height(34).justifyContent(FlexAlign.Center).borderRadius(9)
      .border({ width: 1, color: this.tint(TEAL, '66') })
      .margin({ top: 8, bottom: 12 })
      .onClick(() => this.openNewTab())
      .padding({ left: 12, right: 12 })
      .constraintSize({ maxWidth: width - 24 })
    }
    .width(width).height('100%').backgroundColor(FILL)
  }

  @Builder
  sessionRow(r: SessRow) {
    Row({ space: 10 }) {
      Row().width(3).height(30).borderRadius(2)
        .backgroundColor(r.tabId === this.activeTabId ? TEAL : Color.Transparent)
      this.wdAvatar(r.workDirId, r.owner, 30, 9)
      Column({ space: 2 }) {
        Row({ space: 5 }) {
          Text(r.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(FG)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          if (r.unread) {
            Circle().width(6).height(6).fill(TEAL)
          }
        }
        Text(r.dir).fontSize(11).fontFamily(MONO).fontColor(DIM)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).ellipsisMode(EllipsisMode.CENTER)
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      this.statusPill(r.status, r.statusLabel)
    }
    .width('100%').height(52).padding({ right: 10 }).borderRadius(10)
    .backgroundColor(r.tabId === this.activeTabId ? this.tint(TEAL, '1A') : Color.Transparent)
    .onClick(() => this.switchTab(r.tabId))
  }

  // ===========================================================================
  // UI：TerminalColumn
  // ===========================================================================

  @Builder
  terminalColumn() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 终端：hterm 多图层 WebView + 透明输入框。对话记录模式时只隐藏（不销毁，保住屏幕状态）
        Stack({ alignContent: Alignment.TopStart }) {
          Web({ src: $rawfile('term/term.html'), controller: this.webCtl })
            .javaScriptAccess(true).domStorageAccess(true)
            .javaScriptProxy({ object: this.jsBridge, name: 'arkBridge', methodList: ['post'], controller: this.webCtl })
            .onPageEnd(() => { this.webCtl.runJavaScript('term_init()'); })
            .backgroundColor(TERM).width('100%').height('100%')
          TextInput({ text: this.inputBuf })
            .id('termInput')
            .width('100%').height('100%')
            .backgroundColor(Color.Transparent).fontColor(Color.Transparent).caretColor(Color.Transparent)
            .enterKeyType(EnterKeyType.Send)
            .focusOnTouch(false).enableKeyboardOnFocus(this.kbWanted)
            .onChange((v: string) => this.onInput(v))
            .onSubmit(() => this.submitLine())
            .onKeyEvent((e: KeyEvent) => this.onHwKey(e))
        }
        .width('100%').height('100%').padding(6).backgroundColor(TERM)
        .visibility(this.mode === 'chat' ? Visibility.Hidden : Visibility.Visible)
        .priorityGesture(
          PanGesture({ direction: PanDirection.Vertical, distance: 10 })
            .onActionStart(() => { this.lastPanY = 0; this.webCtl.runJavaScript('term_wheel_reset()'); })
            .onActionUpdate((e: GestureEvent) => {
              const dy: number = e.offsetY - this.lastPanY;
              this.lastPanY = e.offsetY;
              this.webCtl.runJavaScript(`term_wheel(${this.getUIContext().vp2px(dy)})`);
            })
        )
        .onClick(() => this.focusTerm())

        if (this.activeTabId.length === 0) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.rectangle_split_3x1')).fontSize(34).fontColor(['#3A4048'])
            Text('从左侧选择一个会话打开').fontSize(14).fontColor(DIM)
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor(TERM)
        }

        if (this.mode === 'chat') {
          this.chatView()
        }
      }
      .layoutWeight(1).width('100%')

      this.bottomDock()
    }
    .layoutWeight(1).height('100%').backgroundColor(TERM)
  }

  @Builder
  chatView() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.message')).fontSize(15).fontColor([TEAL])
        Text('对话记录').fontSize(14).fontWeight(FontWeight.Medium).fontColor(FG)
        Text(this.activeTitle()).fontSize(12).fontFamily(MONO).fontColor(DIM)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.chatRefreshing) {
          LoadingProgress().width(16).height(16).color(DIM)
        }
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(12).fontColor([TEAL])
          Text('终端').fontSize(12).fontColor(TEAL)
        }
        .padding({ left: 10, right: 12, top: 5, bottom: 5 }).borderRadius(8).backgroundColor(this.tint(TEAL, '1A'))
        .onClick(() => this.closeChat())
      }
      .width('100%').height(40).padding({ left: 14, right: 10 }).backgroundColor(PANEL2)
      Web({ src: this.chatUrl, controller: this.chatWebCtl })
        .layoutWeight(1).width('100%').backgroundColor('#101216').fileAccess(true)
        .onHttpAuthRequest((event) => {
          if (event) {
            const cred: string[] | null = this.pinnedAuthFor(event.host);
            if (cred !== null) {
              event.handler.confirm(cred[0], cred[1]);
            } else {
              event.handler.cancel();
            }
          }
          return true;
        })
        .javaScriptProxy({ object: this.chatBridge, name: 'blinkNative', methodList: ['copy', 'fetchImage'], controller: this.chatWebCtl })
    }
    .width('100%').height('100%').backgroundColor('#101216')
  }

  // ===========================================================================
  // 底部 dock —— 严格按 iOS VoiceInputView 的布局（同手机版鸿蒙 bottomDock）：
  //   第一行：功能/键盘 分段 + 工具药丸（funcTools / keyToolsRow1）
  //   第二行：功能组 = 对话记录钮 + 按住说话条；键盘组 = keyToolsRow2
  // 平板左侧已有机器栏、没有内置浏览器，去掉 iOS 的 browser / desktop 两个药丸。
  // ===========================================================================

  private switchToolsGroup(idx: number): void {
    this.toolsGroup = idx;
    if (idx === 1 && this.recording) {
      // 切到键盘组时丢弃进行中的录音（iOS toolsGroupChanged 同逻辑）
      this.recording = false;
      this.fieldMode = 'idle';
      this.recorder.stop().then((_: Uint8Array): void => {}).catch((): void => {});
    }
  }

  @Builder
  toolSeg(label: string, idx: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.toolsGroup === idx ? '#F2F2F2' : '#8CFFFFFF')
      .fontWeight(this.toolsGroup === idx ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(this.toolsGroup === idx ? '#29FFFFFF' : Color.Transparent)
      .borderRadius(12)
      .onClick(() => this.switchToolsGroup(idx))
  }

  // 平板紧凑尺寸：药丸 42×36（手机 54×44）
  @Builder
  symPill(res: Resource, color: string, action: () => void) {
    Stack() {
      SymbolGlyph(res).fontSize(17).fontColor([color])
    }
    .width(42).height(36).borderRadius(11)
    .backgroundColor('#0FFFFFFF').border({ width: 1, color: '#24FFFFFF' })
    .stateStyles({ pressed: { .opacity(0.6) }, normal: { .opacity(1) } })
    .onClick(action)
  }

  @Builder
  textPill(label: string, action: () => void) {
    Stack() {
      Text(label).fontSize(13).fontColor('#E8E8E8')
    }
    .width(42).height(36).borderRadius(11)
    .backgroundColor('#0FFFFFFF').border({ width: 1, color: '#24FFFFFF' })
    .stateStyles({ pressed: { .opacity(0.6) }, normal: { .opacity(1) } })
    .onClick(action)
  }

  @Builder
  imgPill(res: Resource, action: () => void) {
    Stack() {
      Image(res).width(18).height(18).objectFit(ImageFit.Contain).draggable(false)
    }
    .width(42).height(36).borderRadius(11)
    .backgroundColor('#0FFFFFFF').border({ width: 1, color: '#24FFFFFF' })
    .stateStyles({ pressed: { .opacity(0.6) }, normal: { .opacity(1) } })
    .onClick(action)
  }

  // 终端列宽度（vp）：够宽时 dock 并成一行
  private dockOneRow(): boolean {
    const side: number = this.winW >= 900 ? 220 : 200;
    const team: number = (this.showTeam && this.winW >= 1000) ? (this.winW >= 1300 ? 296 : 260) : 0;
    return this.winW - 64 - side - team >= 760;
  }

  @Builder
  toolSegGroup() {
    Row({ space: 2 }) {
      this.toolSeg('功能', 0)
      this.toolSeg('键盘', 1)
    }
    .padding(2).backgroundColor('#09FFFFFF').borderRadius(14)
  }

  // 工具药丸（功能组 = iOS funcTools；键盘组 = keyToolsRow1 + 一行时顺带 keyToolsRow2）
  @Builder
  toolPills(withKeysRow2: boolean) {
    Row({ space: 6 }) {
      if (this.toolsGroup === 0) {
        this.symPill($r('sys.symbol.star'), '#E8E8E8', () => { this.sheet = 'favorites'; })
        this.symPill($r('sys.symbol.picture'), '#E8E8E8', () => this.pickAndUploadImage())
        this.textPill('Esc', () => this.sendKey([0x1b]))
        this.symPill($r('sys.symbol.text_clipboard'), '#E8E8E8', () => this.pasteClipboard())
        this.symPill($r('sys.symbol.arrow_clockwise'), '#E8E8E8', () => this.reconnectActive())
        this.symPill($r('sys.symbol.clock'), '#E8E8E8', () => { this.sheet = 'history'; })
        Row().width(1).height(20).backgroundColor('#1FFFFFFF')
        this.symPill(this.store.isResting(this.activeTabId) ? $r('sys.symbol.moon_z_fill') : $r('sys.symbol.moon_z'),
          this.store.isResting(this.activeTabId) ? C_REST : '#E8E8E8',
          () => { if (this.activeTabId.length > 0) { this.toggleRest(this.activeTabId); } })
        this.symPill($r('sys.symbol.wand_and_stars'), '#E8E8E8', () => { this.sheet = 'claude'; })
      } else {
        this.imgPill($r('app.media.tool_up'), () => this.sendKey([0x1b, 0x5b, 0x41]))
        this.imgPill($r('app.media.tool_down'), () => this.sendKey([0x1b, 0x5b, 0x42]))
        this.imgPill($r('app.media.tool_left'), () => this.sendKey([0x1b, 0x5b, 0x44]))
        this.imgPill($r('app.media.tool_right'), () => this.sendKey([0x1b, 0x5b, 0x43]))
        if (withKeysRow2) {
          Row().width(1).height(20).backgroundColor('#1FFFFFFF')
          this.keysRow2Pills()
        }
      }
    }
  }

  @Builder
  keysRow2Pills() {
    // iOS keyToolsRow2：/rewind /compact ⏎ ⇤(shift-tab) 清行(Ctrl+U)
    this.imgPill($r('app.media.tool_rewind'), () => this.sendLine('/rewind'))
    this.imgPill($r('app.media.tool_compact'), () => this.sendLine('/compact'))
    this.imgPill($r('app.media.tool_return'), () => this.sendKey([0x0d]))
    this.imgPill($r('app.media.tool_mode'), () => this.sendKey([0x1b, 0x5b, 0x5a]))
    this.imgPill($r('app.media.tool_clear'), () => this.sendKey([0x15]))
  }

  @Builder
  recordingStatus() {
    Row({ space: 8 }) {
      Circle().width(7).height(7).fill('#FF453A')
      Text(this.fieldMode === 'recording' ? '正在聆听…' : 'AI 识别整理中…')
        .fontSize(12).fontColor('#A0FFFFFF')
    }
    .padding({ left: 6 })
  }

  @Builder
  chatModeBtn() {
    // 显示模式切换：终端 ↔ 对话记录（iOS modeButton 同位置）
    Stack() {
      SymbolGlyph($r('sys.symbol.message')).fontSize(16).fontColor([this.mode === 'chat' ? TEAL : '#EBFFFFFF'])
    }
    .width(36).height(36).borderRadius(18)
    .backgroundColor(this.mode === 'chat' ? this.tint(TEAL, '1F') : '#0BFFFFFF')
    .border({ width: 1, color: '#24FFFFFF' })
    .onClick(() => this.toggleChat())
  }

  @Builder
  bottomDock() {
    if (this.dockOneRow()) {
      // 宽屏一行：[功能|键盘] 药丸…  [对话] [按住说话……]
      Row({ space: 8 }) {
        this.toolSegGroup()
        if (this.fieldMode === 'recording' || this.fieldMode === 'busy') {
          this.recordingStatus()
        } else {
          this.toolPills(true)
        }
        if (this.toolsGroup === 0) {
          this.chatModeBtn()
          Row() {
            this.voiceField()
          }
          .layoutWeight(1)
        } else {
          Blank()
        }
      }
      .width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor('#0A0A0A')
    } else {
      // 窄屏两行（同手机布局，紧凑尺寸）
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          this.toolSegGroup()
          if (this.fieldMode === 'recording' || this.fieldMode === 'busy') {
            this.recordingStatus()
          } else {
            Scroll() {
              this.toolPills(false)
            }
            .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
            .align(Alignment.Start)
          }
        }
        .width('100%')
        if (this.toolsGroup === 0) {
          Row({ space: 8 }) {
            this.chatModeBtn()
            Row() {
              this.voiceField()
            }
            .layoutWeight(1)
          }
          .width('100%')
        } else {
          Row({ space: 6 }) {
            this.keysRow2Pills()
          }
          .width('100%')
        }
      }
      .width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor('#0A0A0A')
    }
  }

  // 按住说话条：长按录音，松开 ASR+AI 整理进 review；轻点弹浮动打字条（同 iOS / 手机版）
  @Builder
  voiceField() {
    Row({ space: 8 }) {
      if (this.fieldMode === 'review') {
        Stack() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor(['#FF6B6B'])
        }
        .width(28).height(28)
        .onClick(() => { this.reviewText = ''; this.fieldMode = 'idle'; this.toast('已丢弃'); })
        Text(this.reviewText)
          .fontSize(13).fontColor('#FFFFFF').layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => this.openManualInput(this.reviewText))
      } else {
        SymbolGlyph($r('sys.symbol.mic')).fontSize(15)
          .fontColor([this.fieldMode === 'recording' ? '#FF9F9F' : '#66FFFFFF'])
          .margin({ left: 6 })
        Text(this.fieldMode === 'recording' ? '正在聆听 · 松开发送'
          : (this.fieldMode === 'busy' ? '识别中…' : '按住说话…'))
          .fontSize(13)
          .fontColor(this.fieldMode === 'recording' ? '#FF9F9F' : '#66FFFFFF')
          .layoutWeight(1)
      }
      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(14)
          .fontColor([this.fieldMode === 'review' ? '#0B1B14' : '#660B1B14'])
      }
      .width(28).height(28).borderRadius(14)
      .backgroundColor(this.fieldMode === 'review' ? GREEN : '#5933E0A1')
      .onClick(() => {
        if (this.fieldMode === 'review') {
          this.commitLine(this.reviewText);
          this.reviewText = '';
          this.fieldMode = 'idle';
        } else if (this.fieldMode === 'idle') {
          // 输入框为空点发送 = 发一个回车
          const c = this.activeClient();
          if (c !== null) {
            c.sendInput('\r');
          }
        }
      })
    }
    .width('100%').height(36).borderRadius(18)
    .padding({ left: 6, right: 4 })
    .backgroundColor(this.fieldMode === 'recording' ? '#24FF3B30' : '#0BFFFFFF')
    .border({ width: 1, color: this.fieldMode === 'recording' ? '#66FF3B30' : '#24FFFFFF' })
    .gesture(GestureGroup(GestureMode.Exclusive,
      LongPressGesture({ duration: 500 })
        .onAction(() => { this.holdStart(); })
        .onActionEnd(() => { this.holdEnd(); })
        .onActionCancel(() => { this.holdEnd(); }),
      TapGesture()
        .onAction(() => {
          if (this.fieldMode === 'idle') {
            this.openManualInput('');
          }
        })))
  }

  // ===========================================================================
  // UI：TeamInspector
  // ===========================================================================

  private statValue(which: string): number {
    if (which === 'wait') {
      return this.statWait;
    } else if (which === 'work') {
      return this.statWork;
    } else if (which === 'rest') {
      return this.statRest;
    }
    return this.statIdle;
  }

  // 注意：@Builder 的基本类型参数按值传，状态变了不会刷新——数值在里面直接读 @State
  @Builder
  statCell(which: string, label: string, color: string) {
    Column({ space: 2 }) {
      Text(this.statValue(which).toString()).fontSize(15).fontFamily(MONO).fontWeight(FontWeight.Bold).fontColor(color)
      Text(label).fontSize(11).fontColor(DIM)
    }.layoutWeight(1)
  }

  @Builder
  segItem(label: string, v: Inspector) {
    Text(label).fontSize(12).fontWeight(this.inspector === v ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.inspector === v ? FG : SUB)
      .layoutWeight(1).height(28).textAlign(TextAlign.Center).borderRadius(7)
      .backgroundColor(this.inspector === v ? PANEL3 : Color.Transparent)
      .onClick(() => { this.inspector = v; this.refreshAll(); })
  }

  @Builder
  teamInspector(width: number, overlay: boolean) {
    Column() {
      Row() {
        Text('团队').fontSize(17).fontWeight(FontWeight.Bold).fontColor(FG).layoutWeight(1)
        this.iconBtn($r('sys.symbol.arrow_clockwise'), SUB, 15, () => this.probeNow())
        if (overlay) {
          this.iconBtn($r('sys.symbol.xmark'), SUB, 15, () => this.toggleTeam())
        }
      }
      .width('100%').padding({ left: 16, right: 8, top: 10 })

      Row() {
        this.statCell('wait', '等你', C_WAIT)
        this.statCell('work', '干活', C_WORK)
        this.statCell('idle', '空闲', '#757F8F')
        this.statCell('rest', '休息', C_REST)
      }
      .width('100%').padding({ top: 10, bottom: 10 }).margin({ top: 8, left: 12, right: 12 })
      .borderRadius(12).backgroundColor(PANEL2).border({ width: 1, color: HAIR })
      .constraintSize({ maxWidth: width - 24 })

      Row({ space: 2 }) {
        this.segItem('按员工', 'employee')
        this.segItem('按项目', 'project')
        this.segItem('按机器', 'machine')
      }
      .padding(3).borderRadius(9).backgroundColor(PANEL).margin({ top: 10, left: 12, right: 12 })
      .constraintSize({ maxWidth: width - 24 })

      List({ space: 12 }) {
        ForEach(this.teamGroups, (g: TeamGroupVM) => {
          ListItem() {
            this.teamGroup(g)
          }
        }, (g: TeamGroupVM) => g.key + '_' + this.inspector + '_' + this.tick)
      }
      .layoutWeight(1).width('100%').padding({ left: 12, right: 12, top: 12, bottom: 12 }).scrollBar(BarState.Off)
    }
    .width(width).height('100%').backgroundColor(overlay ? PANEL : FILL)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  teamGroup(g: TeamGroupVM) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (g.avatarWorkDirId.length > 0) {
          this.wdAvatar(g.avatarWorkDirId, g.title, 20, 6)
        }
        Text(g.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(FG).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(g.sub).fontSize(11).fontColor(DIM)
      }
      .width('100%').padding({ left: 2, right: 2 })
      Column() {
        ForEach(g.rows, (r: SessRow, i: number) => {
          if (i > 0) {
            Row().width('100%').height(1).backgroundColor(HAIR)
          }
          this.teamRow(r)
        }, (r: SessRow) => r.tabId + '_' + r.status + '_' + (r.tabId === this.activeTabId ? 1 : 0))
      }
      .width('100%').borderRadius(12).backgroundColor(PANEL2).border({ width: 1, color: HAIR }).clip(true)
    }
    .width('100%')
  }

  @Builder
  teamRow(r: SessRow) {
    Row({ space: 9 }) {
      this.wdAvatar(r.workDirId, r.owner, 26, 8)
      Column({ space: 2 }) {
        Text(this.inspector === 'employee' ? r.project : r.name).fontSize(13).fontColor(FG)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 4 }) {
          Circle().width(5).height(5).fill(PadProbe.color(r.status))
          Text(r.statusLabel).fontSize(11).fontColor(PadProbe.color(r.status))
          Text(r.cc).fontSize(10).fontFamily(MONO).fontColor(DIM).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Stack() {
        SymbolGlyph(r.resting ? $r('sys.symbol.moon_z_fill') : $r('sys.symbol.moon')).fontSize(15)
          .fontColor([r.resting ? C_REST : DIM])
      }
      .width(30).height(30).borderRadius(8)
      .onClick(() => this.toggleRest(r.tabId))
    }
    .width('100%').padding({ left: 10, right: 6, top: 8, bottom: 8 })
    .opacity(r.resting ? 0.6 : 1)
    .backgroundColor(r.tabId === this.activeTabId ? this.tint(TEAL, '1A') : Color.Transparent)
    .onClick(() => this.switchTab(r.tabId))
    .bindContextMenu(this.sessionMenu(r.tabId), ResponseType.LongPress)
  }

  // ===========================================================================
  // UI：弹窗（平板用居中卡片，不用手机底部 sheet）
  // ===========================================================================

  private sheetTitle(): string {
    if (this.sheet === 'settings') {
      return '设置';
    } else if (this.sheet === 'newTab') {
      return '新建会话';
    } else if (this.sheet === 'favorites') {
      return '收藏短语';
    } else if (this.sheet === 'claude') {
      return 'Claude 命令';
    } else if (this.sheet === 'history') {
      return '发送历史';
    } else if (this.sheet === 'aiConfig') {
      return 'AI 配置';
    } else if (this.sheet === 'machines') {
      return '机器';
    } else if (this.sheet === 'workDirs') {
      return '工作目录';
    }
    return '';
  }

  @Builder
  sheetDialog() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor('#99000000')
        .onClick(() => { this.sheet = 'none'; this.focusTerm(); })
      Column() {
        Row() {
          Text(this.sheetTitle()).fontSize(17).fontWeight(FontWeight.Bold).fontColor(FG).layoutWeight(1)
          if (this.sheet === 'favorites') {
            Text('发送历史').fontSize(13).fontColor(TEAL).margin({ right: 14 })
              .onClick(() => { this.sheet = 'history'; })
          }
          this.iconBtn($r('sys.symbol.xmark'), SUB, 15, () => { this.sheet = 'none'; this.focusTerm(); })
        }
        .width('100%').height(52).padding({ left: 20, right: 10 })
        Row().width('100%').height(1).backgroundColor(HAIR)

        if (this.sheet === 'settings') {
          this.settingsBody()
        } else if (this.sheet === 'newTab') {
          this.newTabBody()
        } else if (this.sheet === 'favorites') {
          this.listBody(this.sortedFavorites(), '还没有收藏短语（手机端/iOS 添加后会同步过来）', (s: string) => this.useFavorite(s))
        } else if (this.sheet === 'claude') {
          this.listBody(CLAUDE_COMMANDS, '', (s: string) => { this.sendLine(s); this.sheet = 'none'; this.focusTerm(); })
        } else if (this.sheet === 'history') {
          this.listBody(this.reversedHistory(), '还没有发送历史', (s: string) => { this.sendLine(s); this.sheet = 'none'; this.focusTerm(); })
        } else if (this.sheet === 'aiConfig') {
          this.aiConfigBody()
        } else if (this.sheet === 'machines') {
          this.machinesBody()
        } else if (this.sheet === 'workDirs') {
          this.workDirsBody()
        }
      }
      .width(Math.min(600, this.winW * 0.9))
      .height(this.sheet === 'claude' || this.sheet === 'favorites' || this.sheet === 'history' ? '70%' : '82%')
      .borderRadius(16).backgroundColor(PANEL).border({ width: 1, color: HAIR2 })
      .shadow({ radius: 40, color: '#80000000', offsetY: 12 })
      .clip(true)
    }
    .width('100%').height('100%')
  }

  @Builder
  sectionHeader(title: string) {
    Text(title).fontSize(12).fontColor(DIM).width('100%').margin({ top: 14, bottom: 6 })
  }

  @Builder
  listBody(items: string[], empty: string, onPick: (s: string) => void) {
    if (items.length === 0) {
      Column() {
        Text(empty).fontSize(13).fontColor(DIM)
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else {
      List() {
        ForEach(items, (it: string) => {
          ListItem() {
            Text(it).fontSize(14).fontColor(FG).fontFamily(MONO)
              .width('100%').padding({ top: 12, bottom: 12, left: 4, right: 4 }).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .onClick(() => onPick(it))
        }, (it: string, i: number) => i + '_' + it)
      }
      .layoutWeight(1).width('100%').padding({ left: 20, right: 20 }).divider({ strokeWidth: 1, color: HAIR })
    }
  }

  @Builder
  navRow(label: string, detail: string, action: () => void) {
    Row() {
      Text(label).fontSize(14).fontColor(FG).layoutWeight(1)
      Text(detail).fontSize(13).fontColor(SUB)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([DIM]).margin({ left: 6 })
    }.width('100%').height(46).onClick(action)
  }

  @Builder
  toggleRow(label: string, on: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(label).fontSize(14).fontColor(FG).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: on }).selectedColor(C_WORK)
        .onChange((v: boolean) => { onChange(v); this.tick++; })
    }.width('100%').height(46)
  }

  @Builder
  settingsBody() {
    Scroll() {
      Column() {
        this.sectionHeader('Tailscale')
        Column({ space: 10 }) {
          TextInput({ text: this.authKey, placeholder: 'auth key（tskey-…）' })
            .fontSize(13).type(InputType.Password).backgroundColor(PANEL3).fontColor(FG).borderRadius(8)
            .onChange((v: string) => { this.authKey = v; this.saveTs('authKey', v); })
          TextInput({ text: this.hostname, placeholder: '设备名（tailnet 里显示）' })
            .fontSize(13).backgroundColor(PANEL3).fontColor(FG).borderRadius(8)
            .onChange((v: string) => { this.hostname = v; this.saveTs('hostname', v); })
          Row() {
            Circle().width(7).height(7).fill(this.tsState === 'Running' ? C_WORK : DIM)
            Text(this.tsState.length > 0 ? this.tsState : '未连接').fontSize(12)
              .fontColor(this.tsState === 'Running' ? C_WORK : SUB).margin({ left: 6 }).layoutWeight(1)
            Text(this.tsIP).fontSize(12).fontFamily(MONO).fontColor(SUB)
          }.width('100%')
          Button(this.tsConnected ? '断开 tailscale' : '连接 tailscale')
            .fontSize(14).width('100%').height(38)
            .backgroundColor(this.tsConnected ? PANEL3 : C_WORK).fontColor(this.tsConnected ? FG : '#0B1B14')
            .onClick(() => { this.tsConnected ? this.tsDisconnect() : this.tsConnect(); })
        }.padding(14).backgroundColor(PANEL2).borderRadius(12)

        this.sectionHeader('机器 · 工作目录')
        Column() {
          this.navRow('机器', this.store.machines.length + ' 台', () => { this.sheet = 'machines'; })
          Row().width('100%').height(1).backgroundColor(HAIR)
          this.navRow('工作目录（员工）', this.store.workDirs.length + ' 个', () => { this.sheet = 'workDirs'; })
          Row().width('100%').height(1).backgroundColor(HAIR)
          this.toggleRow('断线自动重连', this.store.autoReconnect,
            (v: boolean) => { this.store.autoReconnect = v; this.store.saveAutoReconnect(); })
        }.padding({ left: 14, right: 14 }).backgroundColor(PANEL2).borderRadius(12)

        this.sectionHeader('语音 · AI 整理')
        Column() {
          this.toggleRow('AI 整理', this.store.voice.enabled,
            (v: boolean) => { this.store.voice.enabled = v; this.store.saveVoice(); })
          Row().width('100%').height(1).backgroundColor(HAIR)
          this.navRow('AI 配置', this.store.voice.model, () => { this.sheet = 'aiConfig'; })
        }.padding({ left: 14, right: 14 }).backgroundColor(PANEL2).borderRadius(12)

        this.sectionHeader('终端字号')
        Row({ space: 6 }) {
          ForEach(FONT_SIZES, (px: number) => {
            Text(px.toString()).fontSize(13)
              .fontColor(px === this.fontSize ? '#0B0C0E' : FG)
              .backgroundColor(px === this.fontSize ? TEAL : PANEL3)
              .width(40).height(32).textAlign(TextAlign.Center).borderRadius(8)
              .onClick(() => this.applyFont(px))
          }, (px: number) => px.toString() + '_' + (px === this.fontSize ? 1 : 0))
        }.width('100%').padding(14).backgroundColor(PANEL2).borderRadius(12)

        Text('Blink Pad · HarmonyOS 平板版\n配置经 Mac ~/.blink/sync 与 iOS / 鸿蒙手机双向同步')
          .fontSize(11).fontColor('#4A515C').width('100%').textAlign(TextAlign.Center).margin({ top: 18, bottom: 20 })
      }.width('100%').padding({ left: 20, right: 20 })
    }.layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder
  newTabBody() {
    Scroll() {
      Column() {
        this.sectionHeader('机器')
        Column() {
          ForEach(this.store.machines, (m: Machine) => {
            Row() {
              Text(this.store.machineDisplayName(m)).fontSize(14).fontColor(FG).layoutWeight(1)
              if (this.ntMachineId === m.id) {
                SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(16).fontColor([TEAL])
              }
            }.width('100%').height(42).onClick(() => { this.ntMachineId = m.id; })
          }, (m: Machine) => m.id + '_' + (this.ntMachineId === m.id ? 1 : 0))
        }.padding({ left: 14, right: 14 }).backgroundColor(PANEL2).borderRadius(12)

        this.sectionHeader('工作目录（员工）')
        Column() {
          ForEach(this.store.workDirs, (w: WorkDir) => {
            Row({ space: 10 }) {
              this.wdAvatar(w.id, w.name, 24, 7)
              Column() {
                Text(w.name).fontSize(14).fontColor(FG)
                Text(w.path).fontSize(10).fontFamily(MONO).fontColor(DIM).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.ntWorkDirId === w.id) {
                SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(16).fontColor([TEAL])
              }
            }.width('100%').height(48).onClick(() => { this.ntWorkDirId = w.id; })
          }, (w: WorkDir) => w.id + '_' + (this.ntWorkDirId === w.id ? 1 : 0) + '_' + this.avatarCache.size)
        }.padding({ left: 14, right: 14 }).backgroundColor(PANEL2).borderRadius(12)

        this.sectionHeader('会话名（tmux）')
        TextInput({ text: this.ntSession, placeholder: '留空 = new' })
          .fontSize(14).backgroundColor(PANEL3).fontColor(FG).borderRadius(8)
          .onChange((v: string) => { this.ntSession = v; })

        Button('创建并连接').fontSize(14).width('100%').height(40)
          .backgroundColor(TEAL).fontColor('#0B0C0E').margin({ top: 16, bottom: 20 })
          .onClick(() => this.newTab())
      }.width('100%').padding({ left: 20, right: 20 })
    }.layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder
  machinesBody() {
    Scroll() {
      Column({ space: 8 }) {
        ForEach(this.store.machines, (m: Machine) => {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(this.store.machineDisplayName(m)).fontSize(14).fontColor(FG)
              Text(m.user + '@' + m.host + ' · ' + (m.transport === 'blinkd'
                ? ('blinkd ' + (m.blinkdHost !== undefined ? m.blinkdHost : '')) : 'SSH 经 Mac 中转'))
                .fontSize(11).fontFamily(MONO).fontColor(DIM)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            this.iconBtn($r('sys.symbol.trash'), RED, 15, () => this.deleteMachine(m))
          }
          .width('100%').padding({ left: 14, right: 8, top: 10, bottom: 10 }).backgroundColor(PANEL2).borderRadius(10)
        }, (m: Machine) => m.id + '_' + this.tick)
        Text('机器清单从 iOS 配置同步过来（Mac ~/.blink/sync）。blinkd 机器直连；SSH 机器经 Mac 中转。')
          .fontSize(11).fontColor('#4A515C').width('100%').margin({ top: 6, bottom: 20 })
      }.width('100%').padding({ left: 20, right: 20, top: 14 })
    }.layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder
  workDirsBody() {
    List() {
      ForEach(this.store.workDirs, (w: WorkDir) => {
        ListItem() {
          Row({ space: 10 }) {
            this.wdAvatar(w.id, w.name, 30, 9)
            Column() {
              Text(w.name).fontSize(14).fontColor(FG)
              Text(w.path).fontSize(11).fontFamily(MONO).fontColor(DIM).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').height(52)
        }
      }, (w: WorkDir) => w.id + '_' + this.avatarCache.size)
    }.layoutWeight(1).width('100%').padding({ left: 20, right: 20 }).divider({ strokeWidth: 1, color: HAIR })
  }

  @Builder
  aiConfigBody() {
    Column() {
      this.sectionHeader('GLM API Key')
      TextInput({ text: this.store.voice.apiKey, placeholder: 'API Key' })
        .fontSize(13).type(InputType.Password).backgroundColor(PANEL3).fontColor(FG).borderRadius(8)
        .onChange((v: string) => { this.store.voice.apiKey = v; this.store.saveVoice(); })
      this.sectionHeader('模型')
      TextInput({ text: this.store.voice.model, placeholder: 'glm-4-flashx' })
        .fontSize(13).backgroundColor(PANEL3).fontColor(FG).borderRadius(8)
        .onChange((v: string) => { this.store.voice.model = v; this.store.saveVoice(); })
      this.sectionHeader('Base URL')
      TextInput({ text: this.store.voice.baseURL, placeholder: 'https://…/chat/completions' })
        .fontSize(12).backgroundColor(PANEL3).fontColor(FG).borderRadius(8)
        .onChange((v: string) => { this.store.voice.baseURL = v; this.store.saveVoice(); })
      Text('语音识别 glm-asr-2512，整理用上面的模型。').fontSize(11).fontColor('#4A515C').width('100%').margin({ top: 10 })
    }.width('100%').padding({ left: 20, right: 20 }).alignItems(HorizontalAlign.Start)
  }

  private deleteMachine(m: Machine): void {
    this.getUIContext().showAlertDialog({
      title: '删除机器',
      message: '删除「' + this.store.machineDisplayName(m) + '」？',
      primaryButton: {
        value: '删除', fontColor: RED, action: () => {
          const i = this.store.machines.findIndex((x: Machine) => x.id === m.id);
          if (i >= 0) {
            this.store.machines.splice(i, 1);
            this.store.saveMachines();
            if (this.activeMachineId === m.id) {
              this.activeMachineId = this.store.machines.length > 0 ? this.store.machines[0].id : '';
            }
            this.refreshAll();
          }
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private saveTs(key: string, value: string): void {
    const p = this.tsPrefs;
    if (p !== null) {
      p.put(key, value).then((): Promise<void> => p.flush()).catch(() => {});
    }
  }

  @Builder
  manualInputOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%').backgroundColor('#47000000')
        .onClick(() => { this.showManualInput = false; this.hideKeyboard(); })
      Row({ space: 8 }) {
        TextInput({ text: this.manualText, placeholder: '输入要发给 claude 的内容…' })
          .id('manualInput')
          .layoutWeight(1).height(44).fontSize(15)
          .backgroundColor(Color.Transparent).fontColor('#FFFFFF')
          .placeholderColor('#59FFFFFF').caretColor(GREEN)
          .enterKeyType(EnterKeyType.Send)
          .onChange((v: string) => { this.manualText = v; })
          .onSubmit(() => this.sendManual())
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(15).fontColor(['#0B1B14'])
        }
        .width(34).height(34).borderRadius(17).backgroundColor(GREEN)
        .onClick(() => this.sendManual())
      }
      .width(Math.min(760, this.winW * 0.8)).height(56).borderRadius(20)
      .padding({ left: 14, right: 10 })
      .backgroundColor(PANEL3).border({ width: 1, color: HAIR2 })
      .margin({ bottom: 16 + (this.kbHeight > 0 ? 0 : this.botInset) })
    }
    .width('100%').height('100%')
  }

  // ===========================================================================
  // build
  // ===========================================================================

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row().width('100%').height(this.topInset).backgroundColor(BG)
        this.topBar()
        Row().width('100%').height(1).backgroundColor(HAIR)
        Row() {
          this.machineRail()
          Row().width(1).height('100%').backgroundColor(HAIR)
          this.sessionSidebar(this.winW >= 900 ? 220 : 200)
          Row().width(1).height('100%').backgroundColor(HAIR)
          this.terminalColumn()
          if (this.showTeam && this.winW >= 1000) {
            Row().width(1).height('100%').backgroundColor(HAIR)
            this.teamInspector(this.winW >= 1300 ? 296 : 260, false)
          }
        }
        .layoutWeight(1).width('100%')
        Row().width('100%').height(this.kbHeight > 0 ? 0 : this.botInset).backgroundColor('#0B0C0E')
      }
      .width('100%').height('100%').backgroundColor(BG)

      // 窄窗（竖屏 / 分屏）：团队栏改成右侧抽屉
      if (this.showTeam && this.winW < 1000) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Column().width('100%').height('100%').backgroundColor('#66000000')
            .onClick(() => this.toggleTeam())
          Column() {
            this.teamInspector(300, true)
          }
          .height('100%').padding({ top: this.topInset })
          .shadow({ radius: 30, color: '#99000000', offsetX: -8 })
        }
        .width('100%').height('100%')
      }
      if (this.sheet !== 'none') {
        this.sheetDialog()
      }
      if (this.showManualInput) {
        this.manualInputOverlay()
      }
    }
    .width('100%').height('100%').backgroundColor(BG).padding({ bottom: this.kbHeight })
    .onAreaChange((_o: Area, n: Area) => {
      const w: number = n.width as number;
      if (w > 0 && Math.abs(w - this.winW) > 1) {
        this.winW = w;
      }
    })
  }
}
