////////////////////////////////////////////////////////////////////////////////
//
// BlinkTerminal — Blink for HarmonyOS, in the spirit of the iOS app: you open it
// and you're in a full-screen, all-black terminal. Typing goes straight into the
// terminal (a transparent capture field over the screen, echoed by the remote),
// with a persistent SmartKeys row along the bottom. Tailscale runs underneath
// (auto-connects via the tsvpn base library) so the terminal reaches a blinkd
// node on the tailnet — the HarmonyOS sibling of typing `ssh host` in Blink.
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

  private client: BlinkdClient = new BlinkdClient();
  private enc: util.TextEncoder = new util.TextEncoder();
  private b64: util.Base64Helper = new util.Base64Helper();
  private win: window.Window | null = null;
  private webCtl: webview.WebviewController = new webview.WebviewController();
  private jsBridge: JsBridge = new JsBridge((op: string, data: string): void => { this.onBridge(op, data); });
  private tsPrefs: preferences.Preferences | null = null;
  private bPrefs: preferences.Preferences | null = null;
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
      this.authKey = await this.tsPrefs.get('authKey', '') as string;
      this.hostname = await this.tsPrefs.get('hostname', 'harmony') as string;
      this.bHost = await this.bPrefs.get('host', '') as string;
      this.bPort = await this.bPrefs.get('port', '7777') as string;
      this.bToken = await this.bPrefs.get('token', '') as string;
      this.bExec = await this.bPrefs.get('exec', '') as string;
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

  @Builder
  smartKey(label: string, bytes: number[], accent: string) {
    Text(label)
      .fontSize(14)
      .fontColor(accent)
      .fontFamily('monospace')
      .backgroundColor('#141416')
      .border({ width: 1, color: accent, radius: 9 })
      .constraintSize({ minWidth: 46 })
      .height(38)
      .textAlign(TextAlign.Center)
      .padding({ left: 12, right: 12 })
      .onClick(() => this.sendKey(bytes))
  }

  @Builder
  sessionTab(label: string, selected: boolean) {
    Row({ space: 5 }) {
      Text('●')
        .fontSize(8)
        .fontColor(this.tsState === 'Running' ? '#34C759' : '#666666')
      Text(label)
        .fontSize(14)
        .fontColor(selected ? '#FFFFFF' : '#8A8A8E')
        .fontFamily('monospace')
    }
    .padding({ left: 13, right: 13, top: 6, bottom: 6 })
    .backgroundColor(selected ? '#1E3A5F' : Color.Transparent)
    .borderRadius(9)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // ---- minimal top bar ----
        // ---- toolbar row: ⚙ | filter pill | + ----
        Row({ space: 10 }) {
          Text('⚙')
            .fontSize(19)
            .fontColor('#3DD9C4')
            .onClick(() => { this.showConfig = true; })
          Row({ space: 5 }) {
            Text('≡').fontSize(14).fontColor('#3DD9C4')
            Text('全部').fontSize(13).fontColor('#3DD9C4')
          }
          .padding({ left: 12, right: 13, top: 4, bottom: 4 })
          .border({ width: 1, color: '#2E6E68', radius: 15 })
          Blank()
          Text('＋')
            .fontSize(24)
            .fontColor('#3DD9C4')
            .onClick(() => { this.showConfig = true; })
        }
        .width('100%')
        .height(44)
        .padding({ left: 14, right: 16 })
        .backgroundColor('#000000')

        // ---- session tab bar: user:machine tabs, current highlighted ----
        Row({ space: 8 }) {
          this.sessionTab(this.tabLabel(), true)
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ left: 14, right: 14, bottom: 7 })
        .backgroundColor('#000000')

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

        // ---- persistent SmartKeys row (horizontally scrollable) ----
        Scroll() {
          Row({ space: 7 }) {
            this.smartKey('esc', [0x1b], '#FF6B6B')
            this.smartKey('^C', [0x03], '#FF9F45')
            this.smartKey('^D', [0x04], '#FF9F45')
            this.smartKey('tab', [0x09], '#3DD9C4')
            this.smartKey('~', [0x7e], '#8A8A8E')
            this.smartKey('/', [0x2f], '#8A8A8E')
            this.smartKey('|', [0x7c], '#8A8A8E')
            this.smartKey('-', [0x2d], '#8A8A8E')
            this.smartKey('←', [0x1b, 0x5b, 0x44], '#3DD9C4')
            this.smartKey('↑', [0x1b, 0x5b, 0x41], '#3DD9C4')
            this.smartKey('↓', [0x1b, 0x5b, 0x42], '#3DD9C4')
            this.smartKey('→', [0x1b, 0x5b, 0x43], '#3DD9C4')
            this.smartKey('⏎', [0x0d], '#4A9EFF')
          }
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .backgroundColor('#0A0A0A')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')

      // ---- config overlay (gear) ----
      if (this.showConfig) {
        Column() {
          Column({ space: 8 }) {
            Row() {
              Text('设置').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFF').layoutWeight(1)
              Text('完成').fontSize(14).fontColor('#0A84FF').onClick(() => { this.showConfig = false; })
            }.width('100%').margin({ bottom: 4 })

            Text('Tailscale').fontSize(11).fontColor('#8E8E93').width('100%').textAlign(TextAlign.Start)
            TextInput({ text: this.authKey, placeholder: 'auth key (tskey-…)' })
              .fontSize(12).type(InputType.Password).backgroundColor('#2A2A2C').fontColor('#FFF')
              .onChange((v: string) => { this.authKey = v; this.saveTs('authKey', v); })
            Button(this.tsConnected ? '断开 tailscale' : '连接 tailscale')
              .fontSize(13).width('100%').height(38)
              .backgroundColor(this.tsConnected ? '#3A3A3C' : '#34C759')
              .onClick(() => { this.tsConnected ? this.tsDisconnect() : this.tsConnect(); })

            Divider().color('#3A3A3C').margin({ top: 6, bottom: 6 })

            Text('blinkd 目标').fontSize(11).fontColor('#8E8E93').width('100%').textAlign(TextAlign.Start)
            Row({ space: 6 }) {
              TextInput({ text: this.bHost, placeholder: 'host 例 100.x.y.z' })
                .fontSize(12).layoutWeight(2).backgroundColor('#2A2A2C').fontColor('#FFF')
                .onChange((v: string) => { this.bHost = v; this.saveB('host', v); })
              TextInput({ text: this.bPort, placeholder: 'port' })
                .fontSize(12).layoutWeight(1).type(InputType.Number).backgroundColor('#2A2A2C').fontColor('#FFF')
                .onChange((v: string) => { this.bPort = v; this.saveB('port', v); })
            }
            TextInput({ text: this.bToken, placeholder: 'token' })
              .fontSize(12).type(InputType.Password).backgroundColor('#2A2A2C').fontColor('#FFF')
              .onChange((v: string) => { this.bToken = v; this.saveB('token', v); })
            TextInput({ text: this.bExec, placeholder: '启动命令(可空=登录 zsh)' })
              .fontSize(12).backgroundColor('#2A2A2C').fontColor('#FFF')
              .onChange((v: string) => { this.bExec = v; this.saveB('exec', v); })
            Button(this.bConnected ? '重连 blinkd' : '连接 blinkd')
              .fontSize(13).width('100%').height(38).backgroundColor('#0A84FF')
              .onClick(() => { this.showConfig = false; this.failCount = 0; this.cooldownUntil = 0; this.autoBlinkd = true; this.bConnect(); })
          }
          .width('88%')
          .padding(16)
          .backgroundColor('#1C1C1E')
          .borderRadius(14)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000CC')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .padding({ bottom: this.kbHeight })
  }

  private headerText(): string {
    if (this.bConnected) {
      return this.bHost;
    }
    if (this.bHost.length > 0) {
      return this.bHost;
    }
    return 'blink';
  }

  private tabLabel(): string {
    return this.bHost.length > 0 ? ('blink:' + this.bHost) : 'blink';
  }
}
