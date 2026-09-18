import Foundation

/// 每个「员工」（机器 × tab）开会话时进哪个 CLI。
/// 与 iOS `AgentKind`（Blink/SmarterKeys/TabAgentStore.swift）、鸿蒙同名配置是同一份数据。
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, deepseek
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .deepseek: return "DeepSeek"
        }
    }

    /// 远端实际敲的命令（裸命令，PATH 由登录 shell 提供）
    var command: String {
        switch self {
        case .claude: return "claude --dangerously-skip-permissions"
        case .codex: return "codex"
        case .deepseek: return "deepseek"
        }
    }

    /// 只有 claude 有 ~/.claude/projects 里 customTitle → resume 那套
    var supportsResume: Bool { self == .claude }

    /// SF Symbols（禁 emoji）
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .deepseek: return "water.waves"
        }
    }
}

/// 配置来源跟后台清单（PinnedLinksStore）同一条路：
///   ① `~/.blink/sync/blink_config.json` 的 `agents`（手机一推就到，开发版没 KV 也读得到）；
///   ② iCloud KV `TabAgentStore.agents` 兜底。
/// key = `<machineId>|<title>`，title 就是 tmux 外层会话名 `cc-<TITLE>` 去掉前缀那截。
enum TabAgentStore {
    private static let kAgents = "TabAgentStore.agents"

    static func storeKey(machineId: String, title: String) -> String {
        "\(machineId)|\(title.lowercased())"
    }

    static func all() -> [String: String] {
        if let obj = SyncConfig.read()?["agents"] as? [String: String], !obj.isEmpty { return obj }
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        return (kv.dictionary(forKey: kAgents) as? [String: String]) ?? [:]
    }

    static func agent(machineId: String, title: String) -> AgentKind {
        guard let raw = all()[storeKey(machineId: machineId, title: title)],
              let k = AgentKind(rawValue: raw) else { return .claude }
        return k
    }

    /// 默认值（claude）不落盘，字典只留"非默认"的那几个。
    static func setAgent(_ kind: AgentKind, machineId: String, title: String) {
        var m = all()
        let k = storeKey(machineId: machineId, title: title)
        if kind == .claude { m.removeValue(forKey: k) } else { m[k] = kind.rawValue }
        SyncConfig.patch { $0["agents"] = m }
        let kv = NSUbiquitousKeyValueStore.default
        kv.set(m, forKey: kAgents)
        kv.synchronize()
    }
}

/// `~/.blink/sync/blink_config.json` 的读改写。
///
/// origin 写成 `harmony-mac` 是为了过各端的防回声门槛：iOS 认前缀 `harmony*`、
/// 鸿蒙手机只挡 `harmony`、平板只挡 `harmony-pad`，所以这个值三端都会采纳；
/// 采纳后 iOS 会以 origin=ios 再推一遍，链路回到原样。
/// 除了改动的那个 key 和 origin / updatedAt 之外的字段原样保留，不动别人的配置。
enum SyncConfig {
    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".blink/sync/blink_config.json")
    }

    static func read() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func patch(_ mutate: (inout [String: Any]) -> Void) {
        // machines 为空的多半是半截文件，别在上面盖配置
        guard var obj = read(), (obj["machines"] as? [Any])?.isEmpty == false else { return }
        mutate(&obj)
        obj["origin"] = "harmony-mac"
        obj["updatedAt"] = Date().timeIntervalSince1970
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let tmp = path + ".tmp"
        guard (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                   withItemAt: URL(fileURLWithPath: tmp))
    }
}
