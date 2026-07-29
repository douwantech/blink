////////////////////////////////////////////////////////////////////////////////
//
// BlinkdClient — a HarmonyOS client for the Mac-side `blinkd` daemon (see
// ~/Codes/Jack/blink/mac-daemon/main.go). It speaks blinkd's raw framed TCP
// protocol over a plain socket. That socket runs in the app's own process, whose
// uid the per-app VPN routes, so it reaches a blinkd node on the tailnet (e.g.
// the Mac at 100.x:7777) — the same datapath proven by the SSH TCP test.
//
// Wire protocol (client->server, BigEndian) — mirrors the daemon:
//   0x01 | u16 len | token      auth, must be the first frame
//   0x04 | u16 len | cmdline    exec: command this connection runs (after auth,
//                               before the PTY starts; optional)
//   0x02 | u16 len | bytes      terminal input (keystrokes)
//   0x03 | u16 rows | u16 cols  window resize (fixed 4 bytes, no length prefix)
// server->client: a raw PTY byte stream, no framing.
//
////////////////////////////////////////////////////////////////////////////////

import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0BD1;
const TAG: string = 'blinkd';

const FRAME_AUTH: number = 0x01;
const FRAME_DATA: number = 0x02;
const FRAME_RESIZE: number = 0x03;
const FRAME_EXEC: number = 0x04;

export type BlinkdState = 'idle' | 'connecting' | 'connected' | 'closed' | 'error';

export class BlinkdClient {
  private tcp: socket.TCPSocket | null = null;
  private enc: util.TextEncoder = new util.TextEncoder();
  private authed: boolean = false;

  // The UI wires these up.
  public onData: (bytes: Uint8Array) => void = () => {};
  public onState: (s: BlinkdState, detail: string) => void = () => {};

  public isConnected(): boolean {
    return this.tcp !== null && this.authed;
  }

  // Connect, authenticate, size the tty, and start the shell (or run `cmd`).
  public connect(host: string, port: number, token: string,
                 rows: number, cols: number, cmd: string): void {
    this.onState('connecting', host + ':' + port);
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.authed = false;

    tcp.on('message', (v: socket.SocketMessageInfo) => {
      this.onData(new Uint8Array(v.message));
    });
    tcp.on('close', () => {
      this.authed = false;
      this.onState('closed', '连接已关闭');
    });
    tcp.on('error', (e: BusinessError) => {
      this.onState('error', JSON.stringify(e));
    });

    // OHOS TCPSocket requires bind() before connect().
    tcp.bind({ address: '0.0.0.0', port: 0 })
      .then(() => tcp.connect({ address: { address: host, port: port }, timeout: 8000 }))
      .then(() => this.sendFrame(FRAME_AUTH, this.enc.encodeInto(token)))          // 1. auth
      .then(() => this.sendResize(rows, cols))                                     // 2. size tty
      .then(() => {                                                                // 3. start shell
        const line: string = (cmd.length > 0) ? cmd : 'exec /bin/zsh -il';
        return this.sendFrame(FRAME_EXEC, this.enc.encodeInto(line));
      })
      .then(() => {
        this.authed = true;
        this.onState('connected', '已连上 blinkd');
        hilog.info(DOMAIN, TAG, 'connected %{public}s:%{public}d', host, port);
      })
      .catch((e: Object) => {
        this.onState('error', JSON.stringify(e));
        hilog.error(DOMAIN, TAG, 'connect: %{public}s', JSON.stringify(e));
      });
  }

  public sendInput(text: string): void {
    if (!this.authed) {
      return;
    }
    this.sendFrame(FRAME_DATA, this.enc.encodeInto(text));
  }

  public sendBytes(bytes: Uint8Array): void {
    if (!this.authed) {
      return;
    }
    this.sendFrame(FRAME_DATA, bytes);
  }

  // 0x03 | u16 rows | u16 cols — fixed 4 payload bytes, no length prefix.
  public sendResize(rows: number, cols: number): Promise<void> {
    const b: Uint8Array = new Uint8Array(5);
    b[0] = FRAME_RESIZE;
    b[1] = (rows >> 8) & 0xff;
    b[2] = rows & 0xff;
    b[3] = (cols >> 8) & 0xff;
    b[4] = cols & 0xff;
    return this.rawSend(b);
  }

  public close(): void {
    const tcp: socket.TCPSocket | null = this.tcp;
    this.tcp = null;
    this.authed = false;
    if (tcp !== null) {
      tcp.close().catch((e: Object) => {
        hilog.warn(DOMAIN, TAG, 'close: %{public}s', JSON.stringify(e));
      });
    }
  }

  // type | u16 len | payload
  private sendFrame(type: number, payload: Uint8Array): Promise<void> {
    const n: number = payload.length;
    const b: Uint8Array = new Uint8Array(3 + n);
    b[0] = type;
    b[1] = (n >> 8) & 0xff;
    b[2] = n & 0xff;
    b.set(payload, 3);
    return this.rawSend(b);
  }

  private rawSend(b: Uint8Array): Promise<void> {
    const tcp: socket.TCPSocket | null = this.tcp;
    if (tcp === null) {
      return Promise.reject(new Error('not connected'));
    }
    // b is a freshly allocated, tightly-sized array, so b.buffer is exactly it.
    return tcp.send({ data: b.buffer });
  }
}
