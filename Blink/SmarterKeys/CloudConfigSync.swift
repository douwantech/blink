//
//  CloudConfigSync.swift
//  Blink
//
//  把本地 UserDefaults.standard 里的 app 配置镜像到 iCloud Key-Value Store。
//  目的：重装 app 后沙盒被清空，配置全丢——开启后这些配置会自动存到 iCloud，
//  重装并登录同一 Apple ID 后自动拉回；多设备之间也会同步。
//
//  机制：
//   • 本地任何配置改动 → 防抖后推到 iCloud（只写、不删，避免误删云端备份）。
//   • iCloud 外部变更（别的设备改了 / 重装首次下载）→ 写回本地 UserDefaults。
//   • 各 store 的 getter 都是每次现读 UserDefaults，所以拉回后下次访问即生效，无需 reload。
//
//  注意：iCloud KV Store 总配额 1MB、单值上限 1MB。头像等大值做了体积保护，
//  超限的单个 key 会被跳过（仍留在本地，只是不进 iCloud）。
//

import Foundation

@objc(CloudConfigSync)
final class CloudConfigSync: NSObject {
  @objc static let shared = CloudConfigSync()

  /// 拉回完成后发的通知，UI 可监听刷新（可选）。
  static let didRestoreNotification = Notification.Name("CloudConfigSync.didRestore")

  /// 需要同步的全部配置 key（都在 UserDefaults.standard）。
  private let keys: [String] = [
    // 机器 / 会话
    "BlinkMachineStore.machines",
    "BlinkMachineStore.avatars",
    "BlinkUseTmuxMode",
    "BlinkShowMachineBar",   // 设置里「切换机器条」开关
    "BlinkWorkDirStore.workDirs",
    "BlinkSessionPresetStore.presets",
    "TabStateStore.syncState",   // 终端 tab 列表跨设备同步
    "TabRestStore.resting",      // 「休息」😴 标记跨设备同步（否则各设备各藏各的，tab 列表看着不一致）
    "TeamStatus.summaryCache",   // 团队状态页的 GLM 总结缓存：换设备/重装不用重新总结
    // 人员
    "BlinkPeopleStore.avatars",
    "BlinkPeopleStore.styles",
    "BlinkPeopleStore.names",
    // 语音 AI
    "VoiceInputView.localeIdentifier",
    "VoiceInputView.aiAPIKey",
    "VoiceInputView.aiModel",
    "VoiceInputView.aiBaseURL",
    "VoiceInputView.aiEnabled",
    "VoiceInputView.aiDebounce",
    "VoiceInputView.aiHistory",
    "VoiceInputView.aiFavorites",
    "VoiceInputView.aiFavoriteCounts",
    "VoiceInputView.aiCorrections",
    "VoiceInputView.aiTerms",
    "VoiceInputView.whisperAPIKey",
    // 浏览器
    "PinnedTabsStore.tabs",
    "RecentBrowserTabsStore.tabs",
    "FloatingBrowserButton.posX",
    "FloatingBrowserButton.posY",
    "FloatingDockBar.posX",
    "FloatingDockBar.posY",
  ]

  /// 单值体积上限：iCloud KV 总配额 1MB，给单值留余量。
  private let perValueLimit = 900_000

  private let kv = NSUbiquitousKeyValueStore.default
  private let defaults = UserDefaults.standard
  private var started = false
  private var applyingRemote = false
  private var pushScheduled = false

  /// 从 AppDelegate 启动时调一次。
  @objc static func start() { shared._start() }

  private func _start() {
    guard !started else { return }
    started = true

    NotificationCenter.default.addObserver(
      self, selector: #selector(cloudChanged(_:)),
      name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kv)

    kv.synchronize()

    // 启动即尝试「本地缺失 → 从 iCloud 拉回」（重装后本地全空；云端若已下载到本地缓存则立即恢复，
    // 否则等下面 didChangeExternally 的 InitialSyncChange 再恢复）。
    restoreMissingFromCloud()

    // 之后本地任何改动都镜像到 iCloud；并启动即 seed 一次，把已有本地配置推上云。
    NotificationCenter.default.addObserver(
      self, selector: #selector(localChanged),
      name: UserDefaults.didChangeNotification, object: nil)
    schedulePush()

    // 启动也主动拉一次：adoptSyncedIfNewer 读的是 UserDefaults 镜像，而镜像只有 didChangeExternally
    // 到了才刷新；冷启动那一刻镜像往往还是本机自己的旧值。pullNow 直接读 KV，把云端值灌进镜像，
    // 让启动时的采纳拿到的是真·云端最新。
    pullNow()

    // 双向同步的另一半：鸿蒙推到 Mac 文件的配置，这里拉回来。
    ConfigSyncPull.start()
  }

