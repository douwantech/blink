////////////////////////////////////////////////////////////////////////////////
//
// SessionConn / ConnPool — one live blinkd connection per open tab, mirroring
// iOS where every tab is its own MCPSession kept alive in SessionRegistry.
// Switching tabs never reconnects; a connection only redials after it drops
// (with the same 3→6→12→24→30s backoff the single-session build used, reset
// after a session that held >10s).
//
////////////////////////////////////////////////////////////////////////////////

import { BlinkdClient, BlinkdState } from 'tsvpn';

export type ConnUiState = 'idle' | 'connecting' | 'connected' | 'closed' | 'error';

export class SessionConn {
  tabId: string;
  client: BlinkdClient = new BlinkdClient();
  state: ConnUiState = 'idle';
  failCount: number = 0;
  cooldownUntil: number = 0;
  connectedAt: number = 0;
  unread: boolean = false;       // output arrived while another tab was active
  everConnected: boolean = false;
  lastNote: string = '';         // 去重：同一条连接状态行不重复刷（轮询每 1.5s 会重进 attach）

  constructor(tabId: string) {
    this.tabId = tabId;
  }
}

export class ConnPool {
  private conns: Map<string, SessionConn> = new Map();

  get(tabId: string): SessionConn | null {
    const c = this.conns.get(tabId);
    return c !== undefined ? c : null;
  }

  getOrCreate(tabId: string): SessionConn {
    let c = this.conns.get(tabId);
    if (c === undefined) {
      c = new SessionConn(tabId);
      this.conns.set(tabId, c);
    }
    return c;
  }

  remove(tabId: string): void {
    const c = this.conns.get(tabId);
    if (c !== undefined) {
      c.client.close();
      this.conns.delete(tabId);
    }
  }

  all(): SessionConn[] {
    const out: SessionConn[] = [];
    this.conns.forEach((c: SessionConn) => {
      out.push(c);
    });
    return out;
  }

  closeAll(): void {
    this.conns.forEach((c: SessionConn) => {
      c.client.close();
    });
    this.conns.clear();
  }
}
