---
title: Blink Mac SSH+tmux 二跳认证链路
type: entity
created: 2026-05-12
updated: 2026-05-12
---

# Blink Mac SSH+tmux 二跳认证链路

iPhone Blink → ssh 到 Mac mini (xiaobai@172.16.3.31) → 自动 attach tmux → 在 tmux 里 ssh 到第二跳服务器（如 `root@114.55.28.149`）。这条链路有几个**互相牵制**的环节，每个都可能让二跳 ssh 失败。

## 各环节状态（截至 2026-05-12 确认 work）

| 环节 | 实际情况 | 容易踩的坑 |
|---|---|---|
| Blink 内部 ssh | 用 `BlinkSSH` (libssh) 而非 ios_system 自带 `ssh_main`；命令在 `Sessions/MCPSession.m` 通过 `ios_system(cmdline)` 入口 → 分发到 `blink_ssh_main` (`Blink/Commands/ssh/ssh.swift`) | argv tokenize 阶段对引号包的 arg 做 `dontExpand=true`，但 unquote 不递归 — 见 [ios_system escape 陷阱](ios-system-cmdline-escaping.md) |
| Mac mini 上 sshd 启动的 shell | non-interactive zsh；**无 `SSH_AUTH_SOCK`**、**无 `SECURITYSESSIONID`**；user login shell 是 zsh（prompt `%`） | non-interactive 仍跑 `.zshrc`，可能 echo `command not found: compdef` 噪音 |
| Mac mini tmux server | 由 `~/Library/LaunchAgents/com.user.tmux-blink.plist` 在 gui/uid 域启动 `tmux new-session -A -d -s blink-keep`，server 持有 GUI env (含有效 SECURITYSESSIONID)。Blink 进来用 `tmux new-session -A -s X` 走 attach 分支，新 window **继承 server env**。 | 如果用户在 Blink 里 `tmux kill-server` 然后让 Blink 重连，新 server 由 sshd shell env 启动，**SECURITYSESSIONID 又变空**——破坏 LaunchAgent 的修复。Restart server 必须在 Mac GUI Terminal 里做。 |
| `SSH_AUTH_SOCK` | Mac mini 上用户**手动**起了 `/usr/bin/ssh-agent`，socket 在 `/tmp/ssh-XXXX/agent.<pid>`。GUI Terminal 里 `echo $SSH_AUTH_SOCK` 看到这个路径，sshd shell 看不到（env 不继承）。 | macOS 14+ 没有自动 launchd ssh-agent。`launchctl getenv SSH_AUTH_SOCK` 在 sshd shell 里查的是 user/uid domain，**看不到 gui/uid domain**。需要 sshd shell 自己探。 |
| ssh-agent 里的 key | 仅当用户在 GUI Terminal 跑过一次 `ssh-add --apple-use-keychain ~/.ssh/<key>` 后才装载。该命令把 passphrase 存进 macOS keychain 并加 key 到 agent。 | macOS keychain 访问需要 GUI session 上下文（SECURITYSESSIONID 非空）。Claude Code 的 Bash 工具不在 GUI session 里，**不能**用 keychain unlock id_rsa 的 passphrase。 |
| 二跳服务器 (`root@114.55.28.149`) 接受的 key | 只接受 agent 里某把特定 key — `~/.ssh/id_xxx` 直接 sign 不被服务器接受（authorized_keys 不收录） | server 端 `Authentications that can continue: publickey` + `Offering public key: ...` 之后**没**`Server accepts key` → 路径错 |

## 修复（提交进 BlinkMachineStore.swift）

在 ssh 进入远端后、tmux 启动之前插入一段探测脚本，在 sshd shell 里**主动**找 `/tmp/ssh-*/agent.*` 并 export `SSH_AUTH_SOCK`，同时 `tmux set-environment -g` 让新建 window 继承。

完整脚本和 escape 注意见 [ios_system escape 陷阱](ios-system-cmdline-escaping.md)。

候选路径优先级（顺序重要）：

1. `/tmp/ssh-*/agent.*` — 手动起的 ssh-agent (Mac 上实际是这条)
2. `$TMPDIR/com.apple.launchd.*/Listeners` — macOS 14+ launchd 自动 agent
3. `/private/tmp/com.apple.launchd.*/Listeners` — macOS 13 及以下传统位置
4. `$HOME/.ssh/agent.sock` — 用户自维护稳定 symlink

## 已知 corner case

- **老 window 里 `SSH_AUTH_SOCK` 不更新**。`tmux set-environment -g` 只影响 server-global env，attach 时已存在的 window 里 shell 进程的 env 是它当初创建时的快照。修复：在那个 shell 里 `eval $(tmux show-env -s SSH_AUTH_SOCK)`，或直接 prefix+c 开新 window。
- **ssh-add 误报**：用户首次报问题是看到 `ssh-add: Could not open a connection to your authentication agent` 就以为 ssh 二跳废了。实际上**ssh client 可以绕过 agent**（macOS UseKeychain 配置 + 第一次输 passphrase 进 keychain 后），ssh-add 报错和 ssh 实际能否 work 是两码事。诊断时一定要直接试 `ssh -v <target>` 看 `Server accepts key` 这一行。
- **socket 文件存在但 ssh-agent 进程已死** — 看到 `/tmp/ssh-XXX/agent.<pid>` 不代表 agent 还活着。`ps -ef | grep ssh-agent` 看进程在不在。socket file 的 PID 后缀**不一定**等于 agent 进程的真 PID（macOS 上观察到 socket 是 34309 但实际 agent pid 是 12668，是同一个 agent，PID 后缀只是命名 hint）。

## 不在 Blink 控制范围、需用户在 Mac 端做的事

- 把要给二跳服务器用的 key 加进 agent：`ssh-add --apple-use-keychain ~/.ssh/<key>`（**在 Mac GUI Terminal 里**）
- LaunchAgent plist 在 gui/uid 起 tmux server（已存在 `~/Library/LaunchAgents/com.user.tmux-blink.plist`）
- 若想 restart tmux server：在 GUI Terminal 跑 `tmux kill-server && launchctl bootout gui/$(id -u)/com.user.tmux-blink && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.tmux-blink.plist`

## 文件指向

- ssh 命令构造：`Blink/SmarterKeys/BlinkMachineStore.swift:120-145` (`sshCommand(forMachineId:workDirId:tmuxSession:)`)
- 调用点：`Sessions/MCPSession.m:137,516`
- ssh client 实现：`Blink/Commands/ssh/ssh.swift` (`blink_ssh_main`)
