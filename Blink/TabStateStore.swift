import Foundation

struct TabEntry: Codable, Equatable {
  let id: UUID
  var machineId: String?
  var workDirId: String?
  var tmuxSession: String?
  var useTmux: Bool?
  /// 工作目录的名字/路径快照。跨设备只传 workDirId，对端 workDirs 里没有这条（各设备
  /// 整份数组互相覆盖时很容易丢）就反查不到名字，tab 标题会退化成只剩会话名 ——
  /// 冗余这两个字段做兜底。老数据没有这俩字段 → decode 成 nil。
  var workDirName: String?
  var workDirPath: String?
  /// 用户手动改的标题。非空就直接用它当 tab 名，压过一切自动推导 ——
  /// 自动推导依赖本机能不能反查到 workDirId，改名不该受这个牵连。跟着 tab 一起同步到别的设备。
  var customTitle: String?
}

/// 一个 tab 的显示信息快照（本机 state 优先，缺的用 iCloud 同步值补）。
/// 空串表示没有，调用方 `?? ""` 链起来即可。
struct TabDisplaySnapshot {
  var workDirName = ""
  var workDirPath = ""
  var customTitle = ""

  var isEmpty: Bool { workDirName.isEmpty && workDirPath.isEmpty && customTitle.isEmpty }
}

struct TabState: Codable {
  var version: Int
  var tabs: [TabEntry]
  var currentId: UUID?
  var updatedAt: Double?   // epoch 秒；跨设备 last-writer-wins。老文件无此字段 → nil 视作 0
  var closedIds: [UUID]?   // 墓碑：被显式关闭的 tab id，跨设备传播删除。老文件 nil → 视作空

  init(version: Int = 1, tabs: [TabEntry] = [], currentId: UUID? = nil, updatedAt: Double? = nil, closedIds: [UUID]? = nil) {
    self.version = version
    self.tabs = tabs
    self.currentId = currentId
    self.updatedAt = updatedAt
    self.closedIds = closedIds
  }
}

final class TabStateStore {
  static let shared = TabStateStore()

  /// 镜像到 UserDefaults 的 key（CloudConfigSync 会把它同步到 iCloud，实现 tab 跨设备）。
  static let kSyncKey = "TabStateStore.syncState"

