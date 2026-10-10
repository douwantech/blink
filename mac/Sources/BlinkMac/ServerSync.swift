import Foundation
import SwiftUI
import AppKit

// 服务器同步（Blink 原生 Mac 版，2026-10-05 老板拍板弃 iCloud 后的 Mac 落地）。
//
// iOS 端 ServerConfigSync（Blink/SmarterKeys/ServerConfigSync.swift）已把配置服务器
// (blink-api.douwantech.com) 设为唯一权威：管理员维护机器与公用标签清单，
// Mac 按同一快照展示团队和标签，并把个人休息名单、模型选择写回服务器。
//   login → GET /v1/config → 快照整份写进 ~/.blink/sync/blink_config.json
//     （machines / sharedTabs / recentSelection / agents）。公用标签与个人标签分开保存。
// watchSyncFile() 盯目录变更后刷新 UI；离线时使用上次快照。
//
// token 存 UserDefaults 而非 Keychain：SPM dev 版（swift run）无 entitlement，
// dataProtection keychain 会 errSecMissingEntitlement，出现「存了读不回」；正式版也没配
// keychain-access-groups。Preferences 目录 0700 用户级保护，与 ~/.secrets 同级强度。
final class ServerSync: ObservableObject {
  static let shared = ServerSync()

  @Published private(set) var username: String?
  @Published private(set) var isOnline = false
  @Published private(set) var isLoading = false

  private let baseURL = URL(string: "https://blink-api.douwantech.com")!
  private let defaults = UserDefaults.standard
  private let tokenKey = "BlinkServer.token"
  private let userKey = "BlinkServer.username"
  private let versionKey = "BlinkServer.appliedVersion"
  private var updatingPersonal = false
  private var activeRefreshes = 0
  private var foregroundPoll: Timer?
  private var voiceUploadWork: DispatchWorkItem?
  private var uploadingVoiceInput = false
  private let voiceCore = VoiceSyncCore.shared

  var hasSession: Bool { defaults.string(forKey: tokenKey) != nil }

  private init() {
    username = defaults.string(forKey: userKey)
    VoiceInputAccount.shared.migrateLegacyCloud()
    VoiceInputAccount.shared.onChange = { [weak self] in self?.scheduleVoiceInputUpload() }
  }

  private struct SyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  // MARK: - API

  @MainActor func login(username: String, password: String) async throws {
    isLoading = true
    defer { isLoading = false }
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/login"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if http.statusCode == 401 { throw SyncError(message: "用户名或密码错误") }
    if http.statusCode == 429 { throw SyncError(message: "尝试次数过多，请等 5 分钟后再登录") }
    guard http.statusCode == 200 else { throw SyncError(message: "服务器暂时不可用（HTTP \(http.statusCode)）") }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = obj["token"] as? String,
          let user = obj["user"] as? [String: Any],
          let name = user["username"] as? String else { throw SyncError(message: "登录响应异常") }
    VoiceInputAccount.shared.prepareAccount(name, previous: username)
    defaults.set(token, forKey: tokenKey)
    defaults.set(name, forKey: userKey)
    self.username = name
    defaults.removeObject(forKey: versionKey)   // 重登/换账号：下次全量拉
    await refresh()
  }

  @MainActor func logout() {
    voiceUploadWork?.cancel()
    defaults.removeObject(forKey: tokenKey)
    defaults.removeObject(forKey: userKey)
    defaults.removeObject(forKey: versionKey)
    username = nil
    isOnline = false
  }

  /// 有 session 就拉一次（启动 / 回前台 / 登录后）。带上次采纳的 version：304 = 服务器
  /// 没变，跳过落盘（也不必触发 reload）。token 失效（401）清 session，下次启动弹登录。
  @MainActor func refresh() async {
    guard defaults.string(forKey: tokenKey) != nil else { return }
    activeRefreshes += 1
    defer { activeRefreshes -= 1 }
    switch await fetchAndApply() {
    case .ok: isOnline = true
    case .notModified: isOnline = true
    case .unauthorized:
      defaults.removeObject(forKey: tokenKey)
      username = nil
      isOnline = false
    case .offline: isOnline = false   // 网络不通：读链路还有 sync 文件 / KV 兜底，静默
    case .noSession: break
    }
    scheduleVoiceInputUpload()
  }

