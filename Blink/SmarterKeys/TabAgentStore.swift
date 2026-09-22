//
//  TabAgentStore.swift
//  每个「员工」（机器 × tab）开会话时进哪个 CLI：claude / codex / deepseek。
//
//  为什么按 机器+tab 记：同一个名字（比如 talkai）在不同机器上是不同的人干不同的活，
//  key 用 "<machineId>|<title>"，title 就是 BlinkMachineStore.ccTitle 算出来的 cc-<TITLE>
//  里那截（也是 tmux 外层 session 名去掉 cc- 前缀），三端一致。
//
//  存 UserDefaults + 进 CloudConfigSync 白名单，同步文件里的 key 叫 "agents"，
//  所以 iOS / macOS / 鸿蒙看到的是同一份配置。默认 claude，选回 claude 就把键删掉
//  （字典只存"非默认"的那几个，省 iCloud KV 配额）。
//

import Foundation

/// tab 打开时进哪个 CLI
@objc(BlinkAgentKind)
enum AgentKind: Int, CaseIterable {
  case claude = 0
  case codex = 1
  case deepseek = 2

  init?(id: String) {
    switch id {
    case "claude": self = .claude
    case "codex": self = .codex
    case "deepseek": self = .deepseek
    default: return nil
    }
  }

  var id: String {
    switch self {
    case .claude: return "claude"
    case .codex: return "codex"
    case .deepseek: return "deepseek"
    }
  }

  /// 菜单里显示的名字
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
    // 跟 claude 的 --dangerously-skip-permissions 对等：跳过全部确认（含新目录的
    // 「信任这个文件夹吗」）并关掉沙箱。放在命令行而不是各机器的 ~/.codex/config.toml，
    // 新机器不用再配一遍。
    case .codex: return "codex --dangerously-bypass-approvals-and-sandbox"
    // DeepSeek 档跑的也是 claude，只是 ANTHROPIC_* 指到 DeepSeek 的兼容端点
    case .deepseek: return "claude --dangerously-skip-permissions"
    }
  }

  /// claude / DeepSeek（也是 claude，只是换了后端）都有 ~/.claude/projects 里
  /// customTitle → resume 那套；codex 没有，直接起。
  var supportsResume: Bool { self != .codex }

  /// 可执行名候选（按顺序 command -v，第一个找得到的就用它起）
  var bins: [String] {
    switch self {
    case .claude: return ["claude"]
    case .codex: return ["codex"]
    case .deepseek: return ["claude"]
    }
  }

  /// 没装时自动装的命令；nil = 不自动装
  var installCommand: String? {
    switch self {
    case .claude: return nil   // 能开会话说明本来就装着
    case .codex:
      return "if command -v npm >/dev/null 2>&1; then npm i -g @openai/codex; elif command -v brew >/dev/null 2>&1; then brew install codex; fi"
    case .deepseek: return nil   // 跑的就是 claude，本来就装着
    }
  }

  /// 装不上时屏幕上给的提示
  var installHint: String {
    switch self {
    case .claude: return "装一下 claude code"
    case .codex: return "手动装：npm i -g @openai/codex 或 brew install codex"
    case .deepseek: return "装一下 claude code"
    }
  }

  /// 起这个 CLI 前要带的环境变量。
  /// DeepSeek 档 = claude 指到 DeepSeek 的 Anthropic 兼容端点：这四个变量 claude 认，
  /// 换掉后端和模型，其余（resume / rename / 工具）跟平时一模一样。
  ///
  /// key 不由 App 下发，**从那台机器自己的 `$DEEPSEEK_API_KEY` 读**（~/.zshrc 里 export）：
  /// 每台机器用自己的 key，App 里不存、不同步，也就不会再被哪一端的旧值盖回去。
  /// 没配就不启动，把怎么配留在屏上——别悄悄退回去跑 Anthropic 的 claude。
  /// 结尾是 `&& `，接在后面的 `cd … && { … }` 前面，没 key 时整条短路。
  var envPrefix: String {
    guard self == .deepseek else { return "" }
    return "if [ -z \"$DEEPSEEK_API_KEY\" ]; then "
      + "echo \"[blink] 这台机器还没配 DeepSeek key：在 ~/.zshrc 里加一行 export DEEPSEEK_API_KEY=sk-…，再重开这个会话\"; false; "
      + "else export ANTHROPIC_BASE_URL=\"\(TabAgentStore.deepseekBaseURL)\"; "
      + "export ANTHROPIC_AUTH_TOKEN=\"$DEEPSEEK_API_KEY\"; "
      + "export ANTHROPIC_MODEL=\"\(TabAgentStore.deepseekModel)\"; "
      + "export ANTHROPIC_SMALL_FAST_MODEL=\"\(TabAgentStore.deepseekSmallModel)\"; fi && "
  }

  /// 起这个 CLI 的整段 shell：没装先装（能自动装的话），装不上就把原因留在屏上。
  /// 外层是 `$SHELL -lic '...'`，里面只能用双引号——别引入单引号。
  func launchSnippet(cdTarget: String) -> String {
    let has = bins.map { "command -v \($0) >/dev/null 2>&1" }.joined(separator: " || ")
    // 官方安装脚本装到 ~/.local/bin，登录 shell 未必带它
    let path = "case \":$PATH:\" in *:\"$HOME/.local/bin\":*) ;; *) PATH=\"$HOME/.local/bin:$PATH\";; esac; "
    let miss = installCommand.map {
      "if ! { \(has); }; then echo \"[blink] 这台机器没装 \(bins[0])，正在装…\"; \($0); hash -r 2>/dev/null; fi; "
    } ?? ""
    var run = ""
    for b in bins {
      let cmd = (b == bins[0]) ? command : b
      run += "if command -v \(b) >/dev/null 2>&1; then \(cmd); el"
    }
    run += "se echo \"[blink] 没有 \(bins.joined(separator: "/"))：\(installHint)\"; "
    run += "fi; "   // elif 串起来的整条只收一个 fi
    return "cd \(cdTarget) && { \(path)\(envPrefix)\(miss)\(run)}"
  }

  /// UI 图标（禁 emoji，统一 SF Symbols）
  var symbol: String {
    switch self {
    case .claude: return "sparkle"
    case .codex: return "chevron.left.forwardslash.chevron.right"
    case .deepseek: return "water.waves"
    }
  }
}

