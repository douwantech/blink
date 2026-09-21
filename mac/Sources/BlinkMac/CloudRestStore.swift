import Foundation

/// 跨设备「休息」同步（正式版才生效）。
///
/// iOS Blink 把休息状态存成一组 **tab UUID**（`TabRestStore.resting`），并通过 iCloud KV
/// (`NSUbiquitousKeyValueStore`) 跨设备同步。正式版 BlinkMac 用 team 通配的 iCloud KV
/// entitlement（`659T9VUN97.*` → 认领 Blink 的 `659T9VUN97.com.aitools.talkcode.stg`）
/// 直接读写同一份 KV，实现手机⇄Mac 双向。
///
/// Mac 侧会话按 `cc-<title>` 认（title = `basename(workDir)-tmuxSession`），跟 iOS 的 tab UUID
/// 对不上，所以要靠 Blink 容器里的 `TabStateStore.syncState`(tab→workDir) + `BlinkWorkDirStore.workDirs`
/// (workDir→path) 还原出 `cc-title ↔ [tab UUID]` 映射。
///
/// dev 版（SPM/ad-hoc，无 entitlement）读 KV 是空的 → `available` 为 false → 回退本地 [[MacRestStore]]。
enum CloudRestStore {
    static let kvKey = "TabRestStore.resting"
    private static let bundleId = "com.aitools.talkcode.stg"

    /// 会话键 → 该会话对应的所有 tab UUID（同机器同名多 tab 都算）。
    /// 会话键 = `<machineId>/cc-<title>` 小写，跟 Session.id 同格式：同名会话在不同机器上是不同的标签，
    /// 不按机器区分的话，在 mac 上休息 jack-huum 会把 Jun 上的 jack-huum 也一起休息掉。
    struct Mapping { var ccToUUIDs: [String: [String]] = [:] }

    static func key(machineId: String, cc: String) -> String { "\(machineId)/\(cc)".lowercased() }

    /// 是否有可用的共享 KV（正式版签名 + 已同步过才有 key）。dev 版恒 false。
    static var available: Bool {
        if SyncConfig.available { return true }
        let kv = NSUbiquitousKeyValueStore.default
        return !kv.dictionaryRepresentation.isEmpty
    }

    /// 当前休息中的 tab UUID（大写）：优先三端共用的同步文件，没有再读 KV。
    private static func restingUUIDs() -> Set<String> {
        if let f = SyncConfig.read(), (f["machines"] as? [Any])?.isEmpty == false {
            return Set(((f["resting"] as? [String]) ?? []).map { $0.uppercased() })
        }
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        return Set((kv.array(forKey: kvKey) as? [String] ?? []).map { $0.uppercased() })
    }

    // MARK: 读

    /// 从 Blink 容器还原 cc-title ↔ tab UUID 映射。读别的 app 容器会被 TCC 卡，务必 off-main。
    static func loadMapping() -> Mapping {
        guard let url = containerPlist(),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return Mapping() }

        // workDirId → basename(path)（cc-title 的 owner 段）
        var idToBase: [String: String] = [:]
        if let wdData = plist["BlinkWorkDirStore.workDirs"] as? Data,
           let arr = try? JSONSerialization.jsonObject(with: wdData) as? [[String: Any]] {
            for w in arr {
                guard let id = w["id"] as? String, let path = w["path"] as? String else { continue }
                idToBase[id] = (path as NSString).lastPathComponent.lowercased()
            }
        }

        // tabs：id + tmuxSession + workDirId
        var m = Mapping()
        let syncRaw = plist["TabStateStore.syncState"]
        let syncData: Data? = (syncRaw as? Data) ?? (syncRaw as? String)?.data(using: .utf8)
        if let sd = syncData,
           let obj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any],
           let tabs = obj["tabs"] as? [[String: Any]] {
            for t in tabs {
                guard let id = t["id"] as? String,
                      let mid = t["machineId"] as? String, !mid.isEmpty,
                      let session = t["tmuxSession"] as? String, !session.isEmpty,
                      let wid = t["workDirId"] as? String,
                      let base = idToBase[wid] else { continue }
                let cc = "cc-" + ccTitle(basename: base, session: session)
                m.ccToUUIDs[key(machineId: mid, cc: cc), default: []].append(id)
            }
        }
        return m
    }

    /// 当前休息中的会话键集合（UUID → `<machineId>/cc-<title>`）。off-main。
    static func restingCCTitles(_ mapping: Mapping) -> Set<String> {
        let uuids = restingUUIDs()
        guard !uuids.isEmpty else { return [] }
        var out = Set<String>()
        for (cc, ids) in mapping.ccToUUIDs where ids.contains(where: { uuids.contains($0.uppercased()) }) {
            out.insert(cc)
        }
        return out
    }

    // MARK: 写（Mac → 手机）

    /// 把某个 cc-title 的所有对应 tab UUID 写进/移出 KV，Blink 收到 iCloud 变更后同步。
    /// 返回是否真的写了（无映射/无 KV → false，调用方回退本地）。
    @discardableResult
    static func setResting(key: String, on: Bool, mapping: Mapping) -> Bool {
        guard available, let ids = mapping.ccToUUIDs[key.lowercased()], !ids.isEmpty else { return false }
        let upper = Set(ids.map { $0.uppercased() })
        // 同步文件：各端采纳时整份替换 resting，所以写完整数组
        var fileDone = false
        if SyncConfig.available {
            fileDone = SyncConfig.patch { obj in
                var list = (obj["resting"] as? [String]) ?? []
                list.removeAll { upper.contains($0.uppercased()) }
                if on { list.append(contentsOf: ids) }
                obj["resting"] = list
            }
        }
        // iCloud KV 暂时保留，照旧写一份
        let kv = NSUbiquitousKeyValueStore.default
        var kvDone = false
        if !kv.dictionaryRepresentation.isEmpty {
            var set = Set(kv.array(forKey: kvKey) as? [String] ?? [])
            if on { ids.forEach { set.insert($0) } } else { ids.forEach { set.remove($0) } }
            kv.set(Array(set), forKey: kvKey)
            kv.synchronize()
            kvDone = true
        }
        return fileDone || kvDone
    }

    // MARK: cc-title 规则（逐字对齐 iOS BlinkMachineStore.ccTitle）

    /// title = `<basename>-<session>`；session 已是 basename 或以 `basename-` 开头则不再拼。
    static func ccTitle(basename: String, session: String) -> String {
        let s = session.lowercased()
        let b = basename.lowercased()
        if s == b || s.hasPrefix("\(b)-") { return s }
        return "\(b)-\(s)"
    }

    private static func containerPlist() -> URL? {
        let base = NSHomeDirectory() + "/Library/Containers"
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) {
            for d in dirs {
                let p = "\(base)/\(d)/Data/Library/Preferences/\(bundleId).plist"
                if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
            }
        }
        let direct = NSHomeDirectory() + "/Library/Preferences/\(bundleId).plist"
        return FileManager.default.fileExists(atPath: direct) ? URL(fileURLWithPath: direct) : nil
    }
}
