////////////////////////////////////////////////////////////////////////////////
//
// BlinkTerminal — Blink for HarmonyOS, in the spirit of the iOS app: a full-screen
// black terminal with the iOS Blink chrome on top — a top bar (⚙ / machine pill /
// moon·sparkles·＋), a horizontal session-tab strip, the floating round tool dock
// on the right edge, and a rich bottom input accessory (two SmartKeys rows + arrow
// pad + a voice/line composer). Typing goes straight into the terminal (a
// transparent capture field over the screen, echoed by the remote). Tailscale runs
// underneath (tsvpn base library) so the terminal reaches a blinkd node on the
// tailnet — the HarmonyOS sibling of typing `ssh host` in Blink.
//
// The transport/terminal/input logic below is the device-verified path; the UI
// layer (builders + build()) is the iOS-faithful chrome on top of it.
//
////////////////////////////////////////////////////////////////////////////////

import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { vpnExtension } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util, buffer } from '@kit.ArkTS';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BlinkdClient, BlinkdState, TailscaleCore, StatusStore } from 'tsvpn';

const DOMAIN: number = 0x0B11;
const TAG: string = 'BlinkTerminal';
const BUNDLE: string = 'com.douwantech.blink';

// palette (matches the iOS Blink look)
const TEAL: string = '#3DD9C4';
const CARD: string = '#141416';
const HAIRLINE: string = '#2E6E68';

interface Theme {
  name: string;
  bg: string;
  fg: string;
  cursor: string;
}

// A few ready-made terminal themes (applied live to hterm via term_set_colors).
const THEMES: Theme[] = [
  { name: 'Blink 暗', bg: '#000000', fg: '#D4D4D4', cursor: 'rgba(61,217,196,0.65)' },
  { name: 'Solarized', bg: '#002B36', fg: '#93A1A1', cursor: 'rgba(38,139,210,0.75)' },
  { name: 'Monokai', bg: '#272822', fg: '#F8F8F2', cursor: 'rgba(166,226,46,0.75)' },
  { name: 'Nord', bg: '#2E3440', fg: '#D8DEE9', cursor: 'rgba(136,192,208,0.75)' },
  { name: 'WWDC16', bg: '#292C36', fg: '#C7C7C7', cursor: 'rgba(255,255,255,0.6)' },
];

const FONT_SIZES: number[] = [11, 12, 13, 14, 16, 18];