  // MARK: 本地 → iCloud

  @objc private func localChanged() {
    guard !applyingRemote else { return }   // 拉回写本地时不要再回推
    schedulePush()
    // 顺手让 Mac 侧的同步文件也跟上（3s 合并窗口直推，不吃 60s 节流），
    // 鸿蒙端的常驻监听靠它做到秒级跟随。
    // 正在采纳鸿蒙推来的配置时不回推文件（防 ping-pong）；iCloud 镜像照常。
    if !ConfigSyncPull.applying { ConfigSyncPush.shared.noteChanged() }
  }

  private func schedulePush() {
    guard !pushScheduled else { return }
    pushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self else { return }
      self.pushScheduled = false
      self.pushToCloud()
    }
  }

  /// 只写、不删：只把本地非空的值同步到云端。
  /// 删除是通过「整份数组/字典被重写成更短的值」传播的（machines、tabs 等都是单 key 存整份），
  /// 不靠 removeObject，从而避免重装窗口期把云端备份误删。
  private func pushToCloud() {
    // 只同步「真正写进持久域」的值：register(defaults:) 的 seed 默认会让 object(forKey:) 返回非 nil，
    // 但不代表本机真设过——全新安装若把 seed 默认推上 iCloud，会覆盖其它设备已有的真实数据（本次 workDir 丢失根因）。
    let persisted = persistedKeys()
    var dirty = false
    for key in keys {
      guard persisted.contains(key) else { continue }
      guard let value = defaults.object(forKey: key) else { continue }
      if let size = plistSize(value), size > perValueLimit {
        NSLog("[CloudConfigSync] 跳过过大 key=%@ (%d bytes)，超 iCloud KV 单值上限", key, size)
        continue
      }
      kv.set(value, forKey: key)
      dirty = true
    }
    if dirty { kv.synchronize() }
  }

  // MARK: iCloud → 本地

  @objc private func cloudChanged(_ note: Notification) {
    let reason = (note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber)?.intValue ?? -1
    switch reason {
    case NSUbiquitousKeyValueStoreServerChange:
      let ck = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
      applyFromCloud(ck.filter { keys.contains($0) })
    case NSUbiquitousKeyValueStoreInitialSyncChange:
      // 首次下载（典型场景：重装后云端数据到达）——云端为权威，覆盖本地（仅覆盖云端确有的 key）。
      applyFromCloud(keys)
    default:
      break   // 账号变更 / 配额冲突不处理
    }
  }

  private func applyFromCloud(_ keysToApply: [String]) {
    guard !keysToApply.isEmpty else { return }
    applyingRemote = true
    var changed = false
    for key in keysToApply {
      if let value = kv.object(forKey: key) {
        defaults.set(value, forKey: key)
        changed = true
      }
      // 云端没有的 key 保留本地，避免误删。
    }
    applyingRemote = false
    if changed {
      NotificationCenter.default.post(name: CloudConfigSync.didRestoreNotification, object: nil)
    }
  }

  /// 主动从 iCloud 拉一次并应用。不等 `didChangeExternally`——那个投递极不可靠，
  /// 尤其 app 回前台时常常收不到，导致「切到另一台设备看不到最新 tab」。
  /// 回前台 / 变活跃时调这个：synchronize 触发下载，再把 KV 里和本地不同的 key 写回本地并通知刷新。
  /// tab 用 last-writer-wins（adoptSyncedIfNewer 按 updatedAt 决定是否真采纳），所以这里即便把
  /// 稍旧的云端值写进 mirror 也不会覆盖更新的本地 tab。
  @objc func pullNow() {
    guard started else { return }
    kv.synchronize()
    var toApply: [String] = []
    for key in keys {
      guard let remote = kv.object(forKey: key) else { continue }
      let local = defaults.object(forKey: key)
      if !Self.valuesEqual(local, remote) { toApply.append(key) }
    }
    if !toApply.isEmpty {
      NSLog("[CloudConfigSync] pullNow：从 iCloud 应用 %d 个 key：%@", toApply.count, toApply.joined(separator: ","))
      applyFromCloud(toApply)
    }
  }

  private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (nil, _), (_, nil): return false
    default: return (a as AnyObject).isEqual(b)
    }
  }

  /// 启动时：本地缺失而云端已有 → 直接拉回。
  private func restoreMissingFromCloud() {
    let persisted = persistedKeys()
    applyingRemote = true
    // 本机没真正设过（含只有 register seed 默认）的 key，云端若有就拉回——修复「seed 默认挡住拉回」。
    for key in keys where !persisted.contains(key) {
      if let value = kv.object(forKey: key) {
        defaults.set(value, forKey: key)
      }
    }
    applyingRemote = false
  }

  /// 真正写进持久域（本机 plist）的 key——排除 register(defaults:) 的 seed 默认值与参数域。
  private func persistedKeys() -> Set<String> {
    guard let bid = Bundle.main.bundleIdentifier,
          let dom = defaults.persistentDomain(forName: bid) else { return [] }
    return Set(dom.keys)
  }

  // MARK: util

  private func plistSize(_ value: Any) -> Int? {
    (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))?.count
  }
}

