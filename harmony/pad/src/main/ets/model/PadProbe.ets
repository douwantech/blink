////////////////////////////////////////////////////////////////////////////////
//
// PadProbe — 会话状态探测（干活中 / 等你 / 空闲），与 macOS 版 AppState.probeScript 同一份 shell：
// 一条 exec 遍历所有 cc-* tmux 会话，取 pane_current_command + 底部是否有 "esc to interrupt"。
// 分类同 iOS：裸 shell → 空闲；busy → 干活中；否则（claude 在前台等输入）→ 等你。
//
////////////////////////////////////////////////////////////////////////////////

import { PadExec } from './PadExec';

export type WorkStatus = 'work' | 'wait' | 'idle' | 'rest' | 'none';

export const PROBE_SCRIPT: string = [
  'export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
  'BODY=$(',
  "tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^cc-' | while IFS= read -r s; do",
  "  pc=$(tmux display-message -p -t \"$s\" '#{pane_current_command}' 2>/dev/null)",
  '  busy=0',
  "  tmux capture-pane -p -S -250 -t \"$s\" 2>/dev/null | tail -15 | grep -q 'esc to interrupt' && busy=1",
  "  printf '%s\\t%s\\t%s\\n' \"$s\" \"$pc\" \"$busy\"",
  'done',
  ')',
  "EB64=$(printf '%s' \"$BODY\" | base64 | tr -d '\\n')",
  "printf '@TSB64@%s@TSB64E@\\n' \"$EB64\"",
].join('\n');

const SHELLS: string[] = ['zsh', 'bash', 'sh', 'dash', 'ksh', 'fish', '-zsh', '-bash'];

export class PadProbe {
  /// 解析探测输出 → { cc-<title>: 状态 }。解不出包裹返回 null（区分「没有会话」和「探测失败」）。
  static parse(raw: string): Map<string, WorkStatus> | null {
    const body: string | null = PadExec.decodeTsb64(raw);
    if (body === null) {
      return null;
    }
    const map: Map<string, WorkStatus> = new Map();
    const lines: string[] = body.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const f: string[] = lines[i].replace(new RegExp('\\r', 'g'), '').split('\t');
      if (f.length < 3 || f[0].length === 0) {
        continue;
      }
      const pc: string = f[1].trim();
      const busy: boolean = f[2].trim() === '1';
      let st: WorkStatus;
      if (pc.length === 0 || SHELLS.indexOf(pc) >= 0) {
        st = 'idle';
      } else if (busy) {
        st = 'work';
      } else {
        st = 'wait';
      }
      map.set(f[0], st);
    }
    return map;
  }

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
