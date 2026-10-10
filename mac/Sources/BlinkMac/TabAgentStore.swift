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
if named:
    # 工作目录改过后仍按标签名恢复原会话。
    print('I:' + named[0])
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
named_elsewhere = []
for root in (home / '.deepseek/sessions', home / '.codewhale/sessions'):
    for file in root.glob('*.json'):
        try:
            sid = str(uuid.UUID(file.stem))
            with file.open() as stream: head = stream.read(131072)
            start = head.index('"metadata"') + len('"metadata"')
            start = head.index(':', start) + 1
            meta, _ = json.JSONDecoder().raw_decode(head[start:].lstrip())
            if str(uuid.UUID(meta['id'])) != sid: continue
            title, mtime = meta.get('title') or '', file.stat().st_mtime
            if os.path.realpath(meta['workspace']) != cwd:
                if title == name: named_elsewhere.append((sid, mtime, file))
                continue
            sessions[sid] = (title, mtime)
        except (OSError, KeyError, ValueError, TypeError): pass
named = [(sid, mtime) for sid, (title, mtime) in sessions.items() if title == name]
if named:
    print('N:' + max(named, key=lambda item: item[1])[0])
elif named_elsewhere:
    sid, _, file = max(named_elsewhere, key=lambda item: item[1])
    # Codewhale 恢复时会采用会话记录里的 workspace，-C 本身不能覆盖它。
    # 在旧进程退出后迁移这一个按标签名匹配的记录，再恢复原会话。
    try:
        data = json.loads(file.read_text())
        data['metadata']['workspace'] = cwd
        temp = file.with_name(file.name + '.blink-workdir-tmp')
        temp.write_text(json.dumps(data, ensure_ascii=False))
        os.chmod(temp, 0o600)
        os.replace(temp, file)
        print('N:' + sid)
    except (OSError, KeyError, TypeError, ValueError):
        pass
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

/// 每个「员工」（机器 × tab）开会话时进哪个 CLI。
/// 与 iOS `AgentKind`（Blink/SmarterKeys/TabAgentStore.swift）、鸿蒙同名配置是同一份数据。
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, deepseek, glm
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .deepseek: return "DeepSeek"
        case .glm: return "GLM (Claude Code)"
        }
    }

    /// 起的时候统一带上的参数：三家都是「免确认 + 不进沙箱」，只是叫法不同。
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
        case .claude: return " --settings ~/.blink/statusline-settings.json --setting-sources project,local --dangerously-skip-permissions"
        case .codex: return " -c \"tui.status_line=[\\\"model\\\",\\\"context-used\\\",\\\"five-hour-limit\\\",\\\"weekly-limit\\\"]\" --dangerously-bypass-approvals-and-sandbox --no-daemon"
        case .deepseek: return " --provider deepseek --model deepseek-flash --sandbox-mode danger-full-access"
        case .glm: return " --settings ~/.blink/statusline-settings.json --dangerously-skip-permissions"
        }
    }

    /// 远端实际敲的命令（裸命令，PATH 由登录 shell 提供）
    var command: String { bins[0] + args }

    /// 仅原生 Claude 走 customTitle 恢复；Codex 在 launchSnippet 中按标签名恢复。
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
            return AgentStatusLine.claudePrefix + "if [ -n \"$ZHIPU_API_KEY\" ]; then "
                + "export ANTHROPIC_AUTH_TOKEN=\"$ZHIPU_API_KEY\" ANTHROPIC_BASE_URL=\"https://open.bigmodel.cn/api/anthropic\"; BLINK_GLM_USE_USER_SETTINGS=0; "
                + "elif [ -n \"$ZAI_API_KEY\" ]; then "
                + "export ANTHROPIC_AUTH_TOKEN=\"$ZAI_API_KEY\" ANTHROPIC_BASE_URL=\"https://api.z.ai/api/anthropic\"; BLINK_GLM_USE_USER_SETTINGS=0; "
                + "elif [ -f \"$HOME/.claude/settings.json\" ] && grep -Eq \"open.bigmodel.cn|api.z.ai\" \"$HOME/.claude/settings.json\" && grep -q \"ANTHROPIC_AUTH_TOKEN\" \"$HOME/.claude/settings.json\"; then "
                + "BLINK_GLM_USE_USER_SETTINGS=1; unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_REASONING_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; "
                + "else echo \"[blink] 未找到 GLM Key：请在远端 ~/.zshrc 配置 ZHIPU_API_KEY 或 ZAI_API_KEY\"; false; fi && "
                + "if [ \"$BLINK_GLM_USE_USER_SETTINGS\" = 0 ]; then "
                + "unset ANTHROPIC_API_KEY ANTHROPIC_MODEL ANTHROPIC_REASONING_MODEL; "
                + "export ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.3 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3 ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3-flash; fi && "
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
    var fullAccessNudge: String {
        guard self == .deepseek else { return "" }
        let pane = "\"$TMUX_PANE\""
        return "_fa() { [ -n \(pane) ] || return 0; i=0; while [ $i -lt 60 ]; do sleep 1; i=$((i+1)); "
            + "PC=$(tmux display-message -p -t \(pane) \"#{pane_current_command}\" 2>/dev/null); "
            // #81：CLI 也可能跑在 shell 底下（bash -lc "codewhale …; exec bash" 没有作业控制，
            // tmux 报的前台命令是 shell）——那时 pane 进程有子进程，不能只看前台命令就 continue，
            // 否则 Full Access 这一下永远不会发。
            + "case \"$PC\" in \(bins.joined(separator: "|"))) ;; zsh|bash|sh|dash|ksh|fish) "
            + "PP=$(tmux display-message -p -t \(pane) \"#{pane_pid}\" 2>/dev/null); "
            + "[ -n \"$PP\" ] && pgrep -P \"$PP\" >/dev/null 2>&1 || continue;; "
            + "*) continue;; esac; "
            + "case \"$(tmux capture-pane -p -t \(pane) 2>/dev/null)\" in *\"Full Access\"*) return 0;; esac; "
            + "tmux send-keys -t \(pane) M-y 2>/dev/null; done; }; ( _fa >/dev/null 2>&1 & ); "
    }

    /// 起这个 CLI 的整段 shell：没装先装（能自动装的话），装不上就把原因留在屏上。
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
          + "case \"$MATCH\" in N:*) \(b)\(args) -C \"$PWD\" resume \"${MATCH#N:}\";; I:*) if [ -n \"$TMUX_PANE\" ]; then ( _cwren \"$TITLE\" \"$TMUX_PANE\" >/dev/null 2>&1 & ); fi; \(b)\(args) -C \"$PWD\" resume \"${MATCH#I:}\";; *) if [ -n \"$TMUX_PANE\" ]; then ( _cwren \"$TITLE\" \"$TMUX_PANE\" >/dev/null 2>&1 & ); fi; \(b)\(args);; esac"
            } else if self == .glm {
                cmd = "if [ \"$BLINK_GLM_USE_USER_SETTINGS\" = 1 ]; then claude\(args); else claude --settings ~/.blink/statusline-settings.json --setting-sources project,local --dangerously-skip-permissions; fi"
            } else {
                cmd = b + args
            }
            let usable = self == .codex ? has : "command -v \(b) >/dev/null 2>&1"
            run += "if \(usable); then \(cmd); el"
        }
        run += "se echo \"[blink] 没有 \(bins.joined(separator: "/"))：\(installHint)\"; "
        run += "fi; "   // elif 串起来的整条只收一个 fi
        // envPrefix 放在 cd 前面：它以 `&& ` 收尾，没配 key 时整条短路，不会往下把 TUI 起起来
        return envPrefix + "cd \(cdTarget) && { \(path)\(miss)\(fullAccessNudge)\(run)}"
    }

    /// SF Symbols（禁 emoji）
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .deepseek: return "water.waves"
        case .glm: return "sparkle"
        }
    }
}

