import Foundation

struct AccountVoiceInput: Codable, Equatable {
  var favorites: [String] = []
  var history: [String] = []
  var favoriteCounts: [String: Int] = [:]

  mutating func apply(_ op: AccountVoiceOperation) {
    switch op.kind {
    case "addFavorite":
      if !favorites.contains(op.text) { favorites.append(op.text) }
    case "removeFavorite":
      favorites.removeAll { $0 == op.text }; favoriteCounts.removeValue(forKey: op.text)
    case "clearFavorites": favorites = []; favoriteCounts = [:]
    case "useFavorite":
      if favorites.contains(op.text) { favoriteCounts[op.text, default: 0] += 1 }
    case "recordHistory":
      history.removeAll { $0 == op.text }; history.append(op.text)
      history = Array(history.suffix(40))
    case "removeHistory": history.removeAll { $0 == op.text }
    case "clearHistory": history = []
    default: break
    }
  }
}

struct AccountVoiceOperation: Codable {
  var id = UUID().uuidString
  let kind: String
  var text: String = ""
  var data: AccountVoiceInput? = nil
}

/// Protected local cache and durable edit queue. Server refreshes replay pending
/// edits instead of dropping them. Queue ownership survives logout and is reset
/// before another account can upload any of the previous account's data.
final class VoiceInputAccount {
  static let shared = VoiceInputAccount()
  static let didChange = Notification.Name("VoiceInputAccount.didChange")
  var onChange: (() -> Void)?
  private let defaults: UserDefaults
  private let lock = NSRecursiveLock()
  private let ownerKey = "BlinkServer.voiceInputOwner"
  private let migratedKey = "BlinkServer.voiceInputMigrated"
  private let queueKey = "BlinkServer.voiceInputOperations"
  private let ackedVersionKey = "BlinkServer.voiceInputAckedVersion"
  private let favoritesKey = "VoiceInputView.aiFavorites"
  private let historyKey = "VoiceInputView.aiHistory"
  private let countsKey = "VoiceInputView.aiFavoriteCounts"

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  /// Recognize only our own single version increment. Concurrent server edits
  /// still use the normal server-authoritative reconciliation.
  static func ownConfigVersion(previous: String?, personal: String?) -> String? {
    guard let parts = previous?.split(separator: ":"), parts.count == 2,
          let old = UInt64(parts[1]), let personal, let new = UInt64(personal),
          new == old + 1 else { return nil }
    return "\(parts[0]):\(new)"
  }

  /// personal 段（`"7:12"` → 12）。版本是 `"<shared>:<personal>"`（服务端 config.go 同形）。
  static func personalComponent(_ version: String?) -> UInt64? {
    guard let parts = version?.split(separator: ":"), parts.count == 2 else { return nil }
    return UInt64(parts[1])
  }

  /// 收藏 POST 推进的版本回包不能算「服务器前进」，否则本地还没上传的个人状态
  /// （休息开关 / agents）会被服务器快照盖掉。#101 的 keepPendingPersonal。
  static func keepPendingPersonal(localDirty: Bool, snapshotVersion: String,
                                  ownVersion: String?) -> Bool {
    guard localDirty, let ownVersion else { return false }
    return snapshotVersion == ownVersion
  }

  /// 记下「服务器已经到这一版了」。比它旧的快照回包不许再采纳 —— 一个在 POST
  /// 之前发出、POST 之后才回来的 GET（在途 refresh）会带着旧收藏，采纳回去就把
  /// 刚上传的结果冲掉了（review 指出的竞态）。
  func markAcknowledged(version: String?, username: String) {
    lock.lock(); defer { lock.unlock() }
    guard defaults.string(forKey: ownerKey) == username,
          let incoming = Self.personalComponent(version) else { return }
    if let current = Self.personalComponent(defaults.string(forKey: ackedVersionKey)),
       current >= incoming { return }
    defaults.set(version, forKey: ackedVersionKey)
  }

