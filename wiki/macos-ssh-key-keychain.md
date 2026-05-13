---
title: macOS SSH key 进 Keychain —— 跨 Claude/tmux/Blink 二跳的钥匙
type: concept
created: 2026-05-12
updated: 2026-05-12
---

# macOS SSH key 进 Keychain —— 跨 Claude/tmux/Blink 二跳的钥匙

为什么 `git push` / 远程 `ssh` 在 Claude Code 这条链路里"用一下又不好用"，以及一次性修法。

## 症状

- 偶尔能 push 到 GitHub、能 ssh 到 server，过半天又突然 `Permission denied (publickey)`
- Claude Code 进程里 `SSH_AUTH_SOCK=` 是空，`ssh-add -l` 报 "Could not open connection to your authentication agent"
- 在 GUI Terminal 里跑同样命令又能用 —— 仿佛环境不一致

## 根因

`~/.ssh/config` 末尾有全局：
```
Host *
  AddKeysToAgent yes
  UseKeychain yes
```

两条都对，但都依赖**先有一次人机交互的种子**：

- `AddKeysToAgent yes` —— 第一次需要 key 时自动加到 agent，**前提**：当下有 agent socket
- `UseKeychain yes` —— 加 key 到 agent 时把 passphrase 一并存进 macOS Keychain，**前提**：交互输过一次 passphrase

如果从没在 GUI Terminal 里跑过 `ssh-add`，keychain 里 **`SSH:`** 域查不到 passphrase（`security find-generic-password -s "SSH:" -a ~/.ssh/id_rsa` returns "could not be found"）。这种状态下：

- 父 shell 有 SSH_AUTH_SOCK → 偶尔好用
- 父 shell 没 SSH_AUTH_SOCK（Blink → Mac → tmux 二跳进来的、Claude Code 子进程的）→ 没 agent + keychain 也没 passphrase → 全挂

Claude Code 的 env 是它启动那一刻冻结的；后来再起 agent 也注入不进 —— 这就是"用一下又不好用"的具体机制。

## 一步永久解

在 **macOS GUI Terminal** 里跑一次（passphrase 输入只有 controlling tty 接得到，tmux/Blink 套着的 shell 转不动 stdin）：

```bash
ssh-add --apple-use-keychain ~/.ssh/id_rsa
```

输一次 passphrase。完事。之后：

- 任何 ssh 调用即便 `SSH_AUTH_SOCK` 空、agent 没起，**macOS 的 ssh 客户端会直接从 keychain 取 passphrase 解密 id_rsa**。
- GitHub push、所有 `~/.ssh/config` 里的远程主机都通。
- Blink 二跳 → Mac → tmux 进来的 shell 也通（前提：tmux server 起在 gui domain，详见 [Mac 端 tmux LaunchAgent (memory)](../../../.claude/projects/-Users-apple-Codes-IPHONE-blink/memory/project_mac_tmux_launchagent.md)，否则 SACL 不让 access keychain item）。

## 为什么 Claude 自己不能跑

`ssh-add` 通过 `getpass(3)` 从 controlling tty 读 passphrase；Claude 跑在 Blink ssh + tmux 套层下，stdin 不是真正的 tty，密码读不到。一定要 GUI Terminal。

## 验证

执行后随便确认一下：

```bash
security find-generic-password -s "SSH:" -a /Users/<you>/.ssh/id_rsa
# 应该返回一条 attributes 记录，而不是 "could not be found"
```

然后从一个**完全没有 SSH_AUTH_SOCK** 的 shell 试：

```bash
env -i HOME=$HOME PATH=$PATH ssh -T git@github.com
# 应该返回 "Hi <username>! You've successfully authenticated..."
```

## 相关坑

- 如果 keychain 被锁（开机后没登录、或者锁屏太久某些策略下），keychain 取 passphrase 会失败 —— 解锁 keychain（输登录密码）就恢复。
- `id_rsa` 换 passphrase 后要 **重新** `ssh-add --apple-use-keychain` 一次。
- 不要 `rm ~/.ssh/known_hosts` 或乱改 config —— 真正的钥匙在 keychain 里，config 只是"怎么用"。
