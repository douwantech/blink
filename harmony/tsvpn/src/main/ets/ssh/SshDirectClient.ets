import { BlinkdState } from '../blinkd/BlinkdClient';
import { SshSession, SshTarget } from './SshSession';

// Same terminal-facing contract as BlinkdClient; the transport is an SSH PTY.
export class SshDirectClient {
  public onData: (bytes: Uint8Array) => void = () => {};
  public onState: (state: BlinkdState, detail: string) => void = () => {};
  public onHostKey: (host: string, port: number, key: Uint8Array, fingerprint: string) => Promise<boolean> =
    (_host: string, _port: number, _key: Uint8Array, _fingerprint: string): Promise<boolean> => Promise.resolve(false);

  private session: SshSession | null = null;
  private connected: boolean = false;

  connect(host: string, port: number, user: string, rows: number, cols: number, command: string): void {
    this.close();
    const target = new SshTarget();
    target.host = host;
    target.port = port;
    target.username = user;
    target.command = command;
    const session = new SshSession();
    this.session = session;
    this.connected = false;
    session.cols = cols;
    session.rows = rows;
    session.onDataBytes = (data: Uint8Array): void => {
      if (this.session === session) {
        this.onData(data);
      }
    };
    session.onReady = (): void => {
      if (this.session === session) {
        this.connected = true;
        this.onState('connected', 'SSH · ' + host);
      }
    };
    session.onClosed = (reason: string): void => {
      if (this.session === session) {
        this.connected = false;
        this.session = null;
        this.onState(reason === '已断开' ? 'closed' : 'error', reason);
      }
    };
    session.onHostKey = (key: Uint8Array, fp: string): Promise<boolean> =>
      this.onHostKey(host, port, key, fp);
    this.onState('connecting', 'SSH · ' + host + ':' + port);
    session.connect(target);
  }

  isConnected(): boolean {
    return this.connected;
  }

  sendInput(text: string): void {
    const session = this.session;
    if (session !== null && this.connected) {
      session.send(text);
    }
  }

  sendBytes(bytes: Uint8Array): void {
    const session = this.session;
    if (session !== null && this.connected) {
      session.sendBytes(bytes);
    }
  }

  sendResize(rows: number, cols: number): Promise<void> {
    const session = this.session;
    if (session !== null) {
      session.resize(cols, rows);
    }
    return Promise.resolve();
  }

  close(): void {
    const session = this.session;
    this.session = null;
    this.connected = false;
    if (session !== null) {
      session.close();
    }
  }
}
