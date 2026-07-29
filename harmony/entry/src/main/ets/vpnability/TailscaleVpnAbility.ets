import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import { vpnExtension, connection } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';
// Native NAPI module bridging to the Go Tailscale core (libtailscale_ohos.so).
import { TailscaleCore, StatusStore } from 'tsvpn';

const DOMAIN = 0x2020;
const TAG = 'TailscaleVpn';
const BUNDLE = 'com.douwantech.blink';
// Placeholder tun address used only to establish the VPN quickly so OHOS keeps
// this extension alive during login; replaced with the real node IP once known.
const PLACEHOLDER_IP = '100.64.0.1';

let gConn: vpnExtension.VpnConnection | undefined = undefined;
let gPollTimer: number = -1;
let gTunAttached: boolean = false; // tailscale is running over the real-IP tun
let gCreated: boolean = false;     // we've already create()d a tun this process
let gDnsSuffix: string = '';       // tailnet MagicDNS suffix, e.g. tailXXXXXX.ts.net
let gNodeIPv6: string = '';        // node's tailscale IPv6, so the tun is dual-stack
let gStateDir: string = '';        // app state dir, for persisting IPs across restarts
// The Tailscale IPv6 ULA range (fd7a:115c:a1e0::/48) that all peers live in.
const TS_V6_RANGE = 'fd7a:115c:a1e0::';

/**
 * The VPN tunnel process. It owns the Go Tailscale core.
 *
 * Lifecycle note: OHOS reaps a VpnExtensionAbility that doesn't establish a VPN
 * within a few seconds. Tailscale login takes longer than that, so we can't wait
 * for the node IP before the first create(). Instead:
 *
 *   1. create() a tun with a PLACEHOLDER address immediately  → keeps us alive
 *   2. TailscaleCore.start(-1, …)  netstack-only login (our own control/DERP traffic
 *                             bypasses the tun via blockedApplications)
 *   3. poll TailscaleCore.status() until tailscaleIPs is known
 *   4. destroy() + create() the tun with the REAL node IP, then
 *      TailscaleCore.updateTun(fd)  → restart the core onto the real system tun
 *      (login persists via the state dir, so no re-auth)
 */
export default class TailscaleVpnAbility extends VpnExtensionAbility {
  async onCreate(want: Want): Promise<void> {
    hilog.info(DOMAIN, TAG, 'VpnExtensionAbility onCreate');
    const p = (want.parameters ?? {}) as Record<string, Object>;
    const stateDir = (p['stateDir'] as string) ?? this.context.filesDir;
    const hostname = (p['hostname'] as string) ?? 'harmony';
    const controlURL = (p['controlURL'] as string) ?? '';
    const authKey = (p['authKey'] as string) ?? '';

    try {
      const v: string = TailscaleCore.version();
      hilog.info(DOMAIN, TAG, 'core loaded in ext, version=%{public}s', v);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'core load threw: %{public}s', `${e}`);
      return;
    }

    // Recover the node IP from the last mirrored status (persists across ext
    // restarts). If we know it, we can build the real tun in one shot and never
    // reconfigure — reconfiguring drops the VPN for an instant, which makes OHOS
    // reap the extension.
    gStateDir = stateDir;
    const knownIP = StatusStore.readNodeIP(stateDir);
    gNodeIPv6 = StatusStore.readNodeIPv6(stateDir); // dual-stack tun if we know it
    if (gNodeIPv6.length === 0) {
      // Fall back to the last mirrored status, which carries both IPs — so even the
      // first connect after an upgrade builds a dual-stack tun instead of waiting
      // for polling to relearn the IPv6 and reconfigure.
      try {
        const st = JSON.parse(StatusStore.read(stateDir)) as Record<string, Object>;
        const sips = st['tailscaleIPs'] as string[];
        if (sips) {
          for (const ip of sips) {
            if (ip.indexOf(':') >= 0) { gNodeIPv6 = ip; break; }
          }
        }
      } catch (e) { /* no prior status */ }
    }
    gDnsSuffix = StatusStore.readMagicSuffix(stateDir); // for MagicDNS searchDomains

