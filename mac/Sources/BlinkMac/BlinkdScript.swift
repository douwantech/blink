import Foundation

/// 远程 exec 脚本生成——逐字复刻 blink `BlinkMachineStore.sshCommand` 的 tmux 分支：
/// 外层 `tmux new-session -A -s cc-<TITLE>` 里跑 resume-or-new 的 claude，
/// 从 ~/.claude/projects 反查 customTitle 直接 resume，找不到就起新会话并
/// send-keys `/rename` 自动命名；attach 到坏 session 时 heal 自愈重 source。
enum BlinkdScript {

    static let bootPath = "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    /// attach 到一个已存在的 tmux 会话（枚举出来的真实 cc-<TITLE>），不重跑 boot。
    static func attach(_ tmuxName: String) -> String {
        let q = "'" + tmuxName.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(bootPath); exec tmux attach -t \(q)"
    }

    /// 枚举本机所有 tmux 会话：name<TAB>active-pane-path，每行一个。
    static func listSessions() -> String {
        "\(bootPath); tmux list-sessions -F '#{session_name}\t#{pane_current_path}' 2>/dev/null"
    }

    /// blinkd exec 帧的 payload（daemon 会 `/bin/bash -c "<payload>"`）。
    static func tmuxClaude(title: String, workDir: String) -> String {
        let outerSession = "cc-\(title)"
        let cd = "'" + workDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let bootFile = "/tmp/.blink-boot-\(outerSession).sh"

        // inner 被外层 `$SHELL -lic '...'` 单引号包裹，里面只能用双引号；TITLE 预先算好。
        let inner = #"cd \#(cd) && { CUR=$(pwd | sed "s:[/.]:-:g"); PROJ="$HOME/.claude/projects/$CUR"; TITLE="\#(title)"; ID=""; if [ -d "$PROJ" ]; then M=$(find "$PROJ" -maxdepth 1 -name "*.jsonl" -type f -exec grep -lF "\"customTitle\":\"$TITLE\"" {} + 2>/dev/null | head -1); [ -n "$M" ] && ID=$(basename "$M" .jsonl); fi; if [ -n "$ID" ]; then claude --dangerously-skip-permissions --resume "$ID"; else if [ -n "$TMUX" ]; then (sleep 1.5; tmux send-keys "/rename $TITLE" Enter) >/dev/null 2>&1 & claude --dangerously-skip-permissions; else TN="cc-$TITLE"; (sleep 1.5; tmux send-keys -t "$TN" "/rename $TITLE" Enter) >/dev/null 2>&1 & tmux new-session -A -s "$TN" "$SHELL -ic \"claude --dangerously-skip-permissions\""; fi; fi; }"#

        // SSH agent socket 探测（tmux 继承，便于远端 git 等）。
        let detectSock = #"S=$(sh -c 'for p in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null) $TMPDIR/com.apple.launchd.*/Listeners /private/tmp/com.apple.launchd.*/Listeners $HOME/.ssh/agent.sock; do [ -S $p ] && { echo $p; break; }; done'); case x$S in x) ;; *) export SSH_AUTH_SOCK=$S; tmux set-environment -g SSH_AUTH_SOCK $S 2>/dev/null;; esac"#

        // attach 到只剩裸 shell 的坏 session 时，重 source boot 文件自愈（重 cd + resume）。
        let heal = #"if tmux has-session -t \#(outerSession) 2>/dev/null; then PC=$(tmux display-message -p -t \#(outerSession) '#{pane_current_command}' 2>/dev/null); case "$PC" in zsh|bash|sh|dash|ksh|fish) tmux send-keys -t \#(outerSession) C-u; tmux send-keys -t \#(outerSession) " source \#(bootFile)" Enter;; esac; fi"#

        // -lic：登录+交互，确保 .zprofile/.zshenv 里的 PATH（claude 常装在 ~/.local/bin）加载进来。
        // 末尾 `; exec $SHELL -il`：claude 退出就掉到登录 shell，不整个塌掉、报错留屏。
        return #"""
\#(detectSock)
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
cat > \#(bootFile) <<'BLINKBOOT'
\#(inner)
BLINKBOOT
\#(heal)
exec tmux new-session -A -s \#(outerSession) $SHELL -lic 'source \#(bootFile); echo "[blink] claude 已退出，掉到 shell（上方有报错即原因，敲 claude 重试）"; exec $SHELL -il'
"""#
    }
}
