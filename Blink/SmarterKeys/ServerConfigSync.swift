import Foundation
import Security
import SwiftUI

private struct ServerLoginResponse: Decodable {
  let token: String
  let user: ServerUser
}

struct ServerUser: Codable {
  let id: UInt64
  let username: String
  let isAdmin: Bool
  let canWrite: Bool
}

struct ServerAIConfig: Codable {
  let userGlossary: String
  let voice: ServerVoiceConfig?
}

struct ServerVoiceConfig: Codable {
  let model: String
  let baseURL: String
  let apiKey: String
  let debounce: Double
}

struct ServerSnapshot: Codable {
  let version: String
  let machines: [BlinkMachine]
  // 共享书签（浏览器「后台」）。可选是刻意的：老缓存快照/老服务端没有这个字段 → nil，
  // 应用层据此保持本地清单不动；字段存在（哪怕是空数组）就是权威，照服务器顺序覆盖。
  let pinned: [PinnedTab]?
  // 解码前会被 ServerSnapshotDecoder 摘掉公用标签（`"shared": true`），所以这里只装
  // 账号自己的标签 —— `var` 就是为那一步留的。
  var tabs: TabState
  let recentSelection: [String: String]
  let agents: [String: String]
  let aiConfig: ServerAIConfig?
  let voiceCorrections: [String: [String: Int]]?
  let user: ServerUser
}

/// 服务端**读时注入**的全局公用标签（`"shared": true`，见 server/README.md「Public tabs」）。
/// 它们不是账号的数据：不进 `TabState`、不进任何持久化文件，只由 ServerConfigSync 单独持有、
/// 交给 UI 渲染。抽成独立类型的好处是「不回传、不落盘」由构造保证 —— 客户端的持久化只认
/// `TabEntry`，公用标签压根不在那个模型里。
struct SharedTab: Equatable {
  let id: UUID
  let machineId: String
  let tmuxSession: String
}

/// 只带 `shared` 这个键的原始条目。`TabEntry` 是合成 Codable，未知键会被静默丢掉，
/// 所以必须在解成 `TabEntry` 之前先按这个形状看一遍原始 JSON。
private struct RawServerTab: Decodable {
  let id: UUID
  let machineId: String?
  let tmuxSession: String?
  let shared: Bool?
}

/// 注意 `tabs` 是**两层**：外层是 `TabState`，标签数组在它的 `tabs` 里
///（`{"tabs":{"version":1,"tabs":[…]}}`）—— 少这一层就会整段解不出来（`try?` 吞掉后
/// 静默退回「一条公用标签都没看见」，正是最容易漏掉的那种污染）。单测钉着这一点。
private struct RawServerTabs: Decodable {
  struct State: Decodable {
    let tabs: [RawServerTab]
  }
  let tabs: State
}

/// `GET /v1/config` 的解码边界：把公用标签从快照里摘出来单独返回。
/// 这是唯一该做这件事的地方 —— 之后所有下游（kSyncKey 镜像、replaceFromServer、
/// 导出同步文件、uploadPersonal）拿到的 `TabState` 天然只有账号自己的标签。
enum ServerSnapshotDecoder {
  static func decode(_ data: Data) throws -> (snapshot: ServerSnapshot, shared: [SharedTab]) {
    var snapshot = try JSONDecoder().decode(ServerSnapshot.self, from: data)
    // 老服务端/老缓存没有 `shared` 键 → 原始形状解出来是空，快照原样返回。
    guard let raw = try? JSONDecoder().decode(RawServerTabs.self, from: data) else {
      // 解不出来就没法分辨哪些是公用标签，只能原样放行 —— 但这是「可能污染账号」的
      // 状态，必须留痕，别让服务端换了形状以后无声无息地回传。
      NSLog("[ServerConfigSync] 原始 tabs 解不出来，公用标签无法剥离（服务端响应形状变了？）")
      return (snapshot, [])
    }
    let sharedTabs = raw.tabs.tabs.filter { $0.shared == true }
    guard !sharedTabs.isEmpty else { return (snapshot, []) }
    let sharedIds = Set(sharedTabs.map { $0.id })
    // 服务端出口已经做过这两件事，这里是防线：账号自己的列表里不留公用副本，
    // 墓碑里也不留公用 ID（否则本地关一次就会把它记成「已关」回传回去）。
    snapshot.tabs.tabs.removeAll { sharedIds.contains($0.id) }
    snapshot.tabs.closedIds?.removeAll { sharedIds.contains($0) }
    let shared = sharedTabs.compactMap { tab -> SharedTab? in
      guard let machineId = tab.machineId, let tmuxSession = tab.tmuxSession else { return nil }
      return SharedTab(id: tab.id, machineId: machineId, tmuxSession: tmuxSession)
    }
    return (snapshot, shared)
  }
}

