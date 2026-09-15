////////////////////////////////////////////////////////////////////////////////
//
// CfgSync — 配置双向同步（iOS ⇄ Mac 文件 ⇄ 鸿蒙），从手机版 BlinkTerminal.ets 的
// pushSyncConfig / pullSyncConfig / ensureCfgWatcher / finishCfgPull 原样搬成独立类。
//
// 两端都把 seed 形状的配置推到各机器 ~/.blink/sync/blink_config.json（带 origin），
// 这里经 blinkd 一次性 exec 拉回，origin 不是自己且 updatedAt 更新才应用。
// 拉取节流 5 分钟；watcher 盯 mtime 秒级跟随；回前台立即拉一次。
//
// 2026-08-10 事故的三道闸照搬：
// ① 首次成功拉取（或确认文件不存在）之前一律不推；
// ② 推送 stamp 用「本地真实改动时刻」而不是推送时刻；
// ③ 远端文件 updatedAt 更新时推送脚本原地放弃（python3 比对）。
//
////////////////////////////////////////////////////////////////////////////////

import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { BlinkdClient, BlinkdState } from 'tsvpn';
import { BlinkStore, SeedConfig } from './BlinkStores';

const DOMAIN: number = 0x0B12;
const TAG: string = 'PadCfgSync';

export class CfgSync {
  private store: BlinkStore;
  private isRunning: () => boolean;
  private onApply: (cfg: SeedConfig, stamp: number) => Promise<void>;
  uiPrefs: preferences.Preferences | null = null;

  private b64: util.Base64Helper = new util.Base64Helper();
  private lastCfgPull: number = 0;
  private cfgPullBusy: boolean = false;
  private cfgWatcher: BlinkdClient | null = null;
  private cfgWatchBuf: string = '';
  private lastWatchMtime: string = '';
  private lastWatchTry: number = 0;
  private cfgPushDirty: boolean = false;
  private cfgPushTimer: number = -1;
  private cfgPulledOnce: boolean = false;
  private cfgDataStamp: number = 0;

  constructor(store: BlinkStore, isRunning: () => boolean,
              onApply: (cfg: SeedConfig, stamp: number) => Promise<void>) {
    this.store = store;
    this.isRunning = isRunning;
    this.onApply = onApply;
  }

  /// 本地配置变了（store save* 落盘触发）：3s 合并窗口后推送
  notifyChanged(): void {
    this.cfgPushDirty = true;
    this.cfgDataStamp = Date.now() / 1000;
    if (this.cfgPushTimer >= 0) {
      return;
    }
    this.cfgPushTimer = setTimeout(() => {
      this.cfgPushTimer = -1;
      this.push();
    }, 3000);
  }

  /// VPN Running 时每轮轮询调一次：拉（节流）、保 watcher、补推 dirty。
  tick(): void {
    this.pull();
    this.ensureWatcher();
    this.push();
  }

  /// 回前台：清零节流立即拉
  forcePull(): void {
    this.lastCfgPull = 0;
    this.pull();
  }

  close(): void {
    if (this.cfgWatcher !== null) {
      this.cfgWatcher.close();
      this.cfgWatcher = null;
    }
    if (this.cfgPushTimer >= 0) {
      clearTimeout(this.cfgPushTimer);
      this.cfgPushTimer = -1;
    }
  }

  /// VPN 重建后旧 watcher 成了死链，丢掉让下一轮重建
  dropWatcher(): void {
    if (this.cfgWatcher !== null) {
      this.cfgWatcher.close();
      this.cfgWatcher = null;
    }
    this.lastWatchTry = 0;
  }

  private firstEndpoint(): string[] | null {
    for (let i = 0; i < this.store.machines.length; i++) {
      const ep = this.store.blinkdEndpoint(this.store.machines[i]);
      if (ep !== null && ep.blinkdHost !== undefined && ep.blinkdToken !== undefined) {
        const port: number = ep.blinkdPort !== undefined ? ep.blinkdPort : 7777;
        return [ep.blinkdHost, port.toString(), ep.blinkdToken];
      }
    }
    return null;
  }

  push(): void {
    if (!this.cfgPushDirty || !this.isRunning()) {
      return;
    }
    if (!this.cfgPulledOnce) {
      return;   // 还没见过远端文件就不许推（闸 ①），dirty 留着首拉后补推
    }
    this.cfgPushDirty = false;
    const stamp: number = this.cfgDataStamp > 0 ? this.cfgDataStamp : Date.now() / 1000;
    const enc = new util.TextEncoder();
    let b64: string = this.b64.encodeToStringSync(enc.encodeInto(JSON.stringify(this.store.exportSync(stamp, false))));
    if (b64.length > 60000) {
      // blinkd 帧长上限 u16=64KB：超了砍掉学习类大头
      b64 = this.b64.encodeToStringSync(enc.encodeInto(JSON.stringify(this.store.exportSync(stamp, true))));
    }
    if (b64.length === 0 || b64.length > 60000) {
      return;
    }
    const guard: string = 'python3 -c "import json,os;s=os.path.expanduser(\'~/.blink/sync/\');' +
      'cur=json.load(open(s+\'blink_config.json\')).get(\'updatedAt\',0);' +
      'new=json.load(open(s+\'.cfg.tmp\')).get(\'updatedAt\',0);exit(0 if cur>new else 1)"';
    const script: string = "mkdir -p ~/.blink/sync && printf '%s' '" + b64 +
      "' | openssl base64 -d -A > ~/.blink/sync/.cfg.tmp && if " + guard +
      "; then rm -f ~/.blink/sync/.cfg.tmp; else mv ~/.blink/sync/.cfg.tmp ~/.blink/sync/blink_config.json; fi";
    let sent: number = 0;
    for (let i = 0; i < this.store.machines.length; i++) {
      const ep = this.store.blinkdEndpoint(this.store.machines[i]);
      if (ep === null || ep.blinkdHost === undefined || ep.blinkdToken === undefined) {
        continue;
      }
      const client = new BlinkdClient();
      client.connect(ep.blinkdHost, ep.blinkdPort !== undefined ? ep.blinkdPort : 7777,
        ep.blinkdToken, 24, 80, script);
      setTimeout(() => {
        client.close();
      }, 8000);
      sent++;
    }
    if (sent > 0) {
      const p = this.uiPrefs;
      if (p !== null) {
        p.put('cfgSyncStamp', stamp).then((): Promise<void> => p.flush()).catch(() => {});
      }
      hilog.info(DOMAIN, TAG, 'cfg push to %{public}d machines (%{public}d b64)', sent, b64.length);
    }
  }

