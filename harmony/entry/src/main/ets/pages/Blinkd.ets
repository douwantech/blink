////////////////////////////////////////////////////////////////////////////////
//
// Blinkd — a basic in-app terminal that talks to the Mac-side blinkd daemon over
// the tailnet (via the per-app VPN datapath). Enter the blinkd node's host, port
// and token, connect, and you get a shell on that machine. Line commands and the
// common control keys work; full-screen TUIs need a real VT parser (future work).
//
////////////////////////////////////////////////////////////////////////////////

import { router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BlinkdClient, BlinkdState, Terminal } from 'tsvpn';

const PREF: string = 'blinkd_prefs';

@Entry
@Component
struct Blinkd {
  @State host: string = '';
  @State port: string = '7777';
  @State token: string = '';
  @State execCmd: string = '';        // optional; empty → login zsh
  @State display: string = '';
  @State status: string = '未连接';
  @State connected: boolean = false;
  @State cmdLine: string = '';
  @State cols: number = 52;
  @State rows: number = 28;

  private client: BlinkdClient = new BlinkdClient();
  private term: Terminal = new Terminal();
  private scroller: Scroller = new Scroller();
  private store: preferences.Preferences | null = null;

  aboutToAppear(): void {
    this.client.onData = (bytes: Uint8Array) => {
      this.display = this.term.feed(bytes);
      this.scroller.scrollEdge(Edge.Bottom);
    };
    this.client.onState = (s: BlinkdState, detail: string) => {
      this.connected = (s === 'connected');
      this.status = this.stateLabel(s) + (detail.length > 0 ? ' · ' + detail : '');
    };
    this.loadPrefs();
  }

  aboutToDisappear(): void {
    this.client.close();
  }

  private stateLabel(s: BlinkdState): string {
    if (s === 'connecting') {
      return '连接中';
    } else if (s === 'connected') {
      return '已连接';
    } else if (s === 'closed') {
      return '已断开';
    } else if (s === 'error') {
      return '错误';
    }
    return '未连接';
  }

