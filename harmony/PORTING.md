# Blink for HarmonyOS — iOS → 鸿蒙 移植功能清单

研究基准：`/Users/apple/Codes/Jack/blink`（Blink Shell 的 talkcode fork）。由 agent 深挖全仓源码产出。

## 🔑 关键发现：iOS 版本身就是 blinkd 架构
这个 iOS fork **早已把 SSH 换成了和鸿蒙版一样的 blinkd 传输**，围绕它建了"机器(machine) + 工作目录(workDir) + tmux 会话"模型。所以鸿蒙要"一模一样"，对照的是这套 **fork 架构**，不是 upstream Blink。传输层鸿蒙已经对齐（`BlinkdClient.ets` 4 帧齐全）。

iOS 运行链路（移植参照系）：
```
SpaceController (UIPageViewController，管 N 个 tab)
 └ TermController (1 tab = 1 终端)
    └ MCPSession (命令解释器) → BlinkMachine (目标机)
       → BlinkdSession (裸 TCP) → 远端 tmux new -A -s cc-<title>
```

## 鸿蒙现状 vs 缺口
| 已有 | 缺口 |
|---|---|
| tailscale + blinkd 传输（4 帧） | 只有 1 会话 1 tab（iOS 是多机器 × 多 tab） |
| 全屏黑终端 + 实时输入 + 青色 | **终端仿真器玩具级**（吞 ANSI，vim/tmux/htop 会花屏） |
| 一行 SmartKeys | iOS 分区 + 双字符轻扫 + 修饰键粘滞 + F1-F12 + trait 上下文 |
| ⚙ 设置(authKey/host/port) | 无 机器列表 / 主题 / 字体 / 快捷键 / 手势 |
| 单个 `blink:host` 标签 | iOS 机器 chip + 一排 `workDir:session` 标签 |

## P0 — 终端核心（决定能不能用 / 像不像）
1. **真 VT 终端仿真器**（当前最大缺口）：ANSI/CSI/SGR 颜色、光标寻址、擦除、滚动区、alt-screen（vim/htop/tmux 才不花屏）。iOS 用 **hterm**（`Resources/hterm_all.min.js` 塞 WKWebView，`Resources/term.js` 桥）。→ 鸿蒙建议 **ArkWeb 塞同款 hterm** 复用 term.js（hterm 只做渲染、数据由 app 从 blinkd 注入，不上网，不受 render 沙箱路由限制），一步到位；或写原生 VT 解析器。当前 `Terminal.ets` 是原生雏形但远不够。
2. **多 tab + 横滑切换 + 顶部标签栏**：`SpaceController.swift`（UIPageViewController + `_viewportsKeys:[UUID]`）；每 tab 一条独立 blinkd 连接；标签标题 = `workDir:session`。
3. **SmartKeys 完整**：`KBLayout.iPhone` 三区（esc/ctrl/alt/方向 | tab+双字符轻扫符号+F1-F12 | 方向/收键盘/cmd）；ctrl/alt/cmd **粘滞一次性开关**（先点 ctrl 再点 C）；trait 按屏幕方向/硬件键盘动态增删键。
4. **主题 / 字体 / 字号**【数据可直接搬】：5 套主题（Default/Flat/Monokai Light/Solarized/WWDC16，各 16 色 ANSI + 前景/背景/光标）`Resources/Themes/`；10 款字体 `Resources/Fonts/`（默认 JetBrains Mono）；字号 1-100（默认 iPhone 10）；粗体三态 + bold-as-bright + 光标闪烁。

## P1 — 多机器工作流
5. **机器/目标管理** `BlinkMachine{name,host,port,token}[]` + 机器条（`BlinkMachineStore.swift`）—— 单目标扩成列表。
6. **tmux 持久化 + workDir**：exec 帧拼 `tmux new -A -s cc-<t>`；workDir = `cd <path>`。断线重连不丢会话（daemon 侧无需改）。
7. **设置页**：Terminal 段（Style/Display/Keyboard/SmartKeys）+ Connect 段（机器列表）。
8. **手势**：横扫切 tab、捏合缩字号、长按选择、竖拖收键盘。
9. **tab 持久化**（`TabStateStore`/`blink_tabs.json`：存 `{machineId,workDirId,tmuxSession}` 列表）。
10. **Cmd 快捷键**（外接键盘：⌘T新tab/⌘W关/⌘⇧←→切tab/⌘↑↓切机器/⌘1-9选机器…）。

## P2 — 可选 / 后期
11. BlinkCode（`code`，需 blinkd Translator + 内嵌编辑器）
12. 文件访问（复用 `BlinkFiles.Translator/Local`，映射鸿蒙文件框架；FileProvider 不适用）
13. Snippets 片段库（本地 + GitHub）
14. Keys/ssh-agent（仅当要直连 SSH 才做）
15. 语音/AI dock、内嵌浏览器、FaceCam、Geo、WhatsNew（fork 差异化/边缘，按产品定位）
16. IAP/Build 云（Apple/RevenueCat 绑定，不适用）

## 不适用（blinkd 场景无意义）
- SSH Keys / ssh-agent（token 认证取代）
- **本地命令系统**（ssh/mosh/code/ls…）：鸿蒙终端直接进**远端 Mac 的真 shell**，不需要本地命令解释器——这是与 upstream 差异最大处
- FileProvider / IAP / Build 云（Apple 框架绑定）

## 关键源码索引（移植逐个对照）
- 多会话/标签：`Blink/SpaceController.swift`、`SessionRegistry.swift`、`TabStateStore.swift`、`Terminal/TermController.swift`
- 机器/tmux/标签栏：`Blink/SmarterKeys/BlinkMachineStore.swift`（含 `BlinkMachine`/`BlinkWorkDir`/`BlinkTabBar`/`FloatingMachineBar`）、`Sessions/MCPSession.m`、`Sessions/SessionParams.swift`
- blinkd 传输：`Sessions/BlinkdSession.m`、`mac-daemon/main.go`；鸿蒙已实现 `harmony/tsvpn/src/main/ets/blinkd/BlinkdClient.ets`
- SmartKeys：`Blink/SmarterKeys/{KBLayout,KBView,KBSection,KBKey,KBProxy,SmarterTermInput}.swift`、`KB/Native/Model/KBConfig.swift`
- 渲染/主题/字体：`Blink/Terminal/{TermView.m,TermDevice.m,TermJS.h}`、`Resources/{term.html,term.js,term.css,hterm_all.min.js,Themes/*,Fonts/*}`、`Settings/Model/TerminalStyleStore.swift`
- 设置/命令：`Settings/SettingsView.swift`、`Blink/Commands/*`
