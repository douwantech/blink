////////////////////////////////////////////////////////////////////////////////
//
// PadExec — 一次性 blinkd exec：连上 → 跑脚本 → 收集输出直到出现 marker / 连接关闭 / 超时。
// 同 macOS 版 BlinkdExec.run。ssh 机器经 blinkd 中转机再 ssh 过去跑（同手机版 execForTab）。
// 输出统一走 @TSB64@<b64>@TSB64E@ 包裹，躲开 PTY 对换行/控制字节的加工。
//
////////////////////////////////////////////////////////////////////////////////

import { BlinkdClient, BlinkdState } from 'tsvpn';
import { util, buffer } from '@kit.ArkTS';
import { BlinkStore, Machine } from './BlinkStores';

export interface Endpoint {
  host: string;
  port: number;
  token: string;
}

export class PadExec {
  /// 机器对应的 blinkd 端点（blinkd 机器用自己的；ssh 机器用中转机）。
  static endpointFor(store: BlinkStore, m: Machine | null): Endpoint | null {
    const ep = store.blinkdEndpoint(m);
    if (ep === null || ep.blinkdHost === undefined || ep.blinkdToken === undefined) {
      return null;
    }
    return { host: ep.blinkdHost, port: ep.blinkdPort !== undefined ? ep.blinkdPort : 7777, token: ep.blinkdToken };
  }

  /// 脚本按机器传输方式包一层：blinkd 机器 base64 解包直接跑；ssh 机器从中转机 ssh 过去跑。
  static wrapForMachine(m: Machine, script: string): string {
    const b64: string = buffer.from(script, 'utf-8').toString('base64');
    const unpack: string = 'echo ' + b64 + ' | base64 -d | bash';
    if (m.transport === 'blinkd') {
      return unpack;
    }
    return 'ssh -o BatchMode=yes -o ConnectTimeout=6 ' + m.user + '@' + m.host + ' -- ' + BlinkStore.shq(unpack);
  }

  /// 跑一次，返回原始输出（可能含 \r、PTY 回显）。
  static run(ep: Endpoint, cmd: string, timeoutMs: number, marker: string): Promise<string> {
    return new Promise<string>((resolve: (s: string) => void) => {
      let buf: string = '';
      let done: boolean = false;
      const dec = util.TextDecoder.create('utf-8');
      const client = new BlinkdClient();
      const finish = (): void => {
        if (done) {
          return;
        }
        done = true;
        client.close();
        resolve(buf);
      };
      client.onData = (bytes: Uint8Array) => {
        buf += dec.decodeToString(bytes, { stream: true });
        if (marker.length > 0 && buf.indexOf(marker) >= 0) {
          finish();
        }
      };
      client.onState = (st: BlinkdState) => {
        if (st === 'closed' || st === 'error') {
          finish();
        }
      };
      client.connect(ep.host, ep.port, ep.token, 24, 200, cmd);
      setTimeout(finish, timeoutMs);
    });
  }

  /// 取出 @TSB64@…@TSB64E@ 之间的 base64 并解码；没有包裹 / 坏数据返回 null。
  static decodeTsb64(raw: string): string | null {
    const i1: number = raw.indexOf('@TSB64@');
    const i2: number = raw.indexOf('@TSB64E@');
    if (i1 < 0 || i2 <= i1) {
      return null;
    }
    const b64s: string = raw.substring(i1 + 7, i2).replace(new RegExp('[^A-Za-z0-9+/=]', 'g'), '');
    if (b64s.length === 0) {
      return '';
    }
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(b64s);
      return util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (e) {
      return null;
    }
  }
}
