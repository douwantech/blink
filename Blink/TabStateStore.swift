import Foundation

struct TabEntry: Codable, Equatable {
  let id: UUID
  var machineId: String?
  var workDirId: String?
  var tmuxSession: String?
  var useTmux: Bool?
}

struct TabState: Codable {
  var version: Int
  var tabs: [TabEntry]
  var currentId: UUID?
  var updatedAt: Double?   // epoch 秒；跨设备 last-writer-wins。老文件无此字段 → nil 视作 0

  init(version: Int = 1, tabs: [TabEntry] = [], currentId: UUID? = nil, updatedAt: Double? = nil) {
    self.version = version
    self.tabs = tabs
    self.currentId = currentId
    self.updatedAt = updatedAt
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
    let before = state.tabs
    mutate(&state)
    if state.tabs != before {   // tabs 真变了才刷新时间戳（切当前 tab 不算），供跨设备 last-writer-wins
      state.updatedAt = Date().timeIntervalSince1970
    }
    scheduleSave()
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
    state = synced
    let snap = synced
    ioQueue.async { [weak self] in
      guard let self else { return }
      if let d = try? JSONEncoder().encode(snap) { try? d.write(to: self.fileURL, options: [.atomic]) }
    }
    NSLog("[TabStateStore] 采纳 iCloud tab 列表：%d 个 tab", synced.tabs.count)
    return true
  }
}
