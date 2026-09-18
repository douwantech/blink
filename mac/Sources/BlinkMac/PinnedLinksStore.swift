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

/// 后台清单的来源，两条路同一份数据：
///   ① `~/.blink/sync/blink_config.json` 的 `pinned` —— blinkd 同步文件就在本机，
///      手机一推就到，开发版（swift run，没 KV 授权）也读得到，所以优先用它；
///   ② iCloud KV `PinnedTabsStore.tabs` —— 文件不在（没配同步）时的兜底。
enum PinnedLinksStore {
    private static let kPinned = "PinnedTabsStore.tabs"

    static func links() -> [PinnedLink] {
        let fromFile = fromSyncFile()
        if !fromFile.isEmpty { return fromFile }
        return fromCloud() ?? []
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

    /// 在 Mac 上改后台清单：写回同步文件（顺带写 iCloud KV，本机读的是 KV 优先那条路）。
    ///
    /// origin 写成 `harmony-mac` 是为了过各端的防回声门槛：iOS 认前缀 `harmony*`、
    /// 鸿蒙手机只挡 `harmony`、平板只挡 `harmony-pad`，所以这个值三端都会采纳；
    /// 采纳后 iOS 会以 origin=ios 再推一遍，链路回到原样。
    /// 文件里除了 pinned / origin / updatedAt 之外的字段原样保留，不动别人的配置。
    static func save(_ links: [PinnedLink]) {
        let arr: [[String: Any]] = links.map { l in
            var d: [String: Any] = ["title": l.title, "url": l.url]
            if let u = l.authUser, !u.isEmpty { d["authUser"] = u }
            if let p = l.authPassword, !p.isEmpty { d["authPassword"] = p }
            return d
        }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".blink/sync/blink_config.json")
        if let data = FileManager.default.contents(atPath: path),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (obj["machines"] as? [Any])?.isEmpty == false {
            obj["pinned"] = arr
            obj["origin"] = "harmony-mac"
            obj["updatedAt"] = Date().timeIntervalSince1970
            if let out = try? JSONSerialization.data(withJSONObject: obj) {
                let tmp = path + ".tmp"
                if (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil {
                    _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                              withItemAt: URL(fileURLWithPath: tmp))
                }
            }
        }
        if let encoded = try? JSONEncoder().encode(links) {
            let kv = NSUbiquitousKeyValueStore.default
            kv.set(encoded, forKey: kPinned)
            kv.synchronize()
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