// MARK: - iOS ⇄ Mac ⇄ 鸿蒙 双向配置同步
//
// 汇合点：每台 blinkd 机器的 ~/.blink/sync/blink_config.json（鸿蒙 seed 形状）。
// 两端都「本地改动 → 防抖后推到所有机器」+「watcher 盯文件 mtime → 变了就拉」。
// 冲突 last-writer-wins（updatedAt epoch 秒）；payload 带 origin（ios/harmony），
// 拉到自己写的文件直接跳过，防回声循环。tab 删除靠 closedIds 墓碑传播。
// 全程尽力而为，失败静默——同步丢一两次无所谓，下次再推。

import Network
import UIKit

final class ConfigSyncPush: NSObject {
  @objc static let shared = ConfigSyncPush()
  private var lastPush = Date.distantPast

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(pushSoon),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  /// 节流入口：前后台切换都打这里
  @objc func pushSoon() {
    guard Date().timeIntervalSince(lastPush) > 60 else { return }
    lastPush = Date()
    DispatchQueue.global(qos: .utility).async { self.pushNow() }
  }

  private var changePending = false

  /// 配置真的变了（CloudConfigSync 的本地改动钩子）：3s 合并窗口后直推，
  /// 绕过 60s 节流——员工休息/加机器这类改动要秒级到达鸿蒙。
  @objc func noteChanged() {
    guard !changePending else { return }
    changePending = true
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) { [weak self] in
      guard let self else { return }
      self.changePending = false
      self.lastPush = Date()
      self.pushNow()
    }
  }

  private func pushNow() {
    var payload = Self.exportJSON(slim: false)?.base64EncodedString() ?? ""
    // blinkd 帧长上限 u16=64KB：超了就砍掉学习类大头（history/corrections/terms）
    if payload.count > 60_000 {
      payload = Self.exportJSON(slim: true)?.base64EncodedString() ?? ""
    }
    guard !payload.isEmpty, payload.count <= 60_000 else { return }
    let script = "mkdir -p ~/.blink/sync && printf '%s' '\(payload)' | openssl base64 -d -A > ~/.blink/sync/.cfg.tmp && mv ~/.blink/sync/.cfg.tmp ~/.blink/sync/blink_config.json"
    guard let mdata = UserDefaults.standard.data(forKey: "BlinkMachineStore.machines"),
          let machines = (try? JSONSerialization.jsonObject(with: mdata)) as? [[String: Any]] else { return }
    for m in machines {
      guard let host = m["blinkdHost"] as? String, !host.isEmpty,
            let token = m["blinkdToken"] as? String, !token.isEmpty else { continue }
      Self.send(host: host, port: UInt16(m["blinkdPort"] as? Int ?? 7777), token: token, script: script)
    }
  }

  // 导出为鸿蒙 SeedConfig 形状（键名与 rawfile/seed_config.json 一致）
  private static func exportJSON(slim: Bool) -> Data? {
    let d = UserDefaults.standard
    func decoded(_ key: String) -> [Any] {
      guard let data = d.data(forKey: key),
            let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
      return (obj as? [Any]) ?? []
    }
    var workDirs: [[String: Any]] = []
    for case var w as [String: Any] in decoded("BlinkWorkDirStore.workDirs") {
      w["hasIcon"] = w["iconImageData"] != nil
      w.removeValue(forKey: "iconImageData")   // 头像不走这条通道（几十 KB 一张）
      workDirs.append(w)
    }
    var tabs: [[String: Any]] = []
    var currentId = ""
    var closedIds: [String] = []
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    if let data = try? Data(contentsOf: docs.appendingPathComponent("blink_tabs.json")),
       let st = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      closedIds = (st["closedIds"] as? [String]) ?? []
      let closed = Set(closedIds)
      for case let t as [String: Any] in (st["tabs"] as? [Any]) ?? [] {
        guard let id = t["id"] as? String, !closed.contains(id) else { continue }
        tabs.append([
          "id": id,
          "machineId": (t["machineId"] as? String) ?? "",
          "workDirId": (t["workDirId"] as? String) ?? "",
          "tmuxSession": (t["tmuxSession"] as? String) ?? "new",
          "useTmux": (t["useTmux"] as? Bool) ?? true,
        ])
      }
      currentId = (st["currentId"] as? String) ?? ""
    }
    let root: [String: Any] = [
      "machines": decoded("BlinkMachineStore.machines"),
      "workDirs": workDirs,
      "people": decoded("BlinkPeopleStore.names"),
      "presets": decoded("BlinkSessionPresetStore.presets"),
      "tabs": tabs,
      "currentId": currentId,
      "closedIds": closedIds,
      "pinned": decoded("PinnedTabsStore.tabs"),
      "favorites": d.stringArray(forKey: "VoiceInputView.aiFavorites") ?? [],
      "favoriteCounts": d.dictionary(forKey: "VoiceInputView.aiFavoriteCounts") ?? [:],
      "history": slim ? [] : (d.stringArray(forKey: "VoiceInputView.aiHistory") ?? []),
      "corrections": slim ? [] : ((d.array(forKey: "VoiceInputView.aiCorrections") as? [[String]]) ?? []),
      "terms": slim ? [:] : (d.dictionary(forKey: "VoiceInputView.aiTerms") ?? [:]),
      "voice": [
        "enabled": (d.object(forKey: "VoiceInputView.aiEnabled") as? Bool) ?? true,
        "apiKey": d.string(forKey: "VoiceInputView.aiAPIKey") ?? "",
        "model": d.string(forKey: "VoiceInputView.aiModel") ?? "glm-4-flashx",
        "baseURL": d.string(forKey: "VoiceInputView.aiBaseURL") ?? "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        "debounce": (d.object(forKey: "VoiceInputView.aiDebounce") as? Double) ?? 1.5,
      ] as [String: Any],
      "locale": d.string(forKey: "VoiceInputView.localeIdentifier") ?? "zh-CN",
      "resting": d.stringArray(forKey: "TabRestStore.resting") ?? [],
      "filterMachineId": d.string(forKey: "BlinkTabFilterMachineId") ?? "",
      "autoReconnect": (d.object(forKey: "BlinkAutoReconnect") as? Bool) ?? true,
      "workMode": true,
      "origin": "ios",
      "updatedAt": Date().timeIntervalSince1970,
    ]
    return try? JSONSerialization.data(withJSONObject: root)
  }

  // blinkd 裸 TCP：0x01 token 帧 → 0x04 exec 帧（daemon 侧 bash -c 跑），u16 BigEndian
  private static func frame(_ type: UInt8, _ payload: Data) -> Data {
    var out = Data([type])
    out.append(UInt8((payload.count >> 8) & 0xff))
    out.append(UInt8(payload.count & 0xff))
    out.append(payload)
    return out
  }

  private static func send(host: String, port: UInt16, token: String, script: String) {
    guard let p = NWEndpoint.Port(rawValue: port) else { return }
    let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
    var out = frame(0x01, Data(token.utf8))
    out.append(frame(0x04, Data(script.utf8)))
    conn.stateUpdateHandler = { st in
      switch st {
      case .ready:
        conn.send(content: out, completion: .contentProcessed { _ in
          // 给 daemon 一点执行时间再断开
          DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { conn.cancel() }
        })
      case .failed:
        conn.cancel()
      default:
        break
      }
    }
    conn.start(queue: .global(qos: .utility))
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { conn.cancel() }   // 兜底超时
  }
}

