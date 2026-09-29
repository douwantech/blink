import Foundation

/// 「有 tmux 会话、但三端共用的同步文件里没标签」的会话（脚本 / agent 直接起的），
/// 补成标签写回同步文件，iPhone、鸿蒙手机、平板就都能看到，任何一端关掉三端一起消失。
///
/// **本机和远程机器都做。** 远程机器的工作目录不能拿本机文件系统当准
/// （Jun 的 `/Users/mac/Codes/quan` 在这台 Mac 上根本不存在），所以「目录在不在」由调用方
/// 在那台机器上 `test -d` 查好了塞进 `Scan.existingDirs`，这里只认这个集合。
///
/// 只补「上次扫描之后新起的」会话（按 tmux session_created）：在别的设备上关掉的标签，
/// tmux 还活着，但创建时间早于基线，不会被重新补回来。基线**按机器分开存**，
/// 某台机器第一次扫描时没有基线，把它当时的孤儿补一遍（本机沿用老 key，
/// 免得升级后把早先关掉的旧标签又翻出来）。
///
/// 补不了的（找不到三端算得出同名的工作目录）记进 skipped 名单，下次继续试 ——
/// 否则等用户把缺的工作目录配上，这些会话已经被基线挡在外面，永远补不进来了。
///
/// 三端算会话名的规则不完全一样：iOS 用工作目录显示名，Mac / 鸿蒙用路径 basename。
/// 所以只挑「显示名 == 路径 basename」的工作目录，并把 tmuxSession 直接存成完整标题
/// （以 `<basename>-` 开头），三端都会算回同一个 cc-名。找不到这样的工作目录就不补，
/// 免得 iPhone 点开时新建一个空会话。
enum OrphanTabAdopter {
    private static let kSince = "BlinkMac.adoptSince"
    private static let kSkipped = "BlinkMac.adoptSkipped"
    private static let kDirsSig = "BlinkMac.adoptDirsSig"

    /// 一条活着的 tmux 会话。
    struct Live: Sendable, Equatable {
        let title: String     // 不含 "cc-" 前缀，小写
        let created: Double   // epoch 秒
    }

    /// 一台机器的扫描结果，交给 `adopt(_:)` 统一写回。
    struct Scan: Sendable {
        let machineId: String
        let isLocal: Bool
        let live: [Live]
        /// 这台机器上确实存在的工作目录绝对路径（远程机器由调用方 `test -d` 查出来）
        let existingDirs: Set<String>
    }

    struct Result: Sendable {
        var adopted: [String] = []
        var skipped: [String] = []
    }

    // MARK: - 解析

