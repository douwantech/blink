import Foundation

/// 收藏短语（跟手机同一套 key：`VoiceInputView.aiFavorites` + `aiFavoriteCounts`）。
/// 这两个 key 由 iOS CloudConfigSync 逐 key 镜像到 iCloud KV（顶层 key），所以正式版
/// 直接读写 KV 即跨设备同步；dev 版（无 entitlement）走本地 UserDefaults。
///
/// 逐字对齐 iOS AITextPolisher 收藏模型：加入序存储、去重、无上限；显示按 count 降序，
/// 同 count 按加入序新→旧。
enum FavoritesStore {
    static let kFav = "VoiceInputView.aiFavorites"
    static let kCounts = "VoiceInputView.aiFavoriteCounts"

    private static func rawFavorites(cloud: Bool) -> [String] {
        cloud ? (NSUbiquitousKeyValueStore.default.array(forKey: kFav) as? [String] ?? [])
              : (UserDefaults.standard.stringArray(forKey: kFav) ?? [])
    }
    private static func counts(cloud: Bool) -> [String: Int] {
        let raw = cloud ? NSUbiquitousKeyValueStore.default.dictionary(forKey: kCounts)
                        : UserDefaults.standard.dictionary(forKey: kCounts)
        return (raw as? [String: Int]) ?? (raw?.compactMapValues { ($0 as? NSNumber)?.intValue } ?? [:])
    }
    private static func setFav(_ v: [String], cloud: Bool) {
        if cloud { let kv = NSUbiquitousKeyValueStore.default; kv.set(v, forKey: kFav); kv.synchronize() }
        else { UserDefaults.standard.set(v, forKey: kFav) }
    }
    private static func setCounts(_ v: [String: Int], cloud: Bool) {
        if cloud { let kv = NSUbiquitousKeyValueStore.default; kv.set(v, forKey: kCounts); kv.synchronize() }
        else { UserDefaults.standard.set(v, forKey: kCounts) }
    }

    /// 排好序的收藏：count 降序；同 count 按加入序新→旧。
    static func entries(cloud: Bool) -> [String] {
        let c = counts(cloud: cloud)
        return rawFavorites(cloud: cloud).enumerated().sorted { l, r in
            let lc = c[l.element] ?? 0, rc = c[r.element] ?? 0
            return lc != rc ? lc > rc : l.offset > r.offset
        }.map { $0.element }
    }

    static func isFavorited(_ text: String, cloud: Bool) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && rawFavorites(cloud: cloud).contains(t)
    }

    static func add(_ text: String, cloud: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var arr = rawFavorites(cloud: cloud)
        guard !arr.contains(t) else { return }
        arr.append(t); setFav(arr, cloud: cloud)
    }

    static func remove(_ text: String, cloud: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var arr = rawFavorites(cloud: cloud); arr.removeAll { $0 == t }; setFav(arr, cloud: cloud)
        var c = counts(cloud: cloud); c.removeValue(forKey: t); setCounts(c, cloud: cloud)
    }

    /// 用过一次 +1，用于排序（同手机 incrementFavoriteUseCount）。
    static func incrementUse(_ text: String, cloud: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, rawFavorites(cloud: cloud).contains(t) else { return }
        var c = counts(cloud: cloud); c[t, default: 0] += 1; setCounts(c, cloud: cloud)
    }
}