// MARK: - 双向同步的拉取端：鸿蒙 → Mac 文件 → iOS
//
// 鸿蒙改配置后把同形状 JSON 推到各机器的 blink_config.json（origin=harmony）。
// 这里两条路拿到它：回前台主动拉一次 + 前台期间常驻 watcher 盯 mtime（同鸿蒙端做法）。
// 采纳 = 把 SeedConfig 映射回 UserDefaults 各 key，再发 didRestoreNotification，
// 完整复用 iCloud 采纳链路（SpaceController 增量并 tab、墓碑删除、休息标记刷新）。

final class ConfigSyncPull: NSObject {
  static let shared = ConfigSyncPull()

  /// 正在把远端配置写进 UserDefaults——CloudConfigSync.localChanged 据此不回推文件。
  static var applying = false

  private static let kStamp = "ConfigSyncPull.stamp"   // 已采纳的 updatedAt

  private var started = false
  private var pullBusy = false
  private var watcher: NWConnection?
  private var watchBuf = Data()
  private var lastWatchMtime = ""
  private var retryScheduled = false

  static func start() { shared._start() }

  private func _start() {
    guard !started else { return }
    started = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(activated),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(deactivated),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    activated()
  }

  @objc private func activated() {
    pullNow()
    ensureWatcher()
  }

