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
    case .codex: return "codex"
    case .deepseek: return "deepseek"
    }
  }

  /// 只有 claude 有 ~/.claude/projects 里的 customTitle → resume 那套；其余直接起
  var supportsResume: Bool { self == .claude }

  /// 可执行名（command -v 拿它判有没有装）
  var bin: String { id }

  /// 没装时自动装的命令；nil = 不自动装（没有可信的官方包，乱装有供应链风险）
  var installCommand: String? {
    switch self {
    case .claude: return nil   // 能开会话说明本来就装着
    case .codex: return "if command -v npm >/dev/null 2>&1; then npm i -g @openai/codex; elif command -v brew >/dev/null 2>&1; then brew install codex; fi"
    case .deepseek: return nil
    }
  }

  /// 装不上时屏幕上给的提示
  var installHint: String {
    switch self {
    case .claude: return "装一下 claude code"
    case .codex: return "手动装：npm i -g @openai/codex 或 brew install codex"
    case .deepseek: return "deepseek 没有官方 CLI，自己装好后把可执行名设成 deepseek"
    }
  }

  /// 起这个 CLI 的整段 shell：没装先装（能自动装的话），装不上就把原因留在屏上。
  /// 外层是 `$SHELL -lic '...'`，里面只能用双引号。
  func launchSnippet(cdTarget: String) -> String {
    let miss = installCommand.map {
      "if ! command -v \(bin) >/dev/null 2>&1; then echo \"[blink] 这台机器没装 \(bin)，正在装…\"; \($0); hash -r 2>/dev/null; fi; "
    } ?? ""
    return "cd \(cdTarget) && { \(miss)if command -v \(bin) >/dev/null 2>&1; then \(command); "
      + "else echo \"[blink] 没有 \(bin)：\(installHint)\"; fi; }"
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
