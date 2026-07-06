# blinkd — 交接文档

> 2026-07-06 · 分支 `feature/blinkd-local-daemon` · PR: https://github.com/douwantech/blink/pull/1

## 一句话
给 Blink 加一条**不走 SSH** 的连接通道:连一个常驻 Mac 本地的 daemon(`blinkd`),
终端和 agent 一直在本地跑、手机接管即可 —— 绕过 sshd / MDM 防火墙 / 远程登录。
Blink 本身是真终端渲染器,所以 claude 这类 alt-screen TUI 能原生流畅渲染
(cmux companion 那种"文本快照"方案做不到)。

---

## ⚠️ 最紧急的待办(未完成)
清理 cmux 调研现场时,`close-surface surface:N` 是**动态位置索引**,批量关时错位,
**误关了你正在跑 AI-Printer 的 jack-printer claude 会话**(进程被杀)。
- 对话没丢(claude 会话持久化在 `~/.claude/projects/`),恢复:
  ```
  cd ~/Codes/Jack && claude --resume   # 选回那个会话继续
  ```
- 在你确认恢复前,cmux 那边没再动过任何东西。
- 教训已记入长期记忆(以后清 cmux 用 UUID、不用 surface:N 批量关)。

---

## 已完成 ✅
- **Mac 端 daemon** `mac-daemon/`(Go):常驻 PTY 保活(替代 tmux)、256KB 回放缓冲
  (重连恢复画面)、token 握手、resize 帧、`-tsnet` 独立 tailscale 节点(绕 MDM 防火墙)、
  `-cmd` 指定 PTY 跑什么(zsh/claude)、shell 退出正确结束会话(不盲目重启)
- **iOS 端** `Sessions/BlinkdSession.{h,m}`:裸 TCP 会话(照 SSHSession 的 poll 骨架,
  去掉 libssh2);`MCPSession` 挂 `blinkd <host> <port> <token>` 命令。**未碰 ssh/mosh**
- **模拟器全自动 E2E 六项全过**:连接 / 命令执行 / 断线 / 重连回放 / PTY 保活 /
  **claude alt-screen TUI 原生渲染 + 键盘交互**
- **真机**:含 blinkd 的 Blink 已烧 iPhone 16(bundle `com.aitools.talkcode.stg`)
- **launchd 自启** `com.jack.blinkd.plist`:开机起 + KeepAlive + tsnet 复用授权自动上线
- **PR #1** 已建(base `talkai`);演示视频已传 OSS

---

## 当前运行状态
- **launchd daemon**:`com.jack.blinkd`,tsnet 节点 `blinkd` = **`100.96.88.80:7777`**,
  跑 `/bin/zsh`,token 见 `~/.config/blinkd-token.txt`(也写在 plist 里)
- tailscale 节点已授权(binku87 账号),Mac 重启后自动上线,手机直接能连
- 可能残留:临时 claude 实例 `127.0.0.1:7801`(录视频用,可 `pkill -f 'blinkd -port 7801'` 收掉)

## 怎么用(手机 Blink)
```
blinkd 100.96.88.80 7777 <token>      # token 见 ~/.config/blinkd-token.txt
```
连上即 Mac 的 zsh;想直接进 claude,改 plist 的 `-cmd` 为 claude 路径,或另起实例。

---

## 剩余:步骤 2(体验优化,可选)
1. **存配置 + 短命令**:host/port/token 存一次起别名,`blinkd mac` 一敲就连
2. **接自动重连**:让 Blink 断线自动重连认 blinkd(daemon 回放已就绪,只差 iOS 端接
   `MCPSession` 的 `_autoConnectCommand` 机制)
3. (可选)**多 session**:当前 daemon 所有连接共享一个 shell,可改成一连接一 shell
- 做法两档:轻量(存 Blink snippet,不改码) / 正式(加 blinkd host 配置 + 短命令解析)

---

## 关键命令 / 坑(务必看)
**编译 + 烧机 Blink**(命令行必带 `ENABLE_DEBUG_DYLIB=NO`,否则 ios_system 命令符号
进 debug.dylib 会全挂 → 连 ssh 都用不了):
```bash
cd /Users/apple/Codes/Jack/Blink
DEVID=1642527E-DE34-54F2-A1A8-FE606019CC60   # iPhone 16
xcodebuild -project Blink.xcodeproj -scheme Blink \
  -destination "platform=iOS,id=$DEVID" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=659T9VUN97 ENABLE_DEBUG_DYLIB=NO build
# 烧机前必验(见长期记忆 blink-dont-break-ssh):
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Blink-*/Build/Products/Debug-iphoneos/Blink.app | head -1)
nm -g "$APP/Blink" | grep -c blink_ssh_main   # 必须 ≥1,否则弄坏了 ssh
xcrun devicectl device install app --device "$DEVID" "$APP"
```

**daemon 编译/运行**:
```bash
cd mac-daemon && GOPROXY=https://goproxy.cn,direct go build -o blinkd .
./blinkd -tsnet -port 7777 -token <t> -cmd /bin/zsh      # tailscale 模式(需代理连控制面)
./blinkd -bind 127.0.0.1 -port 7799 -token <t>           # 本地/LAN 模式
```

**坑清单**:
- Blink 工程 6 个 target 硬编码官方 team `A2H2CL32AG`,命令行必须 `DEVELOPMENT_TEAM=659T9VUN97` 覆盖
- 构建失败后的增量残留会出半拉子包,怪异时清 `DerivedData` 全量重编
- daemon 二进制被 `.gitignore` 忽略,`go build` 现编
- **cmux `close-surface surface:N` 是动态索引,批量关会误伤 —— 只用 UUID 或逐个确认**

---

## 调研残留(blinkd 站住后可清,但小心)
- cmux 桌面 app(`/Applications/cmux.app`) —— **不能随便关**,你的 claude 在它的 surface 里跑
- cmux-companion(手机)、cmux 官方 iOS app(`dev.junbin.cmuxios`,手机)、GhosttyKit 下载
  (`scratchpad/cmux-src/GhosttyKit.xcframework` 537M) —— 确认不用了再删
