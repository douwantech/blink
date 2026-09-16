import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BlinkdDiscovery } from 'tsvpn';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'Tailscale', 'EntryAbility onCreate');
    // 常驻 Bonjour 发现同网 blinkd，供 LAN 直连优先用（发现不到自动回落 Tailscale）
    BlinkdDiscovery.instance.start(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/BlinkTerminal', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'Tailscale', 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'Tailscale', 'EntryAbility onDestroy');
  }
}
