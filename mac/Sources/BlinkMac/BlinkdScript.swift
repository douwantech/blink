import Foundation

/// 远程 exec 脚本生成——逐字复刻 blink `BlinkMachineStore.sshCommand` 的 tmux 分支：
/// 外层 `tmux new-session -A -s cc-<TITLE>` 里跑 resume-or-new 的 claude，
/// 从 ~/.claude/projects 反查 customTitle 直接 resume，找不到就起新会话并
/// send-keys `/rename` 自动命名；attach 到坏 session 时 heal 自愈重 source。
enum BlinkdScript {

    static let bootPath = "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    /// 枚举本机所有 tmux 会话：name<TAB>active-pane-path，每行一个。
    static func listSessions() -> String {
        "\(bootPath); tmux list-sessions -F '#{session_name}\t#{pane_current_path}' 2>/dev/null"
    }

    /// 枚举本机 tmux 会话 + 创建时间：name<TAB>session_created(epoch 秒)，每行一个。补孤儿标签用。
    static func listSessionsCreated() -> String {
        "\(bootPath); tmux list-sessions -F '#{session_name}\t#{session_created}' 2>/dev/null"
    }

    /// 切换到已有标签时查询 pane 的真实目录；UI 缓存终端视图，不会重新执行启动脚本。
    static func directoryStatus(session: String, workDir: String, agent: AgentKind) -> String {
        let name = "'" + session.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let dir = "'" + workDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let title = session.hasPrefix("cc-") ? String(session.dropFirst(3)) : session
        let quotedTitle = "'" + title.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let codewhaleWorkspace = #"""
import json, pathlib, sys
name = sys.argv[1]
found = []
for root in (pathlib.Path.home() / '.codewhale/sessions', pathlib.Path.home() / '.deepseek/sessions'):
    for file in root.glob('*.json'):
        try:
            with file.open() as stream: head = stream.read(131072)
            start = head.index('"metadata"') + len('"metadata"')
            start = head.index(':', start) + 1
            meta, _ = json.JSONDecoder().raw_decode(head[start:].lstrip())
            if meta.get('title') == name:
                found.append((file.stat().st_mtime, meta.get('workspace') or ''))
        except (OSError, ValueError, TypeError): pass
if found: print(max(found)[1])
"""#
        let encoded = Data(codewhaleWorkspace.utf8).base64EncodedString()
        let agentCheck = agent == .deepseek
            ? "CW=$(printf %s '\(encoded)' | base64 -d | python3 - \(quotedTitle) 2>/dev/null); if [ -n \"$CW\" ] && [ \"$CW\" != \"$D\" ]; then echo BLINK_DIR_MISMATCH; else echo BLINK_DIR_OK; fi"
            : "echo BLINK_DIR_OK"
        return """
        \(bootPath)
        D=$(cd \(dir) 2>/dev/null && pwd -P)
        if [ -z "$D" ]; then
          echo BLINK_DIR_MISSING
        elif ! tmux has-session -t \(name) 2>/dev/null; then
          echo BLINK_DIR_NO_SESSION
        else
          P=$(tmux display-message -p -t \(name) '#{pane_current_path}' 2>/dev/null)
          if [ "$P" != "$D" ]; then echo BLINK_DIR_MISMATCH; else \(agentCheck); fi
        fi
        """
    }

    /// 与 iOS 的 resetPane 一致：重启当前 pane，保留 tmux 会话和工作目录。
    static func resetPane(_ session: String) -> String {
        let quoted = "'" + session.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        \(bootPath)
        S=\(quoted)
        if tmux has-session -t "$S" 2>/dev/null; then
          D=$(tmux display-message -p -t "$S" '#{pane_current_path}' 2>/dev/null)
          D=${D:-$HOME}
          if tmux respawn-pane -k -t "$S" -c "$D" "$SHELL -il" 2>/dev/null; then
            echo BLINK_RESET_OK
          else
            echo BLINK_RESET_FAILED
          fi
        else
          echo BLINK_RESET_NO_SESSION
        fi
        """
    }