    /// `tmux list-sessions -F '#{session_name}\t#{session_created}'` 的输出 → Live 列表。
    /// PTY 输出行尾是 \r\n，Swift 里它是一个 Character，按 "\n" 切不开，要用 isNewline。
    static func parseLive(_ out: String) -> [Live] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: "\t")
            guard p.count >= 2, p[0].hasPrefix("cc-"),
                  let t = Double(p[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return Live(title: String(p[0].dropFirst(3)).lowercased(), created: t)
        }
    }

    // MARK: - 候选

    /// 本机沿用老 key（升级不丢基线），远程机器各存各的。
    private static func sinceKey(_ machineId: String, isLocal: Bool) -> String {
        isLocal ? kSince : "\(kSince).\(machineId)"
    }

    private static func skippedKey(_ machineId: String) -> String { "\(kSkipped).\(machineId)" }

    /// 工作目录清单的指纹。跳过的那些只在这个变了（用户加了工作目录）之后才重试 ——
    /// 否则每次回前台都要为几个永远补不上的会话多跑一趟 `test -d`（远程是一次 ssh 往返）。
    private static func dirsSignature(_ file: [String: Any]) -> String {
        usableDirs(file).map(\.path).sorted().joined(separator: "\n")
    }

    /// 这台机器上还没补过的孤儿会话。空的话调用方就不用再去探目录了。
    ///
    /// 两类：① 基线之后新起的；② 上次因为找不到工作目录被跳过、这次还活着，
    /// 且工作目录清单变过（否则结果必然还是补不上，白跑一趟）。
    static func pending(machineId: String, isLocal: Bool, live: [Live]) -> [Live] {
        let since = UserDefaults.standard.double(forKey: sinceKey(machineId, isLocal: isLocal))
        let firstRun = since == 0
        let dirsChanged = SyncConfig.read().map { dirsSignature($0) }
            != UserDefaults.standard.string(forKey: kDirsSig)
        let retry = dirsChanged
            ? Set(UserDefaults.standard.stringArray(forKey: skippedKey(machineId)) ?? [])
            : Set<String>()
        let existing = Set(CloudTabStore.tabs().filter { $0.machineId == machineId }.map { $0.ccName.lowercased() })
        return live.filter { l in
            !existing.contains(l.title) && (firstRun || l.created > since || retry.contains(l.title))
        }
    }

    /// 同步文件里「显示名和 basename 一致」的工作目录 —— 只有这种三端才会算出同一个名字。
    /// workDirs 里没有 machineId（是全局的），哪台机器有哪个目录只能靠在那台上查路径。
    private static func usableDirs(_ file: [String: Any]) -> [(id: String, path: String, base: String)] {
        ((file["workDirs"] as? [[String: Any]]) ?? []).compactMap { w in
            guard let id = w["id"] as? String, let path = w["path"] as? String, !path.isEmpty else { return nil }
            let base = (path as NSString).lastPathComponent.lowercased()
            let name = ((w["name"] as? String) ?? "").lowercased()
            // 显示名跟 basename 一致（或没设显示名），且不含空格 / 引号，三端才会算出同一个名字
            guard name.isEmpty || name == base, !base.contains(" "), !base.contains("\"") else { return nil }
            return (id, path, base)
        }
    }

    /// 这批孤儿可能用得上的工作目录路径 —— 调用方拿去在目标机器上 `test -d`。
    static func dirsToProbe(for live: [Live]) -> [String] {
        guard let file = SyncConfig.read() else { return [] }
        return usableDirs(file)
            .filter { d in live.contains { $0.title.hasPrefix(d.base + "-") } }
            .map(\.path)
    }

    // MARK: - 写回

    /// 把几台机器的孤儿一次性补成标签。
    /// 同步文件是读-改-写，几台分开写会互相盖掉，所以这里只 patch 一次。
    static func adopt(_ scans: [Scan]) -> Result {
        var r = Result()
        guard let file = SyncConfig.read(), (file["machines"] as? [Any])?.isEmpty == false else { return r }
        let scanAt = Date().timeIntervalSince1970
        let dirs = usableDirs(file)

        var newTabs: [[String: Any]] = []
        var baselines: [String: Double] = [:]      // sinceKey → scanAt
        var stillSkipped: [String: [String]] = [:] // machineId → 这次仍没补上的

        for s in scans {
            baselines[sinceKey(s.machineId, isLocal: s.isLocal)] = scanAt
            var missed: [String] = []
            for c in pending(machineId: s.machineId, isLocal: s.isLocal, live: s.live) {
                // 同一个标题可能匹配到多个目录（如 quan 和 quan-x），取 basename 最长的那个
                let hits = dirs.filter { s.existingDirs.contains($0.path) && c.title.hasPrefix($0.base + "-") }
                guard let wd = hits.max(by: { $0.base.count < $1.base.count }) else {
                    missed.append(c.title)
                    r.skipped.append(c.title)
                    continue
                }
                newTabs.append([
                    "id": UUID().uuidString,
                    "machineId": s.machineId,
                    "workDirId": wd.id,
                    "tmuxSession": c.title,
                    "useTmux": true,
                ])
                r.adopted.append(c.title)
            }
            stillSkipped[s.machineId] = missed
        }

        if !newTabs.isEmpty {
            let ok = SyncConfig.patch { obj in
                obj["tabs"] = ((obj["tabs"] as? [[String: Any]]) ?? []) + newTabs
            }
            if !ok { return Result(adopted: [], skipped: r.skipped + r.adopted) }   // 没写成，下次再试
        }
        for (k, v) in baselines { UserDefaults.standard.set(v, forKey: k) }
        UserDefaults.standard.set(dirsSignature(file), forKey: kDirsSig)
        for (mid, list) in stillSkipped {
            if list.isEmpty { UserDefaults.standard.removeObject(forKey: skippedKey(mid)) }
            else { UserDefaults.standard.set(list, forKey: skippedKey(mid)) }
        }
        return r
    }
}
