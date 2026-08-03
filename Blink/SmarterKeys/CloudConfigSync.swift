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
  }

  // MARK: 本地 → iCloud

  @objc private func localChanged() {
    guard !applyingRemote else { return }   // 拉回写本地时不要再回推
    schedulePush()
    // 顺手让 Mac 侧的同步文件也跟上（3s 合并窗口直推，不吃 60s 节流），
    // 鸿蒙端的常驻监听靠它做到秒级跟随。
    ConfigSyncPush.shared.noteChanged()
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

// MARK: - 方案一：iOS → Mac 配置单向同步（鸿蒙从 Mac 拉）
//
// 把与鸿蒙 seed_config.json 同形状的配置 JSON 推到每台 blinkd 机器的
// ~/.blink/sync/blink_config.json；鸿蒙端启动/回前台时经 blinkd 拉取，
// updatedAt 比本地新才采纳。触发：App 进后台 + 回前台（60s 节流），
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
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    if let data = try? Data(contentsOf: docs.appendingPathComponent("blink_tabs.json")),
       let st = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      let closed = Set((st["closedIds"] as? [String]) ?? [])
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
