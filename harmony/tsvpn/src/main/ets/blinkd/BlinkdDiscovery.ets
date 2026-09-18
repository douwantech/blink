////////////////////////////////////////////////////////////////////////////////
//
// BlinkdDiscovery — 局域网 mDNS/Bonjour 发现同网的 Mac blinkd，供 LAN 直连优先用。
//
// Mac 上的 blinkd 在局域网广播 _blinkd._tcp，TXT 带 ts=<tailscaleIP> + lan=<局域网IP>。
// 这里常驻 browse：把每条记录按 ts= 对上「已配置的机器」（机器的 blinkdHost 就是那个
// Tailscale IP），拿到它当前的 lan= 直连地址。同网时 BlinkdClient 优先直连 LAN（更快、
// 省电、不占 Tailscale/tun），发现不到就回落 Tailscale host。
//
// 注：mDNS 组播（224.0.0.251）不在 VPN 分流的 100.64/10 内，走 wlan0，不受 tun 影响。
//
////////////////////////////////////////////////////////////////////////////////

import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0BD1;
const TAG: string = 'blinkd-mdns';
const SERVICE_TYPE: string = '_blinkd._tcp';

export class BlinkdDiscovery {
  static readonly instance: BlinkdDiscovery = new BlinkdDiscovery();

  private lanByTs: Map<string, string> = new Map();   // tailscaleIP → 当前 LAN IP
  private ds: mdns.DiscoveryService | null = null;
  private ctx: common.Context | null = null;

  // app 启动时调一次（幂等）。ctx 用 UIAbility / 应用上下文。
  start(ctx: common.Context): void {
    if (this.ds !== null) {
      return;
    }
    this.ctx = ctx;
    try {
      const ds: mdns.DiscoveryService = mdns.createDiscoveryService(ctx, SERVICE_TYPE);
      ds.on('serviceFound', (info: mdns.LocalServiceInfo) => this.onFound(info));
      ds.on('serviceLost', (info: mdns.LocalServiceInfo) => this.onLost(info));
      ds.startSearchingMDNS();
      this.ds = ds;
      hilog.info(DOMAIN, TAG, 'discovery started');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'start failed: %{public}s', JSON.stringify(e));
    }
  }

  // 发现一条服务：解析拿到 TXT（ts=/lan=），齐了就记进映射。
  private onFound(info: mdns.LocalServiceInfo): void {
    const ctx: common.Context | null = this.ctx;
    if (ctx === null) {
      return;
    }
    mdns.resolveLocalService(ctx, info).then((r: mdns.LocalServiceInfo) => {
      const attrs: Array<mdns.ServiceAttribute> = r.serviceAttribute ?? [];
      let ts: string = '';
      let lan: string = '';
      for (const a of attrs) {
        if (a.key === 'ts') {
          ts = BlinkdDiscovery.decode(a.value);
        } else if (a.key === 'lan') {
          lan = BlinkdDiscovery.decode(a.value);
        }
      }
      if (ts.length > 0 && lan.length > 0) {
        this.lanByTs.set(ts, lan);
        hilog.info(DOMAIN, TAG, 'lan mapping %{public}s → %{public}s', ts, lan);
      }
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, TAG, 'resolve failed: %{public}s', JSON.stringify(e));
    });
  }

  // 服务消失（daemon 停/离开局域网）：解析拿 ts，从映射里删。
  private onLost(info: mdns.LocalServiceInfo): void {
    const ctx: common.Context | null = this.ctx;
    if (ctx === null) {
      return;
    }
    mdns.resolveLocalService(ctx, info).then((r: mdns.LocalServiceInfo) => {
      const attrs: Array<mdns.ServiceAttribute> = r.serviceAttribute ?? [];
      for (const a of attrs) {
        if (a.key === 'ts') {
          this.lanByTs.delete(BlinkdDiscovery.decode(a.value));
        }
      }
    }).catch(() => {});
  }

  // 该 Tailscale host/IP 对应的机器此刻在本局域网被发现→返回它的 LAN 直连 IP，否则 undefined。
  lanHost(tsHost: string): string | undefined {
    return this.lanByTs.get(tsHost);
  }

  // TXT 值是字节数组，按 ASCII 解成字符串（ts/lan 都是纯 IP 字符）。
  private static decode(bytes: Array<number> | undefined): string {
    if (bytes === undefined) {
      return '';
    }
    let s: string = '';
    for (const b of bytes) {
      s += String.fromCharCode(b);
    }
    return s;
  }
}
