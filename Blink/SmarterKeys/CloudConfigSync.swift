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
    "BlinkUseTmuxMode",
    "BlinkWorkDirStore.workDirs",
    "BlinkSessionPresetStore.presets",
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
  }

  // MARK: 本地 → iCloud

  @objc private func localChanged() {
    guard !applyingRemote else { return }   // 拉回写本地时不要再回推
    schedulePush()
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
    var dirty = false
    for key in keys {
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

  /// 启动时：本地缺失而云端已有 → 直接拉回。
  private func restoreMissingFromCloud() {
    applyingRemote = true
    for key in keys where defaults.object(forKey: key) == nil {
      if let value = kv.object(forKey: key) {
        defaults.set(value, forKey: key)
      }
    }
    applyingRemote = false
  }

  // MARK: util

  private func plistSize(_ value: Any) -> Int? {
    (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))?.count
  }
}
