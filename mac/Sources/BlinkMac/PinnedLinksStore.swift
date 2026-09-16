import Foundation

/// 浏览器「后台」列表里的一条：管理后台网址 + 可选的 HTTP Basic 账密。
/// 与 iOS `PinnedTab`（Blink/PinnedBrowser.swift）、鸿蒙 `PinnedTab`（BlinkStores.ets）同一份数据。
struct PinnedLink: Codable, Equatable, Identifiable {
    var title: String
    var url: String
    var authUser: String?
    var authPassword: String?

    var id: String { url + "|" + title }

    var host: String { URL(string: url)?.host ?? url }
}

/// 后台清单的来源（只读，改动仍然在手机/平板上做，同步链路照旧）：
///   ① iCloud KV `PinnedTabsStore.tabs` —— 签名版（make app）才有 KV 授权；
///   ② `~/.blink/sync/blink_config.json` 的 `pinned` —— blinkd 同步文件就在本机，
///      开发版（swift run，无 KV）也读得到，两边内容是同一份。
enum PinnedLinksStore {
    private static let kPinned = "PinnedTabsStore.tabs"

    static func links() -> [PinnedLink] {
        if let fromKV = fromCloud(), !fromKV.isEmpty { return fromKV }
        return fromSyncFile()
    }

    private static func fromCloud() -> [PinnedLink]? {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        guard let data = kv.data(forKey: kPinned) ?? kv.string(forKey: kPinned)?.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([PinnedLink].self, from: data)
    }

    private static func fromSyncFile() -> [PinnedLink] {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".blink/sync/blink_config.json")
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pinned = obj["pinned"] as? [[String: Any]] else { return [] }
        return pinned.compactMap { p in
            guard let url = p["url"] as? String, !url.isEmpty else { return nil }
            return PinnedLink(title: (p["title"] as? String) ?? "",
                              url: url,
                              authUser: p["authUser"] as? String,
                              authPassword: p["authPassword"] as? String)
        }
    }

    /// 该 host 的 Basic 账密（后台清单里存的）
    static func credentials(forHost host: String) -> (String, String)? {
        for l in links() {
            guard let u = l.authUser, !u.isEmpty, let p = l.authPassword, !p.isEmpty,
                  URL(string: l.url)?.host == host else { continue }
            return (u, p)
        }
        return nil
    }
}
