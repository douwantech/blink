# Index

Catalog of wiki pages. See [CLAUDE.md](CLAUDE.md) for the schema.

## Concepts (platform gotchas / techniques)

- [ios_system 命令字符串 escape 陷阱](ios-system-cmdline-escaping.md) — `\"` 在 dontExpand argv 里字面保留到远端，进 sh -c 单引号脚本后变字面引号字符，让 `[ -S \"$p\" ]` 永远 false
- [hterm 文本抓取：alt screen vs primary + scrollback](blink-hterm-text-extraction.md) — TUI 切 alt screen 后 `term.screen_.rowsArray` 暴露为空，要走 DOM `x-row`；alt screen 没有 scrollback
- [macOS SSH key 进 Keychain](macos-ssh-key-keychain.md) — `git push` / 远程 ssh 在 Claude/tmux/Blink 二跳里"用一下又不好用"的根因，一次 `ssh-add --apple-use-keychain` 永久修

## Entities (subsystems / modules)

- [Blink Mac SSH+tmux 二跳认证链路](blink-mac-ssh-tmux-chain.md) — iPhone→Mac mini→tmux→二跳 ssh 的认证全景，detect 脚本探 SSH_AUTH_SOCK 的位置和原因
- [Blink Tab 持久化（TabStateStore）](blink-tab-persistence.md) — 单文件 JSON 单一真相源，修「重启丢 tab」根因（restore 用空数组覆盖 JSON）
