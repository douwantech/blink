import Foundation

/// 从 iCloud KV 读手机的「标签」(tab) 列表 —— 连不上的机器（SSH / 离线）靠它显示标签，跟手机一致。
///
/// iOS Blink 的 tab 列表存在 `TabStateStore.syncState`，工作目录存在 `BlinkWorkDirStore.workDirs`，
/// 两者都被 CloudConfigSync 镜像进共享 KV（顶层 key，读 KV 不吃 TCC，不像读容器 plist 会卡）。
/// 每个 tab 带 machineId / workDirId / tmuxSession；workDirId → 路径 → basename，配合 tmuxSession
/// 按 iOS 同一套规则算出 cc-title，于是标签名和 blinkd 枚举出来的活会话对得上、能一起分组。
struct CloudTab {
    let machineId: String
    let ccName: String   // cc-title（不含 "cc-" 前缀），如 jack-talkai
    let dir: String      // 工作目录绝对路径
}

enum CloudTabStore {
    private static let kTabs = "TabStateStore.syncState"
    private static let kWorkDirs = "BlinkWorkDirStore.workDirs"

    /// 读 KV 里全部有效标签（排除墓碑 closedIds）。KV 空 / dev 版 → []。
    static func tabs() -> [CloudTab] {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()

        // workDirId → path
        var dirOf: [String: String] = [:]
        if let wd = dataForKey(kv, kWorkDirs),
           let arr = try? JSONSerialization.jsonObject(with: wd) as? [[String: Any]] {
            for w in arr {
                if let id = w["id"] as? String, let path = w["path"] as? String { dirOf[id] = path }
            }
        }

        guard let td = dataForKey(kv, kTabs),
              let obj = try? JSONSerialization.jsonObject(with: td) as? [String: Any],
              let rawTabs = obj["tabs"] as? [[String: Any]] else { return [] }
        let closed = Set((obj["closedIds"] as? [String] ?? []).map { $0.uppercased() })

        var out: [CloudTab] = []
        for t in rawTabs {
            if let id = t["id"] as? String, closed.contains(id.uppercased()) { continue }
            guard let mid = t["machineId"] as? String, !mid.isEmpty else { continue }
            let path = (t["workDirId"] as? String).flatMap { dirOf[$0] } ?? ""
            let basename = path.isEmpty ? "" : (path as NSString).lastPathComponent.lowercased()
            var session = ((t["tmuxSession"] as? String) ?? "").lowercased()
            if session.isEmpty || session == "new" { session = basename }
            let title: String
            if basename.isEmpty { title = session.isEmpty ? "shell" : session }
            else { title = CloudRestStore.ccTitle(basename: basename, session: session.isEmpty ? basename : session) }
            out.append(CloudTab(machineId: mid, ccName: title, dir: path))
        }
        return out
    }

    private static func dataForKey(_ kv: NSUbiquitousKeyValueStore, _ key: String) -> Data? {
        kv.data(forKey: key) ?? kv.string(forKey: key)?.data(using: .utf8)
    }
}
