import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { vpnExtension, socket } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { webview } from '@kit.ArkWeb';
import { router } from '@kit.ArkUI';
import { StatusStore, TailscaleCore } from 'tsvpn';

const DOMAIN = 0x2020;
const TAG = 'TailscaleUI';
const BUNDLE = 'com.douwantech.blink';

@Entry
@Component
struct Index {
  @State connected: boolean = false;
  @State statusText: string = 'Disconnected';
  @State loginUrl: string = '';
  @State nodeIP: string = '';
  @State coreVersion: string = '';
  @State authKey: string = '';        // tskey-auth-… ; persisted; passed to the core for non-interactive login
  @State hostname: string = 'harmony';
  // In-app WebView to test reaching a peer's web service over the tunnel, free of
  // the system browser's onboarding / DoH / IPv6 quirks. Our bundle is in the
  // VPN's trustedApplications, so this WebView's traffic routes through the tun.
  @State webUrl: string = '';
  @State showWeb: boolean = false;
  private webController: webview.WebviewController = new webview.WebviewController();
  // Native TCP reachability test (SSH/blinkd/etc.). Runs in the app's own
  // process/uid — which the VPN routes — so unlike a WebView it isn't stuck in the
  // ArkWeb render sandbox. Proves the phone can open a raw connection to a peer.
  @State tcpHost: string = '';        // host:port, e.g. 100.x.y.z:22
  @State tcpResult: string = '';
  private timer: number = -1;
  private prefs: preferences.Preferences | null = null;

