import * as tsbridge from 'libtsbridge.so';

// TailscaleCore wraps the Go core's NAPI bridge (libtsbridge.so). Keeping the
// native import here means the .so stays encapsulated in this library — app
// modules call TailscaleCore instead of importing 'libtsbridge.so' directly.
export class TailscaleCore {
  // Start the core. fd=-1 runs netstack-only (our own control/DERP traffic);
  // fd=<tun fd> restarts the core onto the real system tun. Returns '' on
  // success, else an error string.
  static start(fd: number, stateDir: string, hostname: string,
               controlURL: string, authKey: string): string {
    return tsbridge.start(fd, stateDir, hostname, controlURL, authKey);
  }

  // Restart the running core onto a new tun fd. Returns '' on success.
  static updateTun(fd: number): string {
    return tsbridge.updateTun(fd);
  }

  static version(): string {
    return tsbridge.version();
  }

  static loginUrl(): string {
    return tsbridge.loginUrl();
  }

  // Backend status as a JSON string (backendState, peers, tailscale IPs, …).
  static status(): string {
    return tsbridge.status();
  }

  static stop(): void {
    tsbridge.stop();
  }
}