/// 服务器共享书签落地：写进浏览器侧真正读的那个 key（`PinnedTabsStore.tabs`，
/// PinnedTabsStore.shared.tabs 的存储），顺序 = 服务器数组顺序。
/// 抽成独立类型是为了能直接对「快照 → 后台列表」这一跳做单测。
enum ServerPinnedStore {
  static let defaultsKey = "PinnedTabsStore.tabs"

  static func apply(_ pinned: [PinnedTab], to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(pinned) else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}

/// Server config is authoritative after login. The last full snapshot remains
/// available on disk when the API cannot be reached.
final class ServerConfigSync: ObservableObject {
  static let shared = ServerConfigSync()
  static let didApply = Notification.Name("ServerConfigSync.didApply")

  @Published private(set) var username: String?
  @Published private(set) var isOnline = false
  @Published private(set) var isLoading = false
  /// 服务端注入的全局公用标签，服务端顺序（项目 → 员工）。只读影子：不落盘、不回传。
  @Published private(set) var sharedTabs: [SharedTab] = []

  private let baseURL: URL = {
    #if BLINK_PUBLISHING_OPTION_DEVELOPER
    // A simulator can point at an unavailable endpoint to exercise offline
    // cache and retry behavior without changing the production server.
    if let value = ProcessInfo.processInfo.environment["BLINK_CONFIG_SERVER_URL"],
       let url = URL(string: value) { return url }
    #endif
    return URL(string: "https://blink-api.douwantech.com")!
  }()
  private let tokenService = "com.douwantech.blink.config-server"
  private let tokenAccount = "session"
  private let defaults = UserDefaults.standard
  private let dirtyKey = "BlinkServer.personalDirty"
  // 上次完整采纳进本地的服务器版本（"global:personal"）。版本是服务器唯一的
  // 权威变更信号：本地 tab updatedAt 与服务器时钟不可比，不能用来判定新旧。
  private let appliedVersionKey = "BlinkServer.appliedVersion"
  private var applying = false
  private var isUploading = false
  private var activeRefreshes = 0
  private var foregroundPoll: Timer?
  private var uploadWork: DispatchWorkItem?

  private init() { username = defaults.string(forKey: "BlinkServer.username") }

  var hasSession: Bool { token != nil }
  var hasCachedSnapshot: Bool {
    if cachedSnapshot() != nil { return true }
    guard let data = defaults.data(forKey: "BlinkMachineStore.machines") else { return false }
    return !((try? JSONDecoder().decode([BlinkMachine].self, from: data))?.isEmpty ?? true)
  }

  private var token: String? {
    // kSecUseDataProtectionKeychain 必须显式打开：iOS-on-Mac（Designed for iPad）不指定时
    // SecItem 走 macOS 传统 file keychain，写入与读取可能落在不同分区——2026-10-05 晚
    // 老板在 Mac 上 11 次 login 200 后紧跟 GET config 401，就是 saveToken 刚写入、
    // 这里读回 nil，请求头拼成 "Bearer nil" 被服务器秒拒（「登录已过期」循环）。
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: tokenService,
                                kSecAttrAccount as String: tokenAccount,
                                kSecUseDataProtectionKeychain as String: true,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func saveToken(_ value: String) throws {
    // 与 token 读取同一套 query（含 data protection keychain 开关），写读分区必须一致。
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: tokenService,
                                kSecAttrAccount as String: tokenAccount,
                                kSecUseDataProtectionKeychain as String: true]
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = Data(value.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw NSError(domain: "BlinkServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法保存登录状态"])
    }
  }

