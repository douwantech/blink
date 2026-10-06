# 出包指令（给 jack）

两条线各自独立，可以分别出。**① 是急件**（老板手机连 brain 弹确认框进不去）。

---

## ① Blink iOS 包 —— 治连 brain 弹主机密钥确认框

**PR #52 已合进 `deploy/blink-api-20261006`**（merge commit `c0ed0c48`）；依赖锁文件 PR #54 也已合（`fe5b116c`）。
不用再合，直接从 deploy 出包：

```bash
cd /Users/apple/Codes/Jack/blink
git fetch origin && git checkout -B build/ssh-hostkey origin/deploy/blink-api-20261006

# ① 工具链：用非 beta 的那份 Xcode（27 beta 会踩下面第三个坑）
ls -d /Applications/Xcode*.app                                          # 先看装了哪些
export DEVELOPER_DIR="/Applications/<非 beta 那份>.app/Contents/Developer"
xcodebuild -version                      # 必须是 26.x，不是 27 beta

# ② 依赖先落到独立目录（锁文件现在在仓库里，第一次跑会把钉住的版本 clone 下来）
xcodebuild -resolvePackageDependencies -project Blink.xcodeproj -scheme Blink \
  -clonedSourcePackagesDirPath /tmp/blink-spm
git -C /tmp/blink-spm/checkouts/purchases-ios describe --tags                  # 应为 5.92.0
git -C /tmp/blink-spm/checkouts/purchases-ios log --oneline -1 \
  -- Sources/Paywalls/PaywallColor.swift    # 含 870899891a（#6949）才算对

# ③ 出包：全新 dd（别复用旧的）+ 两个 flag 硬锁依赖
DEVID=<老板手机的 UDID>
xcodebuild -project Blink.xcodeproj -scheme Blink -destination "generic/platform=iOS" \
  -derivedDataPath /tmp/blink-dd-ssh \
  -clonedSourcePackagesDirPath /tmp/blink-spm \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=659T9VUN97 ENABLE_DEBUG_DYLIB=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  build

APP=/tmp/blink-dd-ssh/Build/Products/Debug-iphoneos/Blink.app
nm -g "$APP/Blink" | grep -c blink_ssh_main    # 必须 ≥1，否则 ssh 被 debug.dylib 弄坏，禁装
xcrun devicectl device install app --device "$DEVID" "$APP"
```

（想发 Release 就加 `-configuration Release`，APP 路径跟着变成 `Release-iphoneos`；
jack 一直出的是 Debug，这条没验证过，出急件就用默认。）

三个坑，都踩过：

1. **`ENABLE_DEBUG_DYLIB=NO` 不能漏**：这个包改的正是 ssh 那条路，dylib 一坏看起来就像这版把 ssh 弄挂了。
2. **团队 ID 必须显式覆盖**（`DEVELOPMENT_TEAM=659T9VUN97`）：6 个 target 硬编码官方 team。
3. **依赖必须锁住**：`project.pbxproj` 里依赖是 `upToNextMajorVersion`（SwiftCBOR 甚至是 `branch = master`），
   不锁的话**每台机解析出来的版本都不一样** —— 2026-10-06 出包两连败就是这么来的：解析到的 RevenueCat
   版本在 **Xcode 27 beta** 下编不过（`PaywallColor.swift: invalid redeclaration of synthesized memberwise
   init(stringRepresentation:)` + `CustomerCenterConfigData.swift: ambiguous use`），上游 #6949 才修，
   **5.92.0 是含该修复的版本**。所以：工具链用 26.x，依赖用上面那两个 flag 钉死；
   要升依赖就显式改仓库里那份 `Package.resolved`（#54 收进来的），别指望重新解析。
   两个 flag 的分工：`-disableAutomaticPackageResolution` 缺包就报错、绝不偷偷升级；
   `-onlyUsePackageVersionsFromResolvedFile` 只认那份锁文件。

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
