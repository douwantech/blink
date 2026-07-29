import { fileIo as fs } from '@kit.CoreFileKit';

// Tiny cross-process bridge. The VpnExtensionAbility (which owns the Go core)
// writes the latest Tailscale status JSON to a file in the app sandbox; the UI
// process reads it. They are separate processes, so they cannot share the Go
// singleton directly — this file is the shared channel.
//
// JSON is ASCII (backend state, IPs, auth URL), so a byte→char decode is safe.
const FILE = 'ts_status.json';
// Small facts learned only after login are persisted separately so they survive
// extension restarts and are never clobbered by a transient empty status. The
// extension reads them on startup to build the real tun (with the right IP and
// MagicDNS search domain) up front, without a reconfigure.
const NODE_IP_FILE = 'ts_node_ip.txt';
const NODE_IPV6_FILE = 'ts_node_ipv6.txt'; // node's tailscale IPv6, e.g. fd7a:115c:a1e0::…
const DNS_SUFFIX_FILE = 'ts_dns_suffix.txt'; // tailnet MagicDNS suffix, e.g. tailXXXXXX.ts.net

export class StatusStore {
  static path(filesDir: string): string {
    return `${filesDir}/${FILE}`;
  }

  // writeSmall/readSmall persist a single short text value (an IP, a DNS suffix)
  // to its own file. Empty values are ignored so a transient blank never wipes a
  // known-good value.
  private static writeSmall(filesDir: string, name: string, val: string): void {
    if (val.length === 0) {
      return;
    }
    try {
      const f = fs.openSync(
        `${filesDir}/${name}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      fs.writeSync(f.fd, val);
      fs.fsyncSync(f.fd);
      fs.closeSync(f);
    } catch (e) {
      // best-effort
    }
  }

  private static readSmall(filesDir: string, name: string): string {
    try {
      const p = `${filesDir}/${name}`;
      const stat = fs.statSync(p);
      if (stat.size <= 0) {
        return '';
      }
      const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const len = fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const bytes = new Uint8Array(buf, 0, len);
      let s = '';
      for (let i = 0; i < bytes.length; i++) {
        s += String.fromCharCode(bytes[i]);
      }
      return s.trim();
    } catch (e) {
      return '';
    }
  }

  static writeNodeIP(filesDir: string, ip: string): void {
    StatusStore.writeSmall(filesDir, NODE_IP_FILE, ip);
  }

  static readNodeIP(filesDir: string): string {
    return StatusStore.readSmall(filesDir, NODE_IP_FILE);
  }

  static writeNodeIPv6(filesDir: string, ip: string): void {
    StatusStore.writeSmall(filesDir, NODE_IPV6_FILE, ip);
  }

  static readNodeIPv6(filesDir: string): string {
    return StatusStore.readSmall(filesDir, NODE_IPV6_FILE);
  }

  static writeMagicSuffix(filesDir: string, suffix: string): void {
    StatusStore.writeSmall(filesDir, DNS_SUFFIX_FILE, suffix);
  }

  static readMagicSuffix(filesDir: string): string {
    return StatusStore.readSmall(filesDir, DNS_SUFFIX_FILE);
  }

  static write(filesDir: string, json: string): void {
    try {
      const f = fs.openSync(
        StatusStore.path(filesDir),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      fs.writeSync(f.fd, json);
      fs.fsyncSync(f.fd);
      fs.closeSync(f);
    } catch (e) {
      // best-effort
    }
  }

  static read(filesDir: string): string {
    try {
      const stat = fs.statSync(StatusStore.path(filesDir));
      if (stat.size <= 0) {
        return '{}';
      }
      const f = fs.openSync(StatusStore.path(filesDir), fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const len = fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const bytes = new Uint8Array(buf, 0, len);
      let s = '';
      for (let i = 0; i < bytes.length; i++) {
        s += String.fromCharCode(bytes[i]);
      }
      return s;
    } catch (e) {
      return '{}';
    }
  }
}