// Bridge object exposed to hterm's JS as window.arkBridge; JS calls post(op,data).
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
  // tailscale (underlying transport)
  @State tsState: string = '';
  @State tsIP: string = '';
  @State tsConnected: boolean = false;
  @State authKey: string = '';
  @State hostname: string = 'harmony';
  // blinkd session
  @State bHost: string = '';
  @State bPort: string = '7777';
  @State bToken: string = '';
  @State bExec: string = '';
  @State bConnected: boolean = false;
  // real-time input capture (transparent field over the terminal)
  @State inputBuf: string = '';
  // ui
  @State showConfig: boolean = false;
  @State kbHeight: number = 0;   // system keyboard height (vp), to float SmartKeys above it
  @State cols: number = 52;
  @State rows: number = 30;
  // iOS-style chrome state
  @State toolbarOpen: boolean = true;   // right-edge floating dock expanded
  @State voiceMode: boolean = false;    // show the bottom voice/line composer
  @State composerText: string = '';     // text in the composer field
  @State machineName: string = 'mac';   // machine pill label
  @State tabs: string[] = ['jack:blink']; // session tabs (one real session for now)
  @State activeTab: number = 0;
  @State themeIdx: number = 0;          // index into THEMES
  @State fontSize: number = 13;         // terminal font size (px)

  private client: BlinkdClient = new BlinkdClient();
  private enc: util.TextEncoder = new util.TextEncoder();
  private b64: util.Base64Helper = new util.Base64Helper();
  private win: window.Window | null = null;
  private webCtl: webview.WebviewController = new webview.WebviewController();
  private jsBridge: JsBridge = new JsBridge((op: string, data: string): void => { this.onBridge(op, data); });
  private tsPrefs: preferences.Preferences | null = null;
  private bPrefs: preferences.Preferences | null = null;
  private uiPrefs: preferences.Preferences | null = null;
  private timer: number = -1;
  private autoBlinkd: boolean = false;
  private failCount: number = 0;       // consecutive quick reconnect failures (for backoff)
  private cooldownUntil: number = 0;   // Date.now() ms; auto-reconnect won't fire before this
  private connectedAt: number = 0;     // Date.now() ms when the current session connected
  private lastLen: number = 0;      // length of inputBuf already sent
  private skipNext: boolean = false; // skip the onChange fired by clearing inputBuf

  aboutToAppear(): void {
    try {
      TailscaleCore.version();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'core self-test: %{public}s', `${e}`);
    }
    this.client.onData = (bytes: Uint8Array) => {
      this.writeToTerm(bytes);
    };
    this.client.onState = (s: BlinkdState, detail: string) => {
      this.bConnected = (s === 'connected');
      if (s === 'connecting') {
        this.appendLine('· 连接 ' + this.bHost + ' …');
      } else if (s === 'connected') {
        this.connectedAt = Date.now();
      } else if (s === 'closed' || s === 'error') {
        this.autoBlinkd = false;
        // Exponential backoff: a shell that exits instantly (or a dead daemon) must not
        // get hammered every 1.5s poll tick. A session that held >10s counts as healthy
        // → reset and let the poll reconnect promptly; a quick drop backs off
        // 3→6→12→24→30s so we stop pounding the daemon.
        const lasted: number = this.connectedAt > 0 ? (Date.now() - this.connectedAt) : 0;
        this.connectedAt = 0;
        if (lasted > 10000) {
          this.failCount = 0;
          this.cooldownUntil = 0;
          this.appendLine('· 连接已断开');
        } else {
          this.failCount = this.failCount + 1;
          const wait: number = Math.min(1500 * Math.pow(2, this.failCount), 30000);
          this.cooldownUntil = Date.now() + wait;
          this.appendLine('· 连接已断开，' + Math.round(wait / 1000) + ' 秒后重连');
        }
      }
    };
    this.setupKeyboard();
    this.loadPrefs();
  }

  aboutToDisappear(): void {
    this.client.close();
    if (this.win !== null) {
      try {
        this.win.off('keyboardHeightChange');
      } catch (e) {
        // ignore
      }
    }
  }

  // Take over keyboard avoidance so the SmartKeys row sits directly on top of the
  // system keyboard (like Blink's inputAccessoryView), instead of being covered.
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

  // Print a local status line into the terminal (used before the shell is up).
  private appendLine(s: string): void {
    // @ohos.buffer gives correct UTF-8 bytes for app text. (ArkTS TextEncoder garbled
    // multi-byte, and passing raw Chinese through runJavaScript mangles it too.) base64
    // → term_write_b64 is the exact clean path blinkd's shell output already renders with.
    const b64: string = buffer.from(s + '\r\n', 'utf-8').toString('base64');
    this.webCtl.runJavaScript(`term_write_b64('${b64}')`);
  }

  // Push raw bytes into the hterm renderer running in the Web component.
  private writeToTerm(bytes: Uint8Array): void {
    const b64: string = this.b64.encodeToStringSync(bytes);
    this.webCtl.runJavaScript(`term_write_b64('${b64}')`);
  }

  // Messages from harmony_term.js (window.arkBridge.post).
  private onBridge(op: string, dataStr: string): void {
    if (op === 'sigwinch') {
      try {
        const d = JSON.parse(dataStr) as Record<string, number>;
        const cols: number = d.cols as number;
        const rows: number = d.rows as number;
        if (cols > 0 && rows > 0) {
          this.cols = cols;
          this.rows = rows;
          if (this.bConnected) {
            this.client.sendResize(rows, cols);
          }
        }
      } catch (e) {
      }
    } else if (op === 'ready') {
      // terminal is up: re-apply the saved theme / font (hterm booted with defaults).
      const th: Theme = THEMES[this.themeIdx];
      this.webCtl.runJavaScript(`term_set_colors('${th.bg}','${th.fg}','${th.cursor}')`);
      this.webCtl.runJavaScript(`term_setFontSize(${this.fontSize})`);
    } else if (op === 'error') {
      hilog.error(DOMAIN, TAG, 'hterm: %{public}s', dataStr);
    } else {
      hilog.info(DOMAIN, TAG, 'hterm %{public}s: %{public}s', op, dataStr);
    }
  }

  private async loadPrefs(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.tsPrefs = await preferences.getPreferences(ctx, 'ts_prefs');
      this.bPrefs = await preferences.getPreferences(ctx, 'blinkd_prefs');
      this.uiPrefs = await preferences.getPreferences(ctx, 'ui_prefs');
      this.authKey = await this.tsPrefs.get('authKey', '') as string;
      this.hostname = await this.tsPrefs.get('hostname', 'harmony') as string;
      this.bHost = await this.bPrefs.get('host', '') as string;
      this.bPort = await this.bPrefs.get('port', '7777') as string;
      this.bToken = await this.bPrefs.get('token', '') as string;
      this.bExec = await this.bPrefs.get('exec', '') as string;
      this.themeIdx = await this.uiPrefs.get('themeIdx', 0) as number;
      this.fontSize = await this.uiPrefs.get('fontSize', 13) as number;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadPrefs: %{public}s', `${e}`);
    }
    this.appendLine('Blink · HarmonyOS — tailscale + blinkd');
    this.appendLine('');
    if (this.authKey.length > 0) {
      this.appendLine('· 正在连接 tailscale …');
    } else {
      this.appendLine('⚙ 右上角设置 auth key + blinkd 目标，之后自动连接');
    }
    if (this.authKey.length > 0 && !this.tsConnected) {
      this.tsConnect();
    }
  }

  private saveTs(key: string, value: string): void {
    const p = this.tsPrefs;
    if (p === null) {
      return;
    }
    p.put(key, value).then(() => p.flush()).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'saveTs: %{public}s', JSON.stringify(e));
    });
  }

  private saveB(key: string, value: string): void {
    const p = this.bPrefs;
    if (p === null) {
      return;
    }
    p.put(key, value).then(() => p.flush()).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'saveB: %{public}s', JSON.stringify(e));
    });
  }

  private saveUi(key: string, value: number): void {
    const p = this.uiPrefs;
    if (p === null) {
      return;
    }
    p.put(key, value).then(() => p.flush()).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'saveUi: %{public}s', JSON.stringify(e));
    });
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
    } catch (e) {
    }
  }

  // Re-attach the blinkd session now (the ⌘R / 🔄 refresh action).
  private reconnect(): void {
    this.failCount = 0;
    this.cooldownUntil = 0;
    this.autoBlinkd = true;
    this.bConnect();
  }

  private applyTheme(i: number): void {
    if (i < 0 || i >= THEMES.length) {
      return;
    }
    this.themeIdx = i;
    const th: Theme = THEMES[i];
    this.webCtl.runJavaScript(`term_set_colors('${th.bg}','${th.fg}','${th.cursor}')`);
    this.saveUi('themeIdx', i);
  }

  private applyFont(px: number): void {
    this.fontSize = px;
    this.webCtl.runJavaScript(`term_setFontSize(${px})`);
    this.saveUi('fontSize', px);
  }

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
      hilog.error(DOMAIN, TAG, 'stopKeepAlive: %{public}s', `${e}`);
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
        if (state === 'Running' && !this.bConnected && !this.autoBlinkd
            && this.bHost.length > 0 && this.bToken.length > 0
            && Date.now() >= this.cooldownUntil) {
          this.autoBlinkd = true;
          this.bConnect();
        }
      } catch (e) {
        // status file not written yet
      }
    }, 1500);
  }

  private bConnect(): void {
    const p: number = parseInt(this.bPort);
    if (this.bHost.trim().length === 0 || !p || this.bToken.trim().length === 0) {
      this.showConfig = true;
      return;
    }
    this.webCtl.runJavaScript('term_clear()');
    this.inputBuf = '';
    this.lastLen = 0;
    this.client.connect(this.bHost.trim(), p, this.bToken.trim(), this.rows, this.cols, this.bExec.trim());
  }

  private bDisconnect(): void {
    this.client.close();
    this.bConnected = false;
    this.autoBlinkd = false;
    this.failCount = 0;
    this.cooldownUntil = 0;
  }

  // Real-time input: send the delta since we last sent. Growth → send the new
  // suffix; shrink (backspace) → send DELs. Enter is handled in onSubmit.
  private onInput(v: string): void {
    if (this.skipNext) {
      this.skipNext = false;
      this.lastLen = v.length;
      return;
    }
    if (!this.bConnected) {
      this.lastLen = v.length;
      return;
    }
    if (v.length > this.lastLen) {
      this.client.sendInput(v.substring(this.lastLen));
    } else if (v.length < this.lastLen) {
      const dels = new Uint8Array(this.lastLen - v.length);
      dels.fill(0x7f);
      this.client.sendBytes(dels);
    }
    this.lastLen = v.length;
  }

  private submitLine(): void {
    if (this.bConnected) {
      this.client.sendInput('\n');
    }
    this.skipNext = true;
    this.inputBuf = '';
    this.lastLen = 0;
  }

  private sendKey(bytes: number[]): void {
    if (!this.bConnected) {
      return;
    }
    this.client.sendBytes(new Uint8Array(bytes));
  }

  // Send the composed line to the shell, then clear the composer.
  private sendComposer(): void {
    if (this.composerText.length > 0 && this.bConnected) {
      this.client.sendInput(this.composerText + '\n');
    }
    this.composerText = '';
  }

  ////////////////////////////////////////////////////////////////////////////
  // UI builders
  ////////////////////////////////////////////////////////////////////////////

  // A solid colored round button (right-edge dock).
  @Builder
  circleBtn(glyph: string, bg: string, action: () => void) {
    Stack() {
      Text(glyph).fontSize(20).fontColor('#FFFFFF')
    }
    .width(46).height(46).borderRadius(23).backgroundColor(bg)
    .onClick(action)
  }

  // A small outlined round key (in the accessory rows).
  @Builder
  miniBtn(glyph: string, color: string, action: () => void) {
    Stack() {
      Text(glyph).fontSize(15).fontColor(color)
    }
    .width(38).height(38).borderRadius(19)
    .backgroundColor(CARD)
    .border({ width: 1.5, color: color })
    .onClick(action)
  }

  // A labeled pill key (esc / Clear / Claude …).
  @Builder
  pillKey(label: string, accent: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(accent)
      .fontFamily('monospace')
      .backgroundColor(CARD)
      .border({ width: 1, color: accent, radius: 9 })
      .constraintSize({ minWidth: 40 })
      .height(38)
      .textAlign(TextAlign.Center)
      .padding({ left: 9, right: 9 })
      .onClick(action)
  }

  // An arrow / nav key that sends a byte sequence.
  @Builder
  arrowKey(glyph: string, bytes: number[]) {
    Text(glyph)
      .fontSize(16)
      .fontColor(TEAL)
      .backgroundColor(CARD)
      .borderRadius(9)
      .width(40)
      .height(38)
      .textAlign(TextAlign.Center)
      .onClick(() => this.sendKey(bytes))
  }

  // ---- top bar: ⚙ | machine pill | 🌙n ✨ ＋ ----
  @Builder
  topBar() {
    Row() {
      Text('⚙')
        .fontSize(20)
        .fontColor(TEAL)
        .onClick(() => { this.showConfig = true; })
      Row({ space: 5 }) {
        Text('≡').fontSize(15).fontColor(TEAL)
        Text(this.machineName).fontSize(14).fontColor(TEAL)
      }
      .padding({ left: 12, right: 13, top: 4, bottom: 4 })
      .border({ width: 1, color: HAIRLINE, radius: 16 })
      .margin({ left: 12 })
      .onClick(() => this.toast('机器选择 · 开发中'))

      Blank()

      Row({ space: 3 }) {
        Text('🌙').fontSize(16)
        Text(this.tabs.length.toString()).fontSize(15).fontColor('#B0A8FF')
      }
      .onClick(() => this.toast('保持唤醒中'))
      Text('✨').fontSize(17).margin({ left: 12 }).onClick(() => this.toast('AI 助手 · 开发中'))
      Text('＋').fontSize(24).fontColor(TEAL).margin({ left: 12 })
        .onClick(() => { this.showConfig = true; })
    }
    .width('100%')
    .height(46)
    .padding({ left: 14, right: 16 })
    .backgroundColor('#000000')
  }

  // ---- session tab: avatar chip + user:machine, current highlighted ----
  @Builder
  sessionTab(label: string, idx: number) {
    Row({ space: 6 }) {
      // avatar chip (warm-tone placeholder, no emoji dependency)
      Stack() {
        Text(label.length > 0 ? label.substring(0, 1).toUpperCase() : 'J')
          .fontSize(10).fontColor('#FFFFFF')
      }
      .width(20).height(20).borderRadius(10)
      .backgroundColor(idx === this.activeTab ? '#B4694E' : '#5A5A5E')

      Text(label)
        .fontSize(14)
        .fontColor(idx === this.activeTab ? '#FFFFFF' : '#8A8A8E')
        .fontFamily('monospace')
    }
    .padding({ left: 10, right: 13, top: 6, bottom: 6 })
    .backgroundColor(idx === this.activeTab ? '#16323A' : Color.Transparent)
    .border(idx === this.activeTab
      ? { width: 1, color: HAIRLINE, radius: 11 }
      : { width: 0, color: Color.Transparent, radius: 11 })
    .onClick(() => { this.activeTab = idx; })
  }

  @Builder
  tabBar() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.tabs, (t: string, i: number) => {
          this.sessionTab(t, i)
        })
        Text('＋')
          .fontSize(18).fontColor('#5A5A5E')
          .padding({ left: 6, right: 6 })
          .onClick(() => { this.showConfig = true; })
      }
      .padding({ left: 14, right: 14 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ bottom: 7 })
    .backgroundColor('#000000')
  }

  // ---- right-edge floating tool dock (collapsible) ----
  @Builder
  floatingDock() {
    Column({ space: 10 }) {
      // grabber — tap to collapse / expand
      Row()
        .width(34).height(5).borderRadius(3).backgroundColor('#5A5A5E')
        .onClick(() => { this.toolbarOpen = !this.toolbarOpen; })
      if (this.toolbarOpen) {
        this.circleBtn('🌙', '#8E8E93', () => this.toast('保持唤醒'))
        this.circleBtn('🌐', '#4A9EFF', () => this.toast('浏览器 · 开发中'))
        this.circleBtn('⭐', '#FFCC00', () => this.toast('收藏 · 开发中'))
        this.circleBtn('🕐', '#4A9EFF', () => this.toast('历史 · 开发中'))
        this.circleBtn('🔄', '#34C759', () => this.reconnect())
        this.circleBtn('🖥️', '#C74DE0', () => this.toast('投屏 · 开发中'))
        this.circleBtn('🎤', TEAL, () => { this.voiceMode = !this.voiceMode; })
      }
    }
    .padding({ left: 6, right: 6, top: 8, bottom: 10 })
    .backgroundColor('#1C1C1EE6')
    .borderRadius(28)
    .margin({ right: 6 })
  }

  // ---- bottom input accessory: two SmartKeys rows + arrow pad + composer ----
  @Builder
  bottomAccessory() {
    Column({ space: 8 }) {
      // row 1: dev / ✕ / ⭐ / 🕐  ……  keyboard / collapse
      Row() {
        Row({ space: 7 }) {
          this.pillKey('dev', '#8A8A8E', () => this.toast('workspace: dev'))
          this.miniBtn('✕', '#FF3B30', () => { this.voiceMode = false; })
          this.miniBtn('★', '#FFCC00', () => this.toast('收藏'))
          this.miniBtn('↺', TEAL, () => this.toast('历史'))
        }
        Blank()
        Row({ space: 12 }) {
          Text('⌨').fontSize(20).fontColor('#8A8A8E').onClick(() => this.toast('键盘'))
          Text('⌄').fontSize(20).fontColor('#8A8A8E').onClick(() => { this.voiceMode = false; })
        }
      }
      .width('100%')

      // row 2: Clear / ESC / Claude / ⟳  ……  arrow pad
      Row() {
        Row({ space: 7 }) {
          this.pillKey('Clear', '#8A8A8E', () => this.sendKey([0x0c]))
          this.pillKey('ESC', '#FF6B6B', () => this.sendKey([0x1b]))
          this.pillKey('Claude', '#FF9F45', () => { if (this.bConnected) { this.client.sendInput('claude'); } })
          this.miniBtn('⟳', TEAL, () => this.reconnect())
        }
        Blank()
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            this.arrowKey('⇤', [0x09])
            this.arrowKey('↑', [0x1b, 0x5b, 0x41])
            Text('').width(40).height(38)
          }
          Row({ space: 6 }) {
            this.arrowKey('←', [0x1b, 0x5b, 0x44])
            this.arrowKey('↓', [0x1b, 0x5b, 0x42])
            this.arrowKey('→', [0x1b, 0x5b, 0x43])
          }
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // composer (voice / line) — shown in voice mode
      if (this.voiceMode) {
        this.composer()
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor('#0A0A0A')
  }

  @Builder
  composer() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        TextInput({ text: this.composerText, placeholder: '点击下方按钮开始说话' })
          .layoutWeight(1)
          .height(48)
          .backgroundColor(CARD)
          .fontColor('#FFFFFF')
          .placeholderColor('#6A6A6E')
          .borderRadius(10)
          .onChange((v: string) => { this.composerText = v; })
        Column({ space: 6 }) {
          Text('↵')
            .fontSize(18).fontColor('#4A9EFF')
            .width(60).height(40).textAlign(TextAlign.Center)
            .border({ width: 1, color: '#3A5A8A', radius: 9 })
            .onClick(() => { if (this.bConnected) { this.client.sendInput('\n'); } })
          Row({ space: 10 }) {
            Text('📄').fontSize(18).onClick(() => this.toast('粘贴 · 开发中'))
            Text('🖼️').fontSize(18).onClick(() => this.toast('图片 · 开发中'))
            Text('📥').fontSize(18).onClick(() => this.toast('下载 · 开发中'))
          }
        }
      }
      .width('100%')

      Row({ space: 14 }) {
        Stack() {
          Text('🎤').fontSize(22)
        }
        .width(52).height(52).borderRadius(26).backgroundColor('#4A9EFF')
        .onClick(() => this.toast('语音识别 · 开发中'))

        Text('清空')
          .fontSize(16).fontColor('#FF6B6B')
          .layoutWeight(1).textAlign(TextAlign.Center)
          .onClick(() => { this.composerText = ''; })

        Button('确定 ↵')
          .fontSize(16).fontColor('#FFFFFF')
          .backgroundColor('#4A9EFF')
          .height(48).layoutWeight(1)
          .onClick(() => this.sendComposer())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.topBar()
        this.tabBar()

        // ---- full-screen terminal + transparent input capture ----
        Stack({ alignContent: Alignment.TopStart }) {
          // hterm renderer (real VT: colors, cursor, alt-screen — vim/tmux/claude).
          Web({ src: $rawfile('term/term.html'), controller: this.webCtl })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .javaScriptProxy({
              object: this.jsBridge,
              name: 'arkBridge',
              methodList: ['post'],
              controller: this.webCtl,
            })
            .onPageEnd(() => {
              this.webCtl.runJavaScript('term_init()');
            })
            .backgroundColor('#000000')
            .width('100%')
            .height('100%')

          // Transparent field over the whole terminal: tap anywhere to focus and
          // type straight into the session; the remote echoes what you type.
          TextInput({ text: this.inputBuf })
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Transparent)
            .fontColor(Color.Transparent)
            .caretColor(Color.Transparent)
            .enterKeyType(EnterKeyType.Send)
            .enableKeyboardOnFocus(true)
            .onChange((v: string) => this.onInput(v))
            .onSubmit(() => this.submitLine())
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#000000')

        this.bottomAccessory()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')

      // ---- right-edge floating dock (pass-through wrapper) ----
      Column() {
        this.floatingDock()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)

      // ---- settings sheet ----
      if (this.showConfig) {
        this.settingsSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .padding({ bottom: this.kbHeight })
  }

  ////////////////////////////////////////////////////////////////////////////
  // Settings sheet
  ////////////////////////////////////////////////////////////////////////////

  @Builder
  sectionHeader(title: string) {
    Text(title)
      .fontSize(12).fontColor('#8E8E93')
      .width('100%').textAlign(TextAlign.Start)
      .margin({ top: 6, bottom: 4 })
  }

  @Builder
  settingsSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      // tap-outside backdrop
      Column()
        .width('100%').height('100%').backgroundColor('#000000CC')
        .onClick(() => { this.showConfig = false; })
      Column() {
        // grabber + title bar
        Row()
          .width(38).height(5).borderRadius(3).backgroundColor('#3A3A3C')
          .margin({ top: 8, bottom: 10 })
        Row() {
          Text('设置').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').layoutWeight(1)
          Text('完成').fontSize(15).fontColor('#0A84FF').onClick(() => { this.showConfig = false; })
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 8 })

        Scroll() {
          Column({ space: 8 }) {
            // ---- Tailscale ----
            this.sectionHeader('Tailscale')
            Column({ space: 10 }) {
              TextInput({ text: this.authKey, placeholder: 'auth key (tskey-…)' })
                .fontSize(13).type(InputType.Password).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
                .onChange((v: string) => { this.authKey = v; this.saveTs('authKey', v); })
              TextInput({ text: this.hostname, placeholder: '本机名 (hostname)' })
                .fontSize(13).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
                .onChange((v: string) => { this.hostname = v; this.saveTs('hostname', v); })
              Row({ space: 8 }) {
                Text(this.tsState.length > 0 ? ('● ' + this.tsState) : '● 未连接')
                  .fontSize(12).fontColor(this.tsState === 'Running' ? '#34C759' : '#8E8E93').layoutWeight(1)
                Text(this.tsIP).fontSize(12).fontColor('#8E8E93')
              }.width('100%')
              Button(this.tsConnected ? '断开 tailscale' : '连接 tailscale')
                .fontSize(14).width('100%').height(40)
                .backgroundColor(this.tsConnected ? '#3A3A3C' : '#34C759')
                .onClick(() => { this.tsConnected ? this.tsDisconnect() : this.tsConnect(); })
            }
            .width('100%').padding(14).backgroundColor('#1C1C1E').borderRadius(12)

            // ---- blinkd target ----
            this.sectionHeader('blinkd 目标')
            Column({ space: 10 }) {
              Row({ space: 8 }) {
                TextInput({ text: this.bHost, placeholder: 'host 例 100.x.y.z' })
                  .fontSize(13).layoutWeight(2).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
                  .onChange((v: string) => { this.bHost = v; this.saveB('host', v); })
                TextInput({ text: this.bPort, placeholder: 'port' })
                  .fontSize(13).layoutWeight(1).type(InputType.Number).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
                  .onChange((v: string) => { this.bPort = v; this.saveB('port', v); })
              }
              TextInput({ text: this.bToken, placeholder: 'token' })
                .fontSize(13).type(InputType.Password).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
                .onChange((v: string) => { this.bToken = v; this.saveB('token', v); })
              TextInput({ text: this.bExec, placeholder: '启动命令 (可空 = 登录 zsh)' })
                .fontSize(13).backgroundColor('#2A2A2C').fontColor('#FFFFFF').borderRadius(8)
                .onChange((v: string) => { this.bExec = v; this.saveB('exec', v); })
              Button(this.bConnected ? '重连 blinkd' : '连接 blinkd')
                .fontSize(14).width('100%').height(40).backgroundColor('#0A84FF')
                .onClick(() => { this.showConfig = false; this.reconnect(); })
            }
            .width('100%').padding(14).backgroundColor('#1C1C1E').borderRadius(12)

            // ---- appearance ----
            this.sectionHeader('外观 · 主题')
            Column({ space: 10 }) {
              Row({ space: 8 }) {
                ForEach(THEMES, (th: Theme, i: number) => {
                  Column({ space: 4 }) {
                    Stack() {
                      Text('Aa').fontSize(13).fontColor(th.fg)
                    }
                    .width(46).height(38).borderRadius(8).backgroundColor(th.bg)
                    .border(i === this.themeIdx
                      ? { width: 2, color: TEAL }
                      : { width: 1, color: '#3A3A3C' })
                    Text(th.name).fontSize(10)
                      .fontColor(i === this.themeIdx ? TEAL : '#8E8E93')
                  }
                  .onClick(() => this.applyTheme(i))
                })
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween)

              Divider().color('#3A3A3C')

              Row() {
                Text('字号').fontSize(13).fontColor('#FFFFFF').layoutWeight(1)
                Row({ space: 6 }) {
                  ForEach(FONT_SIZES, (px: number) => {
                    Text(px.toString())
                      .fontSize(13)
                      .fontColor(px === this.fontSize ? '#000000' : '#C7C7C7')
                      .backgroundColor(px === this.fontSize ? TEAL : '#2A2A2C')
                      .width(34).height(32).textAlign(TextAlign.Center).borderRadius(7)
                      .onClick(() => this.applyFont(px))
                  })
                }
              }.width('100%')
            }
            .width('100%').padding(14).backgroundColor('#1C1C1E').borderRadius(12)

            Text('Blink · HarmonyOS')
              .fontSize(11).fontColor('#5A5A5E').width('100%').textAlign(TextAlign.Center).margin({ top: 8, bottom: 16 })
          }
          .width('100%').padding({ left: 16, right: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('82%')
      .backgroundColor('#0C0C0E')
      .borderRadius({ topLeft: 18, topRight: 18 })
    }
    .width('100%')
    .height('100%')
  }
}
