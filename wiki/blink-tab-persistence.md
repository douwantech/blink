---
title: Blink Tab 持久化（TabStateStore）
type: entity
created: 2026-05-12
updated: 2026-05-12
---

# Blink Tab 持久化（TabStateStore）

`Blink/TabStateStore.swift` — 单例 + 单文件 `Documents/blink_tabs.json` 存所有 tab 的 id / machineId / workDirId / tmuxSession + 当前选中 id。

## 为什么是这个形状

历史上有过**三套并行**持久化：UserDefaults 三个 key (`BlinkViewportsKeys` / `BlinkCurrentViewportKey` / `BlinkViewportsMcpParams`) + JSON snapshot 文件 + NSUserActivity (UIStateRestorable)。每条写入路径都可能在出错时写半截脏状态进 UserDefaults / JSON，造成下次启动**只剩 1 个新 tab**——重启就丢标签的稳定再现 bug。

## 根因（commit `8ced29e7`）

`SpaceController.restore(withState:)` 在 NSUserActivity keys 空 + JSON 也读不到时，仍然走到这行：

```swift
_viewportsKeys = keys  // ← keys 是空数组也照样赋值
```

赋值触发 `_viewportsKeys.didSet` → `_writeViewportsSnapshotFile()` → **用空数组覆盖磁盘上原本好的 JSON**。然后 `viewDidLoad` 兜底走 `_newShellAction(animated: false)` → 再次写 1-tab JSON → 用户下次启动只看到 1 个 tab。

## 修复策略

- **单一真相源**：所有 tab 状态只走 `TabStateStore`（单 JSON 文件）。UserDefaults 三个 viewport key 全删。
- **不在恢复失败路径上写盘**：`TabStateStore.load()` decode 失败时**备份**原文件到 `.corrupt.<ts>` 而不是覆盖。
- **debounce 写盘**：state 变化标脏，250 ms 后合并写入。`willResignActive` / `didEnterBackground` 时 `flushNow()` 同步刷盘。
- **restore(withState:) 只接管 `bgColor`**：不再碰 keys，断掉根因路径。
- **`SessionRegistry.track(session:)` 提前到 `_viewportsKeys.insert` 之前**：避免 didSet 在 term 还没 track 时读到空 mcpParams 写脏 entry。

## 不动的部分

- **`SessionRegistry`**：自有 `~/Library/Application Support/sessions/index.json` + 每 session 一文件 (`<UUID>` 持久化档案)。subscript 永远不返回 nil，即使 _sessionsIndex / _metaIndex 都没该 key 也会**懒构造**一个空 suspended TermController。所以 tab 列表恢复后 `SessionRegistry.shared[key]` 永远拿得到 term，问题不可能在它这层。
- **`onDidDiscardSceneSessions`**：改成 no-op。SessionRegistry 自己 10 秒后 `_cleanLostSessions` 扫孤儿。

## 写入触发点

- `_viewportsKeys.didSet` → `_persistTabsToStore()` 把当前 keys 序列化进 store
- `_currentKey.didSet` → `TabStateStore.update { $0.currentId = ... }`（修了切换 tab 不持久化的潜在 bug）

## 恢复路径

`viewDidLoad`：
1. 如果 `_viewportsKeys.isEmpty` → `_restoreFromStore()`：从 store 读，先把每个 entry 的 MCPParams 灌给 TermController（`bindRestoredMcpParams`），再赋 `_viewportsKeys = keys`
2. 如果还是空 → `_newShellAction(animated: false)` 起初始 tab

## 不做兼容旧 UserDefaults 数据

用户明确说不需要顾老数据。第一次跑新版的用户会看到 tab 清空一次，之后正常。

## 文件指向

- 单例：`Blink/TabStateStore.swift`
- 集成：`Blink/SpaceController.swift:63-118` (`_viewportsKeys` / `_currentKey` didSet + `_persistTabsToStore` / `_restoreFromStore`)
