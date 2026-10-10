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
  private let boundKey = "BlinkServer.voiceInputPersonalBound"   // 已见个人版本下限（UInt64 文本）
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
  ///
  /// 两个判据是**分开**的，任一成立即保住本地未上传的个人改动：
  ///  1. `ownVersion` —— 本次回包正好是「我自己推的那一版」（previous+1）。精确，
  ///     但只在没有并发写入、也没有重试时成立；
  ///  2. `acknowledgedPersonal` —— 回包头 `X-Personal-Version` 的真值下限。并发另一台
  ///     设备写入（+2）或幂等重试（不 +1）时判据 1 落空，但拉回来的快照个人版本只要
  ///     没超过这个下限，就不含比本次上传更新的外部改动，本地改动必须留着、发了再采纳。
  static func keepPendingPersonal(localDirty: Bool, snapshotVersion: String,
                                  ownVersion: String?,
                                  acknowledgedPersonal: UInt64?) -> Bool {
    guard localDirty else { return false }
    if let ownVersion, snapshotVersion == ownVersion { return true }
    guard let acknowledgedPersonal, let incoming = personalComponent(snapshotVersion) else {
      return false
    }
    return incoming <= acknowledgedPersonal
  }

  /// 已见个人版本下限（只前进）。比它旧的快照回包一律不采纳。
  private var personalBound: UInt64? {
    get { defaults.string(forKey: boundKey).flatMap(UInt64.init) }
    set { defaults.set(newValue.map(String.init), forKey: boundKey) }
  }

  /// 记下「服务器已到这个个人版本」。
  ///
  /// 直接用**有效响应头** `X-Personal-Version`（那一刻服务端的真值），**不是**
  /// previous+1 —— 并发别的设备写入、或幂等重试回包时 +1 不成立，但头里的值仍然
  /// 是可靠下限。+1 只用来判断「这一版是不是我自己推的」（保护 pending-personal），
  /// 两件事分开。
  func noteAcknowledged(personalHeader: String?, username: String) {
    lock.lock(); defer { lock.unlock() }
    guard defaults.string(forKey: ownerKey) == username,
          let header = personalHeader, let incoming = UInt64(header) else { return }
    advanceBound(incoming)
  }

  /// 已见下限只前进。
  private func advanceBound(_ incoming: UInt64) {
    if let current = personalBound, current >= incoming { return }
    personalBound = incoming
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
      defaults.removeObject(forKey: boundKey)   // 已见下限也是上一个账号的
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
  /// than the seen personal version bound (an in-flight GET that started before our
  /// POST and landed after it, or two refreshes answering out of order) is ignored.
  /// Returns true when the snapshot was adopted.
  @discardableResult
  func adopt(_ remote: AccountVoiceInput?, version: String? = nil, username: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    prepareAccount(username)
    let incoming = Self.personalComponent(version)
    if let incoming, let bound = personalBound, incoming < bound { return false }
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
    // 采纳成功（正常 GET 也走这里）就把下限推到这份快照的版本：两个 refresh 乱序
    // 回包时，先到的那份（版本高）推高下限，后到的那份（版本低）就不会把状态退回去。
    if let incoming { advanceBound(incoming) }
    return true
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