  var snapshot: AccountVoiceInput {
    lock.lock(); defer { lock.unlock() }
    return AccountVoiceInput(favorites: defaults.stringArray(forKey: favoritesKey) ?? [],
      history: defaults.stringArray(forKey: historyKey) ?? [],
      favoriteCounts: defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:])
  }

  private var queue: [AccountVoiceOperation] {
    get {
      guard let data = defaults.data(forKey: queueKey) else { return [] }
      return (try? JSONDecoder().decode([AccountVoiceOperation].self, from: data)) ?? []
    }
    set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: queueKey) } }
  }

  private func write(_ state: AccountVoiceInput) {
    defaults.set(state.favorites, forKey: favoritesKey)
    defaults.set(state.history, forKey: historyKey)
    defaults.set(state.favoriteCounts, forKey: countsKey)
    DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
  }

  func prepareAccount(_ username: String, previous: String? = nil) {
    lock.lock(); defer { lock.unlock() }
    let owner = defaults.string(forKey: ownerKey) ?? previous
    if let owner, owner != username {
      write(AccountVoiceInput()); queue = []
      defaults.set(false, forKey: migratedKey)
      defaults.removeObject(forKey: ackedVersionKey)   // 已确认版本也是上一个账号的
    }
    defaults.set(username, forKey: ownerKey)
  }

  func perform(_ kind: String, text: String = "") {
    lock.lock(); defer { lock.unlock() }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !kind.hasPrefix("clear") && trimmed.isEmpty { return }
    let op = AccountVoiceOperation(kind: kind, text: trimmed)
    var state = snapshot
    state.apply(op); write(state)
    var pending = queue; pending.append(op); queue = pending
    DispatchQueue.main.async { [weak self] in self?.onChange?() }
  }

  /// Only a null server document triggers legacy migration. An empty document
  /// is deliberate and must clear a newly signed-in device's old cache.
  ///
  /// `version` is the config version this snapshot was cut from. A snapshot older
  /// than what we already acknowledged (an in-flight GET that started before our
  /// POST and landed after it) is ignored outright.
  func adopt(_ remote: AccountVoiceInput?, version: String? = nil, username: String) {
    lock.lock(); defer { lock.unlock() }
    prepareAccount(username)
    if let stale = Self.personalComponent(version),
       let acked = Self.personalComponent(defaults.string(forKey: ackedVersionKey)),
       stale < acked {
      return
    }
    if !defaults.bool(forKey: migratedKey) {
      if remote == nil {
        // Pre-migration edits are already reflected in the local snapshot.
        queue = [AccountVoiceOperation(kind: "seed", data: snapshot)]
      }
      defaults.set(true, forKey: migratedKey)
    }
    var state = remote ?? queue.first(where: { $0.kind == "seed" })?.data ?? snapshot
    for op in queue { state.apply(op) }
    write(state)
  }

  func needsInitialSnapshot(username: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return defaults.string(forKey: ownerKey) != username || !defaults.bool(forKey: migratedKey)
  }

  func pending(username: String) -> [AccountVoiceOperation] {
    lock.lock(); defer { lock.unlock() }
    guard defaults.string(forKey: ownerKey) == username else { return [] }
    return Array(queue.prefix(100))
  }

  func acknowledge(_ sent: [AccountVoiceOperation], remote: AccountVoiceInput, username: String) {
    lock.lock(); defer { lock.unlock() }
    guard defaults.string(forKey: ownerKey) == username else { return }
    let ids = Set(sent.map(\.id))
    queue = queue.filter { !ids.contains($0.id) }
    var state = remote
    for op in queue { state.apply(op) }
    write(state)
  }

  func migrateLegacyCloud() {
    lock.lock(); defer { lock.unlock() }
    guard defaults.string(forKey: ownerKey) == nil else { return }
    let cloud = NSUbiquitousKeyValueStore.default
    if defaults.object(forKey: favoritesKey) == nil,
       let favorites = cloud.array(forKey: favoritesKey) as? [String] {
      defaults.set(favorites, forKey: favoritesKey)
      defaults.set(cloud.dictionary(forKey: countsKey) ?? [:], forKey: countsKey)
    }
    if defaults.object(forKey: historyKey) == nil,
       let history = cloud.array(forKey: historyKey) as? [String] { defaults.set(history, forKey: historyKey) }
  }
}
