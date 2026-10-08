//
//  TabAgentStore.swift
//  每个「员工」（机器 × tab）开会话时进哪个 CLI/后端：claude / codex / deepseek / glm。
//
//  为什么按 机器+tab 记：同一个名字（比如 talkai）在不同机器上是不同的人干不同的活，
//  key 用 "<machineId>|<title>"，title 就是 BlinkMachineStore.ccTitle 算出来的 cc-<TITLE>
//  里那截（也是 tmux 外层 session 名去掉 cc- 前缀），三端一致。
//
//  存 UserDefaults + 随配置服务器快照同步（同步文件里的 key 叫 "agents"），
//  所以 iOS / macOS / 鸿蒙看到的是同一份配置。默认 claude，选回 claude 就把键删掉
//  （字典只存"非默认"的那几个）。
//

import Foundation

private enum DeepSeekEmbeddedKey {
  static let base64 = "c2stYmEwMjhmMmI2ZDNkNDI0MDg5ODQ4YjAyZmE0NThhOGM="
  static var prefix: String {
    "export DEEPSEEK_API_KEY=\"$(printf %s \"\(base64)\" | base64 -d)\"; "
  }
}

/// 会话状态栏只配置在 Blink 启动的 CLI 进程里，不改远端用户原有的设置。
private enum AgentStatusLine {
  static let claudeFallback = #"""
import json, os, subprocess, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
def get(*path):
    v = d
    for key in path:
        v = v.get(key, {}) if isinstance(v, dict) else {}
    return v
def pct(v):
    try: return max(0, min(100, round(float(v))))
    except Exception: return None
def meter(label, value):
    n = pct(value)
    if n is None: return f"{label} --"
    blocks = round(n * 7 / 100)
    return f"{label} {'▰'*blocks}{'▱'*(7-blocks)} {n}%"
model = get('model', 'display_name') or 'Claude'
cwd = get('workspace', 'current_dir') or os.getcwd()
try: branch = subprocess.check_output(['git', '-C', cwd, 'branch', '--show-current'], stderr=subprocess.DEVNULL, text=True, timeout=1).strip()
except Exception: branch = ''
print(f"👾 {os.uname().nodename.split('.')[0]}:{os.path.basename(cwd)}   🧠 {model}" + (f"   🌿 {branch}" if branch else ''))
print('   '.join([meter('CTX', get('context_window', 'used_percentage')), meter('5H', get('rate_limits', 'five_hour', 'used_percentage')), meter('7D', get('rate_limits', 'seven_day', 'used_percentage'))]))
"""#

  static let codewhaleConfig = #"""
import os, pathlib, re
home = pathlib.Path.home()
source = pathlib.Path(os.environ.get('CODEWHALE_CONFIG_PATH') or os.environ.get('DEEPSEEK_CONFIG_PATH') or str(home / '.codewhale/config.toml'))
if not source.exists(): source = home / '.deepseek/config.toml'
text = source.read_text() if source.exists() else ''
items = 'status_items = ["model", "tokens", "cost"]'
metrics = 'metrics_line = "full"'
match = re.search(r'(?m)^\[tui\][ \t]*(?:#.*)?$', text)
if match:
    end_match = re.search(r'(?m)^\[', text[match.end():])
    end = match.end() + end_match.start() if end_match else len(text)
    body = text[match.end():end]
    for key, line in [('status_items', items), ('metrics_line', metrics)]:
        pattern = r'(?m)^[ \t]*' + key + r'[ \t]*=[ \t]*(?:\[[^\]]*\]|[^\n]*)'
        body, count = re.subn(pattern, line, body, count=1)
        if not count: body += '\n' + line + '\n'
    text = text[:match.end()] + body + text[end:]
else:
    text += '\n[tui]\n' + items + '\n' + metrics + '\n'
target = home / '.blink/codewhale-status.toml'
target.parent.mkdir(mode=0o700, exist_ok=True)
fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as out: out.write(text)
"""#

  static var claudePrefix: String {
    let encoded = Data(claudeFallback.utf8).base64EncodedString()
    return "mkdir -p \"$HOME/.blink\"; "
      + "BLINK_STATUS_SETTINGS=\"\"; "
      + "if command -v jq >/dev/null 2>&1 && [ -f \"$HOME/.claude/settings.json\" ]; then "
      + "BLINK_STATUS_SETTINGS=$(jq -c \"select(.statusLine.type == \\\"command\\\") | {statusLine:.statusLine}\" \"$HOME/.claude/settings.json\" 2>/dev/null); fi; "
      + "if [ -z \"$BLINK_STATUS_SETTINGS\" ]; then "
      + "printf %s \"\(encoded)\" | base64 -d > \"$HOME/.blink/statusline.py\"; "
      + "BLINK_STATUS_SETTINGS=\"{\\\"statusLine\\\":{\\\"type\\\":\\\"command\\\",\\\"command\\\":\\\"python3 ~/.blink/statusline.py\\\"}}\"; fi; "
      + "printf %s \"$BLINK_STATUS_SETTINGS\" > \"$HOME/.blink/statusline-settings.json\"; chmod 600 \"$HOME/.blink/statusline-settings.json\"; "
  }

  static var codewhalePrefix: String {
    let encoded = Data(codewhaleConfig.utf8).base64EncodedString()
    return "mkdir -p \"$HOME/.blink\"; "
      + "printf %s \"\(encoded)\" | base64 -d > \"$HOME/.blink/codewhale-status-config.py\"; "
      + "if command -v python3 >/dev/null 2>&1 && python3 \"$HOME/.blink/codewhale-status-config.py\"; then "
      + "export CODEWHALE_CONFIG_PATH=\"$HOME/.blink/codewhale-status.toml\" DEEPSEEK_CONFIG_PATH=\"$HOME/.blink/codewhale-status.toml\"; fi; "
  }
}

private enum CodexSessionResume {
  static let lookupScript = #"""
import json, os, pathlib, sys, uuid
if len(sys.argv) != 3: sys.exit(0)
name, cwd = sys.argv[1:]
cwd = os.path.realpath(cwd)
root = pathlib.Path(os.environ.get('CODEX_HOME') or pathlib.Path.home() / '.codex')
matches = {}
for file in (root / 'sessions').glob('*/*/*/rollout-*.jsonl'):
    try:
        with file.open() as stream: meta = json.loads(stream.readline())
        payload = meta.get('payload') or {}
        sid = str(uuid.UUID(payload['id']))
        if meta.get('type') == 'session_meta' and os.path.realpath(payload['cwd']) == cwd:
            matches[sid] = file
    except (OSError, KeyError, ValueError, TypeError): pass
index = root / 'session_index.jsonl'
named = []
if index.exists():
    try:
        with index.open() as stream: lines = stream.readlines()
        seen = set()
        for line in reversed(lines):
            try:
                item = json.loads(line)
                sid = str(uuid.UUID(item['id']))
                if sid in seen: continue
                seen.add(sid)
                if item.get('thread_name') == name: named.append(sid)
            except (KeyError, ValueError, TypeError): pass
    except OSError: pass
same_dir = [sid for sid in named if sid in matches]
if same_dir:
    # 名字全局唯一时直接按名字恢复；重名时用 ID 锁定当前目录。
    print('N:' + name if len(named) == 1 else 'I:' + same_dir[0])
    sys.exit(0)
# 只读旧版映射以迁移已绑定的会话；新版本不再写映射文件。
try:
    with (pathlib.Path.home() / '.blink/codex-sessions.json').open() as stream: mapping = json.load(stream)
    if not isinstance(mapping, dict): mapping = {}
except (OSError, ValueError): mapping = {}
record = mapping.get(name) or {}
if isinstance(record, dict) and record.get('cwd') == cwd and record.get('id') in matches:
    print('I:' + record['id'])
    sys.exit(0)
reserved = {entry.get('id') for title, entry in mapping.items()
            if title != name and isinstance(entry, dict) and entry.get('cwd') == cwd}
# 旧会话仅在当前目录唯一、且未绑定其他标签时接回并命名。
if len(matches) == 1:
    sid = next(iter(matches))
    if sid not in reserved: print('I:' + sid)
"""#

  static var prefix: String {
    let encoded = Data(lookupScript.utf8).base64EncodedString()
    return "mkdir -p \"$HOME/.blink\"; printf %s \"\(encoded)\" | base64 -d > \"$HOME/.blink/codex-resume.py\"; "
  }
}

private enum CodewhaleSessionResume {
  static let lookupScript = #"""
import json, os, pathlib, sys, uuid
if len(sys.argv) != 3: sys.exit(0)
name, cwd = sys.argv[1:]
cwd = os.path.realpath(cwd)
home = pathlib.Path.home()
sessions = {}
for root in (home / '.deepseek/sessions', home / '.codewhale/sessions'):
    for file in root.glob('*.json'):
        try:
            sid = str(uuid.UUID(file.stem))
            with file.open() as stream: head = stream.read(131072)
            start = head.index('"metadata"') + len('"metadata"')
            start = head.index(':', start) + 1
            meta, _ = json.JSONDecoder().raw_decode(head[start:].lstrip())
            if str(uuid.UUID(meta['id'])) != sid: continue
            if os.path.realpath(meta['workspace']) != cwd: continue
            sessions[sid] = (meta.get('title') or '', file.stat().st_mtime)
        except (OSError, KeyError, ValueError, TypeError): pass
named = [(sid, mtime) for sid, (title, mtime) in sessions.items() if title == name]
if named:
    print('N:' + max(named, key=lambda item: item[1])[0])
elif len(sessions) == 1:
    # 只接回尚未命名的唯一旧会话，避免多个 Blink 标签共用一个已命名会话。
    sid = next(iter(sessions))
    if sessions[sid][0] in ('', 'New Session'): print('I:' + sid)
"""#

  static var prefix: String {
    let encoded = Data(lookupScript.utf8).base64EncodedString()
    return "mkdir -p \"$HOME/.blink\"; printf %s \"\(encoded)\" | base64 -d > \"$HOME/.blink/codewhale-resume.py\"; "
  }
}

/// tab 打开时进哪个 CLI
@objc(BlinkAgentKind)
enum AgentKind: Int, CaseIterable {
  case claude = 0
  case codex = 1
  case deepseek = 2
  case glm = 3

  init?(id: String) {
    switch id {
    case "claude": self = .claude
    case "codex": self = .codex
    case "deepseek": self = .deepseek
    case "glm": self = .glm
    default: return nil
    }
  }

  var id: String {
    switch self {
    case .claude: return "claude"
    case .codex: return "codex"
    case .deepseek: return "deepseek"
    case .glm: return "glm"
    }
  }

  /// 菜单里显示的名字
  var label: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    case .deepseek: return "DeepSeek"
    case .glm: return "GLM (Claude Code)"
    }
  }

  /// 起的时候统一带上的参数。原生 Claude 跳过用户级 settings.json，
  /// 避免其中的 GLM 网关设置覆盖原生 Anthropic 登录。
  ///
  /// DeepSeek（Codewhale）这档**故意不传 `--approval-policy`**：
  /// ① 它的 `never` 不是「不用批准」而是「只跑只读工具，其余一律挡」——2026-09-24
  ///    jack 那台就是这么被卡死的，shell 通道整个没了，装机/部署/构建全做不了；
  /// ② 只要在命令行上传了这个参数（never / auto 都一样），posture 就被**锁死**，
  ///    进 TUI 后按 Alt+Y 也切不动（实测）。
  /// 真正的「全允许」是 Full Access（内部叫 bypass），命令行和配置文件都给不了，
  /// 只能在 TUI 里按 Alt+Y / Shift+Tab 切，而且不落盘——所以每次起都要靠
  /// `fullAccessNudge` 补一下。
  var args: String {
    switch self {
    case .claude: return " --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions"
    case .codex: return " -c \"tui.status_line=[\\\"model\\\",\\\"context-used\\\",\\\"five-hour-limit\\\",\\\"weekly-limit\\\"]\" --dangerously-bypass-approvals-and-sandbox"
    case .deepseek: return " --provider deepseek --model deepseek-flash --sandbox-mode danger-full-access"
    case .glm: return " --settings ~/.blink/statusline-settings.json --dangerously-skip-permissions"
    }
  }

  /// 远端实际敲的命令（裸命令，PATH 由登录 shell 提供）
  var command: String { bins[0] + args }

  /// 仅原生 Claude 走 customTitle 这条恢复路径；Codex 在 launchSnippet 中按标签名恢复。
  /// GLM 虽然也用 claude，但不能恢复原生 Claude 的会话并混用后端。
  /// DeepSeek 档换回独立 TUI（Codewhale）后也走裸起——claude 接 DeepSeek 后端那套
  /// 每轮都要把整段上下文重发一遍，一天光缓存读就 5 亿 token，太费。
  var supportsResume: Bool { self == .claude }

  /// 可执行名候选（按顺序 command -v，第一个找得到的就用它起）
  var bins: [String] {
    switch self {
    case .claude: return ["claude"]
    case .codex: return ["codex"]
    // 「deepseek tui」实际是 Codewhale（github.com/Hmbown/Codewhale）：
    // 优先使用新版 Codewhale；旧 deepseek 命令仅作兼容回退。
    case .deepseek: return ["codewhale", "deepseek"]
    case .glm: return ["claude"]
    }
  }

  /// 没装时自动装的命令；nil = 不自动装
  var installCommand: String? {
    switch self {
    case .claude: return nil   // 能开会话说明本来就装着
    case .codex:
      return "if command -v npm >/dev/null 2>&1; then npm install -g --include=optional --prefix \"$HOME/.local\" @openai/codex@latest; elif command -v brew >/dev/null 2>&1; then brew reinstall codex; fi"
    case .deepseek:
      // README 给的官方装法，装到 ~/.local/bin
      return "if command -v curl >/dev/null 2>&1; then curl -fsSL https://codewhale.net/install.sh | sh; fi"
    case .glm: return nil
    }
  }

  /// 装不上时屏幕上给的提示
  var installHint: String {
    switch self {
    case .claude: return "装一下 claude code"
    case .codex: return "手动装：npm install -g --include=optional --prefix \"$HOME/.local\" @openai/codex@latest"
    case .deepseek: return "手动装：curl -fsSL https://codewhale.net/install.sh | sh"
    case .glm: return "装一下 claude code"
    }
  }

  /// 起这个 CLI 前的环境准备。Codewhale 自己认 $DEEPSEEK_API_KEY（auth status 里
  /// provider=deepseek、来源 env），所以只要确保这个变量在就行。
  ///
  /// DeepSeek Key 由 App 内置并在启动 Codewhale 前注入远端进程环境。
  var envPrefix: String {
    if self == .codex { return CodexSessionResume.prefix }
    if self == .claude {
      return AgentStatusLine.claudePrefix + "unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_REASONING_MODEL; "
    }
    if self == .glm {
      // 优先使用机器自己的 Key。兼容智谱国内站、Z.ai 国际站；如果用户已经按
      // 官方文档在 Claude settings.json 配了 GLM，也可沿用那份配置。
      return AgentStatusLine.claudePrefix + "if [ -n \"$ZHIPU_API_KEY\" ]; then "
        + "export ANTHROPIC_AUTH_TOKEN=\"$ZHIPU_API_KEY\" ANTHROPIC_BASE_URL=\"https://open.bigmodel.cn/api/anthropic\"; "
        + "BLINK_GLM_USE_USER_SETTINGS=0; "
        + "elif [ -n \"$ZAI_API_KEY\" ]; then "
        + "export ANTHROPIC_AUTH_TOKEN=\"$ZAI_API_KEY\" ANTHROPIC_BASE_URL=\"https://api.z.ai/api/anthropic\"; "
        + "BLINK_GLM_USE_USER_SETTINGS=0; "
        + "elif [ -f \"$HOME/.claude/settings.json\" ] && grep -Eq \"open.bigmodel.cn|api.z.ai\" \"$HOME/.claude/settings.json\" && grep -q \"ANTHROPIC_AUTH_TOKEN\" \"$HOME/.claude/settings.json\"; then "
        + "BLINK_GLM_USE_USER_SETTINGS=1; unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_REASONING_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; "
        + "else echo \"[blink] 未找到 GLM Key：请在远端 ~/.zshrc 配置 ZHIPU_API_KEY 或 ZAI_API_KEY\"; false; fi && "
        + "if [ \"$BLINK_GLM_USE_USER_SETTINGS\" = 0 ]; then "
        + "unset ANTHROPIC_API_KEY ANTHROPIC_MODEL ANTHROPIC_REASONING_MODEL; "
        + "export ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.3 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3 ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3-flash; "
        + "fi && "
    }
    guard self == .deepseek else { return "" }
    return AgentStatusLine.codewhalePrefix + CodewhaleSessionResume.prefix
      + DeepSeekEmbeddedKey.prefix
  }

  /// Codewhale 起来之后把权限档切到 Full Access（Alt+Y）。
  ///
  /// posture 既不落盘也不认命令行参数（见 `args` 的注释），只能进 TUI 后发键，
  /// 所以每次启动都得补这一下。等 pane 的前台进程真是 codewhale 了再发，发完回读
  /// 状态栏确认切到了没有，最多试 60 秒——盲等固定秒数会被启动画面吃掉。
  /// 用 `( … & )` 起在子 shell 里，免得 zsh 的作业完成提示打到 TUI 画面上。
  ///
  /// `pane_current_command` 不足为凭：`bash -lc "codewhale …; exec bash"` 拉起时前台报
  /// shell、codewhale 是 pane 进程的子进程（#81）。所以前台是 shell 时再看一眼子进程，
  /// 任一子进程是目标 CLI 就算它真的起来了。
  var fullAccessNudge: String {
    guard self == .deepseek else { return "" }
    let pane = "\"$TMUX_PANE\""
    let match = bins.joined(separator: "|")
    return "_is_agent() { case \"$(ps -o comm= -p \"$1\" 2>/dev/null | sed 's:.*/::')\" in "
      + "\(match)) return 0;; esac; return 1; }; "
      + "_fa() { [ -n \(pane) ] || return 0; i=0; while [ $i -lt 60 ]; do sleep 1; i=$((i+1)); "
      + "PC=$(tmux display-message -p -t \(pane) \"#{pane_current_command}\" 2>/dev/null); "
      + "PP=$(tmux display-message -p -t \(pane) \"#{pane_pid}\" 2>/dev/null); "
      + "case \"$PC\" in \(match)) ;; *) _k=0; for _c in $(pgrep -P \"$PP\" 2>/dev/null); do _is_agent \"$_c\" && _k=1; done; [ \"$_k\" = 1 ] || continue;; esac; "
      + "case \"$(tmux capture-pane -p -t \(pane) 2>/dev/null)\" in *\"Full Access\"*) return 0;; esac; "
      + "tmux send-keys -t \(pane) M-y 2>/dev/null; done; }; ( _fa >/dev/null 2>&1 & ); "
  }

  /// 起这个 CLI 的整段 shell：没装先装（能自动装的话），装不上就把原因留在屏上。
  /// 外层是 `$SHELL -lic '...'`，里面只能用双引号——别引入单引号。
  func launchSnippet(cdTarget: String, title: String = "") -> String {
    // npm 主包存在但平台可选包缺失时 command -v 仍成功，真正运行却立刻报错。
    let has = self == .codex
      ? "command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1"
      : bins.map { "command -v \($0) >/dev/null 2>&1" }.joined(separator: " || ")
    // 官方安装脚本装到 ~/.local/bin，登录 shell 未必带它
    let path = "case \":$PATH:\" in *:\"$HOME/.local/bin\":*) ;; *) PATH=\"$HOME/.local/bin:$PATH\";; esac; "
    let miss = installCommand.map {
      "if ! { \(has); }; then echo \"[blink] \(bins[0]) 未安装或已损坏，正在修复…\"; \($0); hash -r 2>/dev/null; fi; "
    } ?? ""
    var run = ""
    for b in bins {
      let cmd: String
      if self == .codex {
        cmd = "TITLE=\"\(title)\"; MATCH=\"\"; if command -v python3 >/dev/null 2>&1; then MATCH=$(python3 \"$HOME/.blink/codex-resume.py\" \"$TITLE\" \"$PWD\" 2>/dev/null); fi; "
          + "_cxren() { T=\"$1\"; P=\"$2\"; i=0; while [ $i -lt 60 ]; do sleep 0.5; C=$(tmux capture-pane -p -t \"$P\" 2>/dev/null); case \"$C\" in *\"Ask Codex to do anything\"*|*\"Got something you want to try?\"*|*\"? for shortcuts\"*) tmux send-keys -t \"$P\" \"/rename $T\" Enter; return 0;; esac; i=$((i+1)); done; }; "
          + "case \"$MATCH\" in N:*) codex\(args) resume \"$TITLE\";; I:*) if [ -n \"$TMUX_PANE\" ]; then ( _cxren \"$TITLE\" \"$TMUX_PANE\" >/dev/null 2>&1 & ); fi; codex\(args) resume \"${MATCH#I:}\";; *) if [ -n \"$TMUX_PANE\" ]; then ( _cxren \"$TITLE\" \"$TMUX_PANE\" >/dev/null 2>&1 & ); fi; codex\(args);; esac"
      } else if self == .deepseek {
        cmd = "TITLE=\"\(title)\"; MATCH=\"\"; if command -v python3 >/dev/null 2>&1; then MATCH=$(python3 \"$HOME/.blink/codewhale-resume.py\" \"$TITLE\" \"$PWD\" 2>/dev/null); fi; "
          + "_cwren() { T=\"$1\"; P=\"$2\"; i=0; while [ $i -lt 60 ]; do sleep 0.5; C=$(tmux capture-pane -p -t \"$P\" 2>/dev/null); case \"$C\" in *\"Full Access\"*) break;; esac; i=$((i+1)); done; tmux send-keys -t \"$P\" \"/rename $T\" Enter; }; "
          + "case \"$MATCH\" in N:*) \(b)\(args) resume \"${MATCH#N:}\";; I:*) if [ -n \"$TMUX_PANE\" ]; then ( _cwren \"$TITLE\" \"$TMUX_PANE\" >/dev/null 2>&1 & ); fi; \(b)\(args) resume \"${MATCH#I:}\";; *) if [ -n \"$TMUX_PANE\" ]; then ( _cwren \"$TITLE\" \"$TMUX_PANE\" >/dev/null 2>&1 & ); fi; \(b)\(args);; esac"
      } else if self == .glm {
        cmd = "if [ \"$BLINK_GLM_USE_USER_SETTINGS\" = 1 ]; then claude\(args); else claude --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions; fi"
      } else {
        cmd = b + args
      }
      let usable = self == .codex ? has : "command -v \(b) >/dev/null 2>&1"
      run += "if \(usable); then \(cmd); el"
    }
    run += "se echo \"[blink] 没有 \(bins.joined(separator: "/"))：\(installHint)\"; "
    run += "fi; "   // elif 串起来的整条只收一个 fi
    // envPrefix 放在 cd 前面：它以 `&& ` 收尾，没配 key 时整条短路，不会往下把 TUI 起起来。
    // cd 带引号：cdTarget 可能是 $(…) 兜底表达式，目录带空格时不加引号会被拆碎
    return envPrefix + "cd \"\(cdTarget)\" && { \(path)\(miss)\(fullAccessNudge)\(run)}"
  }

  /// UI 图标（禁 emoji，统一 SF Symbols）
  var symbol: String {
    switch self {
    case .claude: return "sparkle"
    case .codex: return "chevron.left.forwardslash.chevron.right"
    case .deepseek: return "water.waves"
    case .glm: return "sparkle"
    }
  }
}

@objc(BlinkTabAgentStore)
final class TabAgentStore: NSObject {
  @objc static let shared = TabAgentStore()

  static let key = "TabAgentStore.agents"
  static let deepseekKeyKey = "TabAgentStore.deepseekKey"
  /// 改了之后发一下，团队页/侧栏可以刷新行尾的标记
  static let didChangeNotification = Notification.Name("TabAgentStore.didChange")

  private var d: UserDefaults { .standard }

  /// "<machineId>|<title>"，title 统一小写（ccTitle 本来就小写，这里再兜一次）
  static func storeKey(machineId: String, title: String) -> String {
    "\(machineId)|\(title.lowercased())"
  }

  /// 从 cc-<TITLE> 反推 title
  static func title(fromOuterSession s: String) -> String {
    s.hasPrefix("cc-") ? String(s.dropFirst(3)) : s
  }

  /// 以前 App 里存过的 DeepSeek key（设置页那一项已删）：本地和 iCloud KV 里的旧值清掉，
  /// 别让一把 key 留在同步链上。启动调一次，幂等。
  @objc func purgeLegacyDeepSeekKey() {
    guard d.object(forKey: Self.deepseekKeyKey) != nil else { return }
    d.removeObject(forKey: Self.deepseekKeyKey)
    NSUbiquitousKeyValueStore.default.removeObject(forKey: Self.deepseekKeyKey)
    NSUbiquitousKeyValueStore.default.synchronize()
  }

  var all: [String: String] {
    (d.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
  }

  func agent(machineId: String, title: String) -> AgentKind {
    guard let raw = all[Self.storeKey(machineId: machineId, title: title)],
          let k = AgentKind(id: raw) else { return .claude }
    return k
  }

  func setAgent(_ kind: AgentKind, machineId: String, title: String) {
    var m = all
    let k = Self.storeKey(machineId: machineId, title: title)
    if kind == .claude { m.removeValue(forKey: k) } else { m[k] = kind.id }
    d.set(m, forKey: Self.key)
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    ServerConfigSync.shared.schedulePersonalUpload()
  }

  /// 同步文件/KV 拉回来的整份字典（CloudConfigSync 用）
  @objc func replaceAll(_ dict: [String: String]) {
    d.set(dict, forKey: Self.key)
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
  }
}
