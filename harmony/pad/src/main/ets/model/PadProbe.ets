////////////////////////////////////////////////////////////////////////////////
//
// PadProbe — 只剩状态的文案和配色。
// 远端探测（pane 前台进程 / 屏幕 spinner / 读 claude 记录）整套拿掉了：
// 分出来的 等你/干活中/空闲 不准，界面上也不显示；状态现在只有「休息 / 在岗」两档。
//
////////////////////////////////////////////////////////////////////////////////

export type WorkStatus = 'work' | 'wait' | 'idle' | 'rest' | 'none';

export class PadProbe {
  /// 解析探测输出 → { cc-<title>: 状态 }。解不出包裹返回 null（区分「没有会话」和「探测失败」）。
  static label(s: WorkStatus): string {
    if (s === 'work') {
      return '干活中';
    } else if (s === 'wait') {
      return '等你';
    } else if (s === 'rest') {
      return '休息';
    } else if (s === 'idle') {
      return '空闲';
    }
    return '未启动';
  }

  // 同 macOS Theme：wait #f5a83d / work #40d68c / idle #757f8f / rest #8f8cff
  static color(s: WorkStatus): string {
    if (s === 'work') {
      return '#40D68C';
    } else if (s === 'wait') {
      return '#F5A83D';
    } else if (s === 'rest') {
      return '#8F8CFF';
    } else if (s === 'idle') {
      return '#757F8F';
    }
    return '#4A515C';
  }
}