  @objc private func deactivated() {
    watcher?.cancel()
    watcher = nil
  }

  /// 第一台配了 blinkd 的机器（两端取同一台，视图一致）。
  private func firstEndpoint() -> (host: String, port: Int, token: String)? {
    guard let mdata = UserDefaults.standard.data(forKey: "BlinkMachineStore.machines"),
          let machines = (try? JSONSerialization.jsonObject(with: mdata)) as? [[String: Any]] else { return nil }
    for m in machines {
      if let host = m["blinkdHost"] as? String, !host.isEmpty,
         let token = m["blinkdToken"] as? String, !token.isEmpty {
        return (host, (m["blinkdPort"] as? Int) ?? 7777, token)
      }
    }
    return nil
  }

  // MARK: 拉取 + 采纳

  func pullNow() {
    guard !pullBusy, let ep = firstEndpoint() else { return }
    pullBusy = true
    BlinkdExecOnce.run(host: ep.host, port: ep.port, token: ep.token,
                       script: "cat ~/.blink/sync/blink_config.json 2>/dev/null | base64",
                       timeout: 15) { [weak self] result in
      guard let self else { return }
      self.pullBusy = false
      guard case .success(let raw) = result else { return }
      // base64 输出躲开 PTY 的 \r 噪音，收端把非 b64 字符全滤掉再解
      let b64 = raw.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
      guard b64.count > 16, let data = Data(base64Encoded: b64),
            let cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
      DispatchQueue.main.async { self.adopt(cfg) }
    }
  }

