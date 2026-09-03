import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0BD2;

export default class WatchAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'watch', 'WatchAbility onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 手表圆屏：铺满全屏
    windowStage.getMainWindow().then((w: window.Window) => {
      w.setWindowLayoutFullScreen(true).catch((): void => {});
    }).catch((): void => {});
    windowStage.loadContent('pages/WatchAssistant', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'watch', 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'watch', 'WatchAbility onDestroy');
  }
}