    if (knownIP.length > 0) {
      // Fast path: create the real tun up front and start the core directly on
      // it. Login state persists via the state dir, so no re-auth and no drop.
      try {
        const fd: number = await this.createTun(knownIP);
        hilog.info(DOMAIN, TAG, 'real tun up front fd=%{public}d ip=%{public}s', fd, knownIP);
        const err: string = TailscaleCore.start(fd, stateDir, hostname, controlURL, authKey);
        if (err.length > 0) {
          hilog.error(DOMAIN, TAG, 'TailscaleCore.start(fd) failed: %{public}s', err);
          return;
        }
        gTunAttached = true; // already on the real tun; poll only mirrors status
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'fast-path start threw: %{public}s', `${e}`);
        return;
      }
    } else {
      // First-ever connect: no node IP yet. Establish a placeholder tun to stay
      // alive, log in over netstack, learn the IP (persisted to the status file),
      // then reconfigure. That reconfigure drops us once; OHOS restarts the
      // extension, which then takes the fast path above and stays up.
      try {
        const fd0: number = await this.createTun(PLACEHOLDER_IP);
        hilog.info(DOMAIN, TAG, 'placeholder tun up (fd=%{public}d)', fd0);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'placeholder createTun failed: %{public}s', JSON.stringify(e));
      }
      try {
        const err: string = TailscaleCore.start(-1, stateDir, hostname, controlURL, authKey);
        if (err.length > 0) {
          hilog.error(DOMAIN, TAG, 'TailscaleCore.start(-1) failed: %{public}s', err);
          return;
        }
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'TailscaleCore.start(-1) threw: %{public}s', `${e}`);
        return;
      }
    }

    this.startPolling(stateDir);
  }

  // ensureConn creates the VpnConnection once.
  private async ensureConn(): Promise<void> {
    if (!gConn) {
      gConn = vpnExtension.createVpnConnection(this.context);
    }
  }

  // createTun (re)creates the system tun with the given address. Uses the classic
  // single-VPN path (no vpnId): passing a generateVpnId() vpnId puts OHOS on the
  // multi-tun (SysVpn) code path, whose per-UID steering and connection tracking
  // misbehave — inbound TCP SYN-ACKs get RST'd and app traffic never completes.
  // The classic path (interface "vpn-tun") is what every official demo uses.
  private async createTun(ipv4: string): Promise<number> {
    await this.ensureConn();
    const conn = gConn as vpnExtension.VpnConnection;
    // Tear down any prior tunnel (this process's, or an orphan left by a crashed
    // predecessor) before creating. On the classic path there's a single slot, so
    // a stale one makes create() fail with 2203002 "VPN exist already".
    try {
      await conn.destroy();
    } catch (e) { /* nothing to tear down */ }

    // Dual-stack disabled: OHOS API-20 VpnConnection.create silently drops an
    // IPv6 tun address (family 2 is correct per the SDK, but the address never
    // lands on vpn-tun). A v6 route WITHOUT a usable v6 source just black-holes
    // the browser's Happy-Eyeballs IPv6 attempt. IPv4-only + isIPv6Accepted:false
    // instead makes the IPv6 attempt fail fast so the browser falls back to IPv4,
    // which the data path fully supports. (gNodeIPv6 still tracked for later.)
    const hasV6 = false;

    // Split tunnel: route ONLY the Tailscale ranges into the tun. Public-internet
    // traffic — including our own DERP/control sockets — stays on wlan0, so
    // there's no full-tunnel self-loop and no need for per-socket protect()
    // (protectProcessNet is API 22+; this device is API 20). All peers live in
    // 100.64.0.0/10 (v4) and fd7a:115c:a1e0::/48 (v6).
    const addresses: connection.LinkAddress[] = [
      { address: { address: ipv4, family: 1 }, prefixLength: 32 },
    ];
    const routes: connection.RouteInfo[] = [
      {
        interface: 'vpn-tun',
        destination: { address: { address: '100.64.0.0', family: 1 }, prefixLength: 10 },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: false,
      },
    ];
    if (hasV6) {
      // Dual-stack: MagicDNS hands the browser an AAAA and Happy-Eyeballs prefers
      // IPv6, so the tun must carry fd7a:115c:a1e0::/48 too or name-based HTTPS
      // stalls on the (unrouted) IPv6 attempt.
      addresses.push({ address: { address: gNodeIPv6, family: 2 }, prefixLength: 128 });
      routes.push({
        interface: 'vpn-tun',
        destination: { address: { address: TS_V6_RANGE, family: 2 }, prefixLength: 48 },
        gateway: { address: '::', family: 2 },
        hasGateway: false,
        isDefaultRoute: false,
      });
    }

    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      mtu: 1280,
      isIPv4Accepted: true,
      isIPv6Accepted: hasV6,
      isBlocking: false,
      // ONLY tailscale's resolver — no public fallback. A second (public) resolver
      // gets used out-of-band over wlan0 for `.ts.net` names too (tailscale
      // publishes them publicly), returning an AAAA that bypasses the tun and our
      // AAAA-strip, so the browser commits to the unroutable IPv6. Routing all DNS
      // through 100.100.100.100 (via the tun) lets the core strip AAAA so the
      // browser uses IPv4. (Public-name resolution is a separate follow-up: the
      // core needs an upstream resolver; today it SERVFAILs non-tailnet names.)
      dnsAddresses: ['100.100.100.100'],
      searchDomains: gDnsSuffix.length > 0 ? [gDnsSuffix] : [],
      // No trusted/blocked lists → route EVERY app (all UIDs) through the tun.
      // This is required because a browser/WebView does its actual page network
      // I/O in a separate ArkWeb *render* process with a DIFFERENT uid (2010xxxx)
      // than the app bundle (2002xxxx); trustedApplications matches the bundle's
      // uid only, so it never captured the render process — DNS went through the
      // tun but the page's TCP connection bypassed it. Empty lists route all uids.
      // The split route (100.64.0.0/10) keeps the core's own DERP/control (public
      // IPs) off the tun, so there's no self-loop.
    };
    const fd: number = await conn.create(config);
    gCreated = true;
    return fd;
  }

  private startPolling(stateDir: string): void {
    gPollTimer = setInterval(() => {
      const s: string = TailscaleCore.status();
      hilog.info(DOMAIN, TAG, 'poll status=%{public}s', s);
      StatusStore.write(stateDir, s); // mirror for the UI process
      try {
        const j = JSON.parse(s) as Record<string, Object>;
        const suffix = j['magicDNSSuffix'] as string;
        if (suffix && suffix.length > 0 && suffix !== gDnsSuffix) {
          gDnsSuffix = suffix; // learned the tailnet suffix; persist for next launch
          StatusStore.writeMagicSuffix(stateDir, suffix);
        }
        const ips = j['tailscaleIPs'] as string[];
        if (ips && ips.length > 0) {
          StatusStore.writeNodeIP(stateDir, ips[0]); // remember for fast reconnect
          // Second address (if any) is the node's tailscale IPv6; keep it so the
          // tun can be dual-stack (browser Happy-Eyeballs prefers IPv6 names).
          for (let i = 1; i < ips.length; i++) {
            if (ips[i].indexOf(':') >= 0) {
              gNodeIPv6 = ips[i];
              StatusStore.writeNodeIPv6(stateDir, ips[i]);
              break;
            }
          }
          if (!gTunAttached) {
            gTunAttached = true; // guard against re-entry before the async work runs
            this.attachRealTun(ips[0]);
          }
        }
      } catch (e) {
        // status not ready yet
      }
    }, 1500);
  }

  // Step 4: reconfigure the tun to the real node IP and hand it to the core.
  private async attachRealTun(nodeIP: string): Promise<void> {
    try {
      const tunfd: number = await this.createTun(nodeIP); // dual-stack via gNodeIPv6
      hilog.info(DOMAIN, TAG, 'real tun fd = %{public}d (node %{public}s)', tunfd, nodeIP);
      const err: string = TailscaleCore.updateTun(tunfd);
      if (err.length > 0) {
        hilog.error(DOMAIN, TAG, 'TailscaleCore.updateTun failed: %{public}s', err);
        gTunAttached = false;
      } else {
        hilog.info(DOMAIN, TAG, 'tailscale now running over system tun');
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'attachRealTun error: %{public}s', JSON.stringify(e));
      gTunAttached = false;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'VpnExtensionAbility onDestroy');
    if (gPollTimer >= 0) {
      clearInterval(gPollTimer);
      gPollTimer = -1;
    }
    try {
      TailscaleCore.stop();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'stop error: %{public}s', JSON.stringify(e));
    }
    if (gConn) {
      const conn = gConn;
      conn.destroy().catch((e: Object) => {
        hilog.error(DOMAIN, TAG, 'destroy error: %{public}s', JSON.stringify(e));
      });
      gConn = undefined;
    }
    gTunAttached = false;
    gCreated = false;
  }
}