  private func adopt(_ cfg: [String: Any]) {
    // 自己（或别的 iOS 设备）写的文件不采纳——iOS 之间走 iCloud，别绕道 Mac 文件回声。
    guard (cfg["origin"] as? String) == "harmony" else { return }
    let stamp = (cfg["updatedAt"] as? Double) ?? 0
    let d = UserDefaults.standard
    guard stamp > d.double(forKey: Self.kStamp) else { return }
    guard let machines = cfg["machines"] as? [[String: Any]], !machines.isEmpty else { return }

    ConfigSyncPull.applying = true
    defer {
      ConfigSyncPull.applying = false
      d.set(stamp, forKey: Self.kStamp)
      NSLog("[ConfigSyncPull] 采纳鸿蒙配置 updatedAt=%.0f machines=%d tabs=%d",
            stamp, machines.count, ((cfg["tabs"] as? [Any])?.count ?? 0))
      NotificationCenter.default.post(name: CloudConfigSync.didRestoreNotification, object: nil)
    }

    func setJSON(_ obj: Any, forKey key: String) {
      if let data = try? JSONSerialization.data(withJSONObject: obj) { d.set(data, forKey: key) }
    }

    setJSON(machines, forKey: "BlinkMachineStore.machines")

    // workDirs：同步文件不带头像（体积），按 id 把本地 iconImageData 保回去，别把头像冲掉
    if let dirs = cfg["workDirs"] as? [[String: Any]] {
      var localIcons: [String: Any] = [:]
      if let ld = d.data(forKey: "BlinkWorkDirStore.workDirs"),
         let locals = (try? JSONSerialization.jsonObject(with: ld)) as? [[String: Any]] {
        for l in locals {
          if let id = l["id"] as? String, let icon = l["iconImageData"] { localIcons[id] = icon }
        }
      }
      var merged: [[String: Any]] = []
      for var w in dirs {
        w.removeValue(forKey: "hasIcon")
        if let id = w["id"] as? String, let icon = localIcons[id] { w["iconImageData"] = icon }
        merged.append(w)
      }
      setJSON(merged, forKey: "BlinkWorkDirStore.workDirs")
    }

    if let people = cfg["people"] as? [String] { setJSON(people, forKey: "BlinkPeopleStore.names") }
    if let presets = cfg["presets"] as? [Any] { setJSON(presets, forKey: "BlinkSessionPresetStore.presets") }
    if let pinned = cfg["pinned"] as? [Any] { setJSON(pinned, forKey: "PinnedTabsStore.tabs") }

    if let fav = cfg["favorites"] as? [String] { d.set(fav, forKey: "VoiceInputView.aiFavorites") }
    if let counts = cfg["favoriteCounts"] as? [String: Any] { d.set(counts, forKey: "VoiceInputView.aiFavoriteCounts") }
    // 学习类大头可能被发端瘦身成空（帧上限），空的不覆盖本地积累
    if let hist = cfg["history"] as? [String], !hist.isEmpty { d.set(hist, forKey: "VoiceInputView.aiHistory") }
    if let corr = cfg["corrections"] as? [[String]], !corr.isEmpty { d.set(corr, forKey: "VoiceInputView.aiCorrections") }
    if let terms = cfg["terms"] as? [String: Any], !terms.isEmpty { d.set(terms, forKey: "VoiceInputView.aiTerms") }

    if let voice = cfg["voice"] as? [String: Any] {
      if let key = voice["apiKey"] as? String, !key.isEmpty { d.set(key, forKey: "VoiceInputView.aiAPIKey") }
      if let model = voice["model"] as? String, !model.isEmpty { d.set(model, forKey: "VoiceInputView.aiModel") }
      if let base = voice["baseURL"] as? String, !base.isEmpty { d.set(base, forKey: "VoiceInputView.aiBaseURL") }
      if let en = voice["enabled"] as? Bool { d.set(en, forKey: "VoiceInputView.aiEnabled") }
      if let db = voice["debounce"] as? Double { d.set(db, forKey: "VoiceInputView.aiDebounce") }
    }
    if let locale = cfg["locale"] as? String, !locale.isEmpty { d.set(locale, forKey: "VoiceInputView.localeIdentifier") }
    if let resting = cfg["resting"] as? [String] { d.set(resting, forKey: "TabRestStore.resting") }
    if let filter = cfg["filterMachineId"] as? String { d.set(filter, forKey: "BlinkTabFilterMachineId") }
    if let ar = cfg["autoReconnect"] as? Bool { d.set(ar, forKey: "BlinkAutoReconnect") }

    // tabs → TabStateStore.syncState（TabState 编码形状），之后 didRestoreNotification
    // 里 SpaceController 走现成的「增量并新 tab + 墓碑删除 + 不切当前 tab」逻辑。
    let tabs = (cfg["tabs"] as? [[String: Any]]) ?? []
    let closedIds = ((cfg["closedIds"] as? [String]) ?? []).filter { UUID(uuidString: $0) != nil }
    var entries: [[String: Any]] = []
    for t in tabs {
      guard let id = t["id"] as? String, UUID(uuidString: id) != nil else { continue }
      var e: [String: Any] = ["id": id]
      if let v = t["machineId"] as? String, !v.isEmpty { e["machineId"] = v }
      if let v = t["workDirId"] as? String, !v.isEmpty { e["workDirId"] = v }
      if let v = t["tmuxSession"] as? String, !v.isEmpty { e["tmuxSession"] = v }
      if let v = t["useTmux"] as? Bool { e["useTmux"] = v }
      entries.append(e)
    }
    if !entries.isEmpty || !closedIds.isEmpty {
      var state: [String: Any] = ["version": 1, "tabs": entries, "updatedAt": stamp, "closedIds": closedIds]
      if let cur = cfg["currentId"] as? String, UUID(uuidString: cur) != nil { state["currentId"] = cur }
      setJSON(state, forKey: TabStateStore.kSyncKey)
    }
  }

