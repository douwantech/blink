import Foundation
import SwiftUI

// 服务器同步（Blink 原生 Mac 版，2026-10-05 老板拍板弃 iCloud 后的 Mac 落地）。
//
// iOS 端 ServerConfigSync（Blink/SmarterKeys/ServerConfigSync.swift）已把配置服务器
// (blink-api.douwantech.com) 设为唯一权威：管理员维护机器清单，每端登录后拉自己的
// machines / tabs / agents。Mac 端这一版是「下行同步器」：
//   login → GET /v1/config → 快照整份写进 ~/.blink/sync/blink_config.json
//     （machines / tabs / closedIds / agents；workDirs 服务器快照里没有——那是
//      iOS CloudConfigSync 时代的 KV 镜像字段——保留文件存量，机器上的工作目录基本不变）
// 现有读链路零改动继续工作：watchSyncFile() 盯着该文件（写临时文件再 rename，inode
// 变化即触发），CloudTabStore / TabAgentStore / MacMachineStore 从文件读，UI 自动 reload。
// iCloud KV 降级为只读兜底（服务器不可达时不瞎眼），主链路已是服务器。
//
// 上行（PUT tabs/agents）暂未做：Mac 端是标签的观察者（会话由 blinkd 枚举，不在 Mac 上
// 增删标签），暂无上行数据源；服务器侧 PUT 接口 iOS 端已在用，Mac 需要时再接。
//
// 公用标签（二期）：服务端在 `/v1/config` 读时把管理员维护的**全局公用标签**注入进
// `tabs`，每条带 `"shared": true`（契约见 server/README.md「Public tabs」）。它们是
// 全局派生物、不属于任何账号配置，所以**只在内存里当只读影子，绝不落同步文件、绝不进
// iCloud KV**——落盘前在 applySnapshot 的边界处剥掉（与 iOS ServerSnapshotDecoder.decode
// 同一口径），closedIds 里的公用 id 也一并丢弃。剥出来的那份经 @Published sharedTabs
// 交给 AppState 渲染成只读的「公用标签」节。
//
// 304 会让剥离跑不到（服务器没变、applySnapshot 根本不执行），所以 sharedTabs 另外落一份
// **本地** UserDefaults 缓存（按用户名分键），304 / 离线时用它，否则重启后公用标签全空。
//
// token 存 UserDefaults 而非 Keychain：SPM dev 版（swift run）无 entitlement，
// dataProtection keychain 会 errSecMissingEntitlement，出现「存了读不回」；正式版也没配
// keychain-access-groups。Preferences 目录 0700 用户级保护，与 ~/.secrets 同级强度。
/// 服务端读时注入的全局公用标签（`"shared": true`）。**上行只读**：不进同步文件、
/// 不进 iCloud KV；关闭/休息/切 CLI 只在本地生效（本地墓碑/本地休息表），服务端
/// 目录才是这份列表的权威。`tmuxSession` 就是 `cc-title` 那条会话名
/// （`<员工>-<项目>`），所以它天然能对上 blinkd 枚举出来的同名活会话。
struct SharedTab: Equatable, Codable {
  let id: String          // 服务端 UUIDv5（跨端稳定），仅用于防御性比对
  let machineId: String
  let tmuxSession: String
}

/// 侧栏列表口径（老板 2026-10-06：与 iPhone 坞完全同口径，只是把配置放到服务器，
/// 逻辑保持之前一样）：**只铺 tom 的那几条公用标签**，非 tom 的不上列表；Mac 自有
/// 标签彻底不显示。全部公用标签仍注册成会话（休息计数 / 团队面板用），这里只管列不列。
enum DockTabs {
  /// 坞/侧栏只列这一位员工。写死常量、不做筛选器 —— 与 iOS `SharedTabLayout.dockEmployee` 同值同由。
  static let employee = "tom"

  /// 从 tmuxSession 里取员工：第一个 "-" 之前（`tom-ben` → `tom`）。服务端允许员工 id
  /// 自带 "-"，那种情况会截短（`tom-x-ben` → `tom`）—— 与 iOS 同款取舍。
  static func employee(ofTmuxSession session: String) -> String? {
    let head = session.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init)?
      .trimmingCharacters(in: .whitespaces)
    guard let head, !head.isEmpty else { return nil }
    return head.lowercased()
  }

  static func isDockTab(_ t: SharedTab) -> Bool {
    employee(ofTmuxSession: t.tmuxSession) == employee
  }
}

final class ServerSync: ObservableObject {
  static let shared = ServerSync()

  @Published private(set) var username: String?
  @Published private(set) var isOnline = false
  @Published private(set) var isLoading = false
  /// 服务端注入的公用标签（服务端顺序）。只由 refresh() 在主线程写。
  @Published private(set) var sharedTabs: [SharedTab] = []

  private let baseURL = URL(string: "https://blink-api.douwantech.com")!
  private let defaults = UserDefaults.standard
  private let tokenKey = "BlinkServer.token"
  private let userKey = "BlinkServer.username"
  private let versionKey = "BlinkServer.appliedVersion"
  private let sharedCachePrefix = "BlinkServer.sharedTabs."

