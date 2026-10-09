////////////////////////////////////////////////////////////////////////////////
//
// BlinkTerminal — Blink for HarmonyOS, the full iOS-fork experience:
//   • multi-tab, multi-session — one live blinkd connection per tab (ConnPool),
//     switching tabs never reconnects (hterm keeps every layer's screen), the
//     tab strip / machine filter pill / new-tab flow mirror SpaceController.
//   • config seeded from the user's real iOS app (BlinkStore ← seed_config.json):
//     same machines, work dirs, tabs, favorites, voice-AI data.
//   • persistent bottom dock reproduces the latest VoiceInputView: 功能/键盘
//     tool groups, hold-to-talk field (record → glm-asr → polish → review),
//     tap-to-type floating input panel.
//
// The transport/terminal/input plumbing is the device-verified path from the
// single-session build, generalised to N sessions.
//
////////////////////////////////////////////////////////////////////////////////

import { common, wantAgent, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { vpnExtension } from '@kit.NetworkKit';
import { http } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util, buffer } from '@kit.ArkTS';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { BlinkdClient, BlinkdState, TailscaleCore, StatusStore } from 'tsvpn';
import { BlinkStore, Machine, WorkDir, TabModel, PinnedTab } from '../model/BlinkStores';
import { ServerConfig } from '../model/ServerConfig';
import { ProtoCatalog, ProtoCache, ProtoItem, ProtoFetchResult, PROTO_HOST } from '../model/ProtoCatalog';
import { ConnPool, SessionConn, ConnUiState } from '../model/SessionConn';
import { SshDirectClient } from '../ssh/SshDirectClient';
import { SshIdentity } from '../ssh/SshIdentity';
import { GlmClient, VoiceRecorder, Uploader, CLAUDE_COMMANDS, TermEntry } from '../model/GlmVoice';

const DOMAIN: number = 0x0B11;
const TAG: string = 'BlinkTerminal';
const BUNDLE: string = 'com.douwantech.blink';
// tmux 焦点进入序列：ESC [ I。tmux 收到后会把发它的客户端记为「最近活跃」并按它的尺寸重排——
// 别的设备操作完，本机切回这个标签 / 回前台时补发一次，把画面抢回本机尺寸。只对 tmux 标签发。
const FOCUS_IN_BYTES: number[] = [0x1b, 0x5b, 0x49];
const FOCUS_IN_MIN_MS: number = 1000;   // 同一标签 1s 内最多一次（不是每次按键都发）

// palette
const TEAL: string = '#3DD9C4';

// 浏览器（侧栏「后台 / 原型」）配色，与平板版 PadHome 保持一致
const B_PANEL: string = '#121418';
const B_PANEL2: string = '#16191D';
const B_PANEL3: string = '#1A1D23';
const B_FG: string = '#D4DAE0';
const B_SUB: string = '#8B95A5';
const B_DIM: string = '#6B7683';
const B_HAIR: string = '#14FFFFFF';
const B_FILL: string = '#14FFFFFF';
const B_REST: string = '#8F8CFF';
const B_WAIT: string = '#F5A83D';
const B_RED: string = '#FF5A5C';
const MONO: string = 'monospace';
const B_GRADS: string[][] = [
  ['#4EA8FF', '#8F8CFF'],
  ['#F5A83D', '#FF5A5C'],
  ['#40D68C', '#63D3E8'],
  ['#8F8CFF', '#5A57C9'],
];

/// 地址栏输入 → 可加载的网址（同 iOS PinnedBrowserViewController.normalizeURL）
class BrowserUrl {
  static normalize(raw: string): string {
    const s: string = raw.trim();
    if (s.length === 0) {
      return '';
    }
    if (new RegExp('^(https?|about|file|data):', 'i').test(s)) {
      return s;
    }
    if (new RegExp('^(localhost|\\d{1,3}(\\.\\d{1,3}){3})(:\\d+)?(/.*)?$').test(s)) {
      return 'http://' + s;
    }
    if (s.indexOf('.') > 0 && s.indexOf(' ') < 0) {
      return 'https://' + s;
    }
    return 'https://www.bing.com/search?q=' + encodeURIComponent(s);
  }
}

// 原型列表「最近更新」排序用（ArkTS 不许在 sort 里用匿名对象字面量）
interface ProtoSortRow {
  it: ProtoItem;
  i: number;
}

interface DirectSshEndpoint {
  host: string;
  port: number;
}

interface Theme {
  name: string;
  bg: string;
  fg: string;
  cursor: string;
}

// iOS fork's 5 bundled themes (Resources/Themes/*.js).
const THEMES: Theme[] = [
  { name: 'Default', bg: '#101010', fg: '#F0F0F0', cursor: 'rgba(63,222,233,0.5)' },
  { name: 'Solarized', bg: '#002B36', fg: '#839496', cursor: 'rgba(131,148,150,0.4)' },
  { name: 'Flat', bg: '#1A242F', fg: '#BDC3C7', cursor: 'rgba(229,190,12,0.5)' },
  { name: 'WWDC 16', bg: '#292C36', fg: '#FFFFFF', cursor: 'rgba(229,190,12,0.5)' },
  { name: 'Monokai Lt', bg: '#FFFFFF', fg: '#000000', cursor: 'rgba(0,0,0,0.5)' },
];

const FONT_SIZES: number[] = [8, 9, 10, 11, 12, 13, 14];

// what the bottom sheet is currently showing
type Sheet = 'none' | 'more' | 'settings' | 'machinePicker' | 'newTab' | 'claude' | 'favorites' | 'history' | 'machineForm' | 'workDirs' | 'aiConfig' | 'restPanel' | 'pinEdit' | 'protoAuth';

// 团队三视图（#77 评论②）的扁平条目：kind='h' 组头 / 'r' 行——List 里每项只能是一个 ListItem，
// 所以把「组头 + 行」摊平成一个数组再 ForEach。
interface TeamEntry {
  kind: string;
  title: string;
  sub: string;
  tab: TabModel;
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
struct BlinkTerminal {
  // tailscale transport
  @State tsState: string = '';
  @State tsIP: string = '';
  private tsError: string = '';       // VPN 扩展写进状态文件的失败原因
  private lastTsNote: string = '';   // 上次写进终端的 tailscale 状态，去重防刷屏
  @State tsConnected: boolean = false;
  @State authKey: string = '';
  @State hostname: string = 'harmony';
  // ui reactivity: bump `tick` after any store/pool mutation to force re-render
  @State tick: number = 0;
  @State storeReady: boolean = false;
  @State activeTabId: string = '';
  @State visTabs: TabModel[] = [];   // observable copy of store.visibleTabs() for the tab strip
  @State restCount: number = 0;      // resting-session count on the top-bar 🌙 (topBar() reads no other @State)
  @State teamMode: string = 'employee';   // 团队三视图：#77 评论② employee | project | machine
  @State filterLabel: string = '全部'; // machine-filter pill text, same reason
  @State cols: number = 52;
  @State rows: number = 30;
  @State themeIdx: number = 0;
  @State fontSize: number = 11;
  @State kbHeight: number = 0;
  @State topInset: number = 0;       // 状态栏高度（沉浸式后自己垫 #0b0c0e 背景）
  @State botInset: number = 0;       // 底部导航条/安全区高度（垫 dock 同色）
  // 常驻底部 dock（iOS VoiceInputView 最新版）：功能/键盘两组工具 + 按住说话条
  @State toolsGroup: number = 0;       // 0 = 功能, 1 = 键盘
  @State fieldMode: string = 'idle';   // idle | recording | busy | review
  @State reviewText: string = '';
  @State recording: boolean = false;
  @State showManualInput: boolean = false;
  @State manualText: string = '';
  @State inputBuf: string = '';
  // overlays
  @State sheet: Sheet = 'none';
  // 内置浏览器：showBrowser = 当前是否在浏览器界面；browserOpened = Web 是否已挂载
  // （首开后常驻，关掉只隐藏，保住页面不重载）。侧栏分「后台」（钉住的管理后台，
  // 与 iOS / 平板同步）和「原型」（prototype.douwantech.com 目录，ProtoCatalog）。
  @State showBrowser: boolean = false;
  @State browserOpened: boolean = false;
  @State browserSide: boolean = false;          // 侧栏抽屉是否展开
  @State browserSeg: string = 'admin';          // admin | proto
  @State browserPinned: PinnedTab[] = [];
  @State browserCurUrl: string = '';
  @State browserUrlText: string = '';
  @State browserEditing: boolean = false;
  @State browserLoading: boolean = false;
  @State browserProgress: number = 0;
  @State browserCanBack: boolean = false;
  @State browserCanFwd: boolean = false;
  @State protoAll: ProtoItem[] = [];
  @State protoSections: string[] = [];
  @State protoFilter: string = '';              // '' = 最近更新
  @State protoQuery: string = '';
  @State protoState: string = 'idle';           // idle | loading | ok | noauth | error
  @State protoMsg: string = '';
  @State protoUser: string = '';
  @State protoPass: string = '';
  // 后台编辑器暂存
  @State peIdx: number = -1;
  @State peTitle: string = '';
  @State peUrl: string = '';
  @State peUser: string = '';
  @State pePwd: string = '';
  @State showTranscript: boolean = false;
  @State chatName: string = '';
  @State chatRefreshing: boolean = false;
  // new-tab / machine-form scratch state
  @State ntMachineId: string = '';
  @State ntWorkDirId: string = '';
  @State ntSession: string = '';
  @State mfEdit: Machine | null = null;

  private store: BlinkStore = new BlinkStore();
  private pool: ConnPool = new ConnPool();
  private focusInAt: Record<string, number> = {};   // tabId → 上次发焦点进入的时刻（节流用）
  private tabScroller: Scroller = new Scroller();   // scroll the tab strip to the active tab on switch/swipe
  private panMode: string = '';   // active terminal drag axis: '' undecided | 'h' switch tab | 'v' scroll
  private lastPanY: number = 0;   // last vertical offset seen this drag (for incremental scroll)
  private lastTabPerMachine: Record<string, string> = {};   // each machine's last-active tab (iOS _lastKeyPerMachine)
  private b64: util.Base64Helper = new util.Base64Helper();
  private win: window.Window | null = null;
  private webCtl: webview.WebviewController = new webview.WebviewController();
  private browserCtl: webview.WebviewController = new webview.WebviewController();
  private browserStartUrl: string = 'about:blank';
  private browserAttached: boolean = false;
  private browserAuthTries: Map<string, number> = new Map();   // 每个 host 只自动应答一次，防死循环
  private protoFetchedAt: number = 0;
  private jsBridge: JsBridge = new JsBridge((op: string, data: string): void => { this.onBridge(op, data); });
  private tsPrefs: preferences.Preferences | null = null;
  private uiPrefs: preferences.Preferences | null = null;
  private timer: number = -1;
  private lastVpnKick: number = 0;   // 看门狗上次重拉 VPN 的时刻（节流）
  // 服务器配置同步（唯一权威，见 model/ServerConfig.ets）：登录 session、快照采纳、
  // 个人状态上传、15s 轮询。老的 ~/.blink/sync/blink_config.json 双向文件同步已全部停掉。
  private serverConfig: ServerConfig | null = null;
  @State authGate: string = 'checking';   // checking | login | ready（没 session 时只显示登录页）
  @State accountName: string = '';        // 设置页显示的账号名（非机密）
  @State loginUser: string = '';
  @State loginPwd: string = '';
  @State loginError: string = '';
  @State loginBusy: boolean = false;
  @State brainSshHost: string = '';
  @State brainSshPort: string = '22';
  @State sshPublicKey: string = '';
  @State sshKeyError: string = '';
  private lastLen: number = 0;
  private skipNext: boolean = false;
  private recorder: VoiceRecorder = new VoiceRecorder();
  private transcriptClient: BlinkdClient | SshDirectClient | null = null;
  // 对话记录页(D 卡片流,与 iOS 一致):本地缓存 + 增量拉取
  private chatWebCtl: webview.WebviewController = new webview.WebviewController();
  private chatUrl: string = 'about:blank';
  private chatSeq: number = 0;
  private chatTabId: string = '';
  private chatAvatarURI: string = '';
  private chatBridge: ChatBridge = new ChatBridge();
  private avatarB64Cache: Map<string, string> = new Map();
  private avatarCache: Map<string, image.PixelMap> = new Map();

  // ---- lifecycle ----

  aboutToAppear(): void {
    try {
      TailscaleCore.version();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'core self-test: %{public}s', `${e}`);
    }
    this.setupKeyboard();
    this.boot();
  }

  aboutToDisappear(): void {
    const sc = this.serverConfig;
    if (sc !== null) {
      sc.stopPolling();
    }
    this.pool.closeAll();
    if (this.win !== null) {
      try {
        this.win.off('keyboardHeightChange');
      } catch (e) {
      }
    }
  }

  private async boot(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.tsPrefs = await preferences.getPreferences(ctx, 'ts_prefs');
    this.uiPrefs = await preferences.getPreferences(ctx, 'ui_prefs');
    this.brainSshHost = await this.uiPrefs.get('brainSshHost', '') as string;
    this.brainSshPort = await this.uiPrefs.get('brainSshPort', '22') as string;
    this.authKey = await this.tsPrefs.get('authKey', '') as string;
    this.hostname = await this.tsPrefs.get('hostname', 'harmony') as string;
    this.themeIdx = await this.uiPrefs.get('themeIdx', 0) as number;
    this.fontSize = await this.uiPrefs.get('fontSize', 9) as number;
    // 一次性迁移 v2：旧默认(11/10)缩到新默认 9（只动没自选过字号的安装，
    // fontSize pref 只有用户在设置里点过档位才会写入）
    const fsShrunk: boolean = await this.uiPrefs.get('fs_shrunk_v2', false) as boolean;
    if (!fsShrunk) {
      if (this.fontSize === 11 || this.fontSize === 10) {
        this.fontSize = 9;
      }
      this.uiPrefs.put('fs_shrunk_v2', true).then((): Promise<void> => this.uiPrefs!.flush()).catch(() => {});
    }
    // 服务器配置（唯一权威）：本机有没有 session 决定进主界面还是只显示登录页
    const server = new ServerConfig(ctx, this.store);
    this.serverConfig = server;
    server.onApplied = (): void => {
      if (this.storeReady) {
        this.syncActiveAfterServerApply();
      }
    };
    const hasSession: boolean = await server.hasSession();
    if (!hasSession) {
      // issue #77：没有 session 时**只显示登录页** —— 不加载 store、不连 VPN、不起轮询。
      // 缓存只用于「已登录 + 网络抖动」时不清空界面，不做离线入口。
      this.authGate = 'login';
      return;
    }
    this.accountName = server.username;
    this.authGate = 'ready';
    await this.startMain(ctx);
    // 先拿缓存把界面填上（网络抖动时不清空），再拉服务器快照覆盖，最后开轮询
    await server.restoreCache();
    this.refreshTabs();
    server.refresh().then((): void => {
      this.refreshTabs();
      this.syncActiveAfterServerApply();
    }).catch((): void => {
    });
    server.startPolling();
  }

  /// 登录成功 / 已有 session 之后的主界面启动（抽出来给登录页复用，避免两份逻辑）
  private async startMain(ctx: common.UIAbilityContext): Promise<void> {
    await this.store.load(ctx);
    // 本地个人状态一变（save* 落盘）→ 防抖 PUT 回服务器（不再往任何机器写文件）
    this.store.onLocalChange = (): void => {
      const sc = this.serverConfig;
      if (sc !== null) {
        sc.markDirty();
      }
    };
    // 用户动过休息开关 → restSessions 从此可以随 selection 上传（键没物化过就不传）
    this.store.onRestChange = (): void => {
      const sc = this.serverConfig;
      if (sc !== null) {
        sc.markRestLoaded();
        sc.markDirty();
      }
    };
    // pick the active tab (persisted current, else first visible)
    const vis = this.store.visibleTabs();
    let cur = this.store.currentTabId;
    // current must sit within the visible set (machine filter + rest hiding), else the
    // terminal boots blank on a filtered-out tab — fall back to the first visible one.
    if (vis.findIndex((t: TabModel) => t.id === cur) < 0) {
      cur = vis.length > 0 ? vis[0].id : '';
    }
    this.activeTabId = cur;
    this.storeReady = true;
    this.refreshTabs();
    this.preloadAvatars(ctx);

    this.appendLocal('Blink · HarmonyOS — ' + this.store.machines.length + ' 台机器 · ' +
      this.store.tabs.length + ' 个会话');
    if (this.authKey.length > 0) {
      this.appendLocal('· 正在连接 tailscale …');
      this.tsConnect();
    } else if (this.brainDirectEndpoint(this.store.machineById(
      this.store.tabById(this.activeTabId)?.machineId || '')) === null) {
      this.appendLocal('⚙ 设置里填 tailscale auth key，之后自动连接');
    }
  }

  /// 服务器快照可能删掉了当前 tab：清掉它的连接/终端图层，退回第一篇可见标签
  private syncActiveAfterServerApply(): void {
    // 服务器快照可能换了「后台」书签：浏览器开着就把书签栏刷成 store 里刚采纳的那份
    // （没开的话 openBrowser() 会从 store 重新取，不必在这儿刷）。
    if (this.browserOpened) {
      this.browserPinned = this.store.pinned.slice();
    }
    this.refreshTabs();
    const visibleIds: string[] = this.visTabs.map((t: TabModel): string => t.id);
    this.pool.all().forEach((c: SessionConn) => {
      if (visibleIds.indexOf(c.tabId) < 0) {
        this.pool.remove(c.tabId);
        this.webCtl.runJavaScript(`term_dispose('${c.tabId}')`);
      }
    });
    if (this.activeTabId.length > 0 && visibleIds.indexOf(this.activeTabId) >= 0) {
      return;
    }
    this.activeTabId = '';
    if (this.visTabs.length > 0) {
      this.switchTab(this.visTabs[0].id);
    } else {
      this.webCtl.runJavaScript('term_hide_all()');
      this.refreshTabs();
    }
  }