    /// blinkd exec 帧的 payload（daemon 会 `/bin/bash -c "<payload>"`）。
    /// agent = 这个员工配的 CLI（团队列表行尾齿轮，见 TabAgentStore）；默认 claude。
    static func tmuxClaude(title: String, workDir: String, agent: AgentKind = .claude) -> String {
        let outerSession = "cc-\(title)"
        let cd = "'" + workDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // 启动文件先写临时文件再 mv：几个客户端同时重连时 `cat >` 会互相截断交错，留下半截内容（parse error）
        let bootFile = "/tmp/.blink-boot-\(outerSession).sh"

        // inner 被外层 `$SHELL -lic '...'` 单引号包裹，里面只能用双引号；TITLE 预先算好。
        // Codex 和 Codewhale 从各自会话索引按标签名恢复；GLM 由 Claude Code 启动。
        let inner = !agent.supportsResume ? agent.launchSnippet(cdTarget: cd, title: title)
            // 同名会话可能有好几个（/clear 过就会），resume 要挑最近修改的那个；以前 find | head -1 按目录顺序挑，会接回老对话（2026-09-22 adam-rc 接回了被 DeepSeek 审核拒掉的那段历史）
            : agent.envPrefix + #"cd \#(cd) && { CUR=$(pwd | sed "s:[/.]:-:g"); PROJ="$HOME/.claude/projects/$CUR"; TITLE="\#(title)"; ID=""; M=""; if [ -d "$PROJ" ]; then M=$(find "$PROJ" -maxdepth 1 -name "*.jsonl" -type f -exec grep -lF "\"customTitle\":\"$TITLE\"" {} + 2>/dev/null | while IFS= read -r f; do echo "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) $f"; done | sort -rn | head -1 | cut -d" " -f2-); fi; if [ -z "$M" ]; then M=$(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name "*.jsonl" -type f -exec grep -lF "\"customTitle\":\"$TITLE\"" {} + 2>/dev/null | while IFS= read -r f; do echo "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) $f"; done | sort -rn | head -1 | cut -d" " -f2-); fi; [ -n "$M" ] && ID=$(basename "$M" .jsonl); _ccren() { T="$TMUX_PANE"; i=0; while [ $i -lt 40 ]; do sleep 0.5; C=$(tmux capture-pane -p -t "$T" 2>/dev/null); case "$C" in *"trust the files"*) tmux send-keys -t "$T" Enter; sleep 1; i=$((i+1)); continue;; esac; case "$C" in *"trust this folder"*) tmux send-keys -t "$T" Down; sleep 0.3; tmux send-keys -t "$T" Enter; sleep 1; i=$((i+1)); continue;; esac; case "$C" in *"shift+tab"*|*"for shortcuts"*) tmux send-keys -t "$T" "/rename $TITLE" Enter; return 0;; esac; i=$((i+1)); done; }; if [ -n "$ID" ]; then _ccren >/dev/null 2>&1 & claude --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions --resume "$ID"; else _ccren >/dev/null 2>&1 & claude --settings ~/.blink/statusline-settings.json --setting-sources project,local --model sonnet --dangerously-skip-permissions; fi; }"#

        // SSH agent socket 探测（tmux 继承，便于远端 git 等）。
        let detectSock = #"S=$(sh -c 'for p in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null) $TMPDIR/com.apple.launchd.*/Listeners /private/tmp/com.apple.launchd.*/Listeners $HOME/.ssh/agent.sock; do [ -S $p ] && { echo $p; break; }; done'); case x$S in x) ;; *) export SSH_AUTH_SOCK=$S; tmux set-environment -g SSH_AUTH_SOCK $S 2>/dev/null;; esac"#

        // 已存在的 tmux pane 不受 new-session -c 影响。服务器修改 workDir 后，
        // 旧 CLI 仍在原目录；只有重建 pane 才能让进程真正从新目录启动。
        // 目录一致时保留正在运行的 CLI，只修复退回 shell 的会话。
        let launch = #""$SHELL -lic 'source \#(bootFile); echo [blink] \#(agent.rawValue) 已退出，掉到 shell; exec $SHELL -il'""#
        let enforceDirectory = workDir.hasPrefix("/") ? "true" : "false"
        let heal = #"if tmux has-session -t \#(outerSession) 2>/dev/null; then D=$(cd \#(cd) 2>/dev/null && pwd -P); P=$(tmux display-message -p -t \#(outerSession) '#{pane_current_path}' 2>/dev/null); if \#(enforceDirectory) && [ -n "$D" ] && [ "$P" != "$D" ]; then tmux respawn-pane -k -t \#(outerSession) -c "$D" \#(launch); else PC=$(tmux display-message -p -t \#(outerSession) '#{pane_current_command}' 2>/dev/null); case "$PC" in zsh|bash|sh|dash|ksh|fish) tmux send-keys -t \#(outerSession) C-c; tmux send-keys -t \#(outerSession) "cd \#(cd) && source \#(bootFile)" Enter;; esac; fi; fi"#

        // -lic：登录+交互，确保 .zprofile/.zshenv 里的 PATH（claude 常装在 ~/.local/bin）加载进来。
        // 末尾 `; exec $SHELL -il`：claude 退出就掉到登录 shell，不整个塌掉、报错留屏。
        return #"""
\#(detectSock)
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
cat > \#(bootFile).$$ <<'BLINKBOOT'
\#(inner)
BLINKBOOT
mv -f \#(bootFile).$$ \#(bootFile)
\#(heal)
exec tmux new-session -A -s \#(outerSession) -c \#(cd) \#(launch)
"""#
    }
}
