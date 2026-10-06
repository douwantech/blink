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
  var closedIds: [UUID]?   // 墓碑：被显式关闭的 tab id，跨设备传播删除。老文件 nil → 视作空

  init(version: Int = 1, tabs: [TabEntry] = [], currentId: UUID? = nil, updatedAt: Double? = nil, closedIds: [UUID]? = nil) {
    self.version = version
    self.tabs = tabs
    self.currentId = currentId
    self.updatedAt = updatedAt
    self.closedIds = closedIds
  }
}

/// 公用标签在 tab 集合里的排布规则：**公用恒在最前**（保持服务端顺序），自有在后。
/// 纯函数，独立成类型是为了能直接对「服务端顺序 → 屏幕顺序」这一跳做单测。
enum SharedTabLayout {
  /// 坞尾「我的标签 (N)」入口的标题。自有标签不再占坞里一格，只在这个入口的列表里。
  static let ownEntryTitle = "我的标签"

  static func ordered(shared: [UUID], own: [UUID]) -> [UUID] {
    shared + own
  }

  /// 落盘/上传前的那一刀：公用标签一律剔掉（它们不是账号的数据）。
  static func ownOnly(_ keys: [UUID], sharedKeys: Set<UUID>) -> [UUID] {
    keys.filter { !sharedKeys.contains($0) }
  }

  /// 坞里真正列出来的键：**一个平铺列表，只列公用标签** —— 不再分「公用标签 / 我的标签」
  /// 两节，自有标签收进坞尾的「我的标签」入口（它仍在滑动集合里，切得走也回得来）。
  static func dockKeys(_ keys: [UUID], sharedKeys: Set<UUID>) -> [UUID] {
    keys.filter { sharedKeys.contains($0) }
  }
}

/// 公用标签的「员工 × 机器」筛选。两个维度都来自服务端下发的标签本身：
/// 机器是结构化的 `machineId`，员工**不结构化** —— 只有 `tmuxSession` 的
/// 「员工-项目」前缀（`tom-ben` → `tom`），服务端就是这么造的（server/admin_tabs.go）。
struct SharedTabFilter: Equatable {
  /// 「显式选了全部」的哨兵值。存储层用它区分「没选过」（走默认 tom×brain）
  /// 和「我就是要看全部」（不过滤）—— 两者在 UserDefaults 里都是空串/缺键就分不开了。
  static let allValue = "*"
  static let defaultEmployee = "tom"
  /// 默认机器按**名字**解析，不把 UUID 字面量写进代码（本仓库是 PUBLIC 的）。
  static let defaultMachineName = "brain"

  var employee: String?     // nil = 全部员工
  var machineId: String?    // nil = 全部机器

  var isActive: Bool { employee != nil || machineId != nil }

  static let none = SharedTabFilter(employee: nil, machineId: nil)
}

enum SharedTabFilterModel {
  /// 从 tmuxSession 里取员工：第一个 "-" 之前（`tom-ben` → `tom`）。
  /// 服务端允许 employeeId 自带 "-"，那种情况这里会截短（见 README「Public tabs」的限制），
  /// 要精确得服务端给每条注入的标签补一个结构化 employeeId 字段。
  static func employee(ofTmuxSession session: String?) -> String? {
    guard let session, !session.isEmpty else { return nil }
    let head = session.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    guard let head, !head.isEmpty else { return nil }
    return head.lowercased()
  }

  static func matches(tmuxSession: String?, machineId: String?, filter: SharedTabFilter) -> Bool {
    if let want = filter.employee, employee(ofTmuxSession: tmuxSession) != want { return false }
    if let want = filter.machineId, machineId != want { return false }
    return true
  }

  /// 过滤后仍保持服务端给的顺序。
  static func visible(_ tabs: [SharedTab], filter: SharedTabFilter) -> [SharedTab] {
    tabs.filter { matches(tmuxSession: $0.tmuxSession, machineId: $0.machineId, filter: filter) }
  }

