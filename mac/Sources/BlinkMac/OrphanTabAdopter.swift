import Foundation

/// 本机 Mac 上「有 tmux 会话、但三端共用的同步文件里没标签」的会话（脚本 / agent 直接起的），
/// 补成标签写回同步文件，iPhone、鸿蒙手机、平板就都能看到，任何一端关掉三端一起消失。
///
/// 只补「上次扫描之后新起的」会话（按 tmux session_created）：在别的设备上关掉的标签，
/// tmux 还活着，但创建时间早于基线，不会被重新补回来。第一次运行没有基线，把当时的孤儿补一遍。
///
/// 三端算会话名的规则不完全一样：iOS 用工作目录显示名，Mac / 鸿蒙用路径 basename。
/// 所以只挑「显示名 == 路径 basename、且路径在这台 Mac 上存在」的工作目录，
/// 并把 tmuxSession 直接存成完整标题（以 `<basename>-` 开头），三端都会算回同一个 cc-名。
/// 找不到这样的工作目录就不补（返回 skipped），免得 iPhone 点开时新建一个空会话。
enum OrphanTabAdopter {
    private static let kSince = "BlinkMac.adoptSince"

    struct Result: Sendable {
        var adopted: [String] = []
        var skipped: [String] = []
    }

    /// live：本机 tmux 会话（title 不含 "cc-" 前缀，小写）+ 创建时间（epoch 秒）。
    static func adopt(machineId: String, live: [(title: String, created: Double)]) -> Result {
        var r = Result()
        guard let file = SyncConfig.read(), (file["machines"] as? [Any])?.isEmpty == false else { return r }
        let scanAt = Date().timeIntervalSince1970
        let since = UserDefaults.standard.double(forKey: kSince)
        let firstRun = since == 0

        let existing = Set(CloudTabStore.tabs().filter { $0.machineId == machineId }.map { $0.ccName.lowercased() })
        let candidates = live.filter { !existing.contains($0.title) && (firstRun || $0.created > since) }

        let fm = FileManager.default
        let dirs: [(id: String, base: String)] = ((file["workDirs"] as? [[String: Any]]) ?? []).compactMap { w in
            guard let id = w["id"] as? String, let path = w["path"] as? String, !path.isEmpty,
                  fm.fileExists(atPath: path) else { return nil }
            let base = (path as NSString).lastPathComponent.lowercased()
            let name = ((w["name"] as? String) ?? "").lowercased()
            // 显示名跟 basename 一致（或没设显示名），且不含空格 / 引号，三端才会算出同一个名字
            guard name.isEmpty || name == base, !base.contains(" "), !base.contains("\"") else { return nil }
            return (id, base)
        }

        var newTabs: [[String: Any]] = []
        for c in candidates {
            let hits = dirs.filter { c.title.hasPrefix($0.base + "-") }
            guard let wd = hits.max(by: { $0.base.count < $1.base.count }) else {
                r.skipped.append(c.title)
                continue
            }
            newTabs.append([
                "id": UUID().uuidString,
                "machineId": machineId,
                "workDirId": wd.id,
                "tmuxSession": c.title,
                "useTmux": true,
            ])
            r.adopted.append(c.title)
        }

        if !newTabs.isEmpty {
            let ok = SyncConfig.patch { obj in
                obj["tabs"] = ((obj["tabs"] as? [[String: Any]]) ?? []) + newTabs
            }
            if !ok { return Result(adopted: [], skipped: r.skipped + r.adopted) }   // 没写成，下次再试
        }
        UserDefaults.standard.set(scanAt, forKey: kSince)
        return r
    }
}
