import Foundation

/// 本地「已关闭标签」记录（按 cc-<title>）。持久到 BlinkMac 自己的 UserDefaults，重启保留。
///
/// 为什么需要它：Mac 上关标签，重启后会话是重新枚举（blinkd tmux 还活着）/ 重读 KV 来的，
/// 光靠 KV 墓碑挡不住——① blinkd 实时会话不看 KV tab；② 没对应 KV tab 的会话压根写不了墓碑。
/// 所以本地也记一份，显示时一并过滤。手机重新开同名 tab（KV 里又有 open 的）时会自动解封（见 AppState）。
enum MacClosedStore {
    private static let key = "BlinkMac.closedCC"   // [String] of cc-<title>(小写)

    static var all: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).map { $0.lowercased() })
    }

    static func add(_ cc: String) {
        var s = all; s.insert(cc.lowercased())
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    /// 清掉一批（手机重新开了 → 解封），保持集合不无限增长。
    static func remove(_ ccs: Set<String>) {
        guard !ccs.isEmpty else { return }
        let lowered = Set(ccs.map { $0.lowercased() })
        let s = all.subtracting(lowered)
        UserDefaults.standard.set(Array(s), forKey: key)
    }
}