  pull(): void {
    if (this.cfgPullBusy || !this.isRunning()) {
      return;
    }
    if (Date.now() - this.lastCfgPull < 300000) {
      return;
    }
    const ep: string[] | null = this.firstEndpoint();
    if (ep === null) {
      return;
    }
    this.lastCfgPull = Date.now();
    this.cfgPullBusy = true;
    let buf: string = '';
    const dec = util.TextDecoder.create('utf-8');
    const client = new BlinkdClient();
    client.onData = (bytes: Uint8Array) => {
      buf += dec.decodeToString(bytes, { stream: true });
    };
    client.onState = (st: BlinkdState) => {
      if (st === 'closed' || st === 'error') {
        this.finishPull(buf);
      }
    };
    client.connect(ep[0], Number.parseInt(ep[1], 10), ep[2], 24, 80,
      '[ -f ~/.blink/sync/blink_config.json ] && cat ~/.blink/sync/blink_config.json | base64 || printf @NOFILE@');
    setTimeout(() => {
      this.finishPull(buf);
      client.close();
    }, 15000);
  }

  private ensureWatcher(): void {
    if (this.cfgWatcher !== null || !this.isRunning()) {
      return;
    }
    if (Date.now() - this.lastWatchTry < 10000) {
      return;
    }
    const ep: string[] | null = this.firstEndpoint();
    if (ep === null) {
      return;
    }
    this.lastWatchTry = Date.now();
    const client = new BlinkdClient();
    this.cfgWatcher = client;
    this.cfgWatchBuf = '';
    const dec = util.TextDecoder.create('utf-8');
    client.onData = (bytes: Uint8Array) => {
      this.cfgWatchBuf += dec.decodeToString(bytes, { stream: true });
      const lines: string[] = this.cfgWatchBuf.split('\n');
      this.cfgWatchBuf = lines[lines.length - 1];
      for (let i = 0; i < lines.length - 1; i++) {
        const at: number = lines[i].indexOf('CFGCHANGED:');
        if (at < 0) {
          continue;
        }
        const mtime: string = lines[i].substring(at + 11).trim();
        if (mtime.length > 0 && mtime !== this.lastWatchMtime) {
          this.lastWatchMtime = mtime;
          this.lastCfgPull = 0;
          this.pull();
        }
      }
    };
    client.onState = (st: BlinkdState) => {
      if (st === 'closed' || st === 'error') {
        if (this.cfgWatcher === client) {
          this.cfgWatcher = null;
        }
      }
    };
    client.connect(ep[0], Number.parseInt(ep[1], 10), ep[2], 24, 80,
      'last=""; while true; do cur=$(stat -f %m ~/.blink/sync/blink_config.json 2>/dev/null); ' +
      'if [ "$cur" != "$last" ]; then last="$cur"; echo "CFGCHANGED:$cur"; fi; sleep 2; done');
  }

  private finishPull(buf: string): void {
    if (!this.cfgPullBusy) {
      return;
    }
    this.cfgPullBusy = false;
    if (buf.indexOf('@NOFILE@') >= 0) {
      this.cfgPulledOnce = true;   // 远端确认没有配置文件：首推安全
      return;
    }
    const b64: string = buf.replace(new RegExp('[^A-Za-z0-9+/=]', 'g'), '');
    if (b64.length < 16) {
      // 冷启动抢跑（tun 还没真起来）：15s 后再试，别被 5 分钟节流堵死
      this.lastCfgPull = Date.now() - 285000;
      return;
    }
    try {
      const bytes: Uint8Array = this.b64.decodeSync(b64);
      const cfg: SeedConfig = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(bytes)) as SeedConfig;
      this.cfgPulledOnce = true;
      if (cfg.origin === 'harmony-pad') {
        return;   // 自己写的文件，不回声采纳（手机版鸿蒙写的 origin=harmony 照常采纳）
      }
      const stamp: number = cfg.updatedAt !== undefined ? cfg.updatedAt : 0;
      const last: number = this.uiPrefs !== null ? this.uiPrefs.getSync('cfgSyncStamp', 0) as number : 0;
      if (stamp <= last || cfg.machines === undefined || cfg.machines.length === 0) {
        return;
      }
      this.onApply(cfg, stamp).then((): void => {
        const p = this.uiPrefs;
        if (p !== null) {
          p.put('cfgSyncStamp', stamp).then((): Promise<void> => p.flush()).catch(() => {});
        }
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cfg sync parse: %{public}s', `${e}`);
    }
  }
}
