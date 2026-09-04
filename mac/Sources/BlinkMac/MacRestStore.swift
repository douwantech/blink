import Foundation

/// 持久化「休息」状态。按 cc-<title>(会话稳定名) 存到 BlinkMac 自己的 UserDefaults，
/// 重启保留、覆盖探测状态（休息优先，跟 iOS `effective = resting ? .rest : status` 一致）。
///
/// 注：iOS 的 TabRestStore 用的是每会话本地随机 UUID，跨设备对不上（iCloud 同步
/// 那串 UUID 实际形同虚设），所以这里用两端都能算的 cc-<title> 作 key，本机持久
/// 但不与手机同步——这是 iOS 现有机制的固有限制。
enum MacRestStore {
    private static let key = "BlinkMac.resting"   // [String] of cc-<title>

    private(set) static var resting: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])

    static func isResting(_ name: String) -> Bool { resting.contains(name) }

    @discardableResult
    static func toggle(_ name: String) -> Bool {
        if resting.contains(name) { resting.remove(name) } else { resting.insert(name) }
        UserDefaults.standard.set(Array(resting), forKey: key)
        return resting.contains(name)
    }
}
