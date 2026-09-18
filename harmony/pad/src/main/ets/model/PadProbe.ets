////////////////////////////////////////////////////////////////////////////////
//
// PadProbe — 读每个会话「在干嘛」，与 macOS 版 AppState.readScript 同一份 shell：
// 一条 exec 遍历所有 cc-* tmux 会话，读 claude 自己写的 jsonl 里最后一条有意义的记录。
// 不再探测状态（pane 前台进程 + 屏幕有没有 spinner 那一套）：分出来的 等你/干活中/空闲
// 本来就不准，界面上也早不显示了。剩下的 WorkStatus 只用来区分「休息 / 其它」。
//
////////////////////////////////////////////////////////////////////////////////

import { PadExec } from './PadExec';

export type WorkStatus = 'work' | 'wait' | 'idle' | 'rest' | 'none';

export interface ProbeInfo {
  doing: string;   // 「正在 Edit · xxx.ets」/ 它最后说的话 / 「你说：…」
  ago: number;     // jsonl 多久没写了（秒），-1 = 不知道
}

/// 「3 分钟前」这种相对时间；-1 返回空串
export function agoText(sec: number): string {
  if (sec < 0) {
    return '';
  }
  if (sec < 60) {
    return '刚刚';
  }
  if (sec < 3600) {
    return Math.floor(sec / 60) + ' 分钟前';
  }
  if (sec < 86400) {
    return Math.floor(sec / 3600) + ' 小时前';
  }
  return Math.floor(sec / 86400) + ' 天前';
}

export const PROBE_SCRIPT: string = [
  'export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
  'now=$(date +%s)',
  'HAVEJQ=0; command -v jq >/dev/null 2>&1 && HAVEJQ=1',
  // 「在干嘛」读 claude 自己写的 jsonl（结构化的工具调用/消息），不刮终端屏幕——
  // 屏幕刮到的常是框线残渣和上一轮的内容，一直不准。
  "JQP='.message as $m",
  '| if (.type=="assistant") and ($m.content|type=="array") then',
  '    ($m.content[]',
  '     | if .type=="tool_use" then',
  '         "正在 " + .name',
  '         + (if (.input.description|type)=="string" then " · " + .input.description',
  '            elif (.input.file_path|type)=="string" then " · " + (.input.file_path|sub("^.*/";""))',
  '            elif (.input.pattern|type)=="string" then " · " + .input.pattern',
  '            elif (.input.command|type)=="string" then " · " + (.input.command|gsub("\\n";" "))',
  '            else "" end)',
  '       elif (.type=="text") and ((.text|ltrimstr(" ")|length) > 1) then',
  '         (.text|gsub("\\n";" ")|gsub("[*#`>]";"")|gsub("  +";" "))',
  '       else empty end)',
  '  elif (.type=="user") and ($m.content|type=="string")',
  '       and ((.isMeta // false)|not) and ($m.content|startswith("<")|not) then',
  '    "你说：" + ($m.content|gsub("\\n";" ")|gsub("  +";" "))',
  "  else empty end'",
  'BODY=$(',
  "tmux list-sessions -F '#{session_name}|#{pane_current_path}' 2>/dev/null | grep '^cc-' | while IFS='|' read -r s cwd; do",
  '  ago=""; doing=""',
  '  if [ "$HAVEJQ" = 1 ] && [ -n "$cwd" ]; then',
  "    enc=$(printf '%s' \"$cwd\" | sed 's:[/.]:-:g')",
  '    D="$HOME/.claude/projects/$enc"',
  '    title=${s#cc-}',
  '    PAT="\\"customTitle\\":\\"$title\\""',
  '    F=""',
  // jsonl 动辄几十 MB，全目录 grep 是几十 GB 的读，探测会卡死；只看最近 8 份的头尾
  '    CANDS=$(ls -t "$D"/*.jsonl 2>/dev/null | head -8)',
  '    for f in $CANDS; do',
  '      head -n 3 "$f" 2>/dev/null | grep -qF "$PAT" && { F="$f"; break; }',
  '    done',
  '    if [ -z "$F" ]; then',
  '      for f in $CANDS; do',
  '        tail -n 200 "$f" 2>/dev/null | grep -qF "$PAT" && { F="$f"; break; }',
  '      done',
  '    fi',
  '    if [ -n "$F" ]; then',
  '      mt=$(stat -f %m "$F" 2>/dev/null || stat -c %Y "$F" 2>/dev/null)',
  '      ago=$(( now - ${mt:-$now} ))',
  '      doing=$(tail -n 120 "$F" | jq -rc "$JQP" 2>/dev/null | tail -1 | tr -d \'\\t\\r\' | cut -c1-160)',
  '    fi',
  '  fi',
  "  printf '%s\\t%s\\t%s\\n' \"$s\" \"$ago\" \"$doing\"",
  'done',
  ')',
  "EB64=$(printf '%s' \"$BODY\" | base64 | tr -d '\\n')",
  "printf '@TSB64@%s@TSB64E@\\n' \"$EB64\"",
].join('\n');

export class PadProbe {
  /// 解析探测输出 → { cc-<title>: 状态 }。解不出包裹返回 null（区分「没有会话」和「探测失败」）。
  /// 一个会话读到的东西：在干嘛 + 距今多久（秒，-1=不知道）。
  /// 解不出包裹返回 null（区分「没有会话」和「读取失败」）。
  static parseInfo(raw: string): Map<string, ProbeInfo> | null {
    const body: string | null = PadExec.decodeTsb64(raw);
    if (body === null) {
      return null;
    }
    const map: Map<string, ProbeInfo> = new Map();
    const lines: string[] = body.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const f: string[] = lines[i].replace(new RegExp('\\r', 'g'), '').split('\t');
      if (f.length < 2 || f[0].length === 0) {
        continue;
      }
      const agoStr: string = f[1].trim();
      const ago: number = agoStr.length > 0 ? parseInt(agoStr, 10) : -1;
      map.set(f[0], { doing: f.length >= 3 ? f[2].trim() : '', ago: isNaN(ago) ? -1 : ago });
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