  private let fileURL: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("blink_tabs.json")
  }()

  private let ioQueue = DispatchQueue(label: "sh.blink.TabStateStore")
  private var pendingWork: DispatchWorkItem?
  private var dirty = false
  private(set) var state = TabState()

  /// 墓碑集合上限：只需撑到所有设备都看过这次删除即可，旧的丢掉无害
  ///（重建的 tab 会拿新 UUID，老墓碑不会误伤）。
  private let maxTombstones = 500

  private init() {
    load()
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      state = try JSONDecoder().decode(TabState.self, from: data)
    } catch {
      let ts = Int(Date().timeIntervalSince1970)
      let backup = fileURL.appendingPathExtension("corrupt.\(ts)")
      try? FileManager.default.moveItem(at: fileURL, to: backup)
      NSLog("[TabStateStore] decode failed (%@), backed up to %@", "\(error)", backup.lastPathComponent)
      state = TabState()
    }
  }

  func snapshot() -> TabState { state }

  func update(_ mutate: (inout TabState) -> Void) {
    let beforeTabs = state.tabs
    let beforeClosed = state.closedIds ?? []
    mutate(&state)
    // tabs 或墓碑真变了才刷新时间戳（切当前 tab 不算），供跨设备 last-writer-wins
    if state.tabs != beforeTabs || (state.closedIds ?? []) != beforeClosed {
      state.updatedAt = Date().timeIntervalSince1970
    }
    scheduleSave()
  }

  /// 记录被关闭的 tab（本机关，或采纳别处的关闭）：加入墓碑集合并从 tabs 移除。
  /// 墓碑随 state 一起同步到 iCloud，别的设备据此把这些 tab 也删掉 ——
  /// 杜绝「一台关了、另一台没删又用更新的时间戳把它推回来」的复活。
  /// 返回墓碑或 tabs 是否真的变了。
  @discardableResult
  func closeTabs(_ ids: [UUID]) -> Bool {
    guard !ids.isEmpty else { return false }
    let idset = Set(ids)
    var changed = false
    update { st in
      var closed = st.closedIds ?? []
      let existing = Set(closed)
      for id in ids where !existing.contains(id) { closed.append(id); changed = true }
      if closed.count > self.maxTombstones { closed.removeFirst(closed.count - self.maxTombstones) }
      st.closedIds = closed
      let beforeCount = st.tabs.count
      st.tabs.removeAll { idset.contains($0.id) }
      if st.tabs.count != beforeCount { changed = true }
    }
    return changed
  }

  func flushNow() {
    pendingWork?.cancel()
    pendingWork = nil
    guard dirty else { return }
    let snap = state
    ioQueue.sync { self.write(snap) }
  }

  private func scheduleSave() {
    dirty = true
    pendingWork?.cancel()
    let snap = state
    let work = DispatchWorkItem { [weak self] in
      self?.write(snap)
    }
    pendingWork = work
    ioQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
  }

  private func write(_ snap: TabState) {
    do {
      let data = try JSONEncoder().encode(snap)
      try data.write(to: fileURL, options: [.atomic])
      dirty = false
      mirrorToSync(snap)
    } catch {
      NSLog("[TabStateStore] write failed: %@", "\(error)")
    }
  }

  /// 一组 tab 里有没有「真实」tab（连了机器/工作目录/会话）。只有空白默认 shell 不算。
  private func hasRealTab(_ tabs: [TabEntry]) -> Bool {
    tabs.contains { $0.machineId != nil || $0.workDirId != nil || $0.tmuxSession != nil }
  }

  /// 把有真实 tab 的状态镜像到 UserDefaults（CloudConfigSync 会推到 iCloud）。
  /// 空列表、或只有空白默认 shell，都不镜像 —— 绝不覆盖云端别设备的真实列表。
  private func mirrorToSync(_ snap: TabState) {
    guard hasRealTab(snap.tabs) else { return }
    if let data = try? JSONEncoder().encode(snap) {
      UserDefaults.standard.set(data, forKey: Self.kSyncKey)
    }
  }

  /// 采纳 iCloud 同步来的 tab 列表。返回是否采纳（采纳后 SpaceController 需重建 tab 栏）。
  /// - 本机没有真实 tab（空 / 仅空白 shell）→ 直接采纳云端真实列表（新设备拿到别人的 tab）。
  /// - 本机有真实 tab → 仅当云端更新（时间戳更晚）且内容不同才采纳（last-writer-wins）。
  /// 不回推（值本就来自云端，避免时间戳 ping-pong）。
  @discardableResult
  func adoptSyncedIfNewer() -> Bool {
    guard let data = UserDefaults.standard.data(forKey: Self.kSyncKey),
          let synced = try? JSONDecoder().decode(TabState.self, from: data),
          hasRealTab(synced.tabs) else { return false }
    if hasRealTab(state.tabs) {
      guard (synced.updatedAt ?? 0) > (state.updatedAt ?? 0), synced.tabs != state.tabs else { return false }
    }
    // 整份采纳前，把本地已有的墓碑并进来（别丢本机关过的记录），并据此剔除云端可能还带着的已关 tab。
    let priorClosed = state.closedIds ?? []
    var newState = synced
    if !priorClosed.isEmpty {
      var merged = synced.closedIds ?? []
      let ex = Set(merged)
      for id in priorClosed where !ex.contains(id) { merged.append(id) }
      if merged.count > maxTombstones { merged.removeFirst(merged.count - maxTombstones) }
      newState.closedIds = merged
      let tomb = Set(merged)
      newState.tabs.removeAll { tomb.contains($0.id) }
    }
    state = newState
    let snap = newState
    ioQueue.async { [weak self] in
      guard let self else { return }
      if let d = try? JSONEncoder().encode(snap) { try? d.write(to: self.fileURL, options: [.atomic]) }
    }
    NSLog("[TabStateStore] 采纳 iCloud tab 列表：%d 个 tab", synced.tabs.count)
    return true
  }

  /// 只读 iCloud 同步来的 tab 列表，不改本地 state。
  /// 活跃设备增量合并用：只把云端新增的 tab 追加到 UI，不整份替换（避免打断当前操作）。
  func syncedTabs() -> [TabEntry] {
    guard let data = UserDefaults.standard.data(forKey: Self.kSyncKey),
          let synced = try? JSONDecoder().decode(TabState.self, from: data) else { return [] }
    return synced.tabs
  }

  /// tab id → 显示信息快照：本机 state 优先，缺的字段用 iCloud 同步值补。
  /// 云端刚追加、还没回写本机 state 的 tab 也能拿到名字，标题不会先闪一下只剩会话名。
  func displaySnapshots() -> [UUID: TabDisplaySnapshot] {
    var out: [UUID: TabDisplaySnapshot] = [:]
    func put(_ t: TabEntry) {
      var s = out[t.id] ?? TabDisplaySnapshot()
      // 非空字段覆盖，空的保留已有值（本机 state 后放，所以本机赢）
      if let v = t.workDirName, !v.isEmpty { s.workDirName = v }
      if let v = t.workDirPath, !v.isEmpty { s.workDirPath = v }
      if let v = t.customTitle, !v.isEmpty { s.customTitle = v }
      guard !s.isEmpty else { return }
      out[t.id] = s
    }
    syncedTabs().forEach(put)
    state.tabs.forEach(put)
    return out
  }

  /// 改某个 tab 的手动标题（传 nil / 空串清掉，恢复自动推导）。
  func setCustomTitle(_ title: String?, for id: UUID) {
    let t = (title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
    update { st in
      guard let i = st.tabs.firstIndex(where: { $0.id == id }) else { return }
      st.tabs[i].customTitle = t
    }
  }

  /// 只读 iCloud 同步来的完整状态（含墓碑 closedIds），不改本地 state。
  /// 活跃设备增量合并用：既要追加云端新 tab，也要采纳云端的关闭墓碑。
  func syncedState() -> TabState? {
    guard let data = UserDefaults.standard.data(forKey: Self.kSyncKey),
          let synced = try? JSONDecoder().decode(TabState.self, from: data) else { return nil }
    return synced
  }
}