  private setupKeyboard(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    window.getLastWindow(this.getUIContext().getHostContext()).then((w: window.Window) => {
      this.win = w;
      w.on('keyboardHeightChange', (h: number) => {
        this.kbHeight = px2vp(h);
      });
      // 沉浸式：内容铺进状态栏/导航条区域，避让高度由页面自己垫正确的背景色
      // （iOS：状态栏/tab 条 #0b0c0e，底部安全区随 dock #0A0A0A）
      w.setWindowLayoutFullScreen(true).catch((): void => {});
      w.setWindowSystemBarProperties({ statusBarContentColor: '#F2F2F2' }).catch((): void => {});
      const sys = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInset = px2vp(sys.topRect.height);
      const nav = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.botInset = px2vp(nav.bottomRect.height);
    }).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'keyboard: %{public}s', JSON.stringify(e));
    });
  }

  // ---- terminal I/O ----

  // Write a local status line into the active tab's terminal.
  private appendLocal(s: string): void {
    if (this.activeTabId.length === 0) {
      return;
    }
    this.writeText(this.activeTabId, s + '\r\n');
  }

  private writeText(tabId: string, s: string): void {
    const b64: string = buffer.from(s, 'utf-8').toString('base64');
    this.webCtl.runJavaScript(`term_write_b64('${tabId}','${b64}')`);
  }

  // 往指定 tab 写一行连接状态（带颜色）。dedupe=true 时同一行不重复刷——
  // attach 每 1.5s 轮询会重进，靠 conn.lastNote 挡掉刷屏。
  private note(tabId: string, conn: SessionConn | null, s: string, dedupe: boolean): void {
    if (dedupe && conn !== null && conn.lastNote === s) {
      return;
    }
    if (conn !== null) {
      conn.lastNote = s;
    }
    this.writeText(tabId, s + '\r\n');
  }

  // 把 onState 的 detail 收拾成一句人话。error 时 detail 是 BusinessError 的 JSON。
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

  // tailscale 后端状态变化时写一行到当前 tab（去重，只在状态真的变了时刷）。
  private noteTsState(state: string): void {
    let line: string = '';
    if (state === 'Running') {
      const ip: string = this.tsIP.length > 0 ? ('（' + this.tsIP + '）') : '';
      line = '\u001b[32m✓ tailscale 已连接' + ip + '\u001b[0m';
    } else if (state === 'Stopped') {
      line = '\u001b[33m⚠ tailscale 已停止，正在重连…\u001b[0m';
    } else if (state === 'NeedsLogin' || state === 'NoState') {
      line = '\u001b[33m⚠ tailscale 需要登录，去设置里填 auth key\u001b[0m';
    } else if (state === 'VpnFailed') {
      line = '\u001b[31m✗ ' + (this.tsError.length > 0 ? this.tsError : 'VPN 启动失败') + '，正在重试…\u001b[0m';
    } else if (state === 'start failed') {
      line = '\u001b[31m✗ tailscale 启动失败\u001b[0m';
    } else {
      // Starting / Restarting VPN / 其它：统一提示连接中
      line = '\u001b[90m· tailscale ' + state + ' …\u001b[0m';
    }
    if (line === this.lastTsNote) {
      return;
    }
    this.lastTsNote = line;
    this.appendLocal(line);
  }

  private writeBytes(tabId: string, bytes: Uint8Array): void {
    const b64: string = this.b64.encodeToStringSync(bytes);
    this.webCtl.runJavaScript(`term_write_b64('${tabId}','${b64}')`);
  }

  private onBridge(op: string, dataStr: string): void {
    if (op === 'sigwinch') {
      try {
        const d = JSON.parse(dataStr) as Record<string, number>;
        const c: number = d.cols as number;
        const r: number = d.rows as number;
        if (c > 0 && r > 0) {
          this.cols = c;
          this.rows = r;
          const conn = this.pool.get(this.activeTabId);
          if (conn !== null && conn.state === 'connected') {
            conn.client.sendResize(r, c);
          }
        }
      } catch (e) {
      }
    } else if (op === 'ready') {
      const th: Theme = THEMES[this.themeIdx];
      this.webCtl.runJavaScript(`term_set_colors('${th.bg}','${th.fg}','${th.cursor}')`);
      this.webCtl.runJavaScript(`term_setFontSize(${this.fontSize})`);
      // create + show the active tab's layer, then connect it once tailscale is up
      if (this.activeTabId.length > 0) {
        this.webCtl.runJavaScript(`term_show('${this.activeTabId}')`);
        // Web/hterm 就绪后补一次连接：登录后立即 attach 时 Web 还没 ready，
        // runJavaScript 会丢（终端一片白就是这个时序）。附：换 tab 后也是一样的道理。
        this.attach(this.activeTabId, false);
      } else {
        this.syncActiveAfterServerApply();
      }
    } else if (op === 'error') {
      hilog.error(DOMAIN, TAG, 'hterm: %{public}s', dataStr);
    } else if (op === 'wheel') {
      this.sendWheel(dataStr);
    }
  }

  // A vertical drag over a full-screen app (alt-screen) becomes SGR mouse-wheel bytes
  // sent over the blinkd connection — hterm's io isn't wired to blinkd, so JS asks us
  // to send. tmux(mouse on) forwards the wheel to the app (claude), which scrolls its
  // own history. btn 64 = wheel-up (older lines), 65 = wheel-down.
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

  // ---- tailscale ----

  private filesDir(): string {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return ctx.filesDir;
  }

  private buildWant(): Want {
    return {
      deviceId: '',
      bundleName: BUNDLE,
      abilityName: 'TailscaleVpnAbility',
      parameters: {
        stateDir: this.filesDir(),
        hostname: this.hostname.length > 0 ? this.hostname : 'harmony',
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
        wants: [{ bundleName: BUNDLE, abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      const wa = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        ctx, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, wa);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startKeepAlive: %{public}s', `${e}`);
    }
  }

  private async stopKeepAlive(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await backgroundTaskManager.stopBackgroundRunning(ctx);
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
        // tailscale 状态变化时写一行到终端：VPN 没通时 blinkd 不会 attach，
        // 不提示的话用户根本不知道是卡在 VPN 还是卡在 blinkd。
        this.noteTsState(this.tsState);
        if (this.activeTabId.length > 0) {
          this.attach(this.activeTabId, false);
        }
        // 配置刷新不再依赖 VPN：ServerConfig 自己的 15s 轮询 + 回前台刷新走 HTTPS
      } catch (e) {
      }
    }, 1500);
  }

  // 回前台：立即向服务器要一次最新配置（版本没变就是 304，什么都不做）
  onPageShow(): void {
    // 回前台：把 tmux 的活跃客户端抢回本机（别的设备操作过就会变成按它尺寸显示）
    this.sendFocusIn(this.activeTabId);
    const sc = this.serverConfig;
    if (sc !== null) {
      sc.refresh().then((): void => {
        this.refreshTabs();
        this.syncActiveAfterServerApply();
      }).catch((): void => {
      });
    }
  }

  // VPN 看门狗：息屏/省电时系统会杀掉 :vpn 扩展进程，status 文件停更但内容
  // 还停留在旧的 Running，app 便一直红点连不上。VPN 活着时每 1.5s 写一次
  // status，mtime 超过 8s 没动即判死，自动重拉扩展（15s 节流防风暴）。
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
        // 旧 tun 上的连接全成了半开死链（state 还挂着 connected 但永远收不到
        // 数据），attach 会以为活着而跳过。主动断开，让它们在新 tun 上重拨。
        this.pool.all().forEach((c: SessionConn) => {
          c.failCount = 0;
          c.cooldownUntil = 0;
          c.client.close();
        });
      }
    } catch (e) {
      // status 文件还不存在：首连由 boot()/tsConnect 负责，这里不掺和
    }
  }

  // ---- per-tab connection ----

  private attach(tabId: string, force: boolean): void {
    const tab = this.store.tabById(tabId);
    if (tab === null) {
      return;
    }
    const conn = this.pool.getOrCreate(tabId);
    const m = this.store.machineById(tab.machineId);
    if (!force && (conn.state === 'connected' || conn.state === 'connecting')) {
      return;
    }
    if (!force && Date.now() < conn.cooldownUntil) {
      return;
    }
    const direct = this.brainDirectEndpoint(m);
    if (direct !== null && conn.directState === 'new' && m !== null) {
      conn.directState = 'active';
      this.attachDirect(tabId, tab, m, direct.host, direct.port, conn);
      return;
    }
    const primary = this.store.blinkdEndpoint(m);
    const relays: Machine[] = this.sshRelays(primary);
    const ep = conn.relayIndex < 0 ? primary : relays[conn.relayIndex];
    if (ep === null || ep.blinkdHost === undefined || ep.blinkdToken === undefined) {
      if (conn.relayIndex < 0 && relays.length > 0) {
        conn.relayIndex = 0;
        this.attach(tabId, true);
        return;
      }
      if (conn.directState === 'tried') {
        conn.directState = 'new';
        conn.state = 'error';
        conn.failCount++;
        conn.cooldownUntil = Date.now() + Math.min(1500 * Math.pow(2, conn.failCount), 30000);
      }
      this.note(tabId, conn, '\u001b[33m⚠ 没有可用的 blinkd 或 SSH 中转端点\u001b[0m', true);
      return;
    }
    const port0: number = ep.blinkdPort !== undefined ? ep.blinkdPort : 7777;
    const viaSSH: boolean = conn.relayIndex >= 0 || (m !== null && m.transport === 'ssh');
    this.note(tabId, conn, '\u001b[90m[' + (viaSSH ? 'SSH 中转' : 'blinkd') + '] 连接 ' + ep.blinkdHost + ':' + port0 + ' …\u001b[0m', false);
    conn.client.close();
    const client = new BlinkdClient();
    conn.client = client;
    client.onData = (bytes: Uint8Array) => {
      if (conn.client !== client) {
        return;
      }
      this.writeBytes(tabId, bytes);
      if (tabId !== this.activeTabId && !conn.unread) {
        conn.unread = true;
        this.refreshTabs();
      }
    };
    client.onState = (st: BlinkdState, detail: string) => {
      if (conn.client !== client) {
        return;
      }
      this.onConnState(tabId, st, detail);
    };
    this.webCtl.runJavaScript(`term_create('${tabId}')`);
    conn.state = 'connecting';
    this.tick++;
    const port: number = ep.blinkdPort !== undefined ? ep.blinkdPort : 7777;
    client.connect(ep.blinkdHost, port, ep.blinkdToken, this.rows, this.cols, this.store.execForTab(tab, viaSSH));
  }

  private brainDirectEndpoint(m: Machine | null): DirectSshEndpoint | null {
    if (m === null || m.name.toLowerCase() !== 'brain' || m.user.length === 0) {
      return null;
    }
    const host = this.brainSshHost.trim().length > 0 ? this.brainSshHost.trim() : (m.host2 || '').trim();
    const port = Number(this.brainSshPort);
    if (host.length === 0 || new RegExp('[\\s/@]').test(host) || !Number.isInteger(port) || port < 1 || port > 65535) {
      return null;
    }
    const endpoint: DirectSshEndpoint = { host: host, port: port };
    return endpoint;
  }

  private saveBrainSsh(): void {
    const host = this.brainSshHost.trim();
    const port = Number(this.brainSshPort);
    if (host.length > 0 && new RegExp('[\\s/@]').test(host)) {
      this.toast('SSH 地址格式不正确');
      return;
    }
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      this.toast('SSH 端口需为 1–65535');
      return;
    }
    const prefs = this.uiPrefs;
    if (prefs === null) {
      return;
    }
    prefs.put('brainSshHost', host).then((): Promise<void> => prefs.put('brainSshPort', String(port)))
      .then((): Promise<void> => prefs.flush()).then((): void => {
        this.pool.all().forEach((c: SessionConn): void => {
          const tab = this.store.tabById(c.tabId);
          const machine = tab !== null ? this.store.machineById(tab.machineId) : null;
          if (machine !== null && machine.name.toLowerCase() === 'brain') {
            c.client.close();
            c.state = 'idle';
            c.relayIndex = -1;
            c.directState = 'new';
            c.cooldownUntil = 0;
          }
        });
        this.toast('已保存 brain SSH 地址');
        if (this.activeTabId.length > 0) {
          this.attach(this.activeTabId, true);
        }
      }).catch((): void => this.toast('保存 SSH 地址失败'));
  }

  private showSshPublicKey(): void {
    SshIdentity.authorizedKey().then((key: string): void => {
      this.sshPublicKey = key;
      this.sshKeyError = '';
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, key);
      pasteboard.getSystemPasteboard().setData(data)
        .then((): void => this.toast('公钥已复制，可加入 brain 的 authorized_keys'))
        .catch((): void => this.toast('公钥已显示，复制失败'));
    }).catch((e: Object): void => {
      const error = e as BusinessError;
      const code: string = error.code !== undefined ? (error.code + ' ') : '';
      this.sshKeyError = '无法生成 SSH 公钥：' + code + error.message;
    });
  }

  private attachDirect(tabId: string, tab: TabModel, m: Machine,
                       host: string, port: number, conn: SessionConn): void {
    this.note(tabId, conn, '\u001b[90m[SSH 直连] 连接 ' + host + ':' + port + ' …\u001b[0m', false);
    conn.client.close();
    const client = new SshDirectClient();
    conn.client = client;
    client.onData = (bytes: Uint8Array): void => {
      if (conn.client !== client) {
        return;
      }
      this.writeBytes(tabId, bytes);
      if (tabId !== this.activeTabId && !conn.unread) {
        conn.unread = true;
        this.refreshTabs();
      }
    };
    client.onState = (st: BlinkdState, detail: string): void => {
      if (conn.client === client) {
        this.onConnState(tabId, st, detail);
      }
    };
    client.onHostKey = (keyHost: string, keyPort: number, key: Uint8Array, fp: string): Promise<boolean> =>
      this.confirmSshHostKey(m.id, keyHost, keyPort, key, fp);
    this.webCtl.runJavaScript(`term_create('${tabId}')`);
    conn.state = 'connecting';
    this.tick++;
    client.connect(host, port, m.user, this.rows, this.cols, this.store.execForTab(tab, false, true));
  }

  private confirmSshHostKey(machineId: string, host: string, port: number,
                            key: Uint8Array, fingerprint: string): Promise<boolean> {
    const prefs = this.uiPrefs;
    if (prefs === null) {
      return Promise.resolve(false);
    }
    const name = 'sshHostKey:' + machineId + '@' + host + ':' + port;
    const encoded = buffer.from(key).toString('base64');
    return prefs.get(name, '').then((saved: preferences.ValueType): Promise<boolean> => {
      if (saved === encoded) {
        return Promise.resolve(true);
      }
      if (saved !== '') {
        this.toast('SSH 主机密钥发生变化，连接已拒绝');
        return Promise.resolve(false);
      }
      return new Promise<boolean>((resolve: (trusted: boolean) => void): void => {
        this.getUIContext().showAlertDialog({
          title: '确认 brain 的 SSH 主机密钥',
          message: host + ':' + port + '\n' + fingerprint + '\n请与服务器上的指纹核对。',
          primaryButton: { value: '信任并连接', action: (): void => {
            prefs.put(name, encoded).then((): Promise<void> => prefs.flush())
              .then((): void => resolve(true)).catch((): void => resolve(false));
          } },
          secondaryButton: { value: '取消', action: (): void => resolve(false) }
        });
      });
    });
  }

  private sshRelays(primary: Machine | null): Machine[] {
    const relays: Machine[] = [];
    for (let i = 0; i < this.store.machines.length; i++) {
      const candidate = this.store.machines[i];
      if (candidate.transport === 'blinkd' && candidate.id !== (primary !== null ? primary.id : '') &&
          candidate.blinkdHost !== undefined && candidate.blinkdHost.length > 0 &&
          candidate.blinkdToken !== undefined && candidate.blinkdToken.length > 0) {
        relays.push(candidate);
      }
    }
    return relays;
  }

  private onConnState(tabId: string, st: BlinkdState, detail: string): void {
    const conn = this.pool.get(tabId);
    if (conn === null) {
      return;
    }
    // (refreshTabs at the end updates the strip's status dot)
    // 状态行也写进终端，让用户看得到「连上没 / 为什么断 / 几秒后重连」——
    // 以前这里只改 state + 刷小圆点，终端全程空白只剩光标闪。
    if (st === 'connecting') {
      conn.state = 'connecting';
    } else if (st === 'connected') {
      conn.state = 'connected';
      conn.connectedAt = Date.now();
      conn.everConnected = true;
      this.note(tabId, conn, '\u001b[32m✓ 已连接\u001b[0m' + (detail.length > 0 ? ' \u001b[2m· ' + detail + '\u001b[0m' : ''), false);
    } else if (st === 'closed' || st === 'error') {
      // The socket may emit error and close for one failure; handle it once.
      conn.client.onState = (_next: BlinkdState, _detail: string): void => {};
      if (conn.directState === 'active') {
        conn.directState = 'tried';
        conn.state = 'idle';
        this.note(tabId, conn, '\u001b[33m⚠ SSH 直连失败：' + detail + '，尝试 blinkd…\u001b[0m', false);
        setTimeout((): void => { this.attach(tabId, true); }, 0);
        return;
      }
      const tab = this.store.tabById(tabId);
      const machine = tab !== null ? this.store.machineById(tab.machineId) : null;
      const relays = this.sshRelays(this.store.blinkdEndpoint(machine));
      if (machine !== null && machine.host.length > 0 && machine.user.length > 0 &&
          conn.relayIndex + 1 < relays.length) {
        conn.relayIndex++;
        conn.state = 'idle';
        this.note(tabId, conn, '\u001b[33m⚠ 当前连接失败，改走 SSH 中转…\u001b[0m', false);
        setTimeout(() => { this.attach(tabId, true); }, 0);
        return;
      }
      conn.relayIndex = -1;
      conn.directState = 'new';
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
          const secs: number = Math.round(wait / 1000);
          this.note(tabId, conn,
            '\u001b[33m⚠ ' + verb + why + '，' + secs + ' 秒后自动重连（第 ' + conn.failCount + ' 次）\u001b[0m',
            false);
        }
      } else {
        this.note(tabId, conn,
          '\u001b[33m⚠ ' + verb + why + '（自动重连已关，点刷新重连）\u001b[0m', false);
      }
    }
    this.refreshTabs();
  }

  private connState(tabId: string): ConnUiState {
    const c = this.pool.get(tabId);
    return c !== null ? c.state : 'idle';
  }

  // ---- tab operations ----

  private switchTab(tabId: string): void {
    if (tabId === this.activeTabId) {
      return;
    }
    this.activeTabId = tabId;
    this.store.currentTabId = tabId;
    this.store.saveCurrent();
    this.inputBuf = '';
    this.lastLen = 0;
    this.webCtl.runJavaScript(`term_show('${tabId}')`);
    const conn = this.pool.get(tabId);
    if (conn !== null) {
      conn.unread = false;
      // 用户主动切过来：清掉重连退避（最长 30s），否则断着的 tab 在冷却期内
      // attach 会静默跳过，切过去就是一片空白、只能手点刷新。
      if (conn.state !== 'connected' && conn.state !== 'connecting') {
        conn.failCount = 0;
        conn.cooldownUntil = 0;
      }
    }
    // 不再等 VPN：服务器下发的机器（公网/内网地址）直接试连，连不上会自己报错重试。
    // 老逻辑等 tsState==='Running'（tailscale）——没开 VPN 时切标签永远白屏（#74 同一课）。
    this.attach(tabId, false);
    this.sendFocusIn(tabId);
    this.refreshTabs();
    this.scrollToActiveTab();
  }

  // Keep the active tab visible in the strip after a switch/swipe (iOS scrollToItem):
  // scroll the horizontal tab List so the current tab sits centered.
  private scrollToActiveTab(): void {
    const idx: number = this.visTabs.findIndex((t: TabModel) => t.id === this.activeTabId);
    if (idx >= 0) {
      this.tabScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    }
  }

  // Horizontal swipe over the terminal switches session (mirrors iOS SpaceController's
  // page-swipe between shells): swipe left → next tab, swipe right → previous, wrapping
  // around so a continued swipe cycles through EVERY open session — across machines too.
  // The swipe set is exactly the same on-duty public list as the dock.
  private swipeTab(dir: number): void {
    const all: TabModel[] = this.store.visibleTabs();
    if (all.length <= 1) {
      return;
    }
    const idx: number = all.findIndex((t: TabModel) => t.id === this.activeTabId);
    if (idx < 0) {
      return;
    }
    let n: number = idx + dir;
    if (n < 0) {
      n = all.length - 1;
    } else if (n >= all.length) {
      n = 0;
    }
    this.switchTab(all[n].id);
  }

  private newTab(machineId: string, workDirId: string, session: string): void {
    const t: TabModel = {
      id: BlinkStore.newId(),
      machineId: machineId,
      workDirId: workDirId,
      tmuxSession: session.length > 0 ? session : 'new',
      useTmux: true,
    };
    this.store.tabs.push(t);
    this.store.saveTabs();
    this.sheet = 'none';
    this.refreshTabs();
    this.switchTab(t.id);
  }

  // 按 host 找钉住浏览器 tab 里存的 Basic Auth 账密(prototype 门禁站等,与浏览器共用一份)
  private pinnedAuthFor(host: string): string[] | null {
    for (let i = 0; i < this.store.pinned.length; i++) {
      const t = this.store.pinned[i];
      if (t.authUser === undefined || t.authUser.length === 0 || t.authPassword === undefined) {
        continue;
      }
      const m = t.url.match(new RegExp('^https?://([^/]+)'));
      if (m === null) {
        continue;
      }
      const h: string = m[1];
      if (h === host || h.split(':')[0] === host) {
        return [t.authUser, t.authPassword];
      }
    }
    // 内置兜底：prototype 原型站没钉住时也能显示门禁内截图（钉住 tab 的账密优先）
    if (host === 'prototype.douwantech.com') {
      return ['binku87', 'binku87works'];
    }
    return null;
  }

  private closeTab(tabId: string): void {
    this.pool.remove(tabId);
    this.webCtl.runJavaScript(`term_dispose('${tabId}')`);
    const idx: number = this.store.tabs.findIndex((x: TabModel) => x.id === tabId);
    if (idx >= 0) {
      this.store.tabs.splice(idx, 1);
    }
    // 墓碑：显式关闭要跨设备传播，否则 iOS 那边还开着又会整份推回来复活
    if (this.store.closedIds.indexOf(tabId) < 0) {
      this.store.closedIds.push(tabId);
      while (this.store.closedIds.length > 500) {
        this.store.closedIds.shift();
      }
      this.store.saveClosed();
    }
    this.store.saveTabs();
    this.refreshTabs();
    if (this.activeTabId === tabId) {
      this.activeTabId = '';
      if (this.visTabs.length > 0) {
        this.switchTab(this.visTabs[0].id);
      }
    }
  }

  private reconnectActive(): void {
    const conn = this.pool.get(this.activeTabId);
    if (conn !== null) {
      conn.failCount = 0;
      conn.cooldownUntil = 0;
      conn.relayIndex = -1;
      conn.directState = 'new';
      conn.client.close();
    }
    this.webCtl.runJavaScript(`term_clear('${this.activeTabId}')`);
    this.attach(this.activeTabId, true);
  }

  // ---- input ----

  /** tmux 焦点进入：切到这个标签 / 回前台时补发一次 ESC [ I，让 tmux 把这台设备当成最近活跃的
   *  客户端、按它的尺寸重排（别的设备操作完、本机被缩成一小块的那次）。
   *  只对 tmux 标签发；同一标签 1s 内最多一次；没连上就不发（连上时 attach 本身就会成为活跃客户端）。 */
  private sendFocusIn(tabId: string): void {
    if (tabId.length === 0) {
      return;
    }
    const tab = this.store.tabById(tabId);
    if (tab === null || !tab.useTmux) {
      return;
    }
    const now: number = Date.now();
    const last: number | undefined = this.focusInAt[tabId];
    if (last !== undefined && now - last < FOCUS_IN_MIN_MS) {
      return;
    }
    const conn = this.pool.get(tabId);
    if (conn === null || conn.state !== 'connected') {
      return;
    }
    this.focusInAt[tabId] = now;
    conn.client.sendBytes(new Uint8Array(FOCUS_IN_BYTES));
  }

  private activeClient(): BlinkdClient | SshDirectClient | null {
    const c = this.pool.get(this.activeTabId);
    return (c !== null && c.state === 'connected') ? c.client : null;
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
      client.sendInput('\n');
    }
    this.skipNext = true;
    this.inputBuf = '';
    this.lastLen = 0;
  }

  private sendKey(bytes: number[]): void {
    const client = this.activeClient();
    if (client !== null) {
      client.sendBytes(new Uint8Array(bytes));
    }
  }

  // send a full line + enter (Claude cmd / favorite / history / composer)
  // 回车只发一个、但延迟一拍：claude 这类 TUI 会把紧跟文本的回车并进粘贴
  // 内容里（表现为要手动再按一次回车才发送），隔开发就稳了。不能补发第二个
  // 回车——/rewind 这类弹菜单的命令会被第二下直接确认关掉。
  private sendLine(text: string): void {
    const client = this.activeClient();
    if (client !== null) {
      client.sendInput(text);
      setTimeout(() => {
        const c = this.activeClient();
        if (c !== null) {
          c.sendInput('\r');
        }
      }, 180);
    }
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1600 });
    } catch (e) {
    }
  }

  // Reassign the @State tab list so ArkUI re-renders the strip (the store itself
  // is a plain class ArkUI can't observe). Call after any tab/conn/filter change.
  // Also mirror the top-bar's dynamic labels into @State: topBar() is a no-arg
  // @Builder that reads no @State directly, so ArkUI skips re-running it unless a
  // @State it reads changes — that's why 🌙 count / filter pill go through @State.
  private refreshTabs(): void {
    this.visTabs = this.store.visibleTabs();
    this.restCount = this.store.restingCount();
    this.filterLabel = this.machineFilterLabel();
    this.tick++;
  }

  // Switch the machine filter AND move onto that machine's session — iOS _applyMachineFilter.
  // Picking a machine used to only filter the strip; the terminal stayed on the old machine's
  // tab (which then got filtered out, leaving nothing highlighted). Now: remember the tab we're
  // leaving, apply the filter, then land on that machine's remembered tab (else the current tab
  // if still visible, else its first). switchTab handles the reconnect + strip scroll.
  private applyMachineFilter(machineId: string): void {
    const curTab = this.store.tabById(this.activeTabId);
    if (curTab !== null) {
      this.lastTabPerMachine[curTab.machineId] = this.activeTabId;
    }
    this.store.filterMachineId = machineId;
    this.store.saveFilter();
    this.refreshTabs();
    const filtered = this.visTabs;
    let target: string = '';
    const remembered: string | undefined = machineId.length > 0 ? this.lastTabPerMachine[machineId] : undefined;
    if (remembered !== undefined && filtered.some((t: TabModel) => t.id === remembered)) {
      target = remembered;
    } else if (machineId.length > 0) {
      // 坞不再按机器收窄（iOS 手机端口径），所以不能拿 filtered[0] 当该机器的第一条。
      // 自己从该机器里挑：优先在岗公用标签，退而求其任意标签。
      const ofMachine: TabModel[] = this.store.tabs.filter((t: TabModel) => t.machineId === machineId);
      const onDuty: TabModel[] = ofMachine.filter((t: TabModel) => this.store.isShared(t.id) && this.store.isOnDuty(t));
      if (onDuty.length > 0) {
        target = onDuty[0].id;
      } else if (ofMachine.length > 0) {
        target = ofMachine[0].id;
      }
    } else if (filtered.some((t: TabModel) => t.id === this.activeTabId)) {
      target = this.activeTabId;
    } else if (filtered.length > 0) {
      target = filtered[0].id;
    }
    if (target.length > 0 && target !== this.activeTabId) {
      this.switchTab(target);
    }
  }

  // ---- appearance ----

  private applyTheme(i: number): void {
    if (i < 0 || i >= THEMES.length) {
      return;
    }
    this.themeIdx = i;
    const th: Theme = THEMES[i];
    this.webCtl.runJavaScript(`term_set_colors('${th.bg}','${th.fg}','${th.cursor}')`);
    const p = this.uiPrefs;
    if (p !== null) {
      p.put('themeIdx', i).then((): Promise<void> => p.flush()).catch(() => {});
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

  // ---- voice pipeline（按住说话，iOS VoiceInputView 流程）----

  private async holdStart(): Promise<void> {
    if (this.fieldMode === 'busy' || this.fieldMode === 'review' || this.recording) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const atm = abilityAccessCtrl.createAtManager();
      const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
      await atm.requestPermissionsFromUser(ctx, perms);
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
            this.store.voice.model, this.store.history,
            GlmClient.termEntries(this.store.terms), this.store.corrections);
          // learn the correction pair (iOS recordCorrection)
          if (out !== raw && raw.length > 0) {
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

  // send + record history (iOS commitText)
  private commitLine(text: string): void {
    const t: string = text.trim();
    if (t.length === 0) {
      return;
    }
    this.sendLine(t);
    // 发送按钮：正常文本在单回车之后再补一个回车，确保提交（第一个回车常被括号
    // 粘贴吞进内容里没提交）。/rewind /compact 走 sendLine 单回车不经过这里。
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

  private sendReview(): void {
    this.commitLine(this.reviewText);
    this.reviewText = '';
    this.fieldMode = 'idle';
  }

  private discardReview(): void {
    this.reviewText = '';
    this.fieldMode = 'idle';
    this.toast('已丢弃');
  }

  // 轻点语音条（没按住）→ 浮动打字条（iOS FloatingTextInputPanel）
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

  private useFavorite(text: string): void {
    this.sendLine(text);
    const c = this.store.favoriteCounts[text];
    this.store.favoriteCounts[text] = (c !== undefined ? c : 0) + 1;
    this.store.saveFavorites();
    this.sheet = 'none';
  }

  private async pasteClipboard(): Promise<void> {
    try {
      const sys = pasteboard.getSystemPasteboard();
      const data = await sys.getData();
      const text: string = data.getPrimaryText();
      if (text && text.length > 0) {
        this.sendLine(text);
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
      const res = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (res.photoUris.length === 0) {
        return;
      }
      this.toast('上传图片中…');
      const url: string = await Uploader.uploadImage(res.photoUris[0], 'image.png');
      this.sendLine(url);
    } catch (e) {
      this.toast('图片上传失败: ' + e);
    }
  }

  // ---- 对话记录页:秒显缓存 → 后台只拉 jsonl 新增行(iOS 同一套) ----

  private dumpTranscript(): void {
    this.openChatRecord();
  }

  private chatCachePath(tabId: string): string {
    return this.filesDir() + '/transcript_' + tabId + '.json';
  }

  private loadChatCache(tabId: string): TranscriptCacheH | null {
    try {
      const txt: string = fs.readTextSync(this.chatCachePath(tabId));
      const c: TranscriptCacheH = JSON.parse(txt) as TranscriptCacheH;
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
        // 从头裁到角色边界,保持消息完整
        const tail: string = b.substring(b.length - 300000);
        const i1: number = tail.indexOf('\n▶');
        const i2: number = tail.indexOf('\n◆');
        let cutAt: number = -1;
        if (i1 >= 0 && i2 >= 0) {
          cutAt = Math.min(i1, i2);
        } else {
          cutAt = Math.max(i1, i2);
        }
        b = cutAt >= 0 ? tail.substring(cutAt + 1) : tail;
      }
      const c: TranscriptCacheH = { file: file, lines: lines, body: b };
      const f = fs.openSync(this.chatCachePath(tabId),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
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

  private async openChatRecord(): Promise<void> {
    const tab = this.store.tabById(this.activeTabId);
    if (tab === null) {
      return;
    }
    const m = this.store.machineById(tab.machineId);
    const ep = this.store.blinkdEndpoint(m);
    const direct = this.brainDirectEndpoint(m);
    const current = this.pool.get(tab.id);
    const useDirect = direct !== null && current !== null && current.client instanceof SshDirectClient &&
      current.state === 'connected';
    if (!useDirect && (ep === null || ep.blinkdHost === undefined || ep.blinkdToken === undefined)) {
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
    this.showTranscript = true;
    if (useDirect && direct !== null && m !== null) {
      this.fetchChatDelta(tab, direct.host, direct.port, m.user,
        cached !== null ? cached.file : '', cached !== null ? cached.lines : 0, true);
    } else if (ep !== null && ep.blinkdHost !== undefined && ep.blinkdToken !== undefined) {
      this.fetchChatDelta(tab, ep.blinkdHost,
        ep.blinkdPort !== undefined ? ep.blinkdPort : 7777, ep.blinkdToken,
        cached !== null ? cached.file : '', cached !== null ? cached.lines : 0, false);
    }
  }

  // 页内 <img> 加载失败(多半是门禁 401——Web 的 auth 挑战对子资源不生效):
  // 原生带 Basic 账密抓回来,以 data URI 塞回去,门禁内的截图也能直接显示。
  private fetchChatImage(url: string, id: string): void {
    const header: Record<string, string> = {};
    let host: string = '';
    const m = url.match(new RegExp('^https?://([^/:]+)'));
    if (m !== null) {
      host = m[1];
    }
    const cred: string[] | null = this.pinnedAuthFor(host);
    if (cred !== null) {
      const enc = new util.TextEncoder();
      header['Authorization'] = 'Basic ' + this.b64.encodeToStringSync(enc.encodeInto(cred[0] + ':' + cred[1]));
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
      // 6MB 上限:整页长图也够用,再大塞 data URI 会把 Web 拖垮
      if (rsp.responseCode !== 200 || bytes.byteLength === 0 || bytes.byteLength > 6000000) {
        this.chatWebCtl.runJavaScript(`imgGiveUp('${id}')`);
        return;
      }
      let mime: string = 'image/png';
      const ct = rsp.header as Record<string, string>;
      if (ct !== undefined && typeof ct['content-type'] === 'string') {
        mime = ct['content-type'].split(';')[0];
      }
      const uri: string = 'data:' + mime + ';base64,' + this.b64.encodeToStringSync(new Uint8Array(bytes));
      this.chatWebCtl.runJavaScript(`imgReady('${id}','${uri}')`);
    }).catch(() => {
      req.destroy();
      try {
        this.chatWebCtl.runJavaScript(`imgGiveUp('${id}')`);
      } catch (e) {
      }
    });
  }

  // 生成 HTML 落到 filesDir,Web loadUrl(带 ?v= 防缓存);controller 未挂载时由
  // onControllerAttached 兜底加载 chatUrl
  private renderChat(body: string): void {
    try {
      const enc = new util.TextEncoder();
      const payload: string = this.b64.encodeToStringSync(
        enc.encodeInto(body.length > 0 ? body : '◆ Claude\n⏳ 正在拉取最新对话…'));
      const html: string = buildChatHtml(payload, this.chatAvatarURI, this.chatName);
      // 双文件轮换防 Web 缓存(file URL 带 ?query 在部分内核上解析不稳,不用)
      this.chatSeq++;
      const p: string = this.filesDir() + (this.chatSeq % 2 === 0 ? '/chat_a.html' : '/chat_b.html');
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, html);
      fs.closeSync(f);
      this.chatUrl = 'file://' + p;
      try {
        this.chatWebCtl.loadUrl(this.chatUrl);
      } catch (e) {
        // Web 还没挂载:overlay 构建时 src 直接用 chatUrl,首帧自己会加载
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'chat render: %{public}s', `${e}`);
    }
  }

  private fetchChatDelta(tab: TabModel, host: string, port: number, tokenOrUser: string,
                          cachedFile: string, cachedLines: number, direct: boolean): void {
    let script = this.store.transcriptDeltaScriptForTab(tab, cachedFile, cachedLines);
    if (script === null) {
      this.chatRefreshing = false;
      return;
    }
    const m = this.store.machineById(tab.machineId);
    if (!direct && m !== null && m.transport !== 'blinkd') {
      // ssh 机器:脚本经中转机 blinkd 再 ssh 过去跑
      const sb64: string = this.b64.encodeToStringSync(new util.TextEncoder().encodeInto(script));
      script = 'ssh ' + m.user + '@' + m.host + ' -- ' + BlinkStore.shq('echo ' + sb64 + ' | base64 -d | bash');
    }
    let buf: string = '';
    let done: boolean = false;
    const dec = util.TextDecoder.create('utf-8');
    const client: BlinkdClient | SshDirectClient = direct ? new SshDirectClient() : new BlinkdClient();
    this.transcriptClient = client;
    const finish = (): void => {
      if (done) {
        return;
      }
      done = true;
      client.close();
      this.transcriptClient = null;
      this.chatRefreshing = false;
      this.handleChatPayload(tab.id, buf);
    };
    client.onData = (bytes: Uint8Array) => {
      buf += dec.decodeToString(bytes, { stream: true });
      if (buf.indexOf('@TSB64E@') >= 0) {
        finish();
      }
    };
    client.onState = (st: BlinkdState) => {
      if (st === 'closed' || st === 'error') {
        finish();
      }
    };
    if (client instanceof SshDirectClient) {
      client.onHostKey = (keyHost: string, keyPort: number, key: Uint8Array, fp: string): Promise<boolean> =>
        this.confirmSshHostKey(tab.machineId, keyHost, keyPort, key, fp);
      client.connect(host, port, tokenOrUser, 24, 80, 'bash -lc ' + BlinkStore.shq(script));
    } else {
      client.connect(host, port, tokenOrUser, 24, 80, script);
    }
    setTimeout(finish, 20000);
  }

  private handleChatPayload(tabId: string, raw: string): void {
    const i1: number = raw.indexOf('@TSB64@');
    const i2: number = raw.indexOf('@TSB64E@');
    if (i1 < 0 || i2 <= i1) {
      const cachedOld = this.loadChatCache(tabId);
      if (cachedOld === null || cachedOld.body.length === 0) {
        this.renderChat('◆ Claude\n拉取失败,请稍后重试');
      }
      return;
    }
    const b64s: string = raw.substring(i1 + 7, i2).replace(new RegExp('[^A-Za-z0-9+/=]', 'g'), '');
    let payload: string = '';
    try {
      const bytes: Uint8Array = this.b64.decodeSync(b64s);
      payload = util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (e) {
      return;
    }
    const nl: number = payload.indexOf('\n');
    const metaLine: string = nl >= 0 ? payload.substring(0, nl) : payload;
    const body: string = nl >= 0 ? payload.substring(nl + 1) : '';
    const meta: string[] = metaLine.split('\t');
    if (meta.length < 4 || meta[0] !== 'META') {
      return;
    }
    const file: string = meta[1];
    const lineCount: number = Number.parseInt(meta[2], 10) > 0 ? Number.parseInt(meta[2], 10) : 0;
    const isFull: boolean = meta[3] === '1';
    if (file === 'NOTFOUND') {
      this.renderChat(body.length > 0 ? '◆ Claude\n' + body : '◆ Claude\n(无内容)');
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
    if ((isFull || body.length > 0 || !hadCache) && this.chatTabId === tabId && this.showTranscript) {
      this.renderChat(merged);
    }
  }

  private closeChatRecord(): void {
    this.showTranscript = false;
    if (this.transcriptClient !== null) {
      this.transcriptClient.close();
      this.transcriptClient = null;
    }
    this.chatRefreshing = false;
  }

  // ===========================================================================
  // UI builders
  // ===========================================================================

  // Load real iOS workDir icons (rawfile PNGs) into PixelMaps once. Dynamic
  // $rawfile() in <Image> is unreliable at runtime, so decode to PixelMap and
  // feed that instead.
  private async preloadAvatars(ctx: common.UIAbilityContext): Promise<void> {
    for (let i = 0; i < this.store.workDirs.length; i++) {
      const w = this.store.workDirs[i];
      if (w.hasIcon !== true || this.avatarCache.has(w.id)) {
        continue;
      }
      try {
        const raw: Uint8Array = await ctx.resourceManager.getRawFileContent('avatars/' + w.id + '.png');
        const src = image.createImageSource(raw.buffer as ArrayBuffer);
        const pm = await src.createPixelMap();
        this.avatarCache.set(w.id, pm);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'avatar %{public}s: %{public}s', w.id, `${e}`);
      }
    }
    // 解码完成后重建 tab 条：visTabs 重新赋值 + key 里的 avatarCache.size 变化
    // 才会让 ForEach 丢弃字母兜底条目换成真头像。
    this.refreshTabs();
  }

  // avatar for a workDir (real iOS icon if decoded, else colored initial)
  @Builder
  avatar(w: WorkDir | null, active: boolean, size: number) {
    if (w !== null && this.avatarCache.has(w.id)) {
      Image(this.avatarCache.get(w.id))
        .width(size).height(size).borderRadius(size / 2).objectFit(ImageFit.Cover)
    } else {
      Stack() {
        Text(w !== null && w.name.length > 0 ? w.name.substring(0, 1).toUpperCase() : '?')
          .fontSize(size * 0.5).fontColor('#FFFFFF')
      }
      .width(size).height(size).borderRadius(size / 2)
      .backgroundColor(active ? '#B4694E' : '#5A5A5E')
    }
  }

  // 头像 + 右下角 CLI 角标（方案 A）：品牌色圆盘 + 官方 mark，外圈底色描边抠出来。
  // 角标直径跟着头像等比缩（26/30 → 13/15），再小图形就认不出来了。
  @Builder
  avatarMark(w: WorkDir | null, active: boolean, size: number, agent: string, ring: string) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      this.avatar(w, active, size)
      Stack() {
        Stack() {
          Image(BlinkStore.agentMark(agent))
            .width(Math.max(13, size * 0.5) * 0.62).height(Math.max(13, size * 0.5) * 0.62)
            .fillColor(BlinkStore.agentInk(agent)).draggable(false)
        }
        .width(Math.max(13, size * 0.5)).height(Math.max(13, size * 0.5))
        .borderRadius(Math.max(13, size * 0.5) / 2)
        .backgroundColor(BlinkStore.agentBrand(agent))
      }
      .width(Math.max(13, size * 0.5) + 3).height(Math.max(13, size * 0.5) + 3)
      .borderRadius((Math.max(13, size * 0.5) + 3) / 2)
      .backgroundColor(ring)
      .offset({ x: size * 0.13, y: size * 0.13 })
    }
    .width(size).height(size)
  }

  // 截图样式的单行顶栏：tab 胶囊横滑 + 右侧 ⋯ 更多（原 ⚙/机器/🌙/＋ 都在里面）
  @Builder
  tabBar() {
    Row({ space: 8 }) {
      // Horizontal List (not Scroll) so switchTab/swipeTab can scrollToIndex the active
      // tab into view — the strip now follows left/right session switches (iOS scrollToItem).
      List({ space: 8, scroller: this.tabScroller }) {
        ForEach(this.visTabs, (t: TabModel) => {
          ListItem() {
            this.sessionTab(t)
          }
        }, (t: TabModel) => t.id + '_' + this.connState(t.id) + '_' + (t.id === this.activeTabId ? '1' : '0') + '_' + (this.tabUnread(t) ? 'u' : '') + '_' + this.agentOf(t) + '_' + this.avatarCache.size)
      }
      .listDirection(Axis.Horizontal).scrollBar(BarState.Off).align(Alignment.Start)
      .layoutWeight(1).height(40)
      Stack() {
        Text('⋯').fontSize(20).fontColor('#DADADA')
      }
      .width(40).height(40).borderRadius(20)
      .backgroundColor('#161618').border({ width: 1, color: '#14FFFFFF' })
      .onClick(() => { this.sheet = 'more'; })
    }
    .width('100%').height(52).padding({ left: 12, right: 12, top: 4, bottom: 8 })
    .backgroundColor('#0b0c0e')
  }

  // iOS phone dock exposes public tabs only; team panel manages on-duty state.
  @Builder
  moreBody() {
    Column({ space: 2 }) {
      this.navRow('⚙ 设置', '', () => { this.sheet = 'settings'; })
      this.navRow('👥 团队（在岗 / 休息）', this.restCount + ' 人休息', () => { this.sheet = 'restPanel'; })
    }.width('100%').padding({ left: 16, right: 16 })
  }

  // 截图样式：深灰圆角胶囊，头像在左、白字标题、右侧小状态点
  @Builder
  sessionTab(t: TabModel) {
    Row({ space: 7 }) {
      this.avatarMark(this.store.workDirById(t.workDirId), t.id === this.activeTabId, 26,
        this.agentOf(t), t.id === this.activeTabId ? '#2A2A2E' : '#161618')
      Text(this.store.tabTitle(t))
        .fontSize(15)
        .fontWeight(t.id === this.activeTabId ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(t.id === this.activeTabId ? '#FFFFFF' : (this.tabUnread(t) ? TEAL : '#9A9A9E'))
        .decoration({ type: this.store.isResting(t.id) ? TextDecorationType.LineThrough : TextDecorationType.None })
      Text('●').fontSize(7).fontColor(this.dotColor(t.id))
    }
    .padding({ left: 6, right: 12, top: 5, bottom: 5 })
    .backgroundColor(t.id === this.activeTabId ? '#2A2A2E' : '#161618')
    .borderRadius(21)
    .border({ width: 1, color: t.id === this.activeTabId ? '#2EFFFFFF' : '#14FFFFFF' })
    .onClick(() => this.switchTab(t.id))
  }

  private tabUnread(t: TabModel): boolean {
    const c = this.pool.get(t.id);
    return c !== null && c.unread && t.id !== this.activeTabId;
  }

  // Dismiss the soft keyboard by dropping focus — voice mode is record-driven and
  // must not leave the system QWERTY sheet covering the composer.
  private hideKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'clearFocus: %{public}s', `${e}`);
    }
  }


  // Horizontal terminal swipe → cycle sessions (shared by both gesture variants).
  private onHSwipe(e: GestureEvent): void {
    if (Math.abs(e.offsetX) < 36) {
      return;
    }
    this.swipeTab(e.offsetX < 0 ? 1 : -1);
  }

  // The single terminal PanGesture: lock the axis on the first update past a small
  // threshold, then a vertical drag live-scrolls (1:1 with the finger) while a
  // horizontal one is left for onActionEnd → onHSwipe.
  private onTermPan(e: GestureEvent): void {
    if (this.panMode === '') {
      const ax: number = Math.abs(e.offsetX);
      const ay: number = Math.abs(e.offsetY);
      if (ax > ay && ax > 18) {
        this.panMode = 'h';
      } else if (ay >= ax && ay > 12) {
        this.panMode = 'v';
      }
    }
    if (this.panMode === 'v') {
      const dyVp: number = e.offsetY - this.lastPanY;
      this.lastPanY = e.offsetY;
      const dyPx: number = this.getUIContext().vp2px(dyVp);
      this.webCtl.runJavaScript(`term_wheel(${dyPx})`);
    }
  }

  // ===========================================================================
  // bottom dock — iOS VoiceInputView 最新版：功能/键盘分组 + 按住说话
  // ===========================================================================

  private switchToolsGroup(idx: number): void {
    this.toolsGroup = idx;
    if (idx === 1 && this.recording) {
      // 切到键盘组时丢弃进行中的录音
      this.recording = false;
      this.fieldMode = 'idle';
      this.recorder.stop().then((_: Uint8Array): void => {}).catch((): void => {});
    }
  }

  @Builder
  segItem(label: string, idx: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.toolsGroup === idx ? '#F2F2F2' : '#8CFFFFFF')
      .fontWeight(this.toolsGroup === idx ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(this.toolsGroup === idx ? '#29FFFFFF' : Color.Transparent)
      .borderRadius(15)
      .onClick(() => this.switchToolsGroup(idx))
  }

  @Builder
  dockPill(glyph: string, action: () => void) {
    Stack() {
      Text(glyph).fontSize(16).fontColor('#E8E8E8')
    }
    .width(54).height(44).borderRadius(15)
    .backgroundColor('#0FFFFFFF')
    .border({ width: 1, color: '#24FFFFFF' })
    .onClick(action)
  }

  // 系统符号版药丸（对齐 iOS SF Symbol 单色线框图标，不用彩色 emoji）
  @Builder
  symPill(res: Resource, action: () => void) {
    Stack() {
      SymbolGlyph(res).fontSize(21).fontColor(['#E8E8E8'])
    }
    .width(54).height(44).borderRadius(15)
    .backgroundColor('#0FFFFFFF')
    .border({ width: 1, color: '#24FFFFFF' })
    .onClick(action)
  }

  // 自定义矢量图标版药丸（media 里的 SVG，描边色已烘焙成 #E8E8E8）
  @Builder
  imgPill(res: Resource, action: () => void) {
    Stack() {
      Image(res).width(22).height(22).objectFit(ImageFit.Contain).draggable(false)
    }
    .width(54).height(44).borderRadius(15)
    .backgroundColor('#0FFFFFFF')
    .border({ width: 1, color: '#24FFFFFF' })
    .onClick(action)
  }

  @Builder
  bottomDock() {
    Column({ space: 9 }) {
      Row({ space: 8 }) {
        Row({ space: 2 }) {
          this.segItem('功能', 0)
          this.segItem('键盘', 1)
        }
        .padding(3).backgroundColor('#09FFFFFF').borderRadius(18)
        if (this.fieldMode === 'recording' || this.fieldMode === 'busy') {
          // 录音/识别时工具行槽位改显状态（iOS composeBar 同槽位替换）
          Row({ space: 8 }) {
            Text('●').fontSize(10).fontColor('#FF453A')
            Text(this.fieldMode === 'recording' ? '正在聆听…' : 'AI 识别整理中…')
              .fontSize(13).fontColor('#A0FFFFFF')
          }
          .layoutWeight(1).padding({ left: 8 })
        } else {
          Scroll() {
            Row({ space: 9 }) {
              if (this.toolsGroup === 0) {
                // 顺序对齐 iOS funcTools：star/photo/esc■/paste/refresh/history | 分隔 |
                // transcript/browser/desktop；✨(Claude 命令) 是鸿蒙特有，放最后。
                this.symPill($r('sys.symbol.star'), () => { this.sheet = 'favorites'; })
                this.symPill($r('sys.symbol.picture'), () => this.pickAndUploadImage())
                this.dockPill('Esc', () => this.sendKey([0x1b]))
                this.symPill($r('sys.symbol.text_clipboard'), () => this.pasteClipboard())
                this.symPill($r('sys.symbol.arrow_clockwise'), () => this.reconnectActive())
                this.symPill($r('sys.symbol.arrow_counterclockwise_clock'), () => { this.sheet = 'history'; })
                Row().width(1).height(26).backgroundColor('#1FFFFFFF')
                this.symPill($r('sys.symbol.discover'), () => this.openBrowser())
                this.symPill($r('sys.symbol.desktop'), () => { this.sheet = 'machinePicker'; })
                this.symPill($r('sys.symbol.wand_and_stars'), () => { this.sheet = 'claude'; })
              } else {
                // iOS keyToolsRow1：只有四个方向键
                this.imgPill($r('app.media.tool_up'), () => this.sendKey([0x1b, 0x5b, 0x41]))
                this.imgPill($r('app.media.tool_down'), () => this.sendKey([0x1b, 0x5b, 0x42]))
                this.imgPill($r('app.media.tool_left'), () => this.sendKey([0x1b, 0x5b, 0x44]))
                this.imgPill($r('app.media.tool_right'), () => this.sendKey([0x1b, 0x5b, 0x43]))
              }
            }
          }
          .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
          .enablePaging(true)
        }
      }
      .width('100%')

      if (this.toolsGroup === 0) {
        Row({ space: 8 }) {
          // 💬 显示模式切换:终端 ↔ 对话记录页(iOS 同位置)
          Stack() {
            SymbolGlyph($r('sys.symbol.message')).fontSize(18).fontColor(['#EBFFFFFF'])
          }
          .width(46).height(48).borderRadius(23)
          .backgroundColor('#0BFFFFFF')
          .border({ width: 1, color: '#24FFFFFF' })
          .onClick(() => { this.dumpTranscript(); })

          Column() {
            this.voiceField()
          }
          .layoutWeight(1)
        }
        .width('100%')
      } else {
        this.keysRow2()
      }
    }
    .width('100%').padding({ left: 13, right: 13, top: 10, bottom: 12 })
    .backgroundColor('#0A0A0A')
  }

  // 键盘组第二行：占语音条的槽位，严格对齐 iOS keyToolsRow2：
  // return / ⇤(shift-tab) / delete_left(Ctrl+U 清当前输入行)。
  @Builder
  keysRow2() {
    Row({ space: 9 }) {
      // Claude 斜杠命令（自定义 Lucide 图标）：走 sendLine（发文本→停一拍→单回车）
      this.imgPill($r('app.media.tool_rewind'), () => this.sendLine('/rewind'))
      this.imgPill($r('app.media.tool_compact'), () => this.sendLine('/compact'))
      this.imgPill($r('app.media.tool_return'), () => this.sendKey([0x0d]))
      this.imgPill($r('app.media.tool_mode'), () => this.sendKey([0x1b, 0x5b, 0x5a]))
      this.imgPill($r('app.media.tool_clear'), () => this.sendKey([0x15]))
    }
    .width('100%').height(48)
  }

  // 按住说话条：长按录音，松开 ASR+AI 整理进 review；轻点弹浮动打字条
  @Builder
  voiceField() {
    Row({ space: 8 }) {
      if (this.fieldMode === 'review') {
        Text('✕').fontSize(15).fontColor('#FF6B6B')
          .width(34).height(34).textAlign(TextAlign.Center)
          .onClick(() => this.discardReview())
        Text(this.reviewText)
          .fontSize(14).fontColor('#FFFFFF').layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => this.openManualInput(this.reviewText))
      } else {
        SymbolGlyph($r('sys.symbol.mic')).fontSize(17)
          .fontColor([this.fieldMode === 'recording' ? '#FF9F9F' : '#66FFFFFF'])
          .margin({ left: 8 })
        Text(this.fieldMode === 'recording' ? '正在聆听 · 松开发送'
          : (this.fieldMode === 'busy' ? '识别中…' : '按住说话…'))
          .fontSize(14)
          .fontColor(this.fieldMode === 'recording' ? '#FF9F9F' : '#66FFFFFF')
          .layoutWeight(1)
      }
      Stack() {
        Text('↑').fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(this.fieldMode === 'review' ? '#0B1B14' : '#660B1B14')
      }
      .width(34).height(34).borderRadius(17)
      .backgroundColor(this.fieldMode === 'review' ? '#33E0A1' : '#5933E0A1')
      .onClick(() => {
        if (this.fieldMode === 'review') {
          this.sendReview();
        } else if (this.fieldMode === 'idle') {
          // 输入框为空点发送 = 发一个回车（空按 Enter）
          const c = this.activeClient();
          if (c !== null) {
            c.sendInput('\r');
          }
        }
      })
    }
    .width('100%').height(48).borderRadius(24)
    .padding({ left: 8, right: 7 })
    .backgroundColor(this.fieldMode === 'recording' ? '#24FF3B30' : '#0BFFFFFF')
    .border({ width: 1, color: this.fieldMode === 'recording' ? '#66FF3B30' : '#24FFFFFF' })
    // 阈值 280ms 太短：自然点一下常超 280ms → 被当长按去录音，单点很难开输入
    // （跟 iOS 之前 0.35s 太紧同一个坑，iOS 已调到 0.6s）。放宽到 500ms：
    // 轻点稳定弹输入面板，只有明确按住 ≥0.5s 才进录音。
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

  // 浮动打字条（iOS FloatingTextInputPanel）：贴键盘顶，点空白收起
  @Builder
  manualInputOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%').backgroundColor('#47000000')
        .onClick(() => { this.showManualInput = false; this.hideKeyboard(); })
      Row({ space: 8 }) {
        TextInput({ text: this.manualText, placeholder: '输入命令…' })
          .id('manualInput')
          .layoutWeight(1).height(44).fontSize(15)
          .backgroundColor(Color.Transparent).fontColor('#FFFFFF')
          .placeholderColor('#59FFFFFF').caretColor('#33E0A1')
          .enterKeyType(EnterKeyType.Send)
          .onChange((v: string) => { this.manualText = v; })
          .onSubmit(() => this.sendManual())
        Stack() {
          Text('↑').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#0B1B14')
        }
        .width(34).height(34).borderRadius(17).backgroundColor('#33E0A1')
        .onClick(() => this.sendManual())
      }
      .width('94%').height(56).borderRadius(20)
      .padding({ left: 10, right: 10 })
      .backgroundColor('#1A212C')
      .border({ width: 1, color: '#24FFFFFF' })
      .margin({ bottom: this.kbHeight > 0 ? 10 : 10 + this.botInset })
    }
    .width('100%').height('100%')
  }

  /// 系统返回手势：先收面板/侧栏，再退网页，最后才交还给系统（退出应用）
  onBackPress(): boolean {
    if (this.sheet !== 'none') {
      this.sheet = 'none';
      return true;
    }
    if (this.showBrowser) {
      if (this.browserSide) {
        this.browserSide = false;
        return true;
      }
      try {
        if (this.browserCtl.accessBackward()) {
          this.browserCtl.backward();
          return true;
        }
      } catch (e) {
      }
      this.closeBrowser();
      return true;
    }
    if (this.showTranscript) {
      this.showTranscript = false;
      return true;
    }
    return false;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 状态栏避让区：和 tab 条同色（iOS _statusBarBg #0b0c0e）
        Row().width('100%').height(this.topInset).backgroundColor('#0b0c0e')
        this.tabBar()
        Stack({ alignContent: Alignment.TopStart }) {
          Web({ src: $rawfile('term/term.html'), controller: this.webCtl })
            .javaScriptAccess(true).domStorageAccess(true)
            .javaScriptProxy({
              object: this.jsBridge, name: 'arkBridge', methodList: ['post'], controller: this.webCtl,
            })
            .onPageEnd(() => { this.webCtl.runJavaScript('term_init()'); })
            .backgroundColor('#000000').width('100%').height('100%')
          TextInput({ text: this.inputBuf })
            .id('termInput')
            .width('100%').height('100%')
            .backgroundColor(Color.Transparent).fontColor(Color.Transparent).caretColor(Color.Transparent)
            .enterKeyType(EnterKeyType.Send)
            // A tap must NOT pop the keyboard (it covers the terminal you're reading):
            // focusOnTouch(false) stops touch from focusing the field; enableKeyboardOnFocus(true)
            // still lets an explicit double-tap → requestFocus raise it. Mirrors iOS
            // canTerminalBecomeFirstResponder gating + interactive keyboard dismiss.
            .focusOnTouch(false).enableKeyboardOnFocus(true)
            .onChange((v: string) => this.onInput(v)).onSubmit(() => this.submitLine())
        }
        .width('100%').layoutWeight(1).backgroundColor('#000000')
        // Terminal gestures — one direction-free PanGesture, disambiguated by hand,
        // so ArkUI (not the Web) owns every drag. Letting touches reach hterm made it
        // preventDefault them (ScrollPort.onTouch_) and killed even the swipe, so we
        // keep all touch in ArkUI: the first update past a threshold locks the axis —
        // horizontal → cycle sessions on release; vertical → live-scroll the scrollback
        // by driving x-screen.scrollTop from JS (term_scroll_move). 终端上点击/双击
        // 都不弹键盘（快速连点会被误判双击）——系统键盘只从 dock 的 ⌨ 药丸或
        // 各输入框自己弹出。
        .priorityGesture(
          PanGesture({ distance: 12 })
            .onActionStart(() => { this.panMode = ''; this.lastPanY = 0; this.webCtl.runJavaScript('term_wheel_reset()'); })
            .onActionUpdate((e: GestureEvent) => this.onTermPan(e))
            .onActionEnd((e: GestureEvent) => { if (this.panMode === 'h') { this.onHSwipe(e); } }),
        )
        this.bottomDock()
        // 底部导航条/安全区：dock 同色填充；键盘弹出时页面整体被 kbHeight 顶起，不再垫
        Row().width('100%').height(this.kbHeight > 0 ? 0 : this.botInset).backgroundColor('#0A0A0A')
      }
      .width('100%').height('100%').backgroundColor('#000000')

      // sheets / overlays
      if (this.sheet !== 'none') {
        this.sheetChrome()
      }
      // 浏览器首开后常驻（关掉只隐藏，网页不重载），可见性在 browserOverlay 里自己判
      if (this.browserOpened) {
        this.browserOverlay()
      }
      if (this.showTranscript) {
        this.transcriptOverlay()
      }
      if (this.showManualInput) {
        this.manualInputOverlay()
      }
      // 登录门控（页面级 overlay，像 sheetChrome 那样放在最外层 —— 放进 WebView 的
      // Stack 会被 Web 表面盖住）。没有 session 时整屏只显示登录页。
      if (this.authGate !== 'ready') {
        this.authOverlay()
      }
    }
    .width('100%').height('100%').backgroundColor('#000000').padding({ bottom: this.kbHeight })
  }

  // ---- helpers for dynamic labels ----

  private machineFilterLabel(): string {
    if (this.store.filterMachineId.length === 0) {
      return '全部';
    }
    const m = this.store.machineById(this.store.filterMachineId);
    return m !== null ? this.store.machineDisplayName(m) : '全部';
  }

  private dotColor(tabId: string): string {
    const s = this.connState(tabId);
    if (s === 'connected') {
      return '#34C759';
    }
    if (s === 'connecting') {
      return '#FF9F45';
    }
    if (s === 'error' || s === 'closed') {
      return '#FF3B30';
    }
    return '#666666';
  }

  private reversedHistory(): string[] {
    const h = this.store.history;
    const out: string[] = [];
    for (let i = h.length - 1; i >= 0; i--) {
      out.push(h[i]);
    }
    return out;
  }

  // dock 🌙: toggle the current tab's rest flag. Mirrors iOS _toggleRestForCurrentTab —
  // Resting public tabs leave the dock immediately.
  private toggleRest(): void {
    if (this.activeTabId.length === 0) {
      return;
    }
    const key: string = this.activeTabId;
    const nowResting: boolean = this.store.toggleResting(key);
    this.toast(nowResting ? '已标记休息 😴' : '已标记在岗');
    if (nowResting) {
      const target: string = this.nextWorkingTab(key);
      this.pool.remove(key);
      this.webCtl.runJavaScript(`term_dispose('${key}')`);
      if (target.length > 0) {
        this.switchTab(target);
        return;
      }
      this.activeTabId = '';
      this.store.currentTabId = '';
      this.store.saveCurrent();
      this.webCtl.runJavaScript('term_hide_all()');
    }
    this.refreshTabs();
  }

  // Next non-resting tab to land on after parking `key` (iOS _nextWorkingKey): prefer the
  // same machine scanning forward & wrapping, else fall back to a working tab anywhere.
  private nextWorkingTab(key: string): string {
    const tabs = this.store.tabs;
    const pos: number = tabs.findIndex((t: TabModel) => t.id === key);
    if (pos < 0 || tabs.length <= 1) {
      return '';
    }
    const cur = this.store.tabById(key);
    const curM: string = cur !== null ? cur.machineId : '';
    let sameMachine: string = '';
    let otherMachine: string = '';
    const n: number = tabs.length;
    for (let step = 1; step < n; step++) {
      const cand = tabs[(pos + step) % n];
      if (cand.id === key || !this.store.isShared(cand.id) || this.store.isResting(cand.id)) {
        continue;
      }
      if (cand.machineId === curM) {
        sameMachine = cand.id;
        break;
      } else if (otherMachine.length === 0) {
        otherMachine = cand.id;
      }
    }
    return sameMachine.length > 0 ? sameMachine : otherMachine;
  }

  private openNewTab(): void {
    const defM: string = this.store.filterMachineId.length > 0 ? this.store.filterMachineId
      : (this.store.machines.length > 0 ? this.store.machines[0].id : '');
    this.ntMachineId = defM;
    this.ntWorkDirId = this.store.workDirs.length > 0 ? this.store.workDirs[0].id : '';
    this.ntSession = '';
    this.sheet = 'newTab';
  }

  // ===========================================================================
  // 内置浏览器（与鸿蒙平板版 PadHome / iOS PinnedBrowser 同一套）
  //   后台 = store.pinned（跟 iOS / 平板同步的管理后台清单）
  //   原型 = prototype.douwantech.com 目录（ProtoCatalog），默认「最近更新」混排
  // 手机屏窄，侧栏做成抽屉浮在网页上，点条目后自动收起。
  // ===========================================================================

  private openBrowser(): void {
    this.hideKeyboard();
    this.browserPinned = this.store.pinned.slice();
    if (!this.browserOpened) {
      const p = this.uiPrefs;
      if (p !== null) {
        this.browserSeg = (p.getSync('browserSeg', 'admin') as string) === 'proto' ? 'proto' : 'admin';
        this.protoUser = p.getSync('protoUser', '') as string;
        this.protoPass = p.getSync('protoPass', '') as string;
      }
      const cache: ProtoCache | null = ProtoCatalog.load(this.protoCachePath());
      if (cache !== null) {
        this.applyProtoCache(cache);
      }
      let first: string = p !== null ? p.getSync('browserLast', '') as string : '';
      if (first.length === 0 && this.browserPinned.length > 0) {
        first = this.browserPinned[0].url;
      }
      this.browserOpened = true;
      if (first.length > 0) {
        this.openInBrowser(first);
      } else {
        this.browserSide = true;   // 没有上次的页面就先把侧栏摊开让人选
      }
    }
    // 目录 10 分钟内拉过就不重拉（侧栏底部可手动刷新）
    if (Date.now() - this.protoFetchedAt > 600000) {
      this.refreshProto();
    }
    this.showBrowser = true;
  }

  private closeBrowser(): void {
    this.showBrowser = false;
    this.browserEditing = false;
  }

  private setBrowserSeg(seg: string): void {
    this.browserSeg = seg;
    const p = this.uiPrefs;
    if (p !== null) {
      p.put('browserSeg', seg).then((): Promise<void> => p.flush()).catch(() => {});
    }
    if (seg === 'proto' && Date.now() - this.protoFetchedAt > 600000) {
      this.refreshProto();
    }
  }

  private protoCachePath(): string {
    return this.filesDir() + '/proto_index.json';
  }

  private applyProtoCache(c: ProtoCache): void {
    this.protoAll = c.items;
    this.protoSections = c.sections;
    this.protoFetchedAt = c.fetchedAt;
    if (this.protoFilter.length > 0 && c.sections.indexOf(this.protoFilter) < 0) {
      this.protoFilter = '';
    }
  }

  private refreshProto(): void {
    if (this.protoState === 'loading') {
      return;
    }
    this.protoState = 'loading';
    ProtoCatalog.fetch(this.protoUser, this.protoPass, (r: ProtoFetchResult, c: ProtoCache | null, msg: string) => {
      if (r === 'ok' && c !== null) {
        this.applyProtoCache(c);
        ProtoCatalog.save(this.protoCachePath(), c);
        this.protoState = 'ok';
        this.protoMsg = '';
      } else {
        this.protoState = r;
        this.protoMsg = msg;
        hilog.warn(DOMAIN, TAG, 'proto fetch %{public}s: %{public}s', r, msg);
      }
    });
  }

  private saveProtoAuth(): void {
    const p = this.uiPrefs;
    if (p !== null) {
      p.put('protoUser', this.protoUser).then((): Promise<void> => p.put('protoPass', this.protoPass))
        .then((): Promise<void> => p.flush()).catch(() => {});
    }
    this.sheet = 'none';
    this.protoFetchedAt = 0;
    this.refreshProto();
    if (this.browserUrlText.indexOf(PROTO_HOST) >= 0) {
      this.browserAuthTries.clear();
      try { this.browserCtl.refresh(); } catch (e) { }
    }
  }

  /// 侧栏「原型」当前要显示的列表：筛选分区 → 搜索 → 最近更新时按日期倒序
  private protoVisible(): ProtoItem[] {
    const q: string = this.protoQuery.trim().toLowerCase();
    let arr: ProtoItem[] = this.protoAll.filter((it: ProtoItem) =>
      (this.protoFilter.length === 0 || it.section === this.protoFilter) &&
      (q.length === 0 || it.title.toLowerCase().indexOf(q) >= 0 || it.desc.toLowerCase().indexOf(q) >= 0 ||
        it.section.toLowerCase().indexOf(q) >= 0));
    if (this.protoFilter.length === 0) {
      arr = arr.map((it: ProtoItem, i: number): ProtoSortRow => ({ it: it, i: i } as ProtoSortRow))
        .sort((a: ProtoSortRow, b: ProtoSortRow) =>
          a.it.updated === b.it.updated ? a.i - b.i : (a.it.updated < b.it.updated ? 1 : -1))
        .map((r: ProtoSortRow): ProtoItem => r.it);
    }
    return arr;
  }

  /// 3 天内更新过的标「新」
  private protoIsNew(updated: string): boolean {
    if (updated.length < 10) {
      return false;
    }
    const t: number = new Date(updated.substring(0, 10) + 'T00:00:00+08:00').getTime();
    return !Number.isNaN(t) && Date.now() - t < 3 * 86400000;
  }

  private sameUrl(a: string, b: string): boolean {
    const strip = (u: string): string => u.replace(new RegExp('^https?://'), '').replace(new RegExp('/$'), '');
    return a.length > 0 && b.length > 0 && strip(a) === strip(b);
  }

  private hostOf(url: string): string {
    const m = url.match(new RegExp('^https?://([^/]+)'));
    return m !== null ? m[1] : url;
  }

  private openInBrowser(url: string): void {
    const u: string = BrowserUrl.normalize(url);
    if (u.length === 0) {
      return;
    }
    this.browserEditing = false;
    this.browserUrlText = u;
    this.browserCurUrl = u;
    this.browserSide = false;   // 手机上侧栏是抽屉，选完就收起看网页
    this.browserAuthTries.clear();
    const p = this.uiPrefs;
    if (p !== null) {
      p.put('browserLast', u).then((): Promise<void> => p.flush()).catch(() => {});
    }
    if (!this.browserAttached) {
      this.browserStartUrl = u;   // Web 还没挂上：挂上时 onControllerAttached 补载
      return;
    }
    try {
      this.browserCtl.loadUrl(u);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'browser load: %{public}s', `${e}`);
    }
  }

  private deletePinned(i: number): void {
    if (i < 0 || i >= this.store.pinned.length) {
      return;
    }
    const t: PinnedTab = this.store.pinned[i];
    this.getUIContext().showAlertDialog({
      title: '删除后台',
      message: '删除「' + (t.title.length > 0 ? t.title : t.url) + '」？',
      primaryButton: {
        value: '删除', fontColor: B_RED, action: () => {
          this.store.pinned.splice(i, 1);
          this.store.savePinned();
          this.browserPinned = this.store.pinned.slice();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  /// 后台编辑器：i = -1 新增（默认填当前网页）
  private openPinEditor(i: number): void {
    if (i >= 0 && i < this.store.pinned.length) {
      const t: PinnedTab = this.store.pinned[i];
      this.peIdx = i;
      this.peTitle = t.title;
      this.peUrl = t.url;
      this.peUser = t.authUser !== undefined ? t.authUser : '';
      this.pePwd = t.authPassword !== undefined ? t.authPassword : '';
    } else {
      this.peIdx = -1;
      let title: string = '';
      let url: string = this.browserUrlText;
      try {
        if (this.browserAttached) {
          const u: string = this.browserCtl.getUrl();
          if (u.length > 0 && u !== 'about:blank') {
            url = u;
            title = this.browserCtl.getTitle();
          }
        }
      } catch (e) {
      }
      this.peTitle = title;
      this.peUrl = url === 'about:blank' ? '' : url;
      this.peUser = '';
      this.pePwd = '';
    }
    this.sheet = 'pinEdit';
  }

  private savePinEditor(): void {
    const url: string = this.peUrl.trim();
    if (url.length === 0) {
      this.toast('网址不能为空');
      return;
    }
    const item: PinnedTab = { title: this.peTitle.trim(), url: url } as PinnedTab;
    if (this.peUser.length > 0) {
      item.authUser = this.peUser;
    }
    if (this.pePwd.length > 0) {
      item.authPassword = this.pePwd;
    }
    if (this.peIdx >= 0 && this.peIdx < this.store.pinned.length) {
      this.store.pinned[this.peIdx] = item;
    } else {
      this.store.pinned.push(item);
    }
    this.store.savePinned();
    this.browserPinned = this.store.pinned.slice();
    this.sheet = 'none';
    this.setBrowserSeg('admin');
    this.openInBrowser(url);
  }

  private onBrowserNav(url: string, begin: boolean): void {
    this.browserLoading = begin;
    if (!this.browserEditing && url.length > 0 && url !== 'about:blank') {
      this.browserUrlText = url;
      this.browserCurUrl = url;
    }
    if (!begin) {
      this.browserAuthTries.clear();
    }
    try {
      this.browserCanBack = this.browserCtl.accessBackward();
      this.browserCanFwd = this.browserCtl.accessForward();
    } catch (e) {
    }
  }

  /// Basic Auth：原型站用原型账密；其它按 host 找后台里存的账密
  private browserAuth(host: string): string[] | null {
    const n: number = this.browserAuthTries.get(host) ?? 0;
    if (n >= 1) {
      return null;
    }
    this.browserAuthTries.set(host, n + 1);
    if (host === PROTO_HOST) {
      return this.protoUser.length > 0 ? [this.protoUser, this.protoPass] : null;
    }
    return this.pinnedAuthFor(host);
  }

  private browserReloadOrStop(): void {
    try {
      if (this.browserLoading) {
        this.browserCtl.stop();
        this.browserLoading = false;
      } else {
        this.browserCtl.refresh();
      }
    } catch (e) {
    }
  }

  private browserLockIcon(): Resource {
    const u: string = this.browserUrlText;
    if (u.startsWith('https://')) {
      return $r('sys.symbol.lock_fill');
    } else if (u.startsWith('http://')) {
      return $r('sys.symbol.exclamationmark_triangle_fill');
    }
    return $r('sys.symbol.discover');
  }

  private protoFooter(): string {
    if (this.protoState === 'loading') {
      return '更新中…';
    }
    if (this.protoFetchedAt <= 0) {
      return '';
    }
    const d = new Date(this.protoFetchedAt);
    const hm: string = d.getHours().toString().padStart(2, '0') + ':' + d.getMinutes().toString().padStart(2, '0');
    const fail: string = (this.protoState === 'noauth' || this.protoState === 'error') ? ' · 刷新失败' : '';
    return this.protoAll.length + ' 页 · ' + hm + ' 更新' + fail;
  }

  private confirmCloseTab(t: TabModel): void {
    this.getUIContext().showAlertDialog({
      title: '关闭会话',
      message: '关闭「' + this.store.tabTitle(t) + '」？(仅关本机标签，tmux 会话仍在)',
      primaryButton: { value: '关闭', fontColor: '#FF3B30', action: () => this.closeTab(t.id) },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  // ===========================================================================
  // sheets
  // ===========================================================================

  // Shared sheet chrome: backdrop + bottom card + grabber + title; the body is
  // dispatched by this.sheet. (ArkTS @Builder can't take a lambda-as-content
  // param, so we dispatch instead of passing a closure.)
  @Builder
  sheetChrome() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%').backgroundColor('#CC000000')
        .onClick(() => { this.sheet = 'none'; })
      Column() {
        Row().width(38).height(5).borderRadius(3).backgroundColor('#3A3A3C').margin({ top: 8, bottom: 10 })
        Row() {
          Text(this.sheetTitle()).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').layoutWeight(1)
          Text('完成').fontSize(15).fontColor('#0A84FF').onClick(() => { this.sheet = 'none'; })
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

        if (this.sheet === 'more') {
          this.moreBody()
        } else if (this.sheet === 'settings') {
          this.settingsBody()
        } else if (this.sheet === 'machinePicker') {
          this.machinePickerBody()
        } else if (this.sheet === 'newTab') {
          this.newTabBody()
        } else if (this.sheet === 'claude') {
          this.listBody(CLAUDE_COMMANDS, (c: string) => { this.sendLine(c); this.sheet = 'none'; })
        } else if (this.sheet === 'favorites') {
          this.listBody(this.store.favorites, (c: string) => this.useFavorite(c))
        } else if (this.sheet === 'history') {
          this.listBody(this.reversedHistory(), (c: string) => { this.sendLine(c); this.sheet = 'none'; })
        } else if (this.sheet === 'machineForm') {
          this.machineFormBody()
        } else if (this.sheet === 'workDirs') {
          this.workDirsBody()
        } else if (this.sheet === 'aiConfig') {
          this.aiConfigBody()
        } else if (this.sheet === 'restPanel') {
          this.restPanelBody()
        } else if (this.sheet === 'pinEdit') {
          this.pinEditBody()
        } else if (this.sheet === 'protoAuth') {
          this.protoAuthBody()
        }
      }
      .width('100%').height(this.sheetHeight()).backgroundColor('#0C0C0E')
      .borderRadius({ topLeft: 18, topRight: 18 })
      .padding({ bottom: this.botInset })
    }
    .width('100%').height('100%')
  }

  private sheetTitle(): string {
    if (this.sheet === 'more') {
      return '更多';
    } else if (this.sheet === 'settings') {
      return '设置';
    } else if (this.sheet === 'machinePicker') {
      return '选择机器';
    } else if (this.sheet === 'newTab') {
      return '新建会话';
    } else if (this.sheet === 'claude') {
      return 'Claude 命令';
    } else if (this.sheet === 'favorites') {
      return '收藏短语';
    } else if (this.sheet === 'history') {
      return '语音历史';
    } else if (this.sheet === 'machineForm') {
      return '机器管理';
    } else if (this.sheet === 'workDirs') {
      return '工作目录';
    } else if (this.sheet === 'aiConfig') {
      return 'AI 配置';
    } else if (this.sheet === 'restPanel') {
      return '团队';
    } else if (this.sheet === 'pinEdit') {
      return this.peIdx >= 0 ? '编辑后台' : '添加后台';
    } else if (this.sheet === 'protoAuth') {
      return '原型站账号';
    }
    return '';
  }

  private sheetHeight(): string {
    if (this.sheet === 'more') {
      return '30%';
    } else if (this.sheet === 'settings') {
      return '86%';
    } else if (this.sheet === 'machinePicker') {
      return '60%';
    } else if (this.sheet === 'newTab' || this.sheet === 'machineForm' || this.sheet === 'workDirs') {
      return '82%';
    } else if (this.sheet === 'aiConfig') {
      return '70%';
    } else if (this.sheet === 'pinEdit') {
      return '64%';
    } else if (this.sheet === 'protoAuth') {
      return '52%';
    }
    return '70%';
  }

  @Builder
  pinEditBody() {
    Column() {
      this.sectionHeader('名称（可空，会用网址）')
      TextInput({ text: this.peTitle, placeholder: '名称' })
        .fontSize(14).backgroundColor(B_PANEL3).fontColor(B_FG).borderRadius(8)
        .onChange((v: string) => { this.peTitle = v; })
      this.sectionHeader('网址')
      TextInput({ text: this.peUrl, placeholder: '如 xxx-admin.douwantech.com/admin' })
        .fontSize(14).type(InputType.URL).backgroundColor(B_PANEL3).fontColor(B_FG).borderRadius(8)
        .onChange((v: string) => { this.peUrl = v; })
      this.sectionHeader('HTTP Basic 账密（可空）')
      Row({ space: 8 }) {
        TextInput({ text: this.peUser, placeholder: '用户名' })
          .layoutWeight(1).fontSize(14).backgroundColor(B_PANEL3).fontColor(B_FG).borderRadius(8)
          .onChange((v: string) => { this.peUser = v; })
        TextInput({ text: this.pePwd, placeholder: '密码' })
          .layoutWeight(1).fontSize(14).type(InputType.Password)
          .backgroundColor(B_PANEL3).fontColor(B_FG).borderRadius(8)
          .onChange((v: string) => { this.pePwd = v; })
      }.width('100%')
      Blank()
      Button('保存').fontSize(14).width('100%').height(40)
        .backgroundColor(TEAL).fontColor('#0B0C0E').margin({ top: 16, bottom: 20 })
        .onClick(() => this.savePinEditor())
    }
    .layoutWeight(1).width('100%').padding({ left: 20, right: 20 }).alignItems(HorizontalAlign.Start)
  }

  @Builder
  protoAuthBody() {
    Column() {
      Text('prototype.douwantech.com 整站有账号密码门禁。只存在这台手机上。')
        .fontSize(12).fontColor(B_DIM).width('100%').margin({ top: 14 })
      this.sectionHeader('用户名')
      TextInput({ text: this.protoUser, placeholder: '用户名' })
        .fontSize(14).backgroundColor(B_PANEL3).fontColor(B_FG).borderRadius(8)
        .onChange((v: string) => { this.protoUser = v; })
      this.sectionHeader('密码')
      TextInput({ text: this.protoPass, placeholder: '密码' })
        .fontSize(14).type(InputType.Password).backgroundColor(B_PANEL3).fontColor(B_FG).borderRadius(8)
        .onChange((v: string) => { this.protoPass = v; })
      Blank()
      Button('保存并刷新目录').fontSize(14).width('100%').height(40)
        .backgroundColor(TEAL).fontColor('#0B0C0E').margin({ top: 16, bottom: 20 })
        .onClick(() => this.saveProtoAuth())
    }
    .layoutWeight(1).width('100%').padding({ left: 20, right: 20 }).alignItems(HorizontalAlign.Start)
  }

  @Builder
  sectionHeader(title: string) {
    Text(title).fontSize(12).fontColor('#8E8E93').width('100%').textAlign(TextAlign.Start)
      .margin({ top: 6, bottom: 4 })
  }

  // -- generic list picker (Claude / favorites / history) --
  @Builder
  listBody(items: string[], onPick: (s: string) => void) {
    List() {
      ForEach(items, (it: string) => {
        ListItem() {
          Text(it).fontSize(15).fontColor('#EDEDED').fontFamily('monospace')
            .width('100%').padding({ top: 13, bottom: 13, left: 4, right: 4 }).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .onClick(() => onPick(it))
      }, (it: string, i: number) => it + i)
    }
    .layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).divider({ strokeWidth: 0.5, color: '#2A2A2C' })
  }

  // -- machine filter / switch --
  @Builder
  machinePickerBody() {
    List() {
      ListItem() {
        Row() {
          Text('全部机器').fontSize(16).fontColor('#FFFFFF').layoutWeight(1)
          if (this.store.filterMachineId.length === 0) {
            Text('✓').fontSize(16).fontColor(TEAL)
          }
        }.width('100%').padding({ top: 14, bottom: 14 })
      }.onClick(() => { this.sheet = 'none'; this.applyMachineFilter(''); })
      ForEach(this.store.machines, (m: Machine) => {
        ListItem() {
          Row({ space: 10 }) {
            Column() {
              Text(this.store.machineDisplayName(m)).fontSize(16).fontColor('#FFFFFF')
              Text(m.user + '@' + m.host + ' · ' + (m.transport === 'blinkd' ? 'Socket' : 'SSH'))
                .fontSize(11).fontColor('#8E8E93')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.store.filterMachineId === m.id) {
              Text('✓').fontSize(16).fontColor(TEAL)
            }
          }.width('100%').padding({ top: 12, bottom: 12 })
        }.onClick(() => { this.sheet = 'none'; this.applyMachineFilter(m.id); })
      }, (m: Machine) => m.id)
    }
    .layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).divider({ strokeWidth: 0.5, color: '#2A2A2C' })
  }

  // -- new tab (machine + workDir + session) --
  @Builder
  newTabBody() {
    Scroll() {
      Column({ space: 8 }) {
        this.sectionHeader('机器')
        Column() {
          ForEach(this.store.machines, (m: Machine) => {
            Row() {
              Text(this.store.machineDisplayName(m)).fontSize(15).fontColor('#FFFFFF').layoutWeight(1)
              if (this.ntMachineId === m.id) {
                Text('✓').fontSize(15).fontColor(TEAL)
              }
            }.width('100%').padding({ top: 11, bottom: 11 }).onClick(() => { this.ntMachineId = m.id; })
          }, (m: Machine) => m.id)
        }.padding({ left: 14, right: 14 }).backgroundColor('#1C1C1E').borderRadius(12)

        this.sectionHeader('工作目录')
        Column() {
          ForEach(this.store.workDirs, (w: WorkDir) => {
            Row({ space: 10 }) {
              this.avatar(w, false, 24)
              Column() {
                Text(w.name).fontSize(15).fontColor('#FFFFFF')
                Text(w.path).fontSize(10).fontColor('#8E8E93').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.ntWorkDirId === w.id) {
                Text('✓').fontSize(15).fontColor(TEAL)
              }
            }.width('100%').padding({ top: 9, bottom: 9 }).onClick(() => { this.ntWorkDirId = w.id; })
          }, (w: WorkDir) => w.id)
        }.padding({ left: 14, right: 14 }).backgroundColor('#1C1C1E').borderRadius(12)

        this.sectionHeader('会话名 (tmux)')
        TextInput({ text: this.ntSession, placeholder: '留空 = new' })
          .fontSize(14).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
          .onChange((v: string) => { this.ntSession = v; })

        Button('创建并连接').fontSize(15).width('100%').height(44).backgroundColor('#0A84FF')
          .margin({ top: 10, bottom: 20 })
          .onClick(() => this.newTab(this.ntMachineId, this.ntWorkDirId, this.ntSession))
      }
      .width('100%').padding({ left: 16, right: 16 })
    }.layoutWeight(1).scrollBar(BarState.Off)
  }

  // -- settings (mirrors iOS VoiceSettingsViewController groups) --
  @Builder
  settingsBody() {
    Scroll() {
      Column({ space: 8 }) {
        this.sectionHeader('账号')
        Column({ space: 2 }) {
          Row() {
            Text(this.accountName.length > 0 ? this.accountName : '未登录')
              .fontSize(15).fontColor('#FFFFFF').layoutWeight(1)
            Text(this.serverConfig !== null && this.serverConfig.isOnline ? '● 在线' : '○ 离线')
              .fontSize(12)
              .fontColor(this.serverConfig !== null && this.serverConfig.isOnline ? '#34C759' : '#8E8E93')
          }.width('100%').padding({ top: 12, bottom: 4 })
          Text('机器与标签由服务器下发，本机只保留选中状态与员工 CLI。')
            .fontSize(11).fontColor('#8E8E93').width('100%').padding({ bottom: 8 })
          Row() {
            Text('退出登录').fontSize(15).fontColor('#FF3B30').layoutWeight(1)
          }.width('100%').padding({ top: 8, bottom: 12 }).onClick(() => this.confirmLogout())
        }.padding({ left: 14, right: 14, top: 4, bottom: 4 }).backgroundColor('#1C1C1E').borderRadius(12)

        this.sectionHeader('机器')
        Column({ space: 2 }) {
          this.navRow('机器管理', this.store.machines.length + ' 台', () => { this.mfEdit = null; this.sheet = 'machineForm'; })
          this.toggleRow('断线自动重连', this.store.autoReconnect, (v: boolean) => { this.store.autoReconnect = v; this.store.saveAutoReconnect(); })
        }.padding({ left: 14, right: 14, top: 4, bottom: 4 }).backgroundColor('#1C1C1E').borderRadius(12)

        this.sectionHeader('工作目录')
        Column({ space: 2 }) {
          this.navRow('工作目录', this.store.workDirs.length + ' 个', () => { this.sheet = 'workDirs'; })
          this.navRow('员工头像', this.store.people.length + ' 人', () => this.toast('员工：' + this.store.people.join('、')))
        }.padding({ left: 14, right: 14, top: 4, bottom: 4 }).backgroundColor('#1C1C1E').borderRadius(12)

        this.sectionHeader('识别 & AI 整理')
        Column({ space: 2 }) {
          this.navRow('识别语言', this.store.locale, () => this.toast('当前 ' + this.store.locale))
          this.toggleRow('AI 整理', this.store.voice.enabled, (v: boolean) => { this.store.voice.enabled = v; this.store.saveVoice(); })
          this.navRow('AI 配置', this.store.voice.model, () => { this.sheet = 'aiConfig'; })
          this.navRow('AI 历史/修正/词表',
            this.store.history.length + '条 · ' + this.store.corrections.length + '对 · ' +
            GlmClient.termEntries(this.store.terms).length + '词', () => this.toast('语音学习数据'))
        }.padding({ left: 14, right: 14, top: 4, bottom: 4 }).backgroundColor('#1C1C1E').borderRadius(12)

        this.sectionHeader('Tailscale')
        Column({ space: 10 }) {
          TextInput({ text: this.authKey, placeholder: 'auth key (tskey-…)' })
            .fontSize(13).type(InputType.Password).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
            .onChange((v: string) => { this.authKey = v; this.saveTs('authKey', v); })
          Row() {
            Text(this.tsState.length > 0 ? ('● ' + this.tsState) : '● 未连接')
              .fontSize(12).fontColor(this.tsState === 'Running' ? '#34C759' : '#8E8E93').layoutWeight(1)
            Text(this.tsIP).fontSize(12).fontColor('#8E8E93')
          }.width('100%')
          Button(this.tsConnected ? '断开 tailscale' : '连接 tailscale')
            .fontSize(14).width('100%').height(40)
            .backgroundColor(this.tsConnected ? '#3A3A3C' : '#34C759')
            .onClick(() => { this.tsConnected ? this.tsDisconnect() : this.tsConnect(); })
        }.padding(14).backgroundColor('#1C1C1E').borderRadius(12)

        this.sectionHeader('brain · 公网 SSH 直连')
        Column({ space: 9 }) {
          Text('填公网 IP 或域名。留空时用服务器下发的 host2；端口默认 22。')
            .fontSize(11).fontColor('#8E8E93').width('100%')
          TextInput({ text: this.brainSshHost, placeholder: '公网 IP / 域名' })
            .fontSize(13).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
            .onChange((v: string): void => { this.brainSshHost = v; })
          TextInput({ text: this.brainSshPort, placeholder: 'SSH 端口（默认 22）' })
            .fontSize(13).type(InputType.Number).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
            .onChange((v: string): void => { this.brainSshPort = v; })
          Button('保存并重连').fontSize(14).width('100%').height(38)
            .backgroundColor('#0A84FF').onClick((): void => this.saveBrainSsh())
          Text('手机私钥保存在系统密钥库。将下方公钥加入 brain 登录用户的 ~/.ssh/authorized_keys。')
            .fontSize(11).fontColor('#8E8E93').width('100%')
          Button('生成并复制本机 SSH 公钥').fontSize(14).width('100%').height(38)
            .backgroundColor('#3A3A3C').onClick((): void => this.showSshPublicKey())
          if (this.sshPublicKey.length > 0) {
            Text(this.sshPublicKey).fontSize(10).fontColor('#D4DAE0').width('100%')
          }
          if (this.sshKeyError.length > 0) {
            Text(this.sshKeyError).fontSize(11).fontColor('#FF5A5C')
          }
        }.padding(14).backgroundColor('#1C1C1E').borderRadius(12)

        this.sectionHeader('外观 · 主题')
        Column({ space: 10 }) {
          Row() {
            ForEach(THEMES, (th: Theme, i: number) => {
              Column({ space: 4 }) {
                Stack() {
                  Text('Aa').fontSize(13).fontColor(th.fg)
                }.width(46).height(38).borderRadius(8).backgroundColor(th.bg)
                .border(i === this.themeIdx ? { width: 2, color: TEAL } : { width: 1, color: '#3A3A3C' })
                Text(th.name).fontSize(9).fontColor(i === this.themeIdx ? TEAL : '#8E8E93')
              }.onClick(() => this.applyTheme(i))
            }, (th: Theme) => th.name)
          }.width('100%').justifyContent(FlexAlign.SpaceBetween)
          Divider().color('#3A3A3C')
          Row() {
            Text('字号').fontSize(13).fontColor('#FFFFFF').layoutWeight(1)
            Row({ space: 6 }) {
              ForEach(FONT_SIZES, (px: number) => {
                Text(px.toString()).fontSize(13)
                  .fontColor(px === this.fontSize ? '#000000' : '#C7C7C7')
                  .backgroundColor(px === this.fontSize ? TEAL : '#2A2A2C')
                  .width(34).height(32).textAlign(TextAlign.Center).borderRadius(7)
                  .onClick(() => this.applyFont(px))
              }, (px: number) => px.toString())
            }
          }.width('100%')
        }.padding(14).backgroundColor('#1C1C1E').borderRadius(12)

        Text('Blink · HarmonyOS').fontSize(11).fontColor('#5A5A5E').width('100%')
          .textAlign(TextAlign.Center).margin({ top: 8, bottom: 20 })
      }.width('100%').padding({ left: 16, right: 16 })
    }.layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder
  navRow(label: string, detail: string, action: () => void) {
    Row() {
      Text(label).fontSize(15).fontColor('#FFFFFF').layoutWeight(1)
      Text(detail).fontSize(13).fontColor('#8E8E93')
      Text(' ›').fontSize(16).fontColor('#8E8E93')
    }.width('100%').padding({ top: 12, bottom: 12 }).onClick(action)
  }

  @Builder
  toggleRow(label: string, on: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(label).fontSize(15).fontColor('#FFFFFF').layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: on }).selectedColor('#34C759')
        .onChange((v: boolean) => { onChange(v); this.tick++; })
    }.width('100%').padding({ top: 8, bottom: 8 })
  }

  // -- 登录门控（issue #77：没有 session 时只显示登录页）--
  @Builder
  authOverlay() {
    Column() {
      if (this.authGate === 'checking') {
        // 启动时先查安全存储里有没有 session，查完才决定去登录页还是主界面
        Text('正在检查登录状态…').fontSize(14).fontColor('#8E8E93')
      } else {
        this.loginBody()
      }
    }
    .width('100%').height('100%').backgroundColor('#0A0A0A')
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  @Builder
  loginBody() {
    Column({ space: 10 }) {
      Text('Blink 登录').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .width('100%').textAlign(TextAlign.Center).margin({ bottom: 6 })
      Text('用团队账号登录，机器与标签从服务器取。').fontSize(12).fontColor('#8E8E93')
        .width('100%').textAlign(TextAlign.Center).margin({ bottom: 10 })
      TextInput({ text: this.loginUser, placeholder: '用户名' })
        .fontSize(15).backgroundColor('#1C1C1E').fontColor('#FFFFFF').borderRadius(8)
        .width('100%').onChange((v: string) => { this.loginUser = v; })
      TextInput({ text: this.loginPwd, placeholder: '密码' })
        .fontSize(15).type(InputType.Password).backgroundColor('#1C1C1E').fontColor('#FFFFFF')
        .borderRadius(8).width('100%').onChange((v: string) => { this.loginPwd = v; })
      if (this.loginError.length > 0) {
        Text(this.loginError).fontSize(13).fontColor('#FF453A')
          .width('100%').textAlign(TextAlign.Center)
      }
      Button(this.loginBusy ? '正在登录…' : '登录 Blink 团队')
        .fontSize(15).width('100%').height(44).backgroundColor('#0A84FF')
        // disabled 条件同 iOS：正在登录，或用户名/密码为空
        .enabled(!this.loginBusy && this.loginUser.length > 0 && this.loginPwd.length > 0)
        .margin({ top: 6 })
        .onClick(() => { this.doLogin(); })
    }.width('80%').padding(16).backgroundColor('#141518').borderRadius(16)
  }

  /// 登录 → 成功进主界面（token 已进系统安全存储，密码立刻从内存清掉）
  private async doLogin(): Promise<void> {
    const sc = this.serverConfig;
    if (sc === null || this.loginBusy) {
      return;
    }
    this.loginBusy = true;
    this.loginError = '';
    try {
      await sc.login(this.loginUser, this.loginPwd);
      this.accountName = sc.username;
      this.loginPwd = '';
      this.authGate = 'ready';
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.startMain(ctx);
      await sc.restoreCache();
      this.refreshTabs();
      sc.refresh().then((): void => {
        this.refreshTabs();
        this.syncActiveAfterServerApply();
      }).catch((): void => {
      });
      sc.startPolling();
    } catch (e) {
      const err = e as Error;
      this.loginError = err.message !== undefined ? err.message : `${e}`;
    }
    this.loginBusy = false;
  }

  /// 退出登录：**先弹确认**，确认后清 session 回登录页（缓存与已采纳数据不动）
  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: '退出登录',
      message: '退出后需要重新输入账号密码才能使用。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '退出登录', fontColor: '#FF3B30', action: () => { this.doLogout(); },
      },
    });
  }

  private async doLogout(): Promise<void> {
    this.sheet = 'none';
    const sc = this.serverConfig;
    if (sc !== null) {
      await sc.logout();
    }
    this.pool.closeAll();
    this.accountName = '';
    this.loginUser = '';
    this.loginPwd = '';
    this.loginError = '';
    this.authGate = 'login';   // 没有 session → 只显示登录页
  }

  // -- machine list（只读：机器由服务器下发，本机不接受编辑）--
  @Builder
  machineFormBody() {
    Scroll() {
      Column({ space: 10 }) {
        ForEach(this.store.machines, (m: Machine) => {
          Row({ space: 10 }) {
            Column() {
              Text(this.store.machineDisplayName(m)).fontSize(15).fontColor('#FFFFFF')
              Text(m.user + '@' + m.host + '  ·  ' + (m.transport === 'blinkd' ? 'Socket ' + (m.blinkdHost !== undefined ? m.blinkdHost : '') : 'SSH'))
                .fontSize(11).fontColor('#8E8E93')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text('服务器下发').fontSize(11).fontColor('#6A6A6E')
          }.width('100%').padding({ top: 10, bottom: 10, left: 14, right: 14 })
          .backgroundColor('#1C1C1E').borderRadius(10)
        }, (m: Machine) => m.id + this.tick)
        Text('这些机器由服务器下发（只读）。连接方式 Socket=blinkd，SSH 走 mac 中转。')
          .fontSize(11).fontColor('#6A6A6E').width('100%').margin({ top: 6, bottom: 20 })
      }.width('100%').padding({ left: 16, right: 16 })
    }.layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder
  workDirsBody() {
    List() {
      ForEach(this.store.workDirs, (w: WorkDir) => {
        ListItem() {
          Row({ space: 10 }) {
            this.avatar(w, false, 30)
            Column() {
              Text(w.name).fontSize(15).fontColor('#FFFFFF')
              Text(w.path).fontSize(11).fontColor('#8E8E93').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').padding({ top: 10, bottom: 10 })
        }
      }, (w: WorkDir) => w.id)
    }.layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).divider({ strokeWidth: 0.5, color: '#2A2A2C' })
  }

  @Builder
  aiConfigBody() {
    Column({ space: 12 }) {
      this.sectionHeader('GLM API Key')
      TextInput({ text: this.store.voice.apiKey, placeholder: 'API Key' })
        .fontSize(13).type(InputType.Password).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
        .onChange((v: string) => { this.store.voice.apiKey = v; this.store.saveVoice(); })
      this.sectionHeader('模型')
      TextInput({ text: this.store.voice.model, placeholder: 'glm-4-flashx' })
        .fontSize(13).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
        .onChange((v: string) => { this.store.voice.model = v; this.store.saveVoice(); })
      this.sectionHeader('Base URL')
      TextInput({ text: this.store.voice.baseURL, placeholder: 'https://…/chat/completions' })
        .fontSize(12).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
        .onChange((v: string) => { this.store.voice.baseURL = v; this.store.saveVoice(); })
      Text('语音识别 glm-asr-2512，整理用上面的模型。都走智谱 bigmodel。')
        .fontSize(11).fontColor('#6A6A6E').width('100%').margin({ top: 4 })
    }.width('100%').padding({ left: 16, right: 16 }).alignItems(HorizontalAlign.Start)
  }

  // -- rest panel (iOS RestPanelViewController): every session with an on-duty/rest
  // switch. Resting sessions are hidden from the strip, so this is the only place to
  // put them back on duty. Switch ON = on-duty (shown), OFF = resting (hidden).
  // ---- 团队列表三视图（#77 评论②）：口径对齐平板 buildGroups()/rowFor() ----
  // owner＝工作目录名（空则「其他」）；project＝tmuxSession 最后一个 '-' 之后（等于 owner 或空时用 owner）。
  // 三档都跨机器列全（团队栏是「看所有人在干嘛」，不该被当前机器挡住）。
  private teamOwner(t: TabModel): string {
    const w = this.store.workDirById(t.workDirId);
    return (w !== null && w.name.length > 0) ? w.name : '其他';
  }

  private teamProject(t: TabModel): string {
    let p: string = t.tmuxSession;
    const i: number = p.lastIndexOf('-');
    if (i >= 0) { p = p.substring(i + 1); }
    const owner: string = this.teamOwner(t);
    if (p.length === 0 || p === owner) { p = owner; }
    return p;
  }

  private teamGroupTitle(t: TabModel): string {
    if (this.teamMode === 'project') { return this.teamProject(t); }
    if (this.teamMode === 'machine') { return this.machineNameForTab(t); }
    // 同名员工在不同机器上是两个人：标题前缀机器名（与平板一致）
    return this.machineNameForTab(t) + ' · ' + this.teamOwner(t);
  }

  private teamKey(t: TabModel): string {
    if (this.teamMode === 'project') { return 'p|' + this.teamProject(t); }
    if (this.teamMode === 'machine') { return 'm|' + t.machineId; }
    return 'e|' + t.machineId + '|' + this.teamOwner(t);
  }

  /// 扁平化成 [组头, 行…, 组头, 行…]（List 里每项一个 ListItem，不能一个 ForEach 产生多个）
  private teamEntries(): TeamEntry[] {
    const out: TeamEntry[] = [];
    const seen: string[] = [];
    // 先按机器/标题排序，让分组稳定：机器按 store.machines 位次，其余按标题
    const tabs: TabModel[] = this.store.tabs.filter((t: TabModel): boolean => this.store.isShared(t.id));
    const rank = (t: TabModel): number => {
      const i: number = this.store.machines.findIndex((m: Machine) => m.id === t.machineId);
      return i < 0 ? 999 : i;
    };
    tabs.sort((a: TabModel, b: TabModel) => {
      const ra: number = rank(a); const rb: number = rank(b);
      if (ra !== rb) { return ra - rb; }
      const ta: string = this.teamGroupTitle(a); const tb: string = this.teamGroupTitle(b);
      if (ta !== tb) { return ta < tb ? -1 : 1; }
      return a.tmuxSession < b.tmuxSession ? -1 : 1;
    });
    for (let i = 0; i < tabs.length; i++) {
      const t: TabModel = tabs[i];
      const k: string = this.teamKey(t);
      if (seen.indexOf(k) < 0) {
        seen.push(k);
        const rows: TabModel[] = tabs.filter((x: TabModel) => this.teamKey(x) === k);
        let rest: number = 0;
        for (let j = 0; j < rows.length; j++) { if (this.store.isResting(rows[j].id)) { rest++; } }
        let sum: string = rows.length + ' 会话';
        if (rest > 0) { sum += ' · ' + rest + ' 休息'; }
        out.push({ kind: 'h', title: this.teamGroupTitle(t), sub: sum, tab: t } as TeamEntry);
      }
      out.push({ kind: 'r', title: '', sub: '', tab: t } as TeamEntry);
    }
    return out;
  }

  @Builder
  teamSeg(label: string, mode: string) {
    Text(label).fontSize(13)
      .fontColor(this.teamMode === mode ? '#0B1B14' : '#E8E8E8')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(13)
      .backgroundColor(this.teamMode === mode ? '#33E0A1' : '#1C1C1E')
      .onClick(() => { this.teamMode = mode; this.tick++; })
  }

  @Builder
  restPanelBody() {
      // 三视图切换（#77 评论②）：按员工 / 按项目 / 按机器
      Row({ space: 8 }) {
        this.teamSeg('按员工', 'employee')
        this.teamSeg('按项目', 'project')
        this.teamSeg('按机器', 'machine')
      }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 4 })
      List() {
      ForEach(this.teamEntries(), (e: TeamEntry) => {
        ListItem() {
          if (e.kind === 'h') {
            Row({ space: 8 }) {
              Text(e.title).fontSize(13).fontColor('#8E8E93').fontWeight(FontWeight.Medium)
              Text(e.sub).fontSize(11).fontColor('#5A5A5E').layoutWeight(1)
            }.width('100%').padding({ top: 14, bottom: 4 }).backgroundColor('#0A0A0A')
          } else {
          Row({ space: 10 }) {
            this.avatarMark(this.store.workDirById(e.tab.workDirId), false, 30, this.agentOf(e.tab), '#1C1C1E')
            Column({ space: 2 }) {
              Text(this.store.tabTitle(e.tab)).fontSize(15).fontColor('#FFFFFF')
              Text(this.machineNameForTab(e.tab) + ' · ' + (this.store.isResting(e.tab.id) ? '😴 休息中' : '在岗'))
                .fontSize(11).fontColor(this.store.isResting(e.tab.id) ? '#B0A8FF' : '#8E8E93')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Stack() {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(15)
                .fontColor([this.agentOf(e.tab) === 'claude' ? '#8E8E93' : BlinkStore.agentBrand(this.agentOf(e.tab))])
            }
            .width(30).height(30).borderRadius(8)
            .bindMenu(this.agentMenu(e.tab))
            Toggle({ type: ToggleType.Switch, isOn: !this.store.isResting(e.tab.id) })
              .selectedColor('#34C759')
              .onChange((on: boolean) => {
                this.store.setResting(e.tab.id, !on);
                this.syncActiveAfterServerApply();
              })
          }.width('100%').padding({ top: 10, bottom: 10 })
          }
        }
      }, (e: TeamEntry) => e.kind + '_' + e.tab.id + '_' + this.teamMode + '_' + (this.store.isResting(e.tab.id) ? 'r' : 'w') + '_' + this.tick)
      }
    .layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).divider({ strokeWidth: 0.5, color: '#2A2A2C' })
    Text('开关打开＝在岗（显示在标签栏），关闭＝休息（从标签栏隐藏）。休息中的员工也能在这里随时改回在岗。')
      .fontSize(11).fontColor('#6A6A6E').width('100%').padding({ left: 16, right: 16, top: 8, bottom: 16 })
  }

  // 这个员工（机器 × tab）开起来进哪个 CLI；title 同远端 tmux 外层会话 cc-<TITLE> 那截
  private ccTitleOf(t: TabModel): string {
    const m = this.store.machineById(t.machineId);
    const w = this.store.workDirById(t.workDirId);
    return BlinkStore.titleFor(w !== null ? w.path : '', t.tmuxSession, m !== null ? m.user : '');
  }

  private agentOf(t: TabModel): string {
    return this.store.agentFor(t.machineId, this.ccTitleOf(t));
  }

  // 只改配置，不动已经跑着的 tmux 会话——里面 claude 的上下文还在，
  // 要换得先把 cc-<TITLE> 关掉重开，所以这里只提示一句。
  private setAgent(t: TabModel, kind: string): void {
    if (this.agentOf(t) === kind) {
      return;
    }
    this.store.setAgent(t.machineId, this.ccTitleOf(t), kind);
    this.refreshTabs();
    this.toast('已设为 ' + BlinkStore.agentLabel(kind) + '，关掉这个会话重开才生效');
  }

  // 行尾齿轮菜单：这个员工下次开会话进哪个 CLI
  @Builder
  agentMenu(t: TabModel) {
    Menu() {
      MenuItem({ content: this.agentOf(t) === 'claude' ? 'Claude Code（当前）' : 'Claude Code' })
        .onClick(() => this.setAgent(t, 'claude'))
      MenuItem({ content: this.agentOf(t) === 'codex' ? 'Codex（当前）' : 'Codex' })
        .onClick(() => this.setAgent(t, 'codex'))
      MenuItem({ content: this.agentOf(t) === 'deepseek' ? 'DeepSeek（当前）' : 'DeepSeek' })
        .onClick(() => this.setAgent(t, 'deepseek'))
      MenuItem({ content: this.agentOf(t) === 'glm' ? 'GLM (Claude Code)（当前）' : 'GLM (Claude Code)' })
        .onClick(() => this.setAgent(t, 'glm'))
    }
  }

  private machineNameForTab(t: TabModel): string {
    const m = this.store.machineById(t.machineId);
    return m !== null ? this.store.machineDisplayName(m) : '其他';
  }

  // ---- browser overlay：顶栏 + 网页 + 抽屉侧栏（后台 / 原型）----

  @Builder
  brIcon(sym: Resource, color: string, size: number, action: () => void) {
    Stack() {
      SymbolGlyph(sym).fontSize(size).fontColor([color])
    }
    .width(34).height(34).borderRadius(8)
    .stateStyles({ pressed: { .backgroundColor(B_FILL) }, normal: { .backgroundColor(Color.Transparent) } })
    .onClick(action)
  }

  @Builder
  browserSegBtn(label: string, seg: string) {
    Row({ space: 5 }) {
      Text(label).fontSize(13)
        .fontWeight(this.browserSeg === seg ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.browserSeg === seg ? '#F2F2F2' : B_SUB)
      // 数量在里面直接读 @State（@Builder 基本类型参数按值传，不会跟着刷新）
      Text((seg === 'admin' ? this.browserPinned.length : this.protoAll.length).toString())
        .fontSize(11).fontFamily(MONO)
        .fontColor(this.browserSeg === seg ? '#B0FFFFFF' : B_DIM)
    }
    .layoutWeight(1).height(30).justifyContent(FlexAlign.Center).borderRadius(8)
    .backgroundColor(this.browserSeg === seg ? '#24FFFFFF' : Color.Transparent)
    .onClick(() => this.setBrowserSeg(seg))
  }

  @Builder
  adminMenu(i: number) {
    Menu() {
      MenuItem({ content: '编辑' }).onClick(() => this.openPinEditor(i))
      MenuItem({ content: '删除' }).onClick(() => this.deletePinned(i))
    }
  }

  @Builder
  adminList() {
    if (this.browserPinned.length === 0) {
      Column({ space: 8 }) {
        Text('还没有后台').fontSize(13).fontColor(B_SUB)
        Text('打开网页后点右上角 + 钉住').fontSize(12).fontColor(B_DIM)
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else {
      List({ space: 2 }) {
        ForEach(this.browserPinned, (t: PinnedTab, i: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Stack() {
                Text((t.title.length > 0 ? t.title : this.hostOf(t.url)).substring(0, 1).toUpperCase())
                  .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              }
              .width(30).height(30).borderRadius(8)
              .linearGradient({
                angle: 135,
                colors: [[B_GRADS[i % B_GRADS.length][0], 0], [B_GRADS[i % B_GRADS.length][1], 1]],
              })
              Column({ space: 1 }) {
                Text(t.title.length > 0 ? t.title : this.hostOf(t.url)).fontSize(14).fontColor(B_FG)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.hostOf(t.url)).fontSize(10.5).fontFamily(MONO).fontColor(B_DIM)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (t.authUser !== undefined && t.authUser.length > 0) {
                SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(10).fontColor(['#4A515C'])
              }
            }
            .width('100%').height(50).padding({ left: 10, right: 10 }).borderRadius(10)
            .backgroundColor(this.sameUrl(this.browserCurUrl, t.url) ? '#1F63D3E8' : Color.Transparent)
            .onClick(() => this.openInBrowser(t.url))
          }
          .bindContextMenu(this.adminMenu(i), ResponseType.LongPress)
        }, (t: PinnedTab, i: number) => i + '_' + t.url + '_' + t.title + '_' +
          (this.sameUrl(this.browserCurUrl, t.url) ? 1 : 0))
      }
      .layoutWeight(1).width('100%').padding({ left: 8, right: 8, top: 4 }).scrollBar(BarState.Off)
    }
  }

  @Builder
  protoChip(label: string, filter: string) {
    Text(label).fontSize(12).maxLines(1)
      .fontColor(this.protoFilter === filter ? '#D9D8FF' : B_SUB)
      .height(26).padding({ left: 11, right: 11 }).borderRadius(13)
      .backgroundColor(this.protoFilter === filter ? '#388F8CFF' : '#0FFFFFFF')
      .onClick(() => { this.protoFilter = filter; })
  }

  @Builder
  protoList() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(13).fontColor([B_DIM])
      TextInput({ text: this.protoQuery, placeholder: '搜索原型' })
        .id('protoSearch')
        .layoutWeight(1).height(30).fontSize(13).fontColor(B_FG).placeholderColor(B_DIM)
        .backgroundColor(Color.Transparent).caretColor(TEAL).padding({ left: 0, right: 0 })
        .onChange((v: string) => { this.protoQuery = v; })
      if (this.protoQuery.length > 0) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(12).fontColor([B_DIM])
          .onClick(() => { this.protoQuery = ''; })
      }
    }
    .height(32).margin({ left: 10, right: 10, top: 2 }).padding({ left: 10, right: 8 })
    .borderRadius(8).backgroundColor(B_PANEL3)

    // 分区筛选：一行横滑，不换行挤成一坨
    Scroll() {
      Row({ space: 6 }) {
        this.protoChip('最近更新', '')
        ForEach(this.protoSections, (s: string) => {
          this.protoChip(s, s)
        }, (s: string) => s + '_' + (this.protoFilter === s ? 1 : 0))
      }
      .padding({ left: 10, right: 10 })
    }
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
    .width('100%').height(28).margin({ top: 10, bottom: 6 }).align(Alignment.Start)

    if (this.protoAll.length === 0) {
      Column({ space: 10 }) {
        if (this.protoState === 'loading') {
          LoadingProgress().width(22).height(22).color(B_DIM)
          Text('正在拉取原型目录…').fontSize(12).fontColor(B_DIM)
        } else if (this.protoState === 'noauth') {
          SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(22).fontColor(['#4A515C'])
          Text(this.protoMsg).fontSize(13).fontColor(B_SUB)
          Text('填写原型站账号').fontSize(13).fontColor(TEAL)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(8)
            .border({ width: 1, color: '#663DD9C4' })
            .onClick(() => { this.sheet = 'protoAuth'; })
        } else {
          Text(this.protoMsg.length > 0 ? this.protoMsg : '还没有原型目录').fontSize(12).fontColor(B_DIM)
            .textAlign(TextAlign.Center).padding({ left: 16, right: 16 })
          Text('重试').fontSize(13).fontColor(TEAL).onClick(() => this.refreshProto())
        }
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else {
      List({ space: 4 }) {
        ForEach(this.protoVisible(), (it: ProtoItem) => {
          ListItem() {
            Column({ space: 3 }) {
              Text(it.title).fontSize(13).fontColor('#E3E8ED').maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.protoFilter.length > 0 && it.desc.length > 0) {
                Text(it.desc).fontSize(11).fontColor(B_DIM).maxLines(2).lineHeight(16)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              Row({ space: 6 }) {
                if (this.protoIsNew(it.updated)) {
                  Text('新').fontSize(9).fontWeight(FontWeight.Bold).fontColor('#1A1206')
                    .padding({ left: 4, right: 4 }).height(15).borderRadius(4).backgroundColor(B_WAIT)
                }
                Text((it.updated.length >= 10 ? it.updated.substring(5, 10) : '') +
                  (this.protoFilter.length === 0 ? '  ·  ' + it.section : ''))
                  .fontSize(10.5).fontFamily(MONO).fontColor('#5A636E')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start).width('100%')
            .padding({ left: 11, right: 11, top: 9, bottom: 9 }).borderRadius(9)
            .backgroundColor(this.sameUrl(this.browserCurUrl, it.url) ? '#248F8CFF' : '#09FFFFFF')
            .border(this.sameUrl(this.browserCurUrl, it.url)
              ? { width: 1, color: '#738F8CFF' } : { width: 1, color: Color.Transparent })
            .onClick(() => this.openInBrowser(it.url))
          }
        }, (it: ProtoItem) => it.url + '_' + it.updated + '_' + this.protoFilter + '_' +
          (this.sameUrl(this.browserCurUrl, it.url) ? 1 : 0))
      }
      .layoutWeight(1).width('100%').padding({ left: 8, right: 8, top: 4 }).scrollBar(BarState.Off)
    }
  }

  @Builder
  browserSidebar() {
    Column() {
      Row({ space: 2 }) {
        this.browserSegBtn('后台', 'admin')
        this.browserSegBtn('原型', 'proto')
      }
      .padding(2).margin({ left: 10, right: 10, top: 10, bottom: 6 })
      .borderRadius(10).backgroundColor('#0DFFFFFF')

      if (this.browserSeg === 'admin') {
        this.adminList()
      } else {
        this.protoList()
      }

      Row({ space: 6 }) {
        if (this.browserSeg === 'proto') {
          Text(this.protoFooter()).fontSize(11).fontFamily(MONO).fontColor(B_DIM).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          this.brIcon($r('sys.symbol.person'), B_SUB, 14, () => { this.sheet = 'protoAuth'; })
          this.brIcon($r('sys.symbol.arrow_clockwise'), B_SUB, 14, () => this.refreshProto())
        } else {
          Text('长按编辑 · 与 iOS / 平板同步').fontSize(11).fontColor(B_DIM).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          this.brIcon($r('sys.symbol.plus'), TEAL, 15, () => this.openPinEditor(-1))
        }
      }
      .width('100%').height(40).padding({ left: 14, right: 6 })
      .border({ width: { top: 1 }, color: B_HAIR })
    }
    .width('84%').height('100%').backgroundColor(B_PANEL)
    .border({ width: { right: 1 }, color: B_HAIR })
  }

  @Builder
  browserOverlay() {
    Column() {
      // 顶栏：侧栏开关 ← → [锁 网址 刷新] + ×
      Row({ space: 2 }) {
        this.brIcon(this.browserSide ? $r('sys.symbol.close_sidebar') : $r('sys.symbol.open_sidebar'),
          this.browserSide ? TEAL : B_SUB, 17, () => { this.browserSide = !this.browserSide; })
        this.brIcon($r('sys.symbol.chevron_left'), this.browserCanBack ? B_FG : '#3A4048', 16, () => {
          try { if (this.browserCtl.accessBackward()) { this.browserCtl.backward(); } } catch (e) { }
        })
        Row({ space: 6 }) {
          if (this.browserLoading) {
            LoadingProgress().width(14).height(14).color(B_DIM)
          } else {
            SymbolGlyph(this.browserLockIcon()).fontSize(12)
              .fontColor([this.browserUrlText.startsWith('http://') ? B_WAIT : B_DIM])
          }
          TextInput({ text: this.browserUrlText, placeholder: '搜索或输入网址' })
            .id('browserUrl')
            .layoutWeight(1).height(32).fontSize(13).fontColor(B_FG).placeholderColor(B_DIM)
            .backgroundColor(Color.Transparent).caretColor(TEAL).padding({ left: 0, right: 0 })
            .type(InputType.URL).enterKeyType(EnterKeyType.Go)
            .textAlign(this.browserEditing ? TextAlign.Start : TextAlign.Center)
            .selectAll(true)
            .onEditChange((editing: boolean) => { this.browserEditing = editing; })
            .onChange((v: string) => { this.browserUrlText = v; })
            .onSubmit(() => this.openInBrowser(this.browserUrlText))
          Stack() {
            SymbolGlyph(this.browserLoading ? $r('sys.symbol.xmark') : $r('sys.symbol.arrow_clockwise'))
              .fontSize(13).fontColor([B_SUB])
          }
          .width(28).height(28).borderRadius(14)
          .onClick(() => this.browserReloadOrStop())
        }
        .layoutWeight(1).height(34).padding({ left: 12, right: 4 }).margin({ left: 2, right: 2 })
        .borderRadius(17).backgroundColor(B_PANEL3)
        this.brIcon($r('sys.symbol.plus'), TEAL, 16, () => this.openPinEditor(-1))
        this.brIcon($r('sys.symbol.xmark'), B_SUB, 16, () => this.closeBrowser())
      }
      .width('100%').height(48).padding({ left: 4, right: 4 })
      .border({ width: { bottom: 1 }, color: B_HAIR })

      // 网页 + 抽屉侧栏（手机屏窄，侧栏浮在网页上，点空白收起）
      Stack({ alignContent: Alignment.TopStart }) {
        Web({ src: this.browserStartUrl, controller: this.browserCtl })
          .javaScriptAccess(true).domStorageAccess(true).fileAccess(true).imageAccess(true)
          .mixedMode(MixedMode.All).zoomAccess(true).overviewModeAccess(true)
          .multiWindowAccess(false)
          .width('100%').height('100%').backgroundColor('#FFFFFF')
          .onControllerAttached(() => {
            this.browserAttached = true;
            if (this.browserStartUrl !== 'about:blank') {
              try {
                if (this.browserCtl.getUrl() !== this.browserStartUrl) {
                  this.browserCtl.loadUrl(this.browserStartUrl);
                }
              } catch (e) {
              }
            }
          })
          .onPageBegin((e) => { if (e) { this.onBrowserNav(e.url, true); } })
          .onPageEnd((e) => { if (e) { this.onBrowserNav(e.url, false); } })
          .onProgressChange((e) => {
            if (e) {
              this.browserProgress = e.newProgress;
              if (e.newProgress >= 100) {
                this.browserLoading = false;
              }
            }
          })
          .onHttpAuthRequest((event) => {
            if (event) {
              const cred: string[] | null = this.browserAuth(event.host);
              if (cred !== null) {
                event.handler.confirm(cred[0], cred[1]);
              } else {
                event.handler.cancel();
                if (event.host === PROTO_HOST) {
                  this.sheet = 'protoAuth';
                }
              }
            }
            return true;
          })

        if (this.browserLoading && this.browserProgress < 100) {
          Row().width(`${Math.max(4, this.browserProgress)}%`).height(2).backgroundColor(TEAL)
            .position({ x: 0, y: 0 })
        }

        if (this.browserCurUrl.length === 0) {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.rectangle_stack')).fontSize(38).fontColor(['#4A515C'])
            Text('从侧栏选一个后台或原型').fontSize(14).fontColor(B_SUB)
            Text('也可以在地址栏直接输入网址').fontSize(12).fontColor(B_DIM)
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('#101216')
        }

        if (this.browserSide) {
          Column().width('100%').height('100%').backgroundColor('#99000000')
            .onClick(() => { this.browserSide = false; })
          this.browserSidebar()
        }
      }
      .layoutWeight(1).width('100%')
    }
    .width('100%').height('100%').backgroundColor(B_PANEL2)
    .padding({ top: this.topInset, bottom: this.botInset })
    .visibility(this.showBrowser ? Visibility.Visible : Visibility.Hidden)
  }

  // ---- 对话记录页 overlay(D 卡片流,与 iOS 一致) ----
  @Builder
  transcriptOverlay() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor(['#1A73E8'])
            .onClick(() => { this.closeChatRecord(); })
          Text(this.chatName).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1A1D21')
            .layoutWeight(1).textAlign(TextAlign.Center)
          if (this.chatRefreshing) {
            LoadingProgress().width(18).height(18).color('#9AA1AA')
          } else {
            Row().width(20)
          }
        }
        .width('100%').height(46).padding({ left: 12, right: 12 })
        .backgroundColor('#F4F5F7')

        // src 直接指向生成好的 HTML 文件(openChatRecord 先 renderChat 再置 showTranscript,
        // 构建时 chatUrl 一定就绪),避免 about:blank 初始导航把 loadUrl 顶掉的竞态
        Web({ src: this.chatUrl, controller: this.chatWebCtl })
          .layoutWeight(1).width('100%')
          .backgroundColor('#F4F5F7')
          .fileAccess(true)
          .onHttpAuthRequest((event) => {
            // 消息里内联的 <img> 撞上门禁(Basic Auth):用钉住浏览器 tab 存的账密应答,
            // 门禁内截图直接显示;没有匹配凭证就取消,让 onerror 回退成链接
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
          .javaScriptProxy({
            object: this.chatBridge,
            name: 'blinkNative',
            methodList: ['copy', 'fetchImage'],
            controller: this.chatWebCtl,
          })
      }
      .width('100%').height('100%')

      // 左下角悬浮返回
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(14).fontColor(['#1A73E8'])
        Text('返回').fontSize(14).fontColor('#1A73E8')
      }
      .padding({ left: 16, right: 18, top: 9, bottom: 9 })
      .backgroundColor('#FFFFFF')
      .borderRadius(19)
      .border({ width: 1, color: '#E2E4E8' })
      .shadow({ radius: 10, color: '#24000000', offsetX: 0, offsetY: 3 })
      .margin({ left: 16, bottom: 12 })
      .onClick(() => { this.closeChatRecord(); })
    }
    .width('100%').height('100%').backgroundColor('#F4F5F7')
    .padding({ top: this.topInset, bottom: this.botInset })
  }

  private saveTs(key: string, value: string): void {
    const p = this.tsPrefs;
    if (p === null) {
      return;
    }
    p.put(key, value).then((): Promise<void> => p.flush()).catch(() => {});
  }
}