  private func scheduleVoiceInputUpload() {
    guard hasSession, isOnline, let username,
          !VoiceInputAccount.shared.pending(username: username).isEmpty else { return }
    voiceUploadWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      Task { @MainActor in await self?.uploadVoiceInput() }
    }
    voiceUploadWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
  }

  @MainActor private func uploadVoiceInput() async {
    guard !uploadingVoiceInput, let bearer = defaults.string(forKey: tokenKey), let account = username else { return }
    // Mac 的个人配置是直写（setAgent / setResting 立即 PUT），没有离线队列要预推；
    // 共享序列的让位 / 记下限 / ack 步骤与 iOS 跑的是同一份 VoiceSyncCore。
    voiceCore.pendingPersonal = false
    let uploadingBefore = uploadingVoiceInput
    let before = defaults.string(forKey: versionKey)
    uploadingVoiceInput = true
    defer { uploadingVoiceInput = false }
    let outcome = await voiceCore.runUpload(
      username: account,
      activeRefreshes: activeRefreshes,
      uploading: uploadingBefore,
      pending: { VoiceInputAccount.shared.pending(username: account) },
      uploadPersonalIfNeeded: {},
      post: { [weak self] ops in
        guard let self else { throw URLError(.cancelled) }
        return try await self.postVoiceInput(ops, bearer: bearer)
      },
      acknowledge: { ops, document, _ in
        VoiceInputAccount.shared.acknowledge(ops, remote: document, username: account)
      })
    switch outcome {
    case .uploaded(let personalHeader):
      guard defaults.string(forKey: tokenKey) == bearer, username == account else { return }
      // 版本缓存用 +1 判定：认得出「这一版是我自己推出来的」就存下，下一次条件 GET 才能
      // 拿 304（不会把服务器快照整个拉下来）。快照下限已由 core 用**响应头真值**推进
      // （`noteAcknowledged`）——并发另一台设备写入 / 幂等重试时 +1 不成立，下限也照旧可靠。
      let acknowledged = VoiceInputAccount.ownConfigVersion(
        previous: before, personal: personalHeader)
      if let acknowledged { defaults.set(acknowledged, forKey: versionKey) }
      else { defaults.removeObject(forKey: versionKey) }
      await refresh()
    case .deferred, .empty:
      scheduleVoiceInputUpload()
    case .failed:
      isOnline = false
    }
  }

  /// POST /v1/config/voice-input。抽成独立方法给 VoiceSyncCore 注入 —— 测试用假网络
  /// 替掉的正是这一步，其余序列全是产品代码。返回 (服务器文档, X-Personal-Version 响应头)。
  @MainActor private func postVoiceInput(_ ops: [AccountVoiceOperation],
                                         bearer: String) async throws -> (AccountVoiceInput, String?) {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/config/voice-input"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(["operations": ops])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let state = try JSONDecoder().decode(AccountVoiceInput.self, from: data)
    return (state, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Personal-Version"))
  }

  /// 前台定期对齐同一账号的标签及团队状态；无变化时 GET 只返回 304。
  @MainActor func startForegroundPolling() {
    guard foregroundPoll == nil else { return }
    foregroundPoll = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, NSApp.isActive, self.hasSession,
              !self.updatingPersonal, self.activeRefreshes == 0,
              !self.uploadingVoiceInput else { return }
        await self.refresh()
      }
    }
  }

  /// 与 iOS SharedRestStore 同一份 recentSelection.restSessions；只改个人 selection。
  @MainActor func setResting(_ resting: Bool, session: String) async -> Bool {
    guard !updatingPersonal, let token = defaults.string(forKey: tokenKey) else { return false }
    updatingPersonal = true
    defer { updatingPersonal = false }
    do {
      var get = URLRequest(url: baseURL.appendingPathComponent("v1/config"))
      get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let (data, response) = try await URLSession.shared.data(for: get)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
            let snap = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
      var selection = snap["recentSelection"] as? [String: String] ?? [:]
      let rows = ((snap["tabs"] as? [String: Any])?["tabs"] as? [[String: Any]]) ?? []
      let shared = rows.compactMap { row -> String? in
        guard row["shared"] as? Bool == true else { return nil }
        return row["tmuxSession"] as? String
      }
      var active = selection["restSessions"].map { Set($0.split(separator: ",").map(String.init)) }
        ?? Set(shared.filter { $0.split(separator: "-").first?.lowercased() == "tom" })
      if resting { active.remove(session) } else { active.insert(session) }
      selection["restSessions"] = active.sorted().joined(separator: ",")
      var put = URLRequest(url: baseURL.appendingPathComponent("v1/config/selection"))
      put.httpMethod = "PUT"
      put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      put.setValue("application/json", forHTTPHeaderField: "Content-Type")
      put.httpBody = try JSONSerialization.data(withJSONObject: selection)
      let (_, putResponse) = try await URLSession.shared.data(for: put)
      guard (putResponse as? HTTPURLResponse)?.statusCode == 204 else { return false }
      defaults.removeObject(forKey: versionKey)
      await refresh()
      return isOnline
    } catch { return false }
  }

  @MainActor func setAgent(_ kind: AgentKind, machineId: String, title: String) async -> Bool {
    guard !updatingPersonal, let token = defaults.string(forKey: tokenKey) else { return false }
    updatingPersonal = true
    defer { updatingPersonal = false }
    do {
      var get = URLRequest(url: baseURL.appendingPathComponent("v1/config"))
      get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let (data, response) = try await URLSession.shared.data(for: get)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
            let snap = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
      var agents = snap["agents"] as? [String: String] ?? [:]
      let key = TabAgentStore.storeKey(machineId: machineId, title: title)
      if kind == .claude { agents.removeValue(forKey: key) }
      else { agents[key] = kind.rawValue }
      var put = URLRequest(url: baseURL.appendingPathComponent("v1/config/agents"))
      put.httpMethod = "PUT"
      put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      put.setValue("application/json", forHTTPHeaderField: "Content-Type")
      put.httpBody = try JSONSerialization.data(withJSONObject: agents)
      let (_, putResponse) = try await URLSession.shared.data(for: put)
      guard (putResponse as? HTTPURLResponse)?.statusCode == 204 else { return false }
      defaults.removeObject(forKey: versionKey)
      await refresh()
      return isOnline
    } catch { return false }
  }

  enum PullResult { case ok, notModified, unauthorized, offline, noSession }

  /// 网络拉取 + 落盘，不碰 @Published —— 可在任意 executor 跑（DIAG 用主线程 semaphore
  /// 等结果，@MainActor 版会把 MainActor 堵死）。
  nonisolated func fetchAndApply() async -> PullResult {
    let defaults = UserDefaults.standard
    guard let token = defaults.string(forKey: tokenKey) else { return .noSession }
    var components = URLComponents(url: baseURL.appendingPathComponent("v1/config"), resolvingAgainstBaseURL: false)!
    if SyncConfig.read()?["sharedTabs"] != nil,
       let account = defaults.string(forKey: userKey),
       !VoiceInputAccount.shared.needsInitialSnapshot(username: account),
       let applied = defaults.string(forKey: versionKey) {
      components.queryItems = [URLQueryItem(name: "version", value: applied)]
    }
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return .offline }
      guard defaults.string(forKey: tokenKey) == token else { return .noSession }
      if http.statusCode == 304 { return .notModified }
      if http.statusCode == 401 { return .unauthorized }
      guard http.statusCode == 200 else { return .offline }
      return await MainActor.run {
        guard defaults.string(forKey: self.tokenKey) == token else { return .noSession }
        self.applySnapshot(data)
        return .ok
      }
    } catch {
      return .offline
    }
  }

  // MARK: - 落盘

  /// 快照 → sync 文件。machines / tabs / closedIds / agents 以服务器为准整份替换；
  /// workDirs 不在服务器快照里，保留文件里的存量。origin 用 "harmony-mac" 沿用三端
  /// 采纳语义（iOS 认 harmony*、鸿蒙手机只挡 harmony、平板只挡 harmony-pad）——服务器化
  /// 后这文件的主要消费方是 Mac 自己，但别弄脏还在读它的端。写法照 SyncConfig.patch：
  /// 临时文件 + rename，让 watchSyncFile() 的 inode 监听触发 UI reload。
  @MainActor private func applySnapshot(_ data: Data) {
    guard let snap = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = snap["version"] as? String else { return }
    // 旧快照门：比本账号已见个人版本下限旧的响应，在写 sync 文件（离线兼底）、更新
    // versionKey、采纳 agents / recentSelection 之前就丢掉 —— 离线缓存不许倒退。
    // 与 iOS ServerConfigSync.syncFromServer 同一道门。
    if let account = (snap["user"] as? [String: Any])?["username"] as? String,
       VoiceInputAccount.shared.isStaleSnapshot(version: version, username: account) { return }
    let machines = snap["machines"] as? [[String: Any]] ?? []
    let tabsState = snap["tabs"] as? [String: Any] ?? [:]
    let tabs = tabsState["tabs"] as? [[String: Any]] ?? []
    let sharedTabs = tabs.filter { $0["shared"] as? Bool == true }
    let personalTabs = tabs.filter { $0["shared"] as? Bool != true }
    let closedIds = tabsState["closedIds"] as? [String] ?? []
    let agents = snap["agents"] as? [String: String] ?? [:]

    var obj = SyncConfig.read() ?? [:]
    if let user = snap["user"] as? [String: Any], let account = user["username"] as? String {
      let state = (snap["voiceInput"] as? [String: Any]).flatMap {
        try? JSONDecoder().decode(AccountVoiceInput.self, from: JSONSerialization.data(withJSONObject: $0))
      }
      VoiceInputAccount.shared.adopt(state, version: version, username: account)
      let local = VoiceInputAccount.shared.snapshot
      obj["favorites"] = local.favorites
      obj["favoriteCounts"] = local.favoriteCounts
      obj["history"] = local.history
    }
    obj["machines"] = machines
    // 共享书签（浏览器「后台」）：服务器快照带 pinned 就是权威，PinnedLinksStore
    // 直接从这个文件读；不带（老快照）就保留文件里的存量，别清掉离线兜底。
    if let pinned = snap["pinned"] as? [[String: Any]] { obj["pinned"] = pinned }
    // 公用标签和个人标签分开保存：公用标签不进个人墓碑/回传链路。
    obj["tabs"] = personalTabs
    obj["sharedTabs"] = sharedTabs
    obj["recentSelection"] = snap["recentSelection"] as? [String: String] ?? [:]
    obj["closedIds"] = closedIds
    obj["agents"] = agents
    obj["origin"] = "harmony-mac"
    obj["updatedAt"] = Date().timeIntervalSince1970
    guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return }
    let tmp = SyncConfig.path + ".tmp"
    guard (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return }
    _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: SyncConfig.path),
                                               withItemAt: URL(fileURLWithPath: tmp))
    // 同步文件里有每台机器的 blinkd token 和书签密码 —— 落盘一律 600（#74：以前 644）。
    // 注意必须改**目标**文件：replaceItemAt 会保留被替换文件的权限，改临时文件没用。
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: SyncConfig.path)
    defaults.set(version, forKey: versionKey)
  }
}