  // MARK: 常驻 watcher（同鸿蒙端：Mac 上跑 stat 小循环，mtime 变了吐一行）

  private func ensureWatcher() {
    guard watcher == nil, let ep = firstEndpoint(),
          let port = NWEndpoint.Port(rawValue: UInt16(clamping: ep.port)) else { return }
    let conn = NWConnection(host: NWEndpoint.Host(ep.host), port: port, using: .tcp)
    watcher = conn
    watchBuf = Data()
    let script = "last=\"\"; while true; do cur=$(stat -f %m ~/.blink/sync/blink_config.json 2>/dev/null); "
      + "if [ \"$cur\" != \"$last\" ]; then last=\"$cur\"; echo \"CFGCHANGED:$cur\"; fi; sleep 2; done"
    func frame(_ type: UInt8, _ payload: Data) -> Data {
      var out = Data([type])
      out.append(UInt8((payload.count >> 8) & 0xff))
      out.append(UInt8(payload.count & 0xff))
      out.append(payload)
      return out
    }
    func receiveLoop() {
      conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 14) { [weak self] data, _, complete, err in
        guard let self, self.watcher === conn else { conn.cancel(); return }
        if let data { self.watchBuf.append(data) }
        self.drainWatchLines()
        if err != nil || complete {
          self.watcherDied(conn)
          return
        }
        receiveLoop()
      }
    }
    conn.stateUpdateHandler = { [weak self] st in
      switch st {
      case .ready:
        var out = frame(0x01, Data(ep.token.utf8))
        out.append(frame(0x04, Data(script.utf8)))
        conn.send(content: out, completion: .contentProcessed { _ in })
        receiveLoop()
      case .failed:
        self?.watcherDied(conn)
      default:
        break
      }
    }
    conn.start(queue: .main)
  }

  private func drainWatchLines() {
    guard let s = String(data: watchBuf, encoding: .utf8) else { return }
    var lines = s.components(separatedBy: "\n")
    let tail = lines.removeLast()               // 尾巴可能是半行，留着
    watchBuf = Data(tail.utf8)
    for line in lines {
      guard let r = line.range(of: "CFGCHANGED:") else { continue }
      let mtime = String(line[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      // 首行也触发：连上时文件可能已更新过，漏掉首行会丢那次变更；
      // 多余的拉取由 origin/updatedAt 门槛挡住，无害。
      if !mtime.isEmpty, mtime != lastWatchMtime {
        lastWatchMtime = mtime
        pullNow()
      }
    }
  }

  private func watcherDied(_ conn: NWConnection) {
    guard watcher === conn else { return }
    conn.cancel()
    watcher = nil
    guard !retryScheduled else { return }
    retryScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self else { return }
      self.retryScheduled = false
      if UIApplication.shared.applicationState == .active { self.ensureWatcher() }
    }
  }
}