// =============================================================================
// 对话记录页支撑件(与 iOS TranscriptViewController 同一套体验)
// =============================================================================

// 每 tab 一份的本地缓存:file/lines 是 jsonl 游标,body 是 "▶ You/◆ Claude" 全文
interface TranscriptCacheH {
  file: string;
  lines: number;
  body: string;
}

// Web 里 JS 调 native(javaScriptProxy 注入为 window.blinkNative):复制 + 带账密抓图
class ChatBridge {
  onCopy: (t: string) => void = (_t: string): void => {};
  onFetchImage: (url: string, id: string) => void = (_u: string, _i: string): void => {};

  copy(t: string): void {
    this.onCopy(t);
  }

  fetchImage(url: string, id: string): void {
    this.onFetchImage(url, id);
  }
}

// D 卡片流 HTML(iOS htmlFor 的移植):浅灰底,Claude 白卡片 + 名字 + 复制,
// user 右侧蓝胶囊;尾部 12 条先渲染秒显,老历史后台补插;隐藏→滚到底→显示防跳动。
function buildChatHtml(payloadB64: string, avatarURI: string, claudeName: string): string {
  const safeName: string = claudeName.replace(new RegExp('["<>\\\\]', 'g'), '');
  const p1: string = '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">' +
    '<style>' +
    'body{font-family:-apple-system,"PingFang SC","HarmonyOS Sans SC",sans-serif;padding:14px 14px 40px;' +
    'line-height:1.6;color:#1a1d21;background:#f4f5f7;font-size:14px;word-wrap:break-word;margin:0;}' +
    'h1,h2,h3{font-weight:600;margin:1em 0 .5em;}h1{font-size:1.3em}h2{font-size:1.18em}h3{font-size:1.08em}' +
    '.msg-block{margin:14px 0;display:flex;gap:8px;align-items:flex-start;}' +
    '.ava{width:30px;height:30px;border-radius:50%;flex:0 0 auto;display:flex;align-items:center;' +
    'justify-content:center;margin-top:2px;-webkit-user-select:none;user-select:none;}' +
    '.ava-claude{background:linear-gradient(135deg,#3fdc97,#2ea9e8);color:#fff;font-size:14px;font-weight:700;}' +
    '.ava-user{background:#4a5568;color:#fff;font-size:12px;font-weight:600;}' +
    '.ava.has-img{background:#e2e4e8;overflow:hidden;}' +
    '.ava-img{width:100%;height:100%;border-radius:50%;object-fit:cover;display:block;}' +
    '.mb-claude .card{flex:1 1 auto;min-width:0;background:#fff;border:1px solid #e2e4e8;' +
    'border-radius:5px 14px 14px 14px;overflow:hidden;box-shadow:0 1px 3px rgba(20,30,40,.05);}' +
    '.mb-claude .msg-head{display:flex;align-items:center;justify-content:space-between;' +
    'padding:7px 14px;background:#fafbfc;border-bottom:1px solid #eef0f3;}' +
    '.mb-claude .msg-body{padding:10px 14px 12px;}' +
    '.msg-block.mb-user{flex-direction:row-reverse;}' +
    '.mb-user .card{max-width:84%;background:#dce8ff;color:#1a3a6b;' +
    'border-radius:16px 5px 16px 16px;padding:8px 13px;}' +
    '.msg-body p:first-child{margin-top:0}.msg-body p:last-child{margin-bottom:0}' +
    '.role{font-weight:600;font-size:11px;letter-spacing:.1em;color:#7a828c;}' +
    '.copy-btn{font-size:12px;color:#1a73e8;background:transparent;border:1px solid #c8d7f5;' +
    'border-radius:6px;padding:3px 10px;}' +
    '.copy-btn.copied{color:#1e9e63;border-color:#b4e3cd;}' +
    '.meta{color:#9aa1aa;font-size:11px;font-family:monospace;margin:10px 2px;}' +
    'pre{background:#14181d;color:#c9d4de;padding:12px;border-radius:10px;overflow-x:auto;' +
    'font-family:monospace;font-size:12px;line-height:1.45;margin:.6em 0;}' +
    'code{background:#eef0f3;padding:2px 5px;border-radius:4px;font-family:monospace;font-size:.9em;color:#1a1d21;}' +
    'pre code{background:none;padding:0;color:#7ee2ad;}' +
    'table{border-collapse:collapse;margin:.8em 0;display:block;overflow-x:auto;font-size:.92em;}' +
    'th,td{border:1px solid #e2e4e8;padding:6px 10px;text-align:left;}th{background:#fafbfc;font-weight:600;}' +
    'ul,ol{padding-left:1.5em;margin:.5em 0;}li{margin:.2em 0;}' +
    'a{color:#1a73e8;text-decoration:none;}' +
    'blockquote{border-left:3px solid #e2e4e8;padding-left:12px;margin:.6em 0;color:#5f6670;}' +
    'hr{border:none;border-top:1px solid #e2e4e8;margin:1.5em 0;}p{margin:.5em 0;}' +
    'img{max-width:100%;border-radius:8px;}' +
    'img.md-img{margin:.5em 0;display:block;}' +
    'a.md-img-fallback{word-break:break-all;}' +
    '</style></head><body><div id="content"></div><script>' +
    'function escapeHTML(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}' +
    'function decodeB64(b){var bin=atob(b);var a=new Uint8Array(bin.length);' +
    'for(var i=0;i<bin.length;i++){a[i]=bin.charCodeAt(i);}return new TextDecoder("utf-8").decode(a);}' +
    'function utf8B64(s){return btoa(unescape(encodeURIComponent(s)));}' +
    'var imgSeq=0;var imgWaiting={};' +
    'function imgLink(el,u){var a=document.createElement("a");a.href=u;a.textContent=u;' +
    'a.className="md-img-fallback";el.replaceWith(a);}' +
    'function imgFail(el){var u=el.getAttribute("src")||"";' +
    'if(el.dataset.retried||u.indexOf("data:")===0){imgLink(el,u);return;}' +
    'el.dataset.retried="1";var id="gi"+(++imgSeq);imgWaiting[id]=el;el.dataset.origsrc=u;' +
    'el.removeAttribute("src");el.alt="载入中…";' +
    'try{window.blinkNative.fetchImage(u,id);}catch(e){imgLink(el,u);}}' +
    'function imgReady(id,uri){var el=imgWaiting[id];if(!el){return;}delete imgWaiting[id];' +
    'el.alt="";el.src=uri;}' +
    'function imgGiveUp(id){var el=imgWaiting[id];if(!el){return;}delete imgWaiting[id];' +
    'imgLink(el,el.dataset.origsrc||"");}' +
    'function inline(s){s=escapeHTML(s);' +
    's=s.replace(/`([^`\\n]+)`/g,"<code>$1</code>");' +
    's=s.replace(/\\*\\*([^*\\n]+)\\*\\*/g,"<strong>$1</strong>");' +
    's=s.replace(/(https?:\\/\\/[^\\s<>"\']+)/g,\'<a href="$1">$1</a>\');' +
    's=s.replace(/<a href="([^"]+\\.(?:jpe?g|png|gif|webp|bmp|heic)(?:\\?[^"]*)?)">[^<]*<\\/a>/gi,' +
    '\'<img class="md-img" src="$1" onerror="imgFail(this)">\');' +
    'return s;}' +
    'function copyMsg(btn){try{var t=decodeB64(btn.getAttribute("data-content"));' +
    'if(window.blinkNative&&window.blinkNative.copy){window.blinkNative.copy(t);}' +
    'btn.textContent="已复制";btn.classList.add("copied");' +
    'setTimeout(function(){btn.textContent="复制";btn.classList.remove("copied");},1200);}catch(e){}}' +
    'function renderBlocks(text){var lines=text.split("\\n");var html="";var i=0;' +
    'while(i<lines.length){var line=lines[i];' +
    'if(/^[▶◆]/.test(line)){var isUser=/^▶/.test(line);i++;var body=[];' +
    'while(i<lines.length&&!/^[▶◆]/.test(lines[i])&&!/^=== /.test(lines[i])){body.push(lines[i]);i++;}' +
    'while(body.length&&body[body.length-1].trim()===""){body.pop();}' +
    'var raw=body.join("\\n");var inner=renderBlocks(raw);' +
    'var head=isUser?"":(\'<div class="msg-head"><span class="role">\'+(CLAUDE_NAME||"CLAUDE")+"</span>"+' +
    '\'<button class="copy-btn" data-content="\'+utf8B64(raw)+\'" onclick="copyMsg(this)">复制</button></div>\');' +
    'var ava=isUser?\'<div class="ava ava-user">我</div>\'' +
    ':(AVA_CLAUDE?\'<div class="ava has-img"><img class="ava-img" src="\'+AVA_CLAUDE+\'"></div>\'' +
    ':\'<div class="ava ava-claude">\'+(CLAUDE_NAME?CLAUDE_NAME.charAt(0).toUpperCase():"C")+"</div>");' +
    'html+=\'<div class="msg-block \'+(isUser?"mb-user":"mb-claude")+\'">\'+ava+\'<div class="card">\'+head+' +
    '\'<div class="msg-body">\'+inner+"</div></div></div>";continue;}' +
    'if(/^```/.test(line)){var code=[];i++;' +
    'while(i<lines.length&&!/^```/.test(lines[i])){code.push(lines[i]);i++;}i++;' +
    'html+="<pre><code>"+escapeHTML(code.join("\\n"))+"</code></pre>";continue;}' +
    'if(/^=== /.test(line)){html+=\'<div class="meta">\'+escapeHTML(line)+"</div>";i++;continue;}' +
    'var h=line.match(/^(#{1,6})\\s+(.+)$/);' +
    'if(h){var lv=h[1].length;html+="<h"+lv+">"+inline(h[2])+"</h"+lv+">";i++;continue;}' +
    'if(/^\\|.*\\|\\s*$/.test(line)&&i+1<lines.length&&/^\\|[\\s\\-:|]+\\|\\s*$/.test(lines[i+1])){' +
    'var hc=line.split("|").slice(1,-1);i+=2;var rows=[];' +
    'while(i<lines.length&&/^\\|.*\\|\\s*$/.test(lines[i])){rows.push(lines[i].split("|").slice(1,-1));i++;}' +
    'var t="<table><thead><tr>";for(var a=0;a<hc.length;a++){t+="<th>"+inline(hc[a].trim())+"</th>";}' +
    't+="</tr></thead><tbody>";for(var r=0;r<rows.length;r++){t+="<tr>";' +
    'for(var c=0;c<rows[r].length;c++){t+="<td>"+inline(rows[r][c].trim())+"</td>";}t+="</tr>";}' +
    'html+=t+"</tbody></table>";continue;}' +
    'if(/^\\s*[-*]\\s+/.test(line)||/^\\s*\\d+\\.\\s+/.test(line)){' +
    'var ordered=/^\\s*\\d+\\.\\s+/.test(line);var items=[];' +
    'while(i<lines.length&&(/^\\s*[-*]\\s+/.test(lines[i])||/^\\s*\\d+\\.\\s+/.test(lines[i]))){' +
    'var mm=lines[i].match(/^\\s*(?:[-*]|\\d+\\.)\\s+(.*)$/);items.push(mm?mm[1]:lines[i]);i++;}' +
    'html+=(ordered?"<ol>":"<ul>");for(var k=0;k<items.length;k++){html+="<li>"+inline(items[k])+"</li>";}' +
    'html+=(ordered?"</ol>":"</ul>");continue;}' +
    'if(/^>\\s+/.test(line)){var q=[];' +
    'while(i<lines.length&&/^>\\s+/.test(lines[i])){q.push(lines[i].replace(/^>\\s+/,""));i++;}' +
    'html+="<blockquote>"+inline(q.join(" "))+"</blockquote>";continue;}' +
    'if(line.trim()===""){i++;continue;}' +
    'var para=line;i++;' +
    'while(i<lines.length&&lines[i].trim()!==""&&' +
    '!/^(```|▶|◆|=== |#{1,6}\\s|\\s*[-*]\\s|\\s*\\d+\\.\\s|>\\s|\\|.*\\|\\s*$)/.test(lines[i])){para+=" "+lines[i];i++;}' +
    'html+="<p>"+inline(para)+"</p>";}' +
    'return html;}' +
    'var RAW=decodeB64("';
  const p2: string = '");var AVA_CLAUDE="';
  const p3: string = '";var CLAUDE_NAME="';
  const p4: string = '";' +
    'document.documentElement.style.opacity="0";' +
    'function reveal(){document.documentElement.style.opacity="1";}' +
    'setTimeout(reveal,400);' +
    'function scrollToBottom(){window.scrollTo(0,document.documentElement.scrollHeight);}' +
    'function splitTail(raw,n){var lines=raw.split("\\n");var idxs=[];' +
    'for(var i=0;i<lines.length;i++){if(/^[▶◆]/.test(lines[i])){idxs.push(i);}}' +
    'if(idxs.length<=n){return {head:"",tail:raw};}' +
    'var cut=idxs[idxs.length-n];' +
    'return {head:lines.slice(0,cut).join("\\n"),tail:lines.slice(cut).join("\\n")};}' +
    'try{' +
    'var parts=splitTail(RAW,12);' +
    'document.getElementById("content").innerHTML=renderBlocks(parts.tail);' +
    'scrollToBottom();' +
    'requestAnimationFrame(function(){scrollToBottom();reveal();});' +
    'if(parts.head){setTimeout(function(){var div=document.createElement("div");' +
    'div.innerHTML=renderBlocks(parts.head);var c=document.getElementById("content");' +
    'var before=document.documentElement.scrollHeight;var y=window.scrollY;' +
    'while(div.lastChild){c.insertBefore(div.lastChild,c.firstChild);}' +
    'var delta=document.documentElement.scrollHeight-before;window.scrollTo(0,y+delta);},80);}' +
    'setTimeout(scrollToBottom,300);' +
    '}catch(e){reveal();document.getElementById("content").textContent="渲染失败: "+e.message;}' +
    '</script></body></html>';
  return p1 + payloadB64 + p2 + avatarURI + p3 + safeName + p4;
}