  var hasSession: Bool { defaults.string(forKey: tokenKey) != nil }

  private init() { username = defaults.string(forKey: userKey) }

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
    defaults.set(token, forKey: tokenKey)
    defaults.set(name, forKey: userKey)
    self.username = name
    defaults.removeObject(forKey: versionKey)   // 重登/换账号：下次全量拉
    await refresh()
  }

  @MainActor func logout() {
    let old = defaults.string(forKey: userKey)
    defaults.removeObject(forKey: tokenKey)
    defaults.removeObject(forKey: userKey)
    defaults.removeObject(forKey: versionKey)
    if let old { defaults.removeObject(forKey: sharedCachePrefix + old) }
    username = nil
    isOnline = false
    sharedTabs = []
  }

  /// 有 session 就拉一次（启动 / 回前台 / 登录后）。带上次采纳的 version：304 = 服务器
  /// 没变，跳过落盘（也不必触发 reload）。token 失效（401）清 session，下次启动弹登录。
  @MainActor func refresh() async {
    guard defaults.string(forKey: tokenKey) != nil else { return }
    let (result, shared) = await fetchAndApply()
    switch result {
    case .ok:
      isOnline = true
      persistSharedTabs(shared)   // 本地缓存：下次 304 启动也拿得到（服务器没变就不会重发）
      sharedTabs = shared
    case .notModified:
      isOnline = true
      sharedTabs = shared         // = 本地缓存那份；空则说明缓存也还没建立过
    case .unauthorized:
      let old = defaults.string(forKey: userKey)
      defaults.removeObject(forKey: tokenKey)
      defaults.removeObject(forKey: versionKey)
      defaults.removeObject(forKey: userKey)
      if let old { defaults.removeObject(forKey: sharedCachePrefix + old) }
      username = nil
      isOnline = false
      sharedTabs = []
    case .offline:
      isOnline = false
      sharedTabs = shared         // 缓存兜底：网络不通也别让公用标签凭空消失
    case .noSession: break
    }
  }

  enum PullResult { case ok, notModified, unauthorized, offline, noSession }

  /// 网络拉取 + 落盘，不碰 @Published —— 可在任意 executor 跑（DIAG 用主线程 semaphore
  /// 等结果，@MainActor 版会把 MainActor 堵死）。
  /// 第二个返回值是「本次应当生效的公用标签」：200 是刚剥出来的，304 / 离线是本地缓存那份。
  nonisolated func fetchAndApply() async -> (result: PullResult, shared: [SharedTab]) {
    let defaults = UserDefaults.standard
    guard let token = defaults.string(forKey: tokenKey) else { return (.noSession, []) }
    var components = URLComponents(url: baseURL.appendingPathComponent("v1/config"), resolvingAgainstBaseURL: false)!
    if let applied = defaults.string(forKey: versionKey) {
      components.queryItems = [URLQueryItem(name: "version", value: applied)]
    }
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return (.offline, cachedSharedTabs()) }
      if http.statusCode == 304 { return (.notModified, cachedSharedTabs()) }
      if http.statusCode == 401 { return (.unauthorized, []) }
      guard http.statusCode == 200 else { return (.offline, cachedSharedTabs()) }
      return (.ok, applySnapshot(data))
    } catch {
      return (.offline, cachedSharedTabs())
    }
  }

  // MARK: - 公用标签的本地缓存（仅 UserDefaults，不是 iCloud KV）

  /// 按用户名分键：换账号不会读到上一个账号的公用标签。
  nonisolated func cachedSharedTabs() -> [SharedTab] {
    let defaults = UserDefaults.standard
    guard let name = defaults.string(forKey: userKey),
          let data = defaults.data(forKey: sharedCachePrefix + name) else { return [] }
    return (try? JSONDecoder().decode([SharedTab].self, from: data)) ?? []
  }

  /// 自测专用：DIAG 用主线程 semaphore 等 `fetchAndApply`，不能调 `@MainActor` 的
  /// `refresh()`（会把 MainActor 堵死），于是用它把结果发布出来给侧栏合成用。
  /// **不落缓存** —— DIAG 是只读检查（`BLINKMAC_SYNC_FILE` 只兜得住同步文件，
  /// UserDefaults 没有对应重定向，写下去会把真账号的公用标签缓存覆盖成 fixture 那份）。
  @MainActor func publishSharedTabsForDiagnostics(_ tabs: [SharedTab]) { sharedTabs = tabs }

  private func persistSharedTabs(_ tabs: [SharedTab]) {
    guard let name = defaults.string(forKey: userKey) else { return }
    guard let data = try? JSONEncoder().encode(tabs) else { return }
    defaults.set(data, forKey: sharedCachePrefix + name)
  }

  // MARK: - 落盘

  /// 快照 → sync 文件，并把公用标签**在边界处剥掉**（照 iOS `ServerSnapshotDecoder.decode`）：
  /// 带 `"shared": true` 的条目不写进文件的 tabs，它们的 id 也从 closedIds 里丢弃——所以
  /// 下游（CloudTabStore / TabAgentStore / CloudRestStore / PinnedLinksStore）永远看不到它们，
  /// 也就无从关闭、休息、切 CLI 或回传。返回剥出来的那份交给内存里的 sharedTabs。
  ///
  /// machines / tabs / closedIds / agents 以服务器为准整份替换；workDirs 不在服务器快照里，
  /// 保留文件里的存量。origin 用 "harmony-mac" 沿用三端采纳语义（iOS 认 harmony*、鸿蒙手机
  /// 只挡 harmony、平板只挡 harmony-pad）——服务器化后这文件的主要消费方是 Mac 自己，
  /// 但别弄脏还在读它的端。写法照 SyncConfig.patch：临时文件 + rename，让 watchSyncFile()
  /// 的 inode 监听触发 UI reload。
  /// 内部可见（不是 private）：`BLINKMAC_DIAG_FIXTURE` 的自测直接喂一份快照走这条路径。
  func applySnapshot(_ data: Data) -> [SharedTab] {
    guard let snap = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = snap["version"] as? String else { return [] }
    let machines = snap["machines"] as? [[String: Any]] ?? []
    let agents = snap["agents"] as? [String: String] ?? [:]

    // 形状解不出来时**不碰**文件里的 tabs/closedIds（分不清哪些是公用标签，宁可不写），
    // 也不记 version —— 下次启动再全量拉一次，等形状恢复。
    var ownTabs: [[String: Any]]?
    var ownClosed: [String]?
    var shared: [SharedTab] = []
    if let tabsState = snap["tabs"] as? [String: Any],
       let rawTabs = tabsState["tabs"] as? [[String: Any]] {
      let rawClosed = tabsState["closedIds"] as? [String] ?? []
      let sharedRaw = rawTabs.filter { ($0["shared"] as? Bool) == true }
      // id 一律小写比对：服务端给的是 UUIDv5 字符串，别让大小写差异漏掉一条墓碑。
      let sharedIDs = Set(sharedRaw.compactMap { ($0["id"] as? String)?.lowercased() })
      ownTabs = rawTabs.filter { ($0["shared"] as? Bool) != true }
      ownClosed = rawClosed.filter { !sharedIDs.contains($0.lowercased()) }
      shared = sharedRaw.compactMap { t in
        guard let id = t["id"] as? String,
              let mid = t["machineId"] as? String, !mid.isEmpty,
              let sess = t["tmuxSession"] as? String, !sess.isEmpty else { return nil }
        return SharedTab(id: id, machineId: mid, tmuxSession: sess)
      }
      if shared.count != sharedRaw.count {
        // 不完整的条目照样已从 ownTabs 剔除（防污染优先），只是渲染不了。
        NSLog("[ServerSync] 有 \(sharedRaw.count - shared.count) 条公用标签缺 id/machineId/tmuxSession，已剥离但不渲染")
      }
    } else {
      NSLog("[ServerSync] tabs 形状解不出来，本轮不改文件里的 tabs/closedIds（否则公用标签会被当自有的落盘）")
    }

    var obj = SyncConfig.read() ?? [:]
    obj["machines"] = machines
    // 共享书签（浏览器「后台」）：服务器快照带 pinned 就是权威，PinnedLinksStore
    // 直接从这个文件读；不带（老快照）就保留文件里的存量，别清掉离线兜底。
    if let pinned = snap["pinned"] as? [[String: Any]] { obj["pinned"] = pinned }
    if let ownTabs { obj["tabs"] = ownTabs }
    if let ownClosed { obj["closedIds"] = ownClosed }
    obj["agents"] = agents
    obj["origin"] = "harmony-mac"
    obj["updatedAt"] = Date().timeIntervalSince1970
    guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return shared }
    let tmp = SyncConfig.path + ".tmp"
    guard (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return shared }
    _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: SyncConfig.path),
                                               withItemAt: URL(fileURLWithPath: tmp))
    if ownTabs != nil { defaults.set(version, forKey: versionKey) }
    return shared
  }
}

/// 登录 sheet（mac 版）：无 session 时启动弹一次；「离线使用」照常进主界面
/// （sync 文件 / KV 里的缓存还在，只是不拉新）。
struct ServerLoginView: View {
  var onSuccess: () -> Void
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
        Button("离线使用") { onSuccess() }
        Spacer()
        Button(busy ? "正在登录…" : "登录") { login() }
          .keyboardShortcut(.defaultAction)
          .disabled(busy || username.isEmpty || password.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 320)
    .background(Theme.bg)
  }

  private func login() {
    busy = true
    error = ""
    Task {
      do {
        try await ServerSync.shared.login(username: username, password: password)
        onSuccess()
      } catch {
        self.error = error.localizedDescription
        busy = false
      }
    }
  }
}
