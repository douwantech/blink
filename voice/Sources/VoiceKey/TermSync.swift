import Foundation

/// 词表三端共用：读改写 `~/.blink/sync/blink_config.json` 的 terms 字段（其余字段不动）。
/// 与其他端同一套约定（iOS ConfigSyncPush/adopt、鸿蒙 BlinkStores、Mac BlinkMac SyncConfig）：
///  - 推：读改写，只更新 terms + origin/updatedAt；origin=harmony-mac 过各端防回声门槛
///    （iOS 认前缀 harmony*、鸿蒙手机只挡 harmony、平板只挡 harmony-pad，三端都会采纳）。
///  - 拉：盯 sync 目录（对端写临时文件再 rename，inode 会变，盯目录不盯文件）；
///    origin 不是自己写的、terms 非空才采纳（LWW 整字段，与 iOS adopt 同语义；
///    对端为躲帧上限 slim 成空时不覆盖本地）。
///  - 两头短路防 ping-pong：拉到的词表和本地一样不写；文件里已是这份词表且是自己写的不推。
final class TermSync {
    static let shared = TermSync()

    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".blink/sync/blink_config.json")
    }

    private var pushPending = false
    private var dirSource: DispatchSourceFileSystemObject?
    /// 正在采纳远端词表——此时 LearningStore 的落库不回推（iOS adopting flag 的同款防回声）。
    static var adopting = false

    // MARK: 推（词表变更后防抖 3s；采纳远端时不推）

    func schedulePush() {
        guard !pushPending else { return }
        pushPending = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.pushPending = false
            self.pushNow()
        }
    }

    private func pushNow() {
        guard !Self.adopting else { return }
        // machines 为空的多半是半截文件，别在上面盖配置（同 BlinkMac SyncConfig.patch）
        guard var obj = readConfig(), (obj["machines"] as? [Any])?.isEmpty == false else { return }
        let mine = LearningStore.shared.terms
        if let cur = obj["terms"] as? [String: Any],
           Self.equal(cur, mine), obj["origin"] as? String == "harmony-mac" { return }
        obj["terms"] = mine
        obj["origin"] = "harmony-mac"
        obj["updatedAt"] = Date().timeIntervalSince1970
        guard writeConfig(obj) else { return }
        Diag.log("词表已推到三端同步文件：\(mine.count) 个错词，origin=harmony-mac")
    }

    // MARK: 拉（启动一次 + 盯目录常驻）

    func startWatching() {
        pullNow()
        let dir = (Self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        var pending = false
        src.setEventHandler { [weak self] in
            guard let self, !pending else { return }
            pending = true
            // 一次换文件会连着触发几次，攒 0.5s 再拉（同 BlinkMac watchSyncFile）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                pending = false
                self?.pullNow()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    func pullNow() {
        guard let cfg = readConfig() else { return }
        guard let origin = cfg["origin"] as? String, origin != "harmony-mac" else { return }  // 自己写的不回声
        guard let remote = cfg["terms"] as? [String: Any], !remote.isEmpty else { return }
        if Self.equal(remote, LearningStore.shared.terms) { return }   // 没变化：不写不推，断开回声环
        Self.adopting = true
        LearningStore.shared.adoptTerms(remote)
        Self.adopting = false
        Diag.log("词表已从 \(origin) 采纳：\(remote.count) 个错词")
    }

    // MARK: util

    private func readConfig() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: Self.path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func writeConfig(_ obj: [String: Any]) -> Bool {
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        let tmp = Self.path + ".tmp"
        guard (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return false }
        return (try? FileManager.default.replaceItemAt(URL(fileURLWithPath: Self.path),
                                                       withItemAt: URL(fileURLWithPath: tmp))) != nil
    }

    /// 两份词表是否等值：JSON 规范化后逐字节比，绕开 NSDictionary/NSNumber 与 Swift 类型的 isEqual 差异。
    private static func equal(_ a: [String: Any], _ b: [String: [String: Int]]) -> Bool {
        guard let ja = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let jb = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
        return ja == jb
    }
}
