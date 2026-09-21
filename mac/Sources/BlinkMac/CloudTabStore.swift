import Foundation

/// 从 iCloud KV 读手机的「标签」(tab) 列表 —— 连不上的机器（SSH / 离线）靠它显示标签，跟手机一致；
/// 同时提供 cc-title ↔ tab UUID 映射，供「休息」跨设备同步（写 KV 的 TabRestStore.resting）。
///
/// iOS Blink 的 tab 列表存在 `TabStateStore.syncState`，工作目录存在 `BlinkWorkDirStore.workDirs`，
/// 两者都被 CloudConfigSync 镜像进共享 KV（顶层 key，读 KV 不吃 TCC，不像读容器 plist 会卡）。
/// 每个 tab 带 id / machineId / workDirId / tmuxSession；workDirId → 路径 → basename，配合 tmuxSession
/// 按 iOS 同一套规则算出 cc-title，于是标签名和 blinkd 枚举出来的活会话对得上、能一起分组，
/// 而 tab 的 id 正是 iOS「休息」用的那个 UUID。
struct CloudTab {
    let id: String       // tab UUID（= iOS TabRestStore.resting 里存的那个）
    let machineId: String
    let ccName: String   // cc-title（不含 "cc-" 前缀），如 jack-talkai
    let dir: String      // 工作目录绝对路径
}

enum CloudTabStore {
    private static let kTabs = "TabStateStore.syncState"
    private static let kWorkDirs = "BlinkWorkDirStore.workDirs"

    /// 读 KV 里全部有效标签（排除墓碑 closedIds）。KV 空 / dev 版 → []。
    static func tabs() -> [CloudTab] { rawEntries().filter { !$0.closed }.map { $0.tab } }

    /// KV 里「仍打开」的 cc-<title> 集合（小写）。
    static func openCC() -> Set<String> { Set(tabs().map { "cc-" + $0.ccName }) }

    /// KV 里「有 tab 但全部已关（墓碑）」的 cc-<title> 集合（小写）——用来隐藏这些标签。
    /// 只要某个 cc 还有至少一个 open 的 tab，就不算全关（手机重新开了同名 → 解封）。
    static func fullyClosedCC() -> Set<String> {
        var open = Set<String>(); var all = Set<String>()
        for e in rawEntries() {
            let cc = "cc-" + e.tab.ccName
            all.insert(cc)
            if !e.closed { open.insert(cc) }
        }
        return all.subtracting(open)
    }

    /// 标签数据源：优先本机同步文件 `~/.blink/sync/blink_config.json`（iOS / 鸿蒙手机 / 平板都在读写它，
    /// 是三端共同的那份）；文件不可用再退回 iCloud KV。返回 (workDirs, tabs, closedIds)。
    private static func source() -> (workDirs: [[String: Any]], tabs: [[String: Any]], closedIds: [String])? {
        if let f = SyncConfig.read(), (f["machines"] as? [Any])?.isEmpty == false {
            return ((f["workDirs"] as? [[String: Any]]) ?? [],
                    (f["tabs"] as? [[String: Any]]) ?? [],
                    (f["closedIds"] as? [String]) ?? [])
        }
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        guard let td = dataForKey(kv, kTabs),
              let obj = try? JSONSerialization.jsonObject(with: td) as? [String: Any],
              let rawTabs = obj["tabs"] as? [[String: Any]] else { return nil }
        let wds = dataForKey(kv, kWorkDirs)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        return (wds, rawTabs, (obj["closedIds"] as? [String]) ?? [])
    }

    /// 解析全部 tab，带 closed 标记（不提前丢弃墓碑）。
    private static func rawEntries() -> [(tab: CloudTab, closed: Bool)] {
        guard let src = source() else { return [] }

        var dirOf: [String: String] = [:]
        for w in src.workDirs {
            if let id = w["id"] as? String, let path = w["path"] as? String { dirOf[id] = path }
        }

        let rawTabs = src.tabs
        let closedIds = Set(src.closedIds.map { $0.uppercased() })

        var out: [(CloudTab, Bool)] = []
        for t in rawTabs {
            guard let id = t["id"] as? String else { continue }
            guard let mid = t["machineId"] as? String, !mid.isEmpty else { continue }
            let path = (t["workDirId"] as? String).flatMap { dirOf[$0] } ?? ""
            let basename = path.isEmpty ? "" : (path as NSString).lastPathComponent.lowercased()
            var session = ((t["tmuxSession"] as? String) ?? "").lowercased()
            if session.isEmpty || session == "new" { session = basename }
            let title: String
            if basename.isEmpty { title = session.isEmpty ? "shell" : session }
            else { title = CloudRestStore.ccTitle(basename: basename, session: session.isEmpty ? basename : session) }
            out.append((CloudTab(id: id, machineId: mid, ccName: title, dir: path), closedIds.contains(id.uppercased())))
        }
        return out
    }

