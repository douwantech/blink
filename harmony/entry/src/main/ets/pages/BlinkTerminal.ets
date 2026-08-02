////////////////////////////////////////////////////////////////////////////////
//
// BlinkTerminal — Blink for HarmonyOS, the full iOS-fork experience:
//   • multi-tab, multi-session — one live blinkd connection per tab (ConnPool),
//     switching tabs never reconnects (hterm keeps every layer's screen), the
//     tab strip / machine filter pill / new-tab flow mirror SpaceController.
//   • config seeded from the user's real iOS app (BlinkStore ← seed_config.json):
//     same machines, work dirs, tabs, favorites, voice-AI data.
//   • bottom accessory reproduces VoiceInputView: SmartKeys, Claude command
//     sheet, favorites/history pickers, and a real GLM voice pipeline
//     (record → glm-asr → polish).
//   • floating dock reproduces FloatingDockBar: rest toggle / browser /
//     favorites / transcript / reconnect / machine switch / mic.
//
// The transport/terminal/input plumbing is the device-verified path from the
// single-session build, generalised to N sessions.
//
////////////////////////////////////////////////////////////////////////////////

import { common, wantAgent, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { vpnExtension } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util, buffer } from '@kit.ArkTS';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { pasteboard } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { BlinkdClient, BlinkdState, TailscaleCore, StatusStore } from 'tsvpn';
import { BlinkStore, Machine, WorkDir, TabModel } from '../model/BlinkStores';
import { ConnPool, SessionConn, ConnUiState } from '../model/SessionConn';
import { GlmClient, VoiceRecorder, Uploader, CLAUDE_COMMANDS, TermEntry } from '../model/GlmVoice';

const DOMAIN: number = 0x0B11;
const TAG: string = 'BlinkTerminal';
const BUNDLE: string = 'com.douwantech.blink';

// palette
const TEAL: string = '#3DD9C4';
const CARD: string = '#141416';
const HAIRLINE: string = '#2E6E68';

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

const FONT_SIZES: number[] = [10, 11, 12, 13, 14, 16, 18];

