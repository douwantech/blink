// Public API of the tsvpn base library. App modules import from 'tsvpn'.
export { TailscaleCore } from './src/main/ets/core/TailscaleCore';
export { BlinkdClient } from './src/main/ets/blinkd/BlinkdClient';
export type { BlinkdState } from './src/main/ets/blinkd/BlinkdClient';
export { BlinkdDiscovery } from './src/main/ets/blinkd/BlinkdDiscovery';
export { Terminal } from './src/main/ets/blinkd/Terminal';
export { StatusStore } from './src/main/ets/common/StatusStore';
// SSH 直连（brain 公网直连用）：HUKS 里的私钥 + 主机指纹确认/固定。
// 手机端和 pad 端共用同一份（同一 bundle，HUKS 别名也共享）。
export { SshDirectClient } from './src/main/ets/ssh/SshDirectClient';
export { SshIdentity } from './src/main/ets/ssh/SshIdentity';