  private var cacheURL: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("blink-server-config.json")
  }

  /// 上次落盘的完整快照（受保护文件；**含**公用标签的原始字节，供离线只读）。
  /// 走 ServerSnapshotDecoder：每次读回来都把公用标签摘出去，口径与在线刷新一致。
  private func cachedSnapshot() -> (snapshot: ServerSnapshot, shared: [SharedTab])? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    return try? ServerSnapshotDecoder.decode(data)
  }

  func restoreCachedSnapshot() {
    guard let cached = cachedSnapshot(),
          !hasSession || cached.snapshot.user.username == username else { return }
    apply(cached.snapshot, shared: cached.shared, replaceTabs: true)
  }

  @MainActor func login(username: String, password: String) async throws {
    isLoading = true
    defer { isLoading = false }
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/login"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard http.statusCode == 200 else {
      let message: String
      if http.statusCode == 401 { message = "用户名或密码错误" }
      else if http.statusCode == 429 { message = "尝试次数过多，请等 5 分钟后再登录" }
      else { message = "服务器暂时不可用（HTTP \(http.statusCode)）" }
      throw NSError(domain: "BlinkServer", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
    }
    let login = try JSONDecoder().decode(ServerLoginResponse.self, from: data)
    if cachedSnapshot()?.snapshot.user.id != login.user.id {
      try? FileManager.default.removeItem(at: cacheURL)
      defaults.removeObject(forKey: dirtyKey)
      defaults.removeObject(forKey: appliedVersionKey)
      // 换账号立即清掉旧账号的语音纠正词（跨账号隔离）。用 replaceTerms([:])
      // 而不是先清 key 再排上传：此刻 keychain 里还是旧账号
      // token，0.8s 后会把空词条写到旧账号名下（#43 e3cfe496）。
      AITextPolisher.shared.replaceTerms([:])
    }
    try saveToken(login.token)
    self.username = login.user.username
    defaults.set(login.user.username, forKey: "BlinkServer.username")
    defaults.set(login.user.isAdmin && login.user.canWrite, forKey: "BlinkServer.canWrite")
    // 登录成功即落袋：这里绝不能因 refresh 失败回滚 session。旧写法在 catch 里按
    // 「缓存不属于该用户」clearSession —— 首次登录缓存必然为空，条件恒真，网络
    // 抖动一下就把刚发的 token 删掉，用户被弹回登录页反复重登（2026-10-05 线上
    // 由此烧穿登录限流 429）。token 已存 Keychain，refresh 失败下次启动会重拉；
    // 若真是 401，syncFromServer 内部自己会 clearSession。
    // 首拉直接用响应里的 token（bearer 直传），不回读 Keychain：2026-10-05 Mac 端
    // Keychain 写读分区不一致时回读 nil，用户刚登录就撞「登录已过期」死循环。
    try await refresh(replaceTabs: true, force: true, bearer: login.token)
  }

  /// 退出登录（设置页「账号」段的入口）。清理语义与换账号时一致：清 Keychain token、
  /// 账号名、公用标签、已采纳版本号；**不动**已缓存的快照与机器/标签，所以离线仍能照旧
  /// 打开上次缓存，重新登录后 `login` 会 `refresh(replaceTabs: true)` 覆盖回来。
  /// 调用方（设置页）负责把登录页弹出来，这里只清状态。
  func logout() {
    clearSession()
  }

  @MainActor func refresh(replaceTabs: Bool = false, force: Bool = false, bearer: String? = nil) async throws {
    guard hasSession else { return }
    activeRefreshes += 1
    defer { activeRefreshes -= 1 }
    try await syncFromServer(replaceTabs: replaceTabs, force: force, bearer: bearer)
    schedulePendingUpload()
  }

  /// 两台设备都保持前台时也能看到对方改过的标签；版本未变时服务器只返回 304。
  @MainActor func startForegroundPolling() {
    guard foregroundPoll == nil else { return }
    foregroundPoll = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, UIApplication.shared.applicationState == .active,
              self.hasSession, !self.isUploading, self.activeRefreshes == 0,
              !self.defaults.bool(forKey: self.dirtyKey) else { return }
        try? await self.refresh()
      }
    }
  }

  /// GET /v1/config 并采纳。304 = 服务器版本未变；200 = 版本前进，apply() 里版本
  /// 优先采纳。这里故意不安排上传：uploadPersonal() 上传前也调本方法对齐版本，
  /// 若在这里 schedule 会互相触发成环。
  @MainActor private func syncFromServer(replaceTabs: Bool = false, force: Bool = false,
                                         bearer: String? = nil) async throws {
    // token 为 nil 时绝不发请求：Optional 插值会把请求头拼成 "Bearer nil"（3 字节，
    // 不是 64 hex），服务器必然 401，用户侧表现成「登录已过期」——2026-10-05 Mac
    // 登录循环就是这么来的。静默跳过，等下次启动/回前台有 token 再拉。
    guard let auth = bearer ?? token else { return }
    var components = URLComponents(url: baseURL.appendingPathComponent("v1/config"), resolvingAgainstBaseURL: false)!
    if !force, let cached = cachedSnapshot(), cached.snapshot.user.username == username {
      let version = cached.snapshot.version
      components.queryItems = [URLQueryItem(name: "version", value: version)]
    }
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      if http.statusCode == 304 {
        isOnline = true
        return
      }
      if http.statusCode == 401 {
        isOnline = false
        clearSession()
        throw NSError(domain: "BlinkServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "登录已过期，请重新登录"])
      }
      guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
      let decoded = try ServerSnapshotDecoder.decode(data)
      let directory = cacheURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // 缓存写的是服务器响应的原始字节（含公用标签）——离线冷启动时再解码一次即可
      // 复原同一份公用标签。它是「服务器说了算」的只读副本，不是用户状态。
      try data.write(to: cacheURL, options: .atomic)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: cacheURL.path)
      apply(decoded.snapshot, shared: decoded.shared, replaceTabs: replaceTabs)
      isOnline = true
    } catch {
      isOnline = false
      if let cached = cachedSnapshot(), cached.snapshot.user.username == username {
        apply(cached.snapshot, shared: cached.shared, replaceTabs: replaceTabs)
      }
      throw error
    }
  }

  private func clearSession() {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: tokenService,
                                kSecAttrAccount as String: tokenAccount,
                                kSecUseDataProtectionKeychain as String: true]
    SecItemDelete(query as CFDictionary)
    username = nil
    sharedTabs = []
    defaults.removeObject(forKey: "BlinkServer.username")
    defaults.removeObject(forKey: appliedVersionKey)
  }

  private func apply(_ snapshot: ServerSnapshot, shared: [SharedTab], replaceTabs: Bool) {
    applying = true
    defer { applying = false }
    // 公用标签只在这里更新，供 UI 渲染（SpaceController 监听 didApply）。
    // snapshot.tabs 已在解码边界摘干净，下面对它的每一次写都不会带上公用标签。
    sharedTabs = shared
    if let data = try? JSONEncoder().encode(snapshot.machines) {
      defaults.set(data, forKey: "BlinkMachineStore.machines")
    }
    // 共享书签：登录/刷新即有，全员同一份（管理员在后台维护）。服务器没带这个字段时
    // 不动本地 —— 离线兜底照旧靠缓存快照与 iCloud KV。
    if let pinned = snapshot.pinned {
      ServerPinnedStore.apply(pinned, to: defaults)
    }
    let localDirty = defaults.bool(forKey: dirtyKey)
    let localTabs = TabStateStore.shared.snapshot()
    let localTime = localTabs.updatedAt ?? 0
    let remoteTime = snapshot.tabs.updatedAt ?? 0
    // 版本优先：服务器版本相对上次采纳有前进（或本机首次采纳）时，服务器快照
    // 无条件生效 —— 管理员在服务端改的标签必须落到每一台手机上，本地时钟与
    // 服务器时钟不可比，updatedAt 比较拦不住这个场景。本地未上传的 pending
    // 此刻放弃（dirty 清掉），也绝不会被回传覆盖服务器（见 uploadPersonal）。
    let serverAdvanced = defaults.string(forKey: appliedVersionKey) != snapshot.version
    let retainLocalTabs = !serverAdvanced &&
      ((localDirty && localTime >= remoteTime) ||
        (!replaceTabs && localTime > remoteTime))
    if serverAdvanced {
      defaults.set(false, forKey: dirtyKey)
    }
    defaults.set(snapshot.version, forKey: appliedVersionKey)
    let selectedTabs = retainLocalTabs ? localTabs : snapshot.tabs
    if let data = try? JSONEncoder().encode(selectedTabs) {
      defaults.set(data, forKey: TabStateStore.kSyncKey)
    }
    // 以前这里还会把服务端的 tabs 播种进 TabStateStore（首次登录没有活跃场景可对账时）。
    // 自有标签已按老板口径彻底丢弃，这条播种也一并删掉：否则服务端那份**旧的**自有标签
    // 会被重新采纳、再被 uploadPersonal 回传，红线就破了。
    // 公用标签跟这条路径无关 —— 它们由 SpaceController._syncSharedTabs 直接从快照绑定。
    // 共享 AI 配置（全局词表）跟 machines 同级：服务器说了算，空值守卫让
    // 内置词表在离线/引导期保留（#43）。
    if let glossary = snapshot.aiConfig?.userGlossary, !glossary.isEmpty {
      AITextPolisher.shared.setSharedGlossary(glossary)
    }
    if let voice = snapshot.aiConfig?.voice {
      AITextPolisher.shared.applySharedEngineConfig(model: voice.model, baseURL: voice.baseURL, apiKey: voice.apiKey, debounce: voice.debounce)
    }
    // 版本前进时个人配置（agents/selection/语音纠正词）同样以服务器为准；只有
    // 服务器版本没动、本地确有未上传改动时才保留本地。voiceCorrections 是
    // 按账号隔离的个人数据，跟随 agents 的同一套版本采纳语义，不另发明规则。
    if serverAdvanced || !localDirty {
      TabAgentStore.shared.replaceAll(snapshot.agents)
      if let terms = snapshot.voiceCorrections {
        AITextPolisher.shared.replaceTerms(terms)
      }
      if let machine = snapshot.recentSelection["machineId"], !machine.isEmpty {
        defaults.set(machine, forKey: "BlinkTabFilterMachineId")
      } else {
        defaults.removeObject(forKey: "BlinkTabFilterMachineId")
      }
      // 公用标签休息名单回读（团队页月亮开关的服务端侧）：在岗集合随账号走，
      // 换设备登录也是同一份。**键不在（老账号/从未切过）不物化** —— 保持「默认只有
      // tom 在岗」的规则活着，别让空集把默认体验清掉；键在了才以服务端为准。
      // dirty（本地有未上传的开关改动）时**跳过**：uploadPersonal 上传前会对齐版本，
      // 服务器版本已被上一轮 PUT 推进 → 这里拉到的是上一轮值，覆盖掉会让本轮开关
      // 静默回弹且永不上传（2026-10-06 老板实测「休息的标签又显示出来」的根因）。
      if !defaults.bool(forKey: dirtyKey),
         let joined = snapshot.recentSelection["restSessions"] {
        SharedRestStore.shared.applyServer(joined)
      }
      // 以前这里还回读员工维度（BlinkTabFilterEmployee，给「员工×机器」二级筛选器用）。
      // 那个筛选器已按老板口径删掉，坞恒为 tom 的标签，这个键不再回读也不再上传。
    }
    if retainLocalTabs && !localDirty {
      defaults.set(true, forKey: dirtyKey)
    }
    defaults.set(snapshot.user.isAdmin && snapshot.user.canWrite, forKey: "BlinkServer.canWrite")
    NotificationCenter.default.post(name: Self.didApply, object: nil)
  }

  func schedulePersonalUpload() {
    guard !applying else { return }
    defaults.set(true, forKey: dirtyKey)
    schedulePendingUpload()
  }

  private func schedulePendingUpload() {
    guard hasSession, isOnline, defaults.bool(forKey: dirtyKey) else { return }
    uploadWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      Task { await self.uploadPersonal() }
    }
    uploadWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
  }

  @MainActor private func uploadPersonal() async {
    guard let token, isOnline, !isUploading, defaults.bool(forKey: dirtyKey) else { return }
    isUploading = true
    // 上传前先向服务器对齐版本：若服务器版本已前进（别处在服务端改过），apply()
    // 会采纳服务器快照并清掉 dirty，下面的 guard 直接退出 —— 本地旧快照永远不会
    // 回传覆盖服务器。只有确认服务器版本没动（304）才继续 PUT 本地改动。
    do { try await syncFromServer() }
    catch {
      isUploading = false
      isOnline = false
      return
    }
    guard defaults.bool(forKey: dirtyKey) else { isUploading = false; return }
    defaults.set(false, forKey: dirtyKey)
    defer {
      isUploading = false
      if isOnline { schedulePendingUpload() }
    }
    let tabs = TabStateStore.shared.snapshot()
    // selection 里只剩机器维度（Mac rail 的导航记忆）、当前 tab 与公用标签的休息名单
    // （restSessions：在岗的 tmuxSession 集合，逗号拼接 —— 团队页月亮开关的服务端持久化）。
    // 未物化（从未在团队页切过）**不带这个键**：传空集会把「默认 tom 在岗」覆盖成全休息。
    var selection = ["machineId": defaults.string(forKey: "BlinkTabFilterMachineId") ?? "",
                     "tabId": tabs.currentId?.uuidString ?? ""]
    if SharedRestStore.shared.loaded { selection["restSessions"] = SharedRestStore.shared.joinedActive }
    let bodies: [(String, Data?)] = [
      ("tabs", try? JSONEncoder().encode(tabs)),
      ("selection", try? JSONEncoder().encode(selection)),
      ("agents", try? JSONEncoder().encode(TabAgentStore.shared.all)),
      // 语音纠正词按账号隔离，随个人配置队列一起上传（#43）
      ("voice-corrections", try? JSONEncoder().encode(AITextPolisher.shared.termsPayload))
    ]
    for (path, body) in bodies {
      guard let body else { continue }
      var request = URLRequest(url: baseURL.appendingPathComponent("v1/config/\(path)"))
      request.httpMethod = "PUT"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
          defaults.set(true, forKey: dirtyKey); isOnline = false; return
        }
      } catch { defaults.set(true, forKey: dirtyKey); isOnline = false; return }
    }
    // PUT 成功后立刻对齐一次版本：服务器 version 已被这轮 PUT 推进，不拉回来的话
    // 下一轮上传前的 syncFromServer 会 200 全量、apply 误判 serverAdvanced。这次
    // 拉回来的就是刚传上去的内容（回读无感），appliedVersion 从此跟上，竞态消除。
    try? await syncFromServer()
  }
}

struct ServerLoginView: View {
  var onSuccess: () -> Void
  var onOffline: () -> Void
  @State private var username = ""
  @State private var password = ""
  @State private var error = ""
  @State private var busy = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("用户名", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("密码", text: $password).textContentType(.password)
        } header: { Text("团队账号") } footer: { Text("登录后自动获取共享机器和自己的标签布局。") }
        Section {
          Button(busy ? "正在登录…" : "登录 Blink 团队") {
            busy = true; error = ""
            Task {
              do { try await ServerConfigSync.shared.login(username: username, password: password); onSuccess() }
              catch { self.error = error.localizedDescription; busy = false }
            }
          }.disabled(busy || username.isEmpty || password.isEmpty)
          if ServerConfigSync.shared.hasCachedSnapshot {
            Button("离线使用上次缓存", action: onOffline)
          }
          if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
      }
      .navigationTitle("Blink 登录")
    }
  }
}
