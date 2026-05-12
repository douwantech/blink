---
title: ios_system 命令字符串 escape 陷阱
type: concept
created: 2026-05-12
updated: 2026-05-12
---

# ios_system 命令字符串 escape 陷阱

**问题简述**：Blink 内部用 `ios_system(cmdline)` (在 `Frameworks/ios_system/ios_system.m`) 把命令字符串切成 argv，然后查表分发给各个内置命令（`blink_ssh_main` 等）。argv tokenize 阶段对**以 `"` 或 `'` 开头的 token** 设 `dontExpand=true` 并跳过 env var / glob 展开，但**`unquoteArgument` 只剥外层引号一层**，内层 `\"` 字面保留。这个字面 `\"` 经 libssh 原样送到远端，远端 shell 把 `\"` 还原成 `"`——然后**在 sh -c 单引号脚本内部**，这些 `"` 变成字面 quote 字符进入 word，让 `[ -S \"$p\" ]` 实际查找路径 `"/tmp/..."`（带字面引号），永远 false。

## 触发条件（三层全中才出事）

1. Swift 端拼接 ssh 命令字符串时用 `\"` escape 双引号包住 remote command：
   ```swift
   return "ssh -t user@host \"\(remoteCmd)\""
   ```
   到 ios_system 时是字面 `ssh -t user@host "REMOTE_CMD_WITH_INNER_\"_CHARS"`。
2. `REMOTE_CMD` 里**也**用了 `\"` 给 zsh 看（为了在外层 `"..."` 里嵌入 `"`）。
3. 内层 zsh 看到的 cmd 字符串里把 `\"` 还原成 `"`，然后**整段又被 `sh -c '...'` 单引号包**送给子 sh。**子 sh 在单引号里把 `\"` 视为字面两字符 `\` 和 `"`**，sh 执行 `[ -S \"$p\" ]` 时：
   - `\"` → 字面 `"`
   - `$p` 展开
   - `\"` → 字面 `"`
   - 合并 word: `"<value of $p>"`（**带字面引号的 3+ 字符**）
   - `[ -S '"<path>"' ]` → 文件不存在 → false

## 别的相关陷阱（不一定踩到但相邻）

| 行为 | 在哪 | 怎么避开 |
|---|---|---|
| 把开头 `VAR=value` 段解析成 `ios_setenv` 并从 cmd 删 | `ios_system.m:2247-2261` | 命令以 `VAR=value` 开头时小心 |
| 解析 `>`, `>>`, `2>`, `<`, `&>`, `2>&1`、`|`、`|&` 切断 cmd 字符串、设 outputFileName 等 | `ios_system.m:2333-2497` | 这些符号写在 ssh argv 的双引号内是安全的（`strstrquoted` 跳过引号内）。但如果用 record separator (0x1e) 包 arg 也算 "quoted"。**没用引号包就一定被切**。 |
| argv 用空格切 + 引号 token 整体取 | `ios_system.m:2536-2561` | 以 `"`/`'` 开头的 token 整体取且 dontExpand=true |
| glob 展开（仅对 `dontExpand=false` 的 token） | `ios_system.m:2574-2599` | dontExpand 的 token 不展开。**但 GLOB_NOMATCH 时也不报错只保留原样**。 |
| splitCommandAndExecute 在 `&&` `||` 切，但**不切 `;`** | `ios_system.m:1495-1542` | `;` 分号串多个命令是**直接送整体**给被分发的命令（比如 ssh），由远端 shell 处理 |

## 推荐写法

**在 Swift 端拼接给 ssh 当 remote command 的脚本，避开任何 `\"`**。具体策略：

1. **不用引号字符** — 直接 `[ -S $p ]`、`echo $p`，依赖路径不含空格（Unix path 一般不含）
2. **用 `case` 替代 `[ -n "$STR" ]`** — POSIX `case` 不需要引号也能正确匹配空字符串：
   ```sh
   case x$S in
       x) ;;        # S 空
       *) ...      # S 非空
   esac
   ```
   `x$S` 这种 prefix 技巧避免 `[ -n $S ]` 在 S 空时变成 `[ -n ]`（一个 arg）的 corner case。
3. **glob 在 sh -c 子壳里跑**（macOS /bin/sh = bash POSIX 模式，glob 失败保留字面量、不报错），避免外层 zsh 的 `setopt nomatch` 整命令爆掉
4. **真要嵌字面引号字符做参数名**？用 base64 编码整段脚本：
   ```sh
   echo BASE64STRING | base64 -d | sh
   ```
   base64 字符集 `[A-Za-z0-9+/=]` 无任何特殊字符，逃过所有 escape 层。

## 实例：BlinkMachineStore 的 detect 脚本

最终能 work 的写法 (`Blink/SmarterKeys/BlinkMachineStore.swift:135`)：

```swift
let detectSock = #"S=$(sh -c 'for p in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null) $TMPDIR/com.apple.launchd.*/Listeners /private/tmp/com.apple.launchd.*/Listeners $HOME/.ssh/agent.sock; do [ -S $p ] && { echo $p; break; }; done'); echo $(date) S=$S >> /tmp/blink-detect.log 2>/dev/null; case x$S in x) ;; *) export SSH_AUTH_SOCK=$S; tmux set-environment -g SSH_AUTH_SOCK $S 2>/dev/null;; esac;"#
```

注意：**完全没有** `\"` 字符，所有 `$p` `$S` 都裸用。Swift `#"..."#` raw string + 远端 zsh 解析全程无引号 escape 链。

## 验证手段

session 里用了一个高产出的诊断技巧：让 detect 脚本第一步**写日志到 `/tmp/blink-detect.log`**（用 `echo $(date) S=$S >> /tmp/blink-detect.log 2>/dev/null`）。每次 Blink 新建 ssh tab 都会 append 一行。重启 Blink → tail 日志，看 S 是空还是有路径，能 1 秒区分是 detect 探测失败还是后续 export 失败。

## 相关页

- [Blink Mac SSH+tmux 二跳认证链路](blink-mac-ssh-tmux-chain.md) — 这个陷阱第一次浮出来的场景