// what the bottom sheet is currently showing
type Sheet = 'none' | 'settings' | 'machinePicker' | 'newTab' | 'claude' | 'favorites' | 'history' | 'machineForm' | 'workDirs' | 'aiConfig' | 'restPanel';

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
  @State tsConnected: boolean = false;
  @State authKey: string = '';
  @State hostname: string = 'harmony';
  // ui reactivity: bump `tick` after any store/pool mutation to force re-render
  @State tick: number = 0;
  @State storeReady: boolean = false;
  @State activeTabId: string = '';
  @State visTabs: TabModel[] = [];   // observable copy of store.visibleTabs() for the tab strip
  @State restCount: number = 0;      // resting-session count on the top-bar 🌙 (topBar() reads no other @State)
  @State filterLabel: string = '全部'; // machine-filter pill text, same reason
  @State cols: number = 52;
  @State rows: number = 30;
  @State themeIdx: number = 0;
  @State fontSize: number = 11;
  @State kbHeight: number = 0;
  @State toolbarOpen: boolean = true;
  @State panelOpen: boolean = false;   // bottom input panel — hidden until the mic button opens it (iOS voiceInputAutoShow)
  @State voiceMode: boolean = false;
  @State composerText: string = '';
  @State recording: boolean = false;
  @State voiceHint: string = '点击下方按钮开始说话';
  @State inputBuf: string = '';
  // overlays
  @State sheet: Sheet = 'none';
  @State showBrowser: boolean = false;
  @State browserUrl: string = '';
  @State showTranscript: boolean = false;
  @State transcriptText: string = '';
  // new-tab / machine-form scratch state
  @State ntMachineId: string = '';
  @State ntWorkDirId: string = '';
  @State ntSession: string = '';
  @State mfEdit: Machine | null = null;

  // floating-dock drag — mirrors iOS FloatingDockBar: free 2-D drag, clamped in-screen, remembered
  @State dockX: number = -1;
  @State dockY: number = -1;
  private areaW: number = 0;
  private areaH: number = 0;
  private dockW: number = 52;
  private dockH: number = 320;
  private dockX0: number = 0;
  private dockY0: number = 0;

  private store: BlinkStore = new BlinkStore();
  private pool: ConnPool = new ConnPool();
  private tabScroller: Scroller = new Scroller();   // scroll the tab strip to the active tab on switch/swipe
  private panMode: string = '';   // active terminal drag axis: '' undecided | 'h' switch tab | 'v' scroll
  private lastPanY: number = 0;   // last vertical offset seen this drag (for incremental scroll)
  private lastTabPerMachine: Record<string, string> = {};   // each machine's last-active tab (iOS _lastKeyPerMachine)
  private b64: util.Base64Helper = new util.Base64Helper();
  private win: window.Window | null = null;
  private webCtl: webview.WebviewController = new webview.WebviewController();
  private jsBridge: JsBridge = new JsBridge((op: string, data: string): void => { this.onBridge(op, data); });
  private tsPrefs: preferences.Preferences | null = null;
  private uiPrefs: preferences.Preferences | null = null;
  private timer: number = -1;
  private lastLen: number = 0;
  private skipNext: boolean = false;
  private recorder: VoiceRecorder = new VoiceRecorder();
  private transcriptClient: BlinkdClient | null = null;
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
    this.authKey = await this.tsPrefs.get('authKey', '') as string;
    this.hostname = await this.tsPrefs.get('hostname', 'harmony') as string;
    this.themeIdx = await this.uiPrefs.get('themeIdx', 0) as number;
    this.fontSize = await this.uiPrefs.get('fontSize', 11) as number;
    this.dockX = await this.uiPrefs.get('dockX', -1) as number;
    this.dockY = await this.uiPrefs.get('dockY', -1) as number;
    await this.store.load(ctx);
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
    } else {
      this.appendLocal('⚙ 设置里填 tailscale auth key，之后自动连接');
    }
  }

  private setupKeyboard(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    window.getLastWindow(this.getUIContext().getHostContext()).then((w: window.Window) => {
      this.win = w;
      w.on('keyboardHeightChange', (h: number) => {
        this.kbHeight = px2vp(h);
      });
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
      const s: string = StatusStore.read(this.filesDir());
      try {
        const j = JSON.parse(s) as Record<string, Object>;
        const state = j['backendState'] as string;
        this.tsState = state ? state : 'Starting';
        const ips = j['tailscaleIPs'] as string[];
        this.tsIP = (ips && ips.length > 0) ? ips[0] : '';
        if (state === 'Running' && this.activeTabId.length > 0) {
          this.attach(this.activeTabId, false);
        }
      } catch (e) {
      }
    }, 1500);
  }

  // ---- per-tab connection ----

  private attach(tabId: string, force: boolean): void {
    const tab = this.store.tabById(tabId);
    if (tab === null) {
      return;
    }
    const m = this.store.machineById(tab.machineId);
    const ep = this.store.blinkdEndpoint(m);
    if (ep === null || ep.blinkdHost === undefined || ep.blinkdToken === undefined) {
      return;
    }
    const conn = this.pool.getOrCreate(tabId);
    if (!force && (conn.state === 'connected' || conn.state === 'connecting')) {
      return;
    }
    if (!force && Date.now() < conn.cooldownUntil) {
      return;
    }
    conn.client.onData = (bytes: Uint8Array) => {
      this.writeBytes(tabId, bytes);
      if (tabId !== this.activeTabId && !conn.unread) {
        conn.unread = true;
        this.refreshTabs();
      }
    };
    conn.client.onState = (st: BlinkdState, detail: string) => {
      this.onConnState(tabId, st, detail);
    };
    this.webCtl.runJavaScript(`term_create('${tabId}')`);
    conn.state = 'connecting';
    this.tick++;
    const port: number = ep.blinkdPort !== undefined ? ep.blinkdPort : 7777;
    conn.client.connect(ep.blinkdHost, port, ep.blinkdToken, this.rows, this.cols, this.store.execForTab(tab));
  }

  private onConnState(tabId: string, st: BlinkdState, detail: string): void {
    const conn = this.pool.get(tabId);
    if (conn === null) {
      return;
    }
    // (refreshTabs at the end updates the strip's status dot)
    if (st === 'connecting') {
      conn.state = 'connecting';
    } else if (st === 'connected') {
      conn.state = 'connected';
      conn.connectedAt = Date.now();
      conn.everConnected = true;
    } else if (st === 'closed' || st === 'error') {
      const lasted: number = conn.connectedAt > 0 ? (Date.now() - conn.connectedAt) : 0;
      conn.connectedAt = 0;
      conn.state = st;
      if (this.store.autoReconnect) {
        if (lasted > 10000) {
          conn.failCount = 0;
          conn.cooldownUntil = 0;
        } else {
          conn.failCount++;
          const wait: number = Math.min(1500 * Math.pow(2, conn.failCount), 30000);
          conn.cooldownUntil = Date.now() + wait;
        }
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
    }
    if (this.tsState === 'Running') {
      this.attach(tabId, false);
    }
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
  // We walk the full tab list (not the filtered visTabs), skipping resting tabs, so a
  // machine filter can't trap the swipe on one machine. When the next tab lives on a
  // different machine we carry the filter onto it (same cross-machine jump toggleRest
  // does), so the strip + filter pill follow the swipe across the boundary instead of
  // leaving the highlighted tab off-strip.
  private swipeTab(dir: number): void {
    const all: TabModel[] = [];
    for (let i = 0; i < this.store.tabs.length; i++) {
      const t = this.store.tabs[i];
      if (this.store.isResting(t.id) && t.id !== this.activeTabId) {
        continue;
      }
      all.push(t);
    }
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
    const target: TabModel = all[n];
    if (this.store.filterMachineId.length > 0 && target.machineId !== this.store.filterMachineId) {
      this.store.filterMachineId = target.machineId;
      this.store.saveFilter();
    }
    this.switchTab(target.id);
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

  private closeTab(tabId: string): void {
    this.pool.remove(tabId);
    this.webCtl.runJavaScript(`term_dispose('${tabId}')`);
    const idx: number = this.store.tabs.findIndex((x: TabModel) => x.id === tabId);
    if (idx >= 0) {
      this.store.tabs.splice(idx, 1);
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
      conn.client.close();
    }
    this.webCtl.runJavaScript(`term_clear('${this.activeTabId}')`);
    this.attach(this.activeTabId, true);
  }

  // ---- input ----

  private activeClient(): BlinkdClient | null {
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
  private sendLine(text: string): void {
    const client = this.activeClient();
    if (client !== null) {
      client.sendInput(text);
      client.sendInput('\n');
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

  // ---- voice pipeline ----

  private async startVoice(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const atm = abilityAccessCtrl.createAtManager();
      const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
      await atm.requestPermissionsFromUser(ctx, perms);
      await this.recorder.start();
      this.recording = true;
      this.voiceHint = '正在听 · 点击结束';
    } catch (e) {
      this.recording = false;
      this.toast('录音启动失败: ' + e);
    }
  }

  private async stopVoice(): Promise<void> {
    this.recording = false;
    this.voiceHint = '识别中…';
    try {
      const wav: Uint8Array = await this.recorder.stop();
      if (wav.length <= 44) {
        this.voiceHint = '点击下方按钮开始说话';
        return;
      }
      const raw: string = await GlmClient.transcribe(wav, this.store.voice.apiKey);
      let out: string = raw;
      if (this.store.voice.enabled && this.store.voice.apiKey.length > 0) {
        this.voiceHint = '整理中…';
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
      this.composerText = this.composerText.length > 0 ? (this.composerText + out) : out;
      this.voiceHint = '点击下方按钮开始说话';
    } catch (e) {
      this.voiceHint = '点击下方按钮开始说话';
      this.toast('识别失败: ' + e);
    }
  }

  private commitComposer(): void {
    const text: string = this.composerText.trim();
    if (text.length > 0) {
      this.sendLine(text);
      // record history (iOS recordHistory)
      this.store.history.push(text);
      if (this.store.history.length > 40) {
        this.store.history.shift();
      }
      this.store.saveHistory();
    }
    this.composerText = '';
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

  // ---- transcript dump (dock 🕐 / panel 📄) ----

  private dumpTranscript(): void {
    const tab = this.store.tabById(this.activeTabId);
    if (tab === null) {
      return;
    }
    const m = this.store.machineById(tab.machineId);
    const ep = this.store.blinkdEndpoint(m);
    if (ep === null || ep.blinkdHost === undefined || ep.blinkdToken === undefined) {
      this.toast('机器未配置 blinkd');
      return;
    }
    this.transcriptText = '正在抓取终端内容…';
    this.showTranscript = true;
    let buf: string = '';
    const dec = util.TextDecoder.create('utf-8');
    const client = new BlinkdClient();
    this.transcriptClient = client;
    client.onData = (bytes: Uint8Array) => {
      buf += dec.decodeToString(bytes, { stream: true });
    };
    client.onState = (st: BlinkdState) => {
      if (st === 'closed' || st === 'error') {
        this.transcriptText = buf.length > 0 ? buf : '(无内容)';
      }
    };
    const port: number = ep.blinkdPort !== undefined ? ep.blinkdPort : 7777;
    // one-shot: blinkd runs `bash -c "<capture>"` then the connection ends
    client.connect(ep.blinkdHost, port, ep.blinkdToken, this.rows, this.cols,
      this.store.transcriptCommandForTab(tab));
    setTimeout(() => {
      this.transcriptText = buf.length > 0 ? buf : '(无内容)';
      client.close();
      this.transcriptClient = null;
    }, 1600);
  }

  // ===========================================================================
  // UI builders
  // ===========================================================================

  @Builder
  circleBtn(glyph: string, bg: string, action: () => void) {
    Stack() {
      Text(glyph).fontSize(20).fontColor('#FFFFFF')
    }
    .width(46).height(46).borderRadius(23).backgroundColor(bg)
    .onClick(action)
  }

  @Builder
  miniBtn(glyph: string, color: string, action: () => void) {
    Stack() {
      Text(glyph).fontSize(15).fontColor(color)
    }
    .width(38).height(38).borderRadius(19).backgroundColor(CARD)
    .border({ width: 1.5, color: color })
    .onClick(action)
  }

  @Builder
  pillKey(label: string, accent: string, action: () => void) {
    Text(label)
      .fontSize(13).fontColor(accent).fontFamily('monospace')
      .backgroundColor(CARD).border({ width: 1, color: accent, radius: 9 })
      .constraintSize({ minWidth: 40 }).height(38).textAlign(TextAlign.Center)
      .padding({ left: 9, right: 9 }).onClick(action)
  }

  @Builder
  arrowKey(glyph: string, bytes: number[]) {
    Text(glyph)
      .fontSize(16).fontColor(TEAL).backgroundColor(CARD).borderRadius(9)
      .width(40).height(38).textAlign(TextAlign.Center)
      .onClick(() => this.sendKey(bytes))
  }

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
    this.tick++;
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

  @Builder
  topBar() {
    Row() {
      Text('⚙').fontSize(20).fontColor(TEAL).onClick(() => { this.sheet = 'settings'; })
      Row({ space: 5 }) {
        Text('≡').fontSize(15).fontColor(TEAL)
        Text(this.filterLabel).fontSize(14).fontColor(TEAL)
      }
      .padding({ left: 12, right: 13, top: 4, bottom: 4 })
      .border({ width: 1, color: HAIRLINE, radius: 16 }).margin({ left: 12 })
      .onClick(() => { this.sheet = 'machinePicker'; })
      Blank()
      Row({ space: 3 }) {
        Text('🌙').fontSize(16)
        Text(this.restCount.toString()).fontSize(15).fontColor('#B0A8FF')
      }.onClick(() => { this.sheet = 'restPanel'; })
      Text('✨').fontSize(17).margin({ left: 12 }).onClick(() => this.toast('AI 助手 · 开发中'))
      Text('＋').fontSize(24).fontColor(TEAL).margin({ left: 12 }).onClick(() => this.openNewTab())
    }
    .width('100%').height(46).padding({ left: 14, right: 16 }).backgroundColor('#000000')
  }

  @Builder
  tabBar() {
    // Horizontal List (not Scroll) so switchTab/swipeTab can scrollToIndex the active
    // tab into view — the strip now follows left/right session switches (iOS scrollToItem).
    List({ space: 8, scroller: this.tabScroller }) {
      ForEach(this.visTabs, (t: TabModel) => {
        ListItem() {
          this.sessionTab(t)
        }
      }, (t: TabModel) => t.id + '_' + this.connState(t.id) + '_' + (t.id === this.activeTabId ? '1' : '0') + '_' + (this.tabUnread(t) ? 'u' : ''))
      ListItem() {
        Text('＋').fontSize(18).fontColor('#5A5A5E').padding({ left: 6, right: 8 })
          .onClick(() => this.openNewTab())
      }
    }
    .listDirection(Axis.Horizontal).scrollBar(BarState.Off).align(Alignment.Start)
    .width('100%').height(40).padding({ left: 14, right: 14, bottom: 7 }).backgroundColor('#000000')
  }

  @Builder
  sessionTab(t: TabModel) {
    Row({ space: 6 }) {
      Text('●').fontSize(8).fontColor(this.dotColor(t.id))
      this.avatar(this.store.workDirById(t.workDirId), t.id === this.activeTabId, 20)
      Text(this.store.tabTitle(t))
        .fontSize(14)
        .fontColor(t.id === this.activeTabId ? '#FFFFFF' : (this.tabUnread(t) ? TEAL : '#8A8A8E'))
        .fontFamily('monospace')
        .decoration({ type: this.store.isResting(t.id) ? TextDecorationType.LineThrough : TextDecorationType.None })
    }
    .padding({ left: 10, right: 12, top: 6, bottom: 6 })
    .backgroundColor(t.id === this.activeTabId ? '#16323A' : Color.Transparent)
    .border(t.id === this.activeTabId
      ? { width: 1, color: HAIRLINE, radius: 11 }
      : { width: 0, color: Color.Transparent, radius: 11 })
    .onClick(() => this.switchTab(t.id))
    .gesture(LongPressGesture().onAction(() => this.confirmCloseTab(t)))
  }

  private tabUnread(t: TabModel): boolean {
    const c = this.pool.get(t.id);
    return c !== null && c.unread && t.id !== this.activeTabId;
  }

  private clampX(x: number): number {
    const maxX = Math.max(4, this.areaW - this.dockW - 4);
    return Math.min(Math.max(x, 4), maxX);
  }

  private clampY(y: number): number {
    const maxY = Math.max(4, this.areaH - this.dockH - 4);
    return Math.min(Math.max(y, 4), maxY);
  }

  // root-area probe: seed the dock's default spot (right edge, vertically centered)
  // on first layout, otherwise re-clamp the remembered position into the new bounds.
  private onRootArea(w: number, h: number): void {
    this.areaW = w;
    // Only capture the full height while the keyboard is down, so the dock keeps
    // its spot instead of jumping up when the soft keyboard resizes the page.
    if (this.kbHeight === 0) {
      this.areaH = h;
    }
    if (this.dockX < 0 || this.dockY < 0) {
      this.dockX = Math.max(4, w - this.dockW - 10);
      this.dockY = Math.max(4, (this.areaH - this.dockH) / 2);
    } else {
      this.dockX = this.clampX(this.dockX);
      this.dockY = this.clampY(this.dockY);
    }
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

  // Explicitly raise the soft keyboard (double-tap the terminal). Terminal taps no longer
  // auto-focus the input (focusOnTouch(false)); requestFocus + enableKeyboardOnFocus(true)
  // is the deliberate way back in.
  private showKeyboard(): void {
    try {
      this.getUIContext().getFocusController().requestFocus('termInput');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'requestFocus: %{public}s', `${e}`);
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

  // Bottom input panel is hidden by default (matches iOS voiceInputAutoShow): the
  // floating mic button opens it into voice mode; ⌄ collapses it fully again so the
  // terminal goes full-screen.
  private togglePanel(): void {
    if (this.panelOpen && this.voiceMode) {
      this.panelOpen = false;
      this.voiceMode = false;
      this.hideKeyboard();
    } else {
      this.panelOpen = true;
      this.voiceMode = true;
    }
    this.tick++;
  }

  private saveDockPos(): void {
    const p = this.uiPrefs;
    if (p === null) {
      return;
    }
    p.put('dockX', this.dockX)
      .then((): Promise<void> => p.put('dockY', this.dockY))
      .then((): Promise<void> => p.flush())
      .catch(() => {});
  }

  @Builder
  floatingDock() {
    Column({ space: 10 }) {
      Row().width(34).height(5).borderRadius(3).backgroundColor('#5A5A5E')
        .onClick(() => { this.toolbarOpen = !this.toolbarOpen; })
      if (this.toolbarOpen) {
        this.circleBtn('🌙', this.store.isResting(this.activeTabId) ? '#5E5CE6' : '#8E8E93',
          () => this.toggleRest())
        this.circleBtn('🌐', '#4A5CE6', () => this.openBrowser())
        this.circleBtn('⭐', '#FFCC00', () => { this.sheet = 'favorites'; })
        this.circleBtn('🕐', '#4A9EFF', () => this.dumpTranscript())
        this.circleBtn('🔄', '#34C759', () => this.reconnectActive())
        this.circleBtn('🖥️', '#C74DE0', () => { this.sheet = 'machinePicker'; })
        this.circleBtn('🎤', TEAL, () => this.togglePanel())
      }
    }
    .padding({ left: 6, right: 6, top: 8, bottom: 10 })
    .backgroundColor('#1C1C1EE6').borderRadius(28)
    .position({ x: this.dockX, y: this.dockY })
    .visibility(this.dockX < 0 ? Visibility.Hidden : Visibility.Visible)
    .onAreaChange((_: Area, n: Area) => {
      this.dockW = n.width as number;
      this.dockH = n.height as number;
      if (this.dockX >= 0) {
        this.dockX = this.clampX(this.dockX);
        this.dockY = this.clampY(this.dockY);
      }
    })
    .gesture(
      PanGesture({ fingers: 1, distance: 6 })
        .onActionStart(() => {
          this.dockX0 = this.dockX;
          this.dockY0 = this.dockY;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.dockX = this.clampX(this.dockX0 + e.offsetX);
          this.dockY = this.clampY(this.dockY0 + e.offsetY);
        })
        .onActionEnd(() => this.saveDockPos()),
    )
  }

  @Builder
  bottomAccessory() {
    Column({ space: 8 }) {
      Row() {
        Row({ space: 7 }) {
          this.pillKey('切换', '#8A8A8E', () => this.openNewTab())
          this.miniBtn('✕', '#FF3B30', () => this.confirmCloseActive())
          this.miniBtn('★', '#FFCC00', () => { this.sheet = 'favorites'; })
          this.miniBtn('↺', TEAL, () => { this.sheet = 'history'; })
        }
        Blank()
        Row({ space: 12 }) {
          Text('⌨').fontSize(20).fontColor('#8A8A8E').onClick(() => { this.voiceMode = false; this.tick++; this.hideKeyboard(); })
          Text('⌄').fontSize(20).fontColor('#8A8A8E').onClick(() => { this.panelOpen = false; this.voiceMode = false; this.tick++; this.hideKeyboard(); })
        }
      }.width('100%')

      Row() {
        Row({ space: 7 }) {
          this.pillKey('Clear', '#8A8A8E', () => this.sendKey([0x15]))
          this.pillKey('ESC', '#FF6B6B', () => this.sendKey([0x1b]))
          this.pillKey('Claude', '#FF9F45', () => { this.sheet = 'claude'; })
          this.miniBtn('⟳', TEAL, () => this.reconnectActive())
        }
        Blank()
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            this.arrowKey('⇤', [0x1b, 0x5b, 0x5a])
            this.arrowKey('↑', [0x1b, 0x5b, 0x41])
            Text('').width(40).height(38)
          }
          Row({ space: 6 }) {
            this.arrowKey('←', [0x1b, 0x5b, 0x44])
            this.arrowKey('↓', [0x1b, 0x5b, 0x42])
            this.arrowKey('→', [0x1b, 0x5b, 0x43])
          }
        }
      }.width('100%').alignItems(VerticalAlign.Top)

      if (this.voiceMode) {
        this.composer()
      }
    }
    .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 10 }).backgroundColor('#0A0A0A')
  }

  @Builder
  composer() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        TextInput({ text: this.composerText, placeholder: this.voiceHint })
          .layoutWeight(1).height(48).backgroundColor(CARD).fontColor('#FFFFFF')
          .placeholderColor('#6A6A6E').borderRadius(10)
          .enableKeyboardOnFocus(false)
          .onChange((v: string) => { this.composerText = v; })
        Column({ space: 6 }) {
          Text('↵').fontSize(18).fontColor('#4A9EFF').width(60).height(40).textAlign(TextAlign.Center)
            .border({ width: 1, color: '#3A5A8A', radius: 9 })
            .onClick(() => this.sendKey([0x0d]))
          Row({ space: 10 }) {
            Text('📄').fontSize(18).onClick(() => this.dumpTranscript())
            Text('🖼️').fontSize(18).onClick(() => this.pickAndUploadImage())
            Text('📥').fontSize(18).onClick(() => this.pasteClipboard())
          }
        }
      }.width('100%')

      Row({ space: 14 }) {
        Stack() {
          Text(this.recording ? '⏹' : '🎤').fontSize(22)
        }
        .width(52).height(52).borderRadius(26)
        .backgroundColor(this.recording ? '#FF3B30' : '#4A9EFF')
        .onClick(() => { this.recording ? this.stopVoice() : this.startVoice(); })

        Text('清空').fontSize(16).fontColor('#FF6B6B').layoutWeight(1).textAlign(TextAlign.Center)
          .onClick(() => { this.composerText = ''; })
        Button('确定 ↵').fontSize(16).fontColor('#FFFFFF').backgroundColor('#4A9EFF')
          .height(48).layoutWeight(1).onClick(() => this.commitComposer())
      }.width('100%')
    }
    .width('100%').padding({ top: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.topBar()
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
        // by driving x-screen.scrollTop from JS (term_scroll_move). Double-tap toggles
        // the soft keyboard; a plain tap does nothing (never auto-pops the keyboard).
        .priorityGesture(
          GestureGroup(GestureMode.Parallel,
            PanGesture({ distance: 12 })
              .onActionStart(() => { this.panMode = ''; this.lastPanY = 0; })
              .onActionUpdate((e: GestureEvent) => this.onTermPan(e))
              .onActionEnd((e: GestureEvent) => { if (this.panMode === 'h') { this.onHSwipe(e); } }),
            TapGesture({ count: 2 })
              .onAction(() => { this.kbHeight > 0 ? this.hideKeyboard() : this.showKeyboard(); })),
        )
        if (this.panelOpen) {
          this.bottomAccessory()
        }
      }
      .width('100%').height('100%').backgroundColor('#000000')

      // floating dock — absolutely positioned & draggable (see dockX/dockY / onRootArea)
      Column() {
        this.floatingDock()
      }
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      // sheets / overlays
      if (this.sheet !== 'none') {
        this.sheetChrome()
      }
      if (this.showBrowser) {
        this.browserOverlay()
      }
      if (this.showTranscript) {
        this.transcriptOverlay()
      }
    }
    .width('100%').height('100%').backgroundColor('#000000').padding({ bottom: this.kbHeight })
    .onAreaChange((_: Area, n: Area) => this.onRootArea(n.width as number, n.height as number))
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
  // resting tabs are always hidden from the strip, so after parking one we jump to the
  // next working tab (same machine first, following the machine filter if it lives
  // elsewhere) so the strip isn't left showing only the tab just parked. Un-resting
  // just re-renders in place.
  private toggleRest(): void {
    if (this.activeTabId.length === 0) {
      return;
    }
    const key: string = this.activeTabId;
    const nowResting: boolean = this.store.toggleResting(key);
    this.toast(nowResting ? '已标记休息 😴' : '已标记在岗');
    if (nowResting) {
      const target: string = this.nextWorkingTab(key);
      if (target.length > 0) {
        const cur = this.store.tabById(key);
        const tgt = this.store.tabById(target);
        if (this.store.filterMachineId.length > 0 && cur !== null && tgt !== null &&
          tgt.machineId !== cur.machineId) {
          this.store.filterMachineId = tgt.machineId;
          this.store.saveFilter();
        }
        this.switchTab(target);
        return;
      }
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
      if (cand.id === key || this.store.isResting(cand.id)) {
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

  private openBrowser(): void {
    this.browserUrl = this.store.pinned.length > 0 ? this.store.pinned[0].url : 'https://www.baidu.com';
    this.showBrowser = true;
  }

  private confirmCloseActive(): void {
    const t = this.store.tabById(this.activeTabId);
    if (t !== null) {
      this.confirmCloseTab(t);
    }
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
      Column().width('100%').height('100%').backgroundColor('#000000CC')
        .onClick(() => { this.sheet = 'none'; })
      Column() {
        Row().width(38).height(5).borderRadius(3).backgroundColor('#3A3A3C').margin({ top: 8, bottom: 10 })
        Row() {
          Text(this.sheetTitle()).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').layoutWeight(1)
          Text('完成').fontSize(15).fontColor('#0A84FF').onClick(() => { this.sheet = 'none'; })
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

        if (this.sheet === 'settings') {
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
        }
      }
      .width('100%').height(this.sheetHeight()).backgroundColor('#0C0C0E')
      .borderRadius({ topLeft: 18, topRight: 18 })
    }
    .width('100%').height('100%')
  }

  private sheetTitle(): string {
    if (this.sheet === 'settings') {
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
      return '员工在岗 / 休息';
    }
    return '';
  }

  private sheetHeight(): string {
    if (this.sheet === 'settings') {
      return '86%';
    } else if (this.sheet === 'machinePicker') {
      return '60%';
    } else if (this.sheet === 'newTab' || this.sheet === 'machineForm' || this.sheet === 'workDirs') {
      return '82%';
    } else if (this.sheet === 'aiConfig') {
      return '70%';
    }
    return '70%';
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

  // -- machine list (delete; add/edit via seeded config) --
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
            Text('删除').fontSize(13).fontColor('#FF3B30').onClick(() => this.deleteMachine(m))
          }.width('100%').padding({ top: 10, bottom: 10, left: 14, right: 14 })
          .backgroundColor('#1C1C1E').borderRadius(10)
        }, (m: Machine) => m.id + this.tick)
        Text('这些机器已从你 iOS 的配置同步过来。连接方式 Socket=blinkd，SSH 走 mac 中转。')
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
  @Builder
  restPanelBody() {
    List() {
      ForEach(this.store.tabs, (t: TabModel) => {
        ListItem() {
          Row({ space: 10 }) {
            this.avatar(this.store.workDirById(t.workDirId), false, 30)
            Column({ space: 2 }) {
              Text(this.store.tabTitle(t)).fontSize(15).fontColor('#FFFFFF')
              Text(this.machineNameForTab(t) + ' · ' + (this.store.isResting(t.id) ? '😴 休息中' : '在岗'))
                .fontSize(11).fontColor(this.store.isResting(t.id) ? '#B0A8FF' : '#8E8E93')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: !this.store.isResting(t.id) })
              .selectedColor('#34C759')
              .onChange((on: boolean) => { this.store.setResting(t.id, !on); this.refreshTabs(); })
          }.width('100%').padding({ top: 10, bottom: 10 })
        }
      }, (t: TabModel) => t.id + (this.store.isResting(t.id) ? '_r' : '_w') + '_' + this.tick)
    }
    .layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).divider({ strokeWidth: 0.5, color: '#2A2A2C' })
    Text('开关打开＝在岗（显示在标签栏），关闭＝休息（从标签栏隐藏）。休息中的员工也能在这里随时改回在岗。')
      .fontSize(11).fontColor('#6A6A6E').width('100%').padding({ left: 16, right: 16, top: 8, bottom: 16 })
  }

  private machineNameForTab(t: TabModel): string {
    const m = this.store.machineById(t.machineId);
    return m !== null ? this.store.machineDisplayName(m) : '其他';
  }

  // ---- browser overlay ----
  @Builder
  browserOverlay() {
    Column() {
      Row({ space: 10 }) {
        Text('‹ 关闭').fontSize(15).fontColor(TEAL).onClick(() => { this.showBrowser = false; })
        Text(this.browserUrl).fontSize(12).fontColor('#8E8E93').layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').height(44).padding({ left: 14, right: 14 }).backgroundColor('#1C1C1E')
      Web({ src: this.browserUrl, controller: new webview.WebviewController() })
        .width('100%').layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor('#000000')
  }

  // ---- transcript overlay ----
  @Builder
  transcriptOverlay() {
    Column() {
      Row() {
        Text('终端内容').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').layoutWeight(1)
        Text('复制').fontSize(14).fontColor(TEAL).margin({ right: 16 }).onClick(() => this.copyTranscript())
        Text('关闭').fontSize(14).fontColor('#0A84FF').onClick(() => { this.showTranscript = false; })
      }.width('100%').height(48).padding({ left: 16, right: 16 })
      Scroll() {
        Text(this.transcriptText).fontSize(12).fontColor('#D4D4D4').fontFamily('monospace')
          .width('100%').textAlign(TextAlign.Start).padding(12)
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }
    .width('100%').height('100%').backgroundColor('#0C0C0E')
  }

  private copyTranscript(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.transcriptText);
    pasteboard.getSystemPasteboard().setData(data).then(() => this.toast('已复制')).catch(() => {});
  }

  private deleteMachine(m: Machine): void {
    this.getUIContext().showAlertDialog({
      title: '删除机器',
      message: '删除「' + this.store.machineDisplayName(m) + '」？',
      primaryButton: {
        value: '删除', fontColor: '#FF3B30', action: () => {
          const i = this.store.machines.findIndex((x: Machine) => x.id === m.id);
          if (i >= 0) {
            this.store.machines.splice(i, 1);
            this.store.saveMachines();
            this.tick++;
          }
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private saveTs(key: string, value: string): void {
    const p = this.tsPrefs;
    if (p === null) {
      return;
    }
    p.put(key, value).then((): Promise<void> => p.flush()).catch(() => {});
  }
}