@objc(BlinkTabAgentStore)
final class TabAgentStore: NSObject {
  @objc static let shared = TabAgentStore()

  static let key = "TabAgentStore.agents"
  static let deepseekKeyKey = "TabAgentStore.deepseekKey"
  /// DeepSeek 的 Anthropic 兼容端点与模型（/models 实测可用的两个 id）
  static let deepseekBaseURL = "https://api.deepseek.com/anthropic"
  static let deepseekModel = "deepseek-v4-pro"
  static let deepseekSmallModel = "deepseek-flash"
  /// 改了之后发一下，团队页/侧栏可以刷新行尾的标记
  static let didChangeNotification = Notification.Name("TabAgentStore.didChange")

  private var d: UserDefaults { .standard }

  /// "<machineId>|<title>"，title 统一小写（ccTitle 本来就小写，这里再兜一次）
  static func storeKey(machineId: String, title: String) -> String {
    "\(machineId)|\(title.lowercased())"
  }

  /// 从 cc-<TITLE> 反推 title
  static func title(fromOuterSession s: String) -> String {
    s.hasPrefix("cc-") ? String(s.dropFirst(3)) : s
  }

  /// 以前 App 里存过的 DeepSeek key（设置页那一项已删）：本地和 iCloud KV 里的旧值清掉，
  /// 别让一把 key 留在同步链上。启动调一次，幂等。
  @objc func purgeLegacyDeepSeekKey() {
    guard d.object(forKey: Self.deepseekKeyKey) != nil else { return }
    d.removeObject(forKey: Self.deepseekKeyKey)
    NSUbiquitousKeyValueStore.default.removeObject(forKey: Self.deepseekKeyKey)
    NSUbiquitousKeyValueStore.default.synchronize()
  }

  var all: [String: String] {
    (d.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
  }

  func agent(machineId: String, title: String) -> AgentKind {
    guard let raw = all[Self.storeKey(machineId: machineId, title: title)],
          let k = AgentKind(id: raw) else { return .claude }
    return k
  }

  func setAgent(_ kind: AgentKind, machineId: String, title: String) {
    var m = all
    let k = Self.storeKey(machineId: machineId, title: title)
    if kind == .claude { m.removeValue(forKey: k) } else { m[k] = kind.id }
    d.set(m, forKey: Self.key)
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
  }

  /// 同步文件/KV 拉回来的整份字典（CloudConfigSync 用）
  @objc func replaceAll(_ dict: [String: String]) {
    d.set(dict, forKey: Self.key)
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
  }
}
