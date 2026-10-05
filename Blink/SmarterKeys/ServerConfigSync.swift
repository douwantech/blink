import Foundation
import Security
import SwiftUI

private struct ServerLoginResponse: Decodable {
  let token: String
  let user: ServerUser
}

private struct ServerUser: Codable {
  let id: UInt64
  let username: String
  let isAdmin: Bool
  let canWrite: Bool
}

private struct ServerSnapshot: Codable {
  let version: String
  let machines: [BlinkMachine]
  let tabs: TabState
  let recentSelection: [String: String]
  let agents: [String: String]
  let user: ServerUser
}

/// Server config is authoritative after login. The last full snapshot remains
/// available on disk when the API cannot be reached.
final class ServerConfigSync: ObservableObject {
  static let shared = ServerConfigSync()
  static let didApply = Notification.Name("ServerConfigSync.didApply")

  @Published private(set) var username: String?
  @Published private(set) var isOnline = false
  @Published private(set) var isLoading = false

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

  private func cachedSnapshot() -> ServerSnapshot? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    return try? JSONDecoder().decode(ServerSnapshot.self, from: data)
  }

  func restoreCachedSnapshot() {
    guard let snapshot = cachedSnapshot(),
          !hasSession || snapshot.user.username == username else { return }
    apply(snapshot, replaceTabs: true)
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
    if cachedSnapshot()?.user.id != login.user.id {
      try? FileManager.default.removeItem(at: cacheURL)
      defaults.removeObject(forKey: dirtyKey)
      defaults.removeObject(forKey: appliedVersionKey)
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

  @MainActor func refresh(replaceTabs: Bool = false, force: Bool = false, bearer: String? = nil) async throws {
    guard hasSession else { return }
    try await syncFromServer(replaceTabs: replaceTabs, force: force, bearer: bearer)
    schedulePendingUpload()
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
    if !force, let snapshot = cachedSnapshot(), snapshot.user.username == username {
      let version = snapshot.version
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
      let snapshot = try JSONDecoder().decode(ServerSnapshot.self, from: data)
      let directory = cacheURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: cacheURL, options: .atomic)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: cacheURL.path)
      apply(snapshot, replaceTabs: replaceTabs)
      isOnline = true
    } catch {
      isOnline = false
      if let snapshot = cachedSnapshot(), snapshot.user.username == username {
        apply(snapshot, replaceTabs: replaceTabs)
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
    defaults.removeObject(forKey: "BlinkServer.username")
    defaults.removeObject(forKey: appliedVersionKey)
  }

  private func apply(_ snapshot: ServerSnapshot, replaceTabs: Bool) {
    applying = true
    defer { applying = false }
    if let data = try? JSONEncoder().encode(snapshot.machines) {
      defaults.set(data, forKey: "BlinkMachineStore.machines")
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
    // On an active scene, the existing tab reconciliation observer reads the
    // mirror and merges remote additions/tombstones without replacing a live
    // terminal. First login has no live scene to reconcile, so seed the store.
    if replaceTabs && !retainLocalTabs {
      TabStateStore.shared.replaceFromServer(snapshot.tabs)
    }
    // 版本前进时个人配置（agents/selection）同样以服务器为准；只有服务器版本
    // 没动、本地确有未上传改动时才保留本地。
    if serverAdvanced || !localDirty {
      TabAgentStore.shared.replaceAll(snapshot.agents)
      if let machine = snapshot.recentSelection["machineId"], !machine.isEmpty {
        defaults.set(machine, forKey: "BlinkTabFilterMachineId")
      } else {
        defaults.removeObject(forKey: "BlinkTabFilterMachineId")
      }
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
    let selection = ["machineId": defaults.string(forKey: "BlinkTabFilterMachineId") ?? "",
                     "tabId": tabs.currentId?.uuidString ?? ""]
    let bodies: [(String, Data?)] = [
      ("tabs", try? JSONEncoder().encode(tabs)),
      ("selection", try? JSONEncoder().encode(selection)),
      ("agents", try? JSONEncoder().encode(TabAgentStore.shared.all))
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
