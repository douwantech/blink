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

    /// 起的时候统一带上的参数：三家都是「免确认 + 不进沙箱」，只是叫法不同
    var args: String {
        switch self {
        case .claude: return " --dangerously-skip-permissions"
        case .codex: return " --dangerously-bypass-approvals-and-sandbox"
        case .deepseek: return " --approval-policy never --sandbox-mode danger-full-access"
        }
    }

    /// 远端实际敲的命令（裸命令，PATH 由登录 shell 提供）
    var command: String { bins[0] + args }

    /// 只有 claude 有 ~/.claude/projects 里的 customTitle → resume 那套；其余直接起。
    /// DeepSeek 档换回独立 TUI（Codewhale）后也走裸起——claude 接 DeepSeek 后端那套
    /// 每轮都要把整段上下文重发一遍，一天光缓存读就 5 亿 token，太费。
    var supportsResume: Bool { self == .claude }

    /// 可执行名候选（按顺序 command -v，第一个找得到的就用它起）
    var bins: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        // 「deepseek tui」实际是 Codewhale（github.com/Hmbown/Codewhale）：
        // 机器上自己装了叫 deepseek 的就用它，否则用 codewhale。
        case .deepseek: return ["deepseek", "codewhale"]
        }
    }

    /// 没装时自动装的命令；nil = 不自动装
    var installCommand: String? {
        switch self {
        case .claude: return nil   // 能开会话说明本来就装着
        case .codex:
            return "if command -v npm >/dev/null 2>&1; then npm i -g @openai/codex; elif command -v brew >/dev/null 2>&1; then brew install codex; fi"
        case .deepseek:
            // README 给的官方装法，装到 ~/.local/bin
            return "if command -v curl >/dev/null 2>&1; then curl -fsSL https://codewhale.net/install.sh | sh; fi"
        }
    }

    /// 装不上时屏幕上给的提示
    var installHint: String {
        switch self {
        case .claude: return "装一下 claude code"
        case .codex: return "手动装：npm i -g @openai/codex 或 brew install codex"
        case .deepseek: return "手动装：curl -fsSL https://codewhale.net/install.sh | sh"
        }
    }

    /// 起这个 CLI 前的环境准备。Codewhale 自己认 $DEEPSEEK_API_KEY（auth status 里
    /// provider=deepseek、来源 env），所以只要确保这个变量在就行。
    ///
    /// key 不由 App 下发，**从那台机器自己的 ~/.zshrc 读**：每台机器用自己的 key，
    /// App 里不存、不同步，不会再被哪一端的旧值盖回去。没配就不启动，把怎么配留在屏上。
    /// 结尾是 `&& `，接在后面的 `cd … && { … }` 前面，没 key 时整条短路。
    var envPrefix: String {
        guard self == .deepseek else { return "" }
        // 往现有 shell 里 source 启动文件时（会话还在的自愈路径），那个 shell 可能是
        // 在 ~/.zshrc 加 key 之前开的，没有这个变量——先自己去 ~/.zshrc 捞一次。
        return "[ -z \"$DEEPSEEK_API_KEY\" ] && [ -f \"$HOME/.zshrc\" ] && eval \"$(grep \"^export DEEPSEEK_API_KEY=\" \"$HOME/.zshrc\" | tail -1)\"; "
            + "if [ -z \"$DEEPSEEK_API_KEY\" ]; then "
            + "echo \"[blink] 这台机器还没配 DeepSeek key：在 ~/.zshrc 里加一行 export DEEPSEEK_API_KEY=sk-…，再重开这个会话\"; false; "
            + "else export DEEPSEEK_API_KEY; fi && "
    }

    /// 起这个 CLI 的整段 shell：没装先装（能自动装的话），装不上就把原因留在屏上。
    func launchSnippet(cdTarget: String) -> String {
        let has = bins.map { "command -v \($0) >/dev/null 2>&1" }.joined(separator: " || ")
        // 官方安装脚本装到 ~/.local/bin，登录 shell 未必带它
        let path = "case \":$PATH:\" in *:\"$HOME/.local/bin\":*) ;; *) PATH=\"$HOME/.local/bin:$PATH\";; esac; "
        let miss = installCommand.map {
            "if ! { \(has); }; then echo \"[blink] 这台机器没装 \(bins[0])，正在装…\"; \($0); hash -r 2>/dev/null; fi; "
        } ?? ""
        var run = ""
        for b in bins {
            let cmd = b + args
            run += "if command -v \(b) >/dev/null 2>&1; then \(cmd); el"
        }
        run += "se echo \"[blink] 没有 \(bins.joined(separator: "/"))：\(installHint)\"; "
        run += "fi; "   // elif 串起来的整条只收一个 fi
        // envPrefix 放在 cd 前面：它以 `&& ` 收尾，没配 key 时整条短路，不会往下把 TUI 起起来
        return envPrefix + "cd \(cdTarget) && { \(path)\(miss)\(run)}"
    }

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

    /// 同步文件可用：存在且 machines 非空（空的多半是半截文件）。
    static var available: Bool { (read()?["machines"] as? [Any])?.isEmpty == false }

    /// 返回是否真的写回了文件。
    @discardableResult
    static func patch(_ mutate: (inout [String: Any]) -> Void) -> Bool {
        // machines 为空的多半是半截文件，别在上面盖配置
        guard var obj = read(), (obj["machines"] as? [Any])?.isEmpty == false else { return false }
        mutate(&obj)
        obj["origin"] = "harmony-mac"
        obj["updatedAt"] = Date().timeIntervalSince1970
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        let tmp = path + ".tmp"
        guard (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return false }
        return (try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                       withItemAt: URL(fileURLWithPath: tmp))) != nil
    }
}
