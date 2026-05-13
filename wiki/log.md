# Log

Append-only session log. One line per substantive op.

## [2026-05-12] handoff | wiki 初始化 + SSH_AUTH_SOCK / TabStateStore / ios_system escape

第一次 handoff。本次会话主要做了几件事：

- Tab 持久化重构 (`8ced29e7`)：单文件 `Documents/blink_tabs.json` + `TabStateStore` 单例，修「重启丢 tab」根因。详见 [blink-tab-persistence](blink-tab-persistence.md)。
- 语音面板粘贴按钮加分段选择 (`4ab20d80`)：剪贴板按空行切段多选粘贴。
- Tab bar 两行重排 (`6c707e8e`)：第一行控制按钮、第二行 tab 列表。
- 语音面板新增「上传图片」按钮：PHPicker 选图后 `UIPasteboard.general.image = ...`。
- **SSH+tmux 二跳认证修复（核心）**：detect 脚本探 `/tmp/ssh-*/agent.*` 并 export `SSH_AUTH_SOCK`、`tmux set-environment -g`。期间踩到 [ios_system escape 陷阱](ios-system-cmdline-escaping.md) 这个**强非派生**的坑——`\"` 在 ios_system 的 dontExpand argv 里字面保留到远端进 `sh -c '...'` 单引号脚本后变成字面引号字符。最终用 `case x$S in x) ;; *) ;; esac` + 不带引号的 `$p` `$S` 绕开整条 escape 链。完整背景见 [blink-mac-ssh-tmux-chain](blink-mac-ssh-tmux-chain.md)。

## [2026-05-12] snapshot | hterm alt screen 文本抓取陷阱

修语音面板"复制 Claude 回复"按钮时挖出的非派生知识。两个交织的坑：

- **SmarterTermInput 既是键盘 web view 又是终端 web view**——它继承 `KBWebView`（默认会加载 `kb.html`），但 `TermView.m:159/440` 显式 `loadFileURL:term.html` 把它覆盖了，所以 `evaluateJavaScript` 拿到的是 hterm 那个 web view。`window.t` 就是 `hterm.Terminal` 实例。
- **TUI 切到 alt screen 时 hterm 状态反直觉**：`term.screen_ === term.alternateScreen_` 为 true，但 `term.screen_.rowsArray.length === 0`、`term.alternateScreen_.rowsArray.length === 31` 同时成立；`scrollbackRows_` 也是空（alt 无 scrollback）。**真正可见的内容只在 DOM `x-row`**。检测 alt screen 后必须走 `document.querySelectorAll('x-row')`，不能信 hterm 内部 array。

详见 [blink-hterm-text-extraction](blink-hterm-text-extraction.md)。同一 session 还有图床上传（`210f097c` 已合并 origin/talkai）、状态栏底色对齐 tab bar、tab 两行间距 +4px 这几项轻量改动，已 build/烧机但**未 commit**，留给随后的 handoff。

## [2026-05-12] snapshot | macOS SSH key 进 Keychain（一次性修反复 push 失败）

`git push` 报 `Permission denied (publickey)`，Claude shell 里 `SSH_AUTH_SOCK` 空、`ssh-add -l` 拿不到 agent。`~/.ssh/config` 末尾全局 `AddKeysToAgent yes` + `UseKeychain yes` 配置都对，但**从没在 GUI Terminal 跑过 `ssh-add`**，所以 keychain 里查不到 `SSH:` 域 passphrase——这俩配置都是"先有一次交互种子"型，没种子全挂。一次 `ssh-add --apple-use-keychain ~/.ssh/id_rsa`（必须 GUI Terminal）后所有 ssh 调用都从 keychain 拿 passphrase，github + 远程 server 全通。push 完成：`210f097c..12fede68 → origin/talkai`（4 个 commit：状态栏底色 + tab 行间距 + 复制 alt-screen 修复 + 本次 wiki）。

详见 [macos-ssh-key-keychain](macos-ssh-key-keychain.md)。
