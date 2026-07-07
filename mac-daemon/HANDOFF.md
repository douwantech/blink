# blinkd — 交接文档

> 2026-07-07 · 分支 `feature/blinkd-all-tabs` · PR #2: https://github.com/douwantech/blink/pull/2
> (步骤2 是 PR #1 `feature/blinkd-local-daemon`，步骤3/per-machine/修复都在 PR #2)

## 一句话
给 Blink 一条**不走 SSH** 的连接通道:手机 ←(tailscale)→ Mac 上常驻的 `blinkd` daemon ←PTY→ tmux+claude。
现在已做到「每台机器可单独选 SSH / Socket(blinkd)」，daemon 是 SSH 的**传输层替代**(远端 tmux+claude 逻辑原样复用)。

---

## ⚠️ 当前卡在这里(最重要)
**真机连生产 tsnet daemon `100.96.88.80:7777` 之前 `connect failed`，刚修完在等用户验证。**

- **根因**(已修 commit 08a14833):daemon 的 tsnet **没等上线就 `srv.Listen()`**，`TailscaleIPs()` 拿到 invalid IP，监听建在无效状态 → 真机 connect failed。之前偶尔能连是碰巧 tsnet 就绪。改成 `srv.Up(ctx)` 等上线再 Listen，日志从 `tsnet listening: invalid IP` 变 `tsnet ready: 100.96.88.80`。
- **为什么必须走 tsnet、不能改直连**:实测 **mac 防火墙拦物理接口入站数据**(daemon 常规监听时，`127.0.0.1:7777` 通，但 `192.168.0.29`/`100.90.240.27` 连上却收不到数据)。tsnet 是 userspace 网络栈、绕过内核防火墙,所以只能走 tsnet。要改直连得先 `sudo socketfilterfw` 放行(需用户密码,自动做不了)。
- **开发机测不了**:本机连自己的 tsnet IP 是回环、连不上,不代表真机(外部 tailnet)。所以真机能否连**只能靠用户测**。已重烧 iPhone16(内置 host 100.96.88.80)。
- **`command not found`**(次要,未根治):只在**连不上、自动重连**时冒出来(`blinkd: command not found`,像 ios_system 没识别 blinkd 命令 fall through)。连上就不出现。根因未定位——初始连接能识别 blinkd(会 connect failed)、重连时却 command not found,可疑但没查到。**优先让连接成功,连上后观察是否还有**。

---

## 架构(步骤3 后)
- **daemon** `mac-daemon/main.go`:**一连接一 PTY**(每 tab 一条连接一个独立 PTY,互不干扰) + **exec 帧(0x04)**(客户端握手时指定跑什么,如 `tmux new -A -s cc-<tab>`)。保活靠**远端 tmux**(连接断→PTY SIGHUP→tmux detach,会话在,重连再 attach),不再用 daemon 侧 ring。不发 exec 则跑默认 `-cmd`(向后兼容手动 `blinkd host port token`)。
- **iOS**:
  - `Sessions/BlinkdSession.m`:裸 TCP 会话;解析 `--exec <base64>` 发 exec 帧;`blinkd save/ls/rm <alias>` 别名(存 `blinkd_hosts.json`);`blinkd <host> <port> <token>` 手动直连。
  - `Blink/SmarterKeys/BlinkMachineStore.swift`:`BlinkMachine` 加 `transport`(ssh/blinkd)+`blinkdHost/Port/Token`;`blinkdCommand` 复用 `sshCommand` 的远端脚本 base64,只换传输层(`ssh -t` → `blinkd … --exec`);**机器编辑页(`MachineFormViewController`)加「连接方式」SSH/Socket 分段控件**。
  - `Sessions/MCPSession.m`:tab 自动连接 blinkd 优先、回退 ssh(两处:初次 + 重连)。**没碰 sshCommand,SSH 完好**。

## 连接方式怎么配(用户)
**设置(齿轮)→ 机器 → 点某台机器 → 「连接方式」选 SSH / Socket**。选 Socket 才显 daemon 地址/端口/token。
- **默认**:名为 `mac` 的机器(内置 `BLINKD_AUTO_MACHINE=mac`)默认走 Socket 且用内置 host/port/token(**留空即可**);其余机器默认 SSH。
- **内置默认值**在 gitignored 的 `developer_setup.xcconfig`(`BLINKD_AUTO_HOST/PORT/TOKEN/MACHINE`)→ Info.plist → 代码读。token 不进 git。
- 其他机器要走 Socket:那台得先跑 blinkd daemon,再在 UI 填它的地址/端口/token。

---

## 完成情况
- ✅ 步骤2:别名短命令 + 掉线自动重连(PR #1, commit ea6c8f04)
- ✅ 步骤3:daemon 一连接一 PTY + exec、iOS 全面切 blinkd(PR #2, d0801f0d/0d7a9aec)
- ✅ 内置默认值,装上即用(caea0a63)
- ✅ per-machine 连接方式 UI(76d95a0f)——模拟器全 E2E 过(mac 默认 Socket/xiaobai 默认 SSH、动态字段、保存进机器、重启按配置走)
- ✅ tsnet Up 修复(08a14833)
- ⏳ **真机连 tsnet 待用户验证**(见上"当前卡在这里")

## 当前运行状态
- launchd `com.jack.blinkd`,plist `~/Library/LaunchAgents/com.jack.blinkd.plist`(已同步 repo `mac-daemon/`),tsnet 节点 `blinkd`=`100.96.88.80:7777`,cmd `/bin/zsh`,token `2bfeae629f16eeac8e20769fed65675a`(也在 `~/.config/blinkd-token.txt`)。
- 改 daemon 后重启:`launchctl unload/load ~/Library/LaunchAgents/com.jack.blinkd.plist`(srv.Up 会等 tsnet 上线,启动慢几秒是正常的)。
- tailscale 是 binku87 账号;走 DERP relay(sfo/lax ~300-800ms),独立节点难直连,但 relay 够用(connectTo 超时 8s)。

---

## 关键命令 / 坑(务必看)
**编译+烧机**(命令行必带 `ENABLE_DEBUG_DYLIB=NO`,否则 ios_system 符号进 debug.dylib、连 ssh 都挂;设备离线用 `generic/platform=iOS` 出包):
```bash
cd /Users/apple/Codes/Jack/blink
DEVID=1642527E-DE34-54F2-A1A8-FE606019CC60   # iPhone 16
xcodebuild -project Blink.xcodeproj -scheme Blink -destination "generic/platform=iOS" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=659T9VUN97 ENABLE_DEBUG_DYLIB=NO build
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Blink-*/Build/Products/Debug-iphoneos/Blink.app | head -1)
nm -g "$APP/Blink" | grep -c blink_ssh_main    # 必须 ≥1,否则弄坏 ssh,禁装
xcrun devicectl device install app --device "$DEVID" "$APP"
```
**daemon**:`cd mac-daemon && GOPROXY=https://goproxy.cn,direct go build -o blinkd .`

**坑清单**:
- 6 个 target 硬编码官方 team,命令行必须 `DEVELOPMENT_TEAM=659T9VUN97` 覆盖。
- **mac 防火墙拦物理接口入站** → daemon 必须 tsnet(userspace 绕防火墙),别改常规监听。
- 模拟器测的是**本地 daemon**(`blinkd -bind 127.0.0.1 -port 7798`),连不上生产 tsnet(回环);真机才连生产 tsnet。
- daemon 二进制被 `.gitignore` 忽略,现编。
- 模拟器测试环境:把真机 Blink 配置(机器/标签)恢复到模拟器(关机时覆盖 plist 绕 cfprefsd)得到活会话,idb 输入才生效(见长期记忆 blink-sim-restore-from-device)。
