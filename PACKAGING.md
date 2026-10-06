# 出包指令（给 jack）

两条线各自独立，可以分别出。**① 是急件**（老板手机连 brain 弹确认框进不去）。

---

## ① Blink iOS 包 —— 治连 brain 弹主机密钥确认框

**PR #52** · 分支 `fix/ssh-brain-host-key` · 提交 `b642e5f9`

先把 #52 合进 `deploy/blink-api-20261006`，再出包装机：

```bash
cd /Users/apple/Codes/Jack/blink
git fetch origin && git checkout deploy/blink-api-20261006 && git pull

DEVID=<老板手机的 UDID>
xcodebuild -project Blink.xcodeproj -scheme Blink -destination "generic/platform=iOS" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=659T9VUN97 ENABLE_DEBUG_DYLIB=NO build

APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Blink-*/Build/Products/Debug-iphoneos/Blink.app | head -1)
nm -g "$APP/Blink" | grep -c blink_ssh_main    # 必须 ≥1，否则 ssh 被 debug.dylib 弄坏，禁装
xcrun devicectl device install app --device "$DEVID" "$APP"
```

`ENABLE_DEBUG_DYLIB=NO` 这次尤其不能漏：这个包改的正是 ssh 那条路，
dylib 一坏看起来就像这版把 ssh 弄挂了。团队 ID 也必须显式覆盖（6 个 target 硬编码官方 team）。

### 验收（不用等老板，jack 自己就能查）

1. 手机上打开 Blink 任意标签，`cat ~/.ssh/known_hosts`
   → 应有三行 `47.237.122.99` 开头（首次启动自动写入）。
   **覆盖安装即可，不用重装**；不用重启也不用先连一次。
2. 点 brain 那个机器标签 → **不再弹** `The server is unknown. Do you trust the host key?`，
   直接进终端。
3. 反例自查：如果还弹，弹框期间**不该**再出现「连接卡住（12s 没连上），重连中…」。

### 这个包改了什么（简述）

- `BlinkPaths.ensureSeededKnownHosts`：启动时把 brain 的 ed25519 / ecdsa / rsa 三条公钥
  补进 `<home>/.ssh/known_hosts`（只补缺的；密钥真换了仍按 CHANGED 弹框问人）。
- `TermDevice.waitingForInput` + `MCPSession._armConnectWatchdogFor:`：正卡在交互提示上等
  用户输入时，12s 看门狗改为**重新计时**而不是掐会话。以后新增机器弹提示也不会被掐死。

---

## ② BlinkMac 二期包（BlinkMac + VoiceKey）

**PR #51** · 分支 `feature/mac-shared-tabs` · 提交 `77e811e7` / `9d4691eb` / `cadd3b89`

```bash
cd /Users/apple/Codes/Jack/blink
cd mac   && make app && make install    # 先出 BlinkMac
cd voice && make install                # 再出 VoiceKey
```

**顺序不能反**：`voice/Makefile install` 会 `rm -rf voice/dist` 并从 LaunchServices 注销重注册，
先出 VoiceKey 会把 BlinkMac 的注册冲掉（同 bundle id 两份 → 双击启到另一份、和正在跑的撞车闪退）。
两个都要 `xcodegen`；team `659T9VUN97`。

### 验收

- `BLINKMAC_DIAG=1` 打出 `LEAK shared_in_tabs=0 shared_in_closed=0`。
- 杀掉重开（走 **304** 路径）后公用标签**仍在**。
- `BLINKMAC_CHATSHOT=1` 出图：侧栏最上有「公用标签」节、行上有「公用」胶囊、右键菜单里没有
  休息/关闭；机器不在本机 rail 的公用行置灰。

第 2、3 项本机没有服务器 token 测不到，只能在老板 Mac 上过；第 1 项的 fixture 版本机能过
（见 PR #51 评论里的完整验收清单）。

---

## 边界

- ①是**治标**：只预置了 brain（`47.237.122.99`）这一个 host 拼写。若某台机器用 host2/内网名连，
  仍会弹一次；但看门狗那条已保证弹了也不会被掐死，用户按一次 Y 就会被 libssh 记进同一个
  known_hosts。根治方向：机器清单里带主机密钥/指纹、客户端读配置自动信任 ——
  `server/config.go` 的 `machine` 结构目前没有该字段。
- 两个包都**不含**任何凭据；`DEVID` 请按实际机器填，不要提交进仓库。