  // Safe self-test: loads the Go core (.so) and runs it — no VPN, no traffic.
  // If coreVersion shows a tailscale version, the Go/gVisor stack is alive on-device.
  aboutToAppear(): void {
    try {
      this.coreVersion = TailscaleCore.version();
      hilog.info(DOMAIN, TAG, 'Go core loaded OK, tailscale version: %{public}s', this.coreVersion);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'core self-test FAILED: %{public}s', `${e}`);
    }
    this.loadPrefs();
  }

  // Persist the auth key + hostname across launches so you set them once.
  private async loadPrefs(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const p = await preferences.getPreferences(ctx, 'ts_prefs');
      this.prefs = p;
      this.authKey = await p.get('authKey', this.authKey) as string;
      this.hostname = await p.get('hostname', this.hostname) as string;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadPrefs: %{public}s', `${e}`);
    }
  }

  private savePref(key: string, value: string): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    p.put(key, value).then(() => {
      p.flush();
    }).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'savePref: %{public}s', JSON.stringify(e));
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
        controlURL: '',        // '' = https://controlplane.tailscale.com
        authKey: this.authKey, // tskey-auth-… from the field below; '' = interactive login
      },
    };
  }

  // Starts the VpnExtensionAbility; the system shows the VPN consent dialog.
  private connect(): void {
    vpnExtension.startVpnExtensionAbility(this.buildWant()).then(() => {
      this.connected = true;
      this.statusText = 'Starting…';
      this.startPolling();
      this.startKeepAlive();
    }).catch((e: Object) => {
      this.statusText = 'start failed: ' + JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'startVpnExtensionAbility: %{public}s', JSON.stringify(e));
    });
  }

  // Continuous task on THIS (main UIAbility) process. The VpnExtensionAbility's
  // lifetime is anchored to the app process that started it, so without this the
  // system freezes/reaps us a few seconds after we leave the foreground and stops
  // the VPN. startBackgroundRunning must run on the UIAbility (not the extension —
  // that throws 401). A WantAgent brings us back to the foreground if the ongoing
  // notification is tapped.
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
      hilog.info(DOMAIN, TAG, 'keep-alive continuous task started');
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

  private disconnect(): void {
    vpnExtension.stopVpnExtensionAbility(this.buildWant()).catch((e: Object) => {
      hilog.error(DOMAIN, TAG, 'stopVpnExtensionAbility: %{public}s', JSON.stringify(e));
    });
    this.stopKeepAlive();
    this.connected = false;
    this.statusText = 'Disconnected';
    this.loginUrl = '';
    this.nodeIP = '';
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  // The tunnel runs in a separate process; read its mirrored status file.
  private startPolling(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
    }
    this.timer = setInterval(() => {
      const s: string = StatusStore.read(this.filesDir());
      try {
        const j = JSON.parse(s) as Record<string, Object>;
        const state = j['backendState'] as string;
        this.statusText = state ? state : 'Starting…';
        this.loginUrl = (j['authURL'] as string) ?? '';
        const ips = j['tailscaleIPs'] as string[];
        this.nodeIP = (ips && ips.length > 0) ? ips[0] : '';
      } catch (e) {
        // status file not written yet
      }
    }, 1500);
  }

  private copyLogin(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.loginUrl);
      pasteboard.getSystemPasteboard().setData(data);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'copyLogin: %{public}s', JSON.stringify(e));
    }
  }

  // Open a raw TCP connection to a peer's service (e.g. its SSH port). This runs
  // in the app's own process, whose uid the VPN routes, so it exercises the real
  // datapath end-to-end. A resolved connect() means the phone reached the peer;
  // for SSH the peer also sends a banner we surface.
  private connectTcp(): void {
    const parts = this.tcpHost.trim().split(':');
    if (parts.length < 2) {
      this.tcpResult = '需要 host:port';
      return;
    }
    const ip = parts[0];
    const port = parseInt(parts[1]);
    this.tcpResult = '连接中 ' + this.tcpHost + ' …';
    const tcp = socket.constructTCPSocketInstance();
    tcp.on('message', (v: socket.SocketMessageInfo) => {
      const bytes = new Uint8Array(v.message);
      let s = '';
      for (let i = 0; i < bytes.length && i < 120; i++) {
        const c = bytes[i];
        s += (c >= 32 && c < 127) ? String.fromCharCode(c) : '.';
      }
      this.tcpResult = '✓ 收到 ' + bytes.length + 'B: ' + s;
    });
    // OHOS TCPSocket requires bind() before connect().
    tcp.bind({ address: '0.0.0.0', port: 0 })
      .then(() => tcp.connect({ address: { address: ip, port: port }, timeout: 8000 }))
      .then(() => {
        this.tcpResult = '✓ TCP 已连上 ' + this.tcpHost + '，等数据…';
        hilog.info(DOMAIN, TAG, 'tcp connected %{public}s', this.tcpHost);
      })
      .catch((e: Object) => {
        this.tcpResult = '✗ 失败: ' + JSON.stringify(e);
        hilog.error(DOMAIN, TAG, 'tcp connect: %{public}s', JSON.stringify(e));
      });
  }

  build() {
    Column({ space: 16 }) {
      Text('Tailscale')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
      Text('for HarmonyOS Next')
        .fontSize(14)
        .fontColor(Color.Gray)

      if (this.coreVersion.length > 0) {
        Text('core ✓ ' + this.coreVersion)
          .fontSize(11)
          .fontColor('#34C759')
      }

      Text(this.statusText)
        .fontSize(16)
        .margin({ top: 12 })

      if (this.nodeIP.length > 0) {
        Text(this.nodeIP)
          .fontSize(14)
          .fontColor('#34C759')
      }

      if (this.loginUrl.length > 0) {
        Column({ space: 6 }) {
          Text('Tap to copy login URL, open in a browser to authenticate:')
            .fontSize(12)
            .fontColor(Color.Gray)
          Text(this.loginUrl)
            .fontSize(13)
            .fontColor('#3478F6')
            .maxLines(3)
            .onClick(() => this.copyLogin())
        }
        .padding(12)
        .borderRadius(10)
        .backgroundColor('#F2F2F7')
        .width('90%')
      }

      if (!this.connected) {
        Column({ space: 8 }) {
          Text('Settings')
            .fontSize(12)
            .fontColor(Color.Gray)
            .width('90%')
            .textAlign(TextAlign.Start)
          TextInput({ text: this.hostname, placeholder: 'hostname (e.g. harmony)' })
            .fontSize(13)
            .width('90%')
            .onChange((v: string) => {
              this.hostname = v;
              this.savePref('hostname', v);
            })
          TextInput({ text: this.authKey, placeholder: 'auth key: tskey-auth-… (optional)' })
            .fontSize(13)
            .width('90%')
            .type(InputType.Password)
            .onChange((v: string) => {
              this.authKey = v;
              this.savePref('authKey', v);
            })
          Text(this.authKey.length > 0
            ? 'Auth key set — will log in without a browser'
            : 'No auth key — Connect shows a login URL to open in a browser')
            .fontSize(11)
            .fontColor(Color.Gray)
            .width('90%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 4 })
      }

      Button(this.connected ? 'Disconnect' : 'Connect')
        .width('80%')
        .height(48)
        .backgroundColor(this.connected ? '#FF3B30' : '#3478F6')
        .onClick(() => {
          if (this.connected) {
            this.disconnect();
          } else {
            this.connect();
          }
        })

      // Native TCP reachability test (SSH / blinkd / any peer port).
      Row({ space: 6 }) {
        TextInput({ text: this.tcpHost, placeholder: 'host:port  例 100.x.y.z:22' })
          .layoutWeight(1)
          .fontSize(11)
          .onChange((v: string) => { this.tcpHost = v; })
        Button('连TCP')
          .fontSize(13)
          .height(36)
          .onClick(() => this.connectTcp())
      }
      .width('94%')
      .margin({ top: 12 })

      if (this.tcpResult.length > 0) {
        Text(this.tcpResult)
          .fontSize(11)
          .fontColor(this.tcpResult.startsWith('✓') ? '#34C759' : '#FF3B30')
          .width('94%')
          .textAlign(TextAlign.Start)
          .margin({ top: 4 })
      }

      // In-app blinkd terminal: SSH-free shell to a tailnet peer running blinkd.
      Button('打开 blinkd 终端')
        .fontSize(13)
        .height(38)
        .width('94%')
        .backgroundColor('#1C1C1E')
        .fontColor('#FFFFFF')
        .margin({ top: 8 })
        .onClick(() => router.pushUrl({ url: 'pages/Blinkd' }))

      // In-app browser test: load a peer URL through the tunnel.
      Row({ space: 6 }) {
        TextInput({ text: this.webUrl, placeholder: 'https://…ts.net/' })
          .layoutWeight(1)
          .fontSize(11)
          .onChange((v: string) => { this.webUrl = v; })
        Button('打开')
          .fontSize(13)
          .height(36)
          .onClick(() => {
            if (this.showWeb) {
              try {
                this.webController.loadUrl(this.webUrl);
              } catch (e) {
                hilog.error(DOMAIN, TAG, 'loadUrl: %{public}s', `${e}`);
              }
            } else {
              this.showWeb = true; // mounts the Web with src=webUrl
            }
          })
      }
      .width('94%')
      .margin({ top: 12 })

      if (this.showWeb) {
        Web({ src: this.webUrl, controller: this.webController })
          .width('100%')
          .layoutWeight(1)
          .domStorageAccess(true)
          .mixedMode(MixedMode.All)
          .onErrorReceive((e) => {
            if (e) {
              hilog.error(DOMAIN, TAG, 'web err code=%{public}d %{public}s',
                e.error.getErrorCode(), e.error.getErrorInfo());
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(this.showWeb ? FlexAlign.Start : FlexAlign.Center)
    .padding(this.showWeb ? 8 : 24)
  }
}
