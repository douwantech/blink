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
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: tokenService,
                                kSecAttrAccount as String: tokenAccount,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func saveToken(_ value: String) throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: tokenService,
                                kSecAttrAccount as String: tokenAccount]
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
      let message = http.statusCode == 401 ? "用户名或密码错误" : "服务器暂时不可用（HTTP \(http.statusCode)）"
      throw NSError(domain: "BlinkServer", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
    }
    let login = try JSONDecoder().decode(ServerLoginResponse.self, from: data)
    if cachedSnapshot()?.user.id != login.user.id {
      try? FileManager.default.removeItem(at: cacheURL)
      defaults.removeObject(forKey: dirtyKey)
    }
    try saveToken(login.token)
    self.username = login.user.username
    defaults.set(login.user.username, forKey: "BlinkServer.username")
    defaults.set(login.user.isAdmin && login.user.canWrite, forKey: "BlinkServer.canWrite")
    do { try await refresh(replaceTabs: true, force: true) }
    catch {
      if cachedSnapshot()?.user.id != login.user.id { clearSession() }
      throw error
    }
  }

  @MainActor func refresh(replaceTabs: Bool = false, force: Bool = false) async throws {
    guard let token else { return }
    var components = URLComponents(url: baseURL.appendingPathComponent("v1/config"), resolvingAgainstBaseURL: false)!
    if !force, let snapshot = cachedSnapshot(), snapshot.user.username == username {
      let version = snapshot.version
      components.queryItems = [URLQueryItem(name: "version", value: version)]
    }
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      if http.statusCode == 304 {
        isOnline = true
        schedulePendingUpload()
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
      schedulePendingUpload()
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
                                kSecAttrAccount as String: tokenAccount]
    SecItemDelete(query as CFDictionary)
    username = nil
    defaults.removeObject(forKey: "BlinkServer.username")
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
    let retainLocalTabs = (localDirty && localTime >= remoteTime) ||
      (!replaceTabs && localTime > remoteTime)
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
    if !localDirty {
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