  /// 筛选器菜单里的员工项：按服务端顺序去重（第一个是见过的那个，稳定）。
  static func employees(in tabs: [SharedTab]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for t in tabs {
      guard let e = employee(ofTmuxSession: t.tmuxSession), seen.insert(e).inserted else { continue }
      out.append(e)
    }
    return out
  }

  /// 筛选器菜单里的机器项：只列**真有公用标签**的机器，顺序跟机器清单一致。
  static func machineIds(in tabs: [SharedTab], machineOrder: [String]) -> [String] {
    let present = Set(tabs.map(\.machineId))
    let ordered = machineOrder.filter { present.contains($0) }
    // 清单里没登记过的机器（服务器加了机器但本地还没同步到）也不该漏掉。
    let known = Set(ordered)
    var seen = known
    var extras: [String] = []
    for t in tabs where seen.insert(t.machineId).inserted { extras.append(t.machineId) }
    return ordered + extras
  }

  static func defaultMachineId(in machines: [BlinkMachine]) -> String? {
    machines.first { $0.name.caseInsensitiveCompare(SharedTabFilter.defaultMachineName) == .orderedSame }?.id
  }

  /// stored* 是 UserDefaults 里的原值：nil = 没选过（走默认），`*` = 显式全部，其余 = 该值。
  ///
  /// 兜底只针对「**没选过**的默认组合」：tom×brain 在别的部署/新账号上可能是空的，
  /// 那时候退化成不过滤（显示全部公用标签），绝不出现空坞。用户显式选出来的空组合
  /// 照用（尊重 ✓），由坞里的提示行兜底。
  static func resolve(storedEmployee: String?, storedMachineId: String?,
                      tabs: [SharedTab], machines: [BlinkMachine]) -> SharedTabFilter {
    let untouched = storedEmployee == nil && storedMachineId == nil
    let employee = storedEmployee == nil
      ? SharedTabFilter.defaultEmployee
      : (storedEmployee == SharedTabFilter.allValue ? nil : storedEmployee)
    let machineId = storedMachineId == nil
      ? defaultMachineId(in: machines)
      : (storedMachineId == SharedTabFilter.allValue ? nil : storedMachineId)
    let candidate = SharedTabFilter(employee: employee, machineId: machineId)
    if untouched, visible(tabs, filter: candidate).isEmpty { return .none }
    return candidate
  }

  /// ⋯ 菜单/坞上那颗筛选钮的文案：显示**实际生效**的那组（不是存下来的那组），
  /// 否则兜底之后会出现「菜单写 tom @ brain、坞里铺着 34 条」这种自相矛盾。
  static func title(_ filter: SharedTabFilter, machines: [BlinkMachine]) -> String {
    guard filter.isActive else { return "全部" }
    let emp = filter.employee ?? "全部"
    let machine = filter.machineId
      .flatMap { id in machines.first { $0.id == id }?.displayName } ?? "全部机器"
    return "\(emp) @ \(machine)"
  }
}

final class TabStateStore {
  static let shared = TabStateStore()

  /// 镜像到 UserDefaults 的 key（ServerConfigSync 据此与配置服务器同步 tab，跨设备）。
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
    ServerConfigSync.shared.schedulePersonalUpload()
  }

  func replaceFromServer(_ incoming: TabState) {
    pendingWork?.cancel()
    pendingWork = nil
    dirty = false
    state = incoming
    ioQueue.sync { self.write(incoming) }
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

  /// 把有真实 tab 的状态镜像到 UserDefaults（ServerConfigSync 上传时读它推到配置服务器）。
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

  /// 只读 iCloud 同步来的完整状态（含墓碑 closedIds），不改本地 state。
  /// 活跃设备增量合并用：既要追加云端新 tab，也要采纳云端的关闭墓碑。
  func syncedState() -> TabState? {
    guard let data = UserDefaults.standard.data(forKey: Self.kSyncKey),
          let synced = try? JSONDecoder().decode(TabState.self, from: data) else { return nil }
    return synced
  }
}
