# Log

Append-only session log. One line per substantive op.

## [2026-05-12] handoff | wiki 初始化 + SSH_AUTH_SOCK / TabStateStore / ios_system escape

第一次 handoff。本次会话主要做了几件事：

- Tab 持久化重构 (`8ced29e7`)：单文件 `Documents/blink_tabs.json` + `TabStateStore` 单例，修「重启丢 tab」根因。详见 [blink-tab-persistence](blink-tab-persistence.md)。
- 语音面板粘贴按钮加分段选择 (`4ab20d80`)：剪贴板按空行切段多选粘贴。
- Tab bar 两行重排 (`6c707e8e`)：第一行控制按钮、第二行 tab 列表。
- 语音面板新增「上传图片」按钮：PHPicker 选图后 `UIPasteboard.general.image = ...`。
- **SSH+tmux 二跳认证修复（核心）**：detect 脚本探 `/tmp/ssh-*/agent.*` 并 export `SSH_AUTH_SOCK`、`tmux set-environment -g`。期间踩到 [ios_system escape 陷阱](ios-system-cmdline-escaping.md) 这个**强非派生**的坑——`\"` 在 ios_system 的 dontExpand argv 里字面保留到远端进 `sh -c '...'` 单引号脚本后变成字面引号字符。最终用 `case x$S in x) ;; *) ;; esac` + 不带引号的 `$p` `$S` 绕开整条 escape 链。完整背景见 [blink-mac-ssh-tmux-chain](blink-mac-ssh-tmux-chain.md)。
