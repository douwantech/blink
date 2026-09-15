import AppKit

/// 读取 iOS Blink 已配置的真实头像。头像存在 blink app 容器的 UserDefaults
/// (`BlinkWorkDirStore.workDirs` 里每个 workDir 的 iconImageData，按人名/项目名 key)。
/// 会话名前缀(owner) 对应 workDir name，取那张图。
enum BlinkAvatars {
    private static let bundleId = "com.aitools.talkcode.stg"

    /// 后台线程加载（读别的 app 容器 plist 会被 TCC 阻塞，绝不能在主线程/渲染里做）。
    static func loadAsync() async -> [String: NSImage] {
        await Task.detached(priority: .utility) { load() }.value
    }

    static func load() -> [String: NSImage] { loadImpl() }

    private static func containerPlist() -> URL? {
        let base = NSHomeDirectory() + "/Library/Containers"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for d in dirs {
            let p = "\(base)/\(d)/Data/Library/Preferences/\(bundleId).plist"
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        // 非沙盒退路
        let direct = NSHomeDirectory() + "/Library/Preferences/\(bundleId).plist"
        return FileManager.default.fileExists(atPath: direct) ? URL(fileURLWithPath: direct) : nil
    }

    private static func loadImpl() -> [String: NSImage] {
        guard let url = containerPlist(),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let wdData = plist["BlinkWorkDirStore.workDirs"] as? Data,
              let arr = try? JSONSerialization.jsonObject(with: wdData) as? [[String: Any]]
        else { return [:] }

        var map: [String: NSImage] = [:]
        for w in arr {
            guard let name = w["name"] as? String else { continue }
            // iconImageData：JSONEncoder 把 Data 编码成 base64 字符串
            guard let b64 = w["iconImageData"] as? String,
                  let imgData = Data(base64Encoded: b64),
                  let img = NSImage(data: imgData) else { continue }
            map[name.lowercased()] = img
        }
        return map
    }
}