  private async loadPrefs(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.store = await preferences.getPreferences(ctx, PREF);
      this.host = await this.store.get('host', '') as string;
      this.port = await this.store.get('port', '7777') as string;
      this.token = await this.store.get('token', '') as string;
      this.execCmd = await this.store.get('exec', '') as string;
    } catch (e) {
      // first run / no store — ignore
    }
  }

  private async savePrefs(): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.put('host', this.host);
      await this.store.put('port', this.port);
      await this.store.put('token', this.token);
      await this.store.put('exec', this.execCmd);
      await this.store.flush();
    } catch (e) {
      // ignore
    }
  }

  private doConnect(): void {
    const p: number = parseInt(this.port);
    if (this.host.trim().length === 0 || !p) {
      this.status = '需要 host 和 port';
      return;
    }
    if (this.token.trim().length === 0) {
      this.status = '需要 token';
      return;
    }
    this.term.clear();
    this.display = '';
    this.savePrefs();
    this.client.connect(this.host.trim(), p, this.token.trim(), this.rows, this.cols, this.execCmd.trim());
  }

  private doDisconnect(): void {
    this.client.close();
    this.connected = false;
    this.status = '已断开';
  }

  private sendLine(): void {
    if (!this.connected) {
      return;
    }
    this.client.sendInput(this.cmdLine + '\n');
    this.cmdLine = '';
  }

  private sendKey(bytes: number[]): void {
    if (!this.connected) {
      return;
    }
    this.client.sendBytes(new Uint8Array(bytes));
  }

  build() {
    Column() {
      // top bar
      Row() {
        Button('‹ 返回')
          .fontSize(13)
          .backgroundColor(Color.Transparent)
          .fontColor('#3478F6')
          .onClick(() => router.back())
        Blank()
        Text('blinkd 终端')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text(this.connected ? '●' : '○')
          .fontSize(16)
          .fontColor(this.connected ? '#34C759' : '#999999')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 6 })

      // connection form (hidden while connected to free up room)
      if (!this.connected) {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            TextInput({ text: this.host, placeholder: 'host 例 100.x.y.z' })
              .layoutWeight(2)
              .fontSize(12)
              .onChange((v: string) => { this.host = v; })
            TextInput({ text: this.port, placeholder: 'port' })
              .layoutWeight(1)
              .fontSize(12)
              .type(InputType.Number)
              .onChange((v: string) => { this.port = v; })
          }
          TextInput({ text: this.token, placeholder: 'token' })
            .fontSize(12)
            .type(InputType.Password)
            .onChange((v: string) => { this.token = v; })
          TextInput({ text: this.execCmd, placeholder: '启动命令(可空=登录 zsh；填 tmux new -A -s x 可持久)' })
            .fontSize(12)
            .onChange((v: string) => { this.execCmd = v; })
        }
        .width('94%')
        .margin({ bottom: 4 })
      }

      Text(this.status)
        .fontSize(11)
        .fontColor('#888888')
        .width('94%')
        .textAlign(TextAlign.Start)
        .margin({ top: 2, bottom: 2 })

      // terminal output
      Scroll(this.scroller) {
        Text(this.display)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor('#D0D0D0')
          .textAlign(TextAlign.Start)
          .width('100%')
      }
      .backgroundColor('#101010')
      .width('96%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .padding(8)
      .borderRadius(6)
      .onAreaChange((_o: Area, n: Area) => {
        const w: number = n.width as number;
        const h: number = n.height as number;
        const c: number = Math.max(20, Math.floor(w / (12 * 0.6)));
        const r: number = Math.max(6, Math.floor(h / (12 * 1.3)));
        if (c !== this.cols || r !== this.rows) {
          this.cols = c;
          this.rows = r;
          if (this.connected) {
            this.client.sendResize(r, c);
          }
        }
      })

      // control keys
      if (this.connected) {
        Row({ space: 5 }) {
          Button('Ctrl-C').fontSize(11).height(30).layoutWeight(1)
            .backgroundColor('#333333').fontColor('#EEEEEE')
            .onClick(() => this.sendKey([0x03]))
          Button('Tab').fontSize(11).height(30).layoutWeight(1)
            .backgroundColor('#333333').fontColor('#EEEEEE')
            .onClick(() => this.sendKey([0x09]))
          Button('Esc').fontSize(11).height(30).layoutWeight(1)
            .backgroundColor('#333333').fontColor('#EEEEEE')
            .onClick(() => this.sendKey([0x1b]))
          Button('↑').fontSize(11).height(30).layoutWeight(1)
            .backgroundColor('#333333').fontColor('#EEEEEE')
            .onClick(() => this.sendKey([0x1b, 0x5b, 0x41]))
          Button('↓').fontSize(11).height(30).layoutWeight(1)
            .backgroundColor('#333333').fontColor('#EEEEEE')
            .onClick(() => this.sendKey([0x1b, 0x5b, 0x42]))
          Button('←').fontSize(11).height(30).layoutWeight(1)
            .backgroundColor('#333333').fontColor('#EEEEEE')
            .onClick(() => this.sendKey([0x1b, 0x5b, 0x44]))
          Button('→').fontSize(11).height(30).layoutWeight(1)
            .backgroundColor('#333333').fontColor('#EEEEEE')
            .onClick(() => this.sendKey([0x1b, 0x5b, 0x43]))
        }
        .width('96%')
        .margin({ top: 6 })
      }

      // bottom: command input (connected) or connect button (disconnected)
      Row({ space: 6 }) {
        if (this.connected) {
          TextInput({ text: this.cmdLine, placeholder: '输入命令，回车发送' })
            .layoutWeight(1)
            .fontSize(13)
            .onChange((v: string) => { this.cmdLine = v; })
            .onSubmit(() => this.sendLine())
          Button('发送')
            .fontSize(13)
            .height(38)
            .onClick(() => this.sendLine())
          Button('断开')
            .fontSize(13)
            .height(38)
            .backgroundColor('#FF3B30')
            .onClick(() => this.doDisconnect())
        } else {
          Button('连接 blinkd')
            .fontSize(15)
            .height(44)
            .width('70%')
            .backgroundColor('#3478F6')
            .onClick(() => this.doConnect())
        }
      }
      .width('96%')
      .margin({ top: 6, bottom: 10 })
    }
    .width('100%')
    .height('100%')
  }
}