    /// cc-<title>(小写) → 该 cc 对应的所有 tab UUID。给「休息」跨设备用（不依赖容器/TCC）。
    static func mapping() -> CloudRestStore.Mapping {
        var m = CloudRestStore.Mapping()
        for t in tabs() {
            m.ccToUUIDs[CloudRestStore.key(machineId: t.machineId, cc: "cc-" + t.ccName), default: []].append(t.id)
        }
        return m
    }

    /// 关闭一个标签并同步到 iOS：读回 KV 里**整份** syncState，把该 tab 从 tabs 移除、
    /// 加进 closedIds 墓碑、bump updatedAt 后整份写回。iOS 靠 closedIds 墓碑传播删除
    /// （last-writer-wins）。读整份再改一条，绝不用 Mac 的局部视图重写 tabs，避免误删别的标签。
    /// 返回是否真的动了（KV 里没这个 tab → false）。
    @discardableResult
    static func closeTab(id: String) -> Bool {
        let fileDone = closeTabInSyncFile(id: id)
        // iCloud KV 暂时保留，照旧写一份
        var kvDone = false
        if let obj = mutateSyncState(closingId: id),
           let out = try? JSONSerialization.data(withJSONObject: obj) {
            let kv = NSUbiquitousKeyValueStore.default
            kv.set(out, forKey: kTabs)
            kv.synchronize()
            kvDone = true
        }
        return fileDone || kvDone
    }

    /// 在三端共用的同步文件里关掉一个 tab：从 tabs 移除 + 加进 closedIds 墓碑（没墓碑各端删不掉）。
    /// 文件里没这个 tab → 不写，返回 false。
    private static func closeTabInSyncFile(id: String) -> Bool {
        let upper = id.uppercased()
        guard let f = SyncConfig.read(),
              ((f["tabs"] as? [[String: Any]]) ?? []).contains(where: { ($0["id"] as? String)?.uppercased() == upper })
        else { return false }
        return SyncConfig.patch { obj in
            var tabs = (obj["tabs"] as? [[String: Any]]) ?? []
            tabs.removeAll { ($0["id"] as? String)?.uppercased() == upper }
            var closed = (obj["closedIds"] as? [String]) ?? []
            if !closed.contains(where: { $0.uppercased() == upper }) { closed.append(id) }
            obj["tabs"] = tabs
            obj["closedIds"] = closed
        }
    }

    /// 纯计算（不写 KV）：读 KV 整份 syncState，产出「关闭 id 后」的新对象；没这个 tab → nil。
    /// closeTab 用它落盘；诊断用它做 dry-run（不动真数据）。
    static func mutateSyncState(closingId id: String) -> [String: Any]? {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        guard let td = dataForKey(kv, kTabs),
              var obj = try? JSONSerialization.jsonObject(with: td) as? [String: Any] else { return nil }
        var tabs = (obj["tabs"] as? [[String: Any]]) ?? []
        let upper = id.uppercased()
        let before = tabs.count
        tabs.removeAll { ($0["id"] as? String)?.uppercased() == upper }
        guard tabs.count < before else { return nil }   // KV 里没这个 tab
        var closed = (obj["closedIds"] as? [String]) ?? []
        if !closed.contains(where: { $0.uppercased() == upper }) { closed.append(id) }
        obj["tabs"] = tabs
        obj["closedIds"] = closed
        obj["updatedAt"] = Date().timeIntervalSince1970
        obj["version"] = (obj["version"] as? Int) ?? 1
        return obj
    }

    private static func dataForKey(_ kv: NSUbiquitousKeyValueStore, _ key: String) -> Data? {
        kv.data(forKey: key) ?? kv.string(forKey: key)?.data(using: .utf8)
    }
}