/// 配置来源跟后台清单（PinnedLinksStore）同一条路：
///   ① `~/.blink/sync/blink_config.json` 的 `agents`（手机一推就到，开发版没 KV 也读得到）；
///   ② iCloud KV `TabAgentStore.agents` 兜底。
/// key = `<machineId>|<title>`，title 就是 tmux 外层会话名 `cc-<TITLE>` 去掉前缀那截。
enum TabAgentStore {
    private static let kAgents = "TabAgentStore.agents"
    static func storeKey(machineId: String, title: String) -> String {
        "\(machineId)|\(title.lowercased())"
    }

    static func all() -> [String: String] {
        if let obj = SyncConfig.read()?["agents"] as? [String: String] { return obj }
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        return (kv.dictionary(forKey: kAgents) as? [String: String]) ?? [:]
    }

    static func agent(machineId: String, title: String) -> AgentKind {
        guard let raw = all()[storeKey(machineId: machineId, title: title)],
              let k = AgentKind(rawValue: raw) else { return .claude }
        return k
    }

    /// 默认值（claude）不落盘，字典只留"非默认"的那几个。
    static func setAgent(_ kind: AgentKind, machineId: String, title: String) {
        var m = all()
        let k = storeKey(machineId: machineId, title: title)
        if kind == .claude { m.removeValue(forKey: k) } else { m[k] = kind.rawValue }
        SyncConfig.patch { $0["agents"] = m }
        let kv = NSUbiquitousKeyValueStore.default
        kv.set(m, forKey: kAgents)
        kv.synchronize()
    }
}

/// `~/.blink/sync/blink_config.json` 的读改写。
///
/// origin 写成 `harmony-mac` 是为了过各端的防回声门槛：iOS 认前缀 `harmony*`、
/// 鸿蒙手机只挡 `harmony`、平板只挡 `harmony-pad`，所以这个值三端都会采纳；
/// 采纳后 iOS 会以 origin=ios 再推一遍，链路回到原样。
/// 除了改动的那个 key 和 origin / updatedAt 之外的字段原样保留，不动别人的配置。
enum SyncConfig {
    static var path: String {
        // BLINKMAC_SYNC_FILE：E2E 测试重定向到 fixture，别写坏真同步文件（老板的
        // 现版 BlinkMac / 鸿蒙端都在读写它）。与 CHATSHOT/DIAG 同类测试钩子。
        if let override = ProcessInfo.processInfo.environment["BLINKMAC_SYNC_FILE"], !override.isEmpty {
            return override
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".blink/sync/blink_config.json")
    }

    static func read() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 同步文件可用：存在且 machines 非空（空的多半是半截文件）。
    static var available: Bool { (read()?["machines"] as? [Any])?.isEmpty == false }

    /// 返回是否真的写回了文件。
    @discardableResult
    static func patch(_ mutate: (inout [String: Any]) -> Void) -> Bool {
        // machines 为空的多半是半截文件，别在上面盖配置
        guard var obj = read(), (obj["machines"] as? [Any])?.isEmpty == false else { return false }
        mutate(&obj)
        obj["origin"] = "harmony-mac"
        obj["updatedAt"] = Date().timeIntervalSince1970
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        let tmp = path + ".tmp"
        guard (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return false }
        let ok = (try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                         withItemAt: URL(fileURLWithPath: tmp))) != nil
        // 同步文件里有每台机器的 blinkd token 和书签密码，建成 600（#74：以前是 644）。
        // 注意必须改**目标**文件：replaceItemAt 会保留被替换文件的权限，改临时文件没用。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return ok
    }
}