/// 登录 sheet（mac 版）：无 session 时启动弹一次；「离线使用」照常进主界面
/// （sync 文件 / KV 里的缓存还在，只是不拉新）。
struct ServerLoginView: View {
  var onSuccess: () -> Void
  var onOffline: (() -> Void)? = nil
  @State private var username = ""
  @State private var password = ""
  @State private var error = ""
  @State private var busy = false

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "person.crop.circle")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
      Text("登录 Blink 团队").font(Theme.ui(16, .bold))
      Text("登录后自动获取共享机器和自己的标签布局")
        .font(Theme.ui(11))
        .foregroundStyle(.secondary)
      TextField("用户名", text: $username)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .onSubmit { if !password.isEmpty { login() } }
      SecureField("密码", text: $password)
        .textFieldStyle(.roundedBorder)
        .onSubmit(login)
      if !error.isEmpty {
        Text(error).font(Theme.ui(11)).foregroundStyle(.red)
      }
      HStack {
        Button("离线使用") {
          resetLoginState()
          if let onOffline { onOffline() } else { onSuccess() }
        }
        Spacer()
        Button(busy ? "正在登录…" : "登录") { login() }
          .keyboardShortcut(.defaultAction)
          .disabled(busy || username.isEmpty || password.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 320)
    .background(Theme.bg)
    .onAppear { resetLoginState() }
  }

  private func login() {
    guard !busy else { return }
    busy = true
    error = ""
    Task {
      do {
        try await ServerSync.shared.login(username: username, password: password)
        resetLoginState()
        onSuccess()
      } catch {
        self.error = error.localizedDescription
        busy = false
      }
    }
  }

  private func resetLoginState() {
    busy = false
    error = ""
    password = ""
  }
}
