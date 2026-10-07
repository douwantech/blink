import SwiftUI

// MARK: - Session status

enum WorkStatus: String, CaseIterable, Identifiable {
    case wait, work, idle, rest
    var id: String { rawValue }

    var label: String {
        switch self {
        case .wait: return "等你"
        case .work: return "干活中"
        case .idle: return "空闲"
        case .rest: return "休息"
        }
    }
    var color: Color {
        switch self {
        case .wait: return Theme.wait
        case .work: return Theme.work
        case .idle: return Theme.idle
        case .rest: return Theme.rest
        }
    }
    var symbol: String {
        switch self {
        case .wait: return "bell.fill"
        case .work: return "bolt.fill"
        case .idle: return "checkmark.circle"
        case .rest: return "moon.zzz.fill"
        }
    }
}

// MARK: - Terminal line

struct TermLine: Identifiable {
    let id = UUID()
    var prefix: String = ""
    var prefixColor: Color = .clear
    var text: String
    var color: Color = Theme.fg
    var italic: Bool = false
}

struct ChatBlock: Identifiable {
    let id = UUID()
    var role: String        // "YOU" / "ASSISTANT"
    var color: Color
    var text: String
}

// MARK: - Machine & Session

enum Transport {
    case local
    case blinkd(host: String, port: UInt16, token: String)
    /// 手机上配成 SSH 的机器：Mac 端用系统 /usr/bin/ssh 连（开会话走 SSHBackend，
    /// 跑单条命令走 SSHExec），要免密才行。
    case ssh(user: String, host: String)
    /// #25：KV 里声明走 blinkd（transport=="blinkd"）但 daemon 三件套没同步过来
    /// （旧数据 / iOS 未升级物化）。这类机器只开 blinkd 没开 sshd——不静默降级 SSH
    /// （降级只会连不上，还掩盖「配置没同步」这个真因），rail 标 ⚠、header 写明，
    /// 手机升级后启动会物化旧配置；无内置默认的机器需补齐 Socket 字段。
    case unconfigured

    var isRemote: Bool { if case .blinkd = self { return true }; return false }
    var isUnconfigured: Bool { if case .unconfigured = self { return true }; return false }
    /// 能否「自动」枚举/探测：SSH 要免密且每次最多等 8 秒，批量拉会话时跳过它，
    /// 改用 iCloud KV 里手机配的标签。**不要拿它当「能不能跑命令」的门槛** ——
    /// SSH 跑单条命令是通的，误用会让切 CLI、刷新这类动作在 SSH 机器上静默失效。
    var connectable: Bool {
        if case .ssh = self { return false }
        if case .unconfigured = self { return false }
        return true
    }
    /// 顶栏徽标文案：blinkd 连接直接带上实际 IP（本机 127.0.0.1 / 远程对应 IP），
    /// 一眼看清走的是哪台/哪条链路，不再只写「本地」这种模糊词。
    var badge: String {
        if case .blinkd(let host, _, _) = self { return "blinkd · \(host)" }
        if case .unconfigured = self { return "blinkd 未配置" }
        return "blinkd"
    }

    /// 机器清单热重载（#25 顺带）用的变化指纹：内容全同视为没变，避免 KV 每次回调都重建 rail。
    var fingerprint: String {
        switch self {
        case .local: return "local"
        case .blinkd(let h, let p, let t): return "blinkd(\(h):\(p):\(t.hashValue))"
        case .ssh(let u, let h): return "ssh(\(u)@\(h))"
        case .unconfigured: return "unconfigured"
        }
    }
}

struct Machine: Identifiable {
    let id: String
    var name: String
    var host: String
    var initials: String
    var grad: [Color]
    var online: Bool = true
    var transport: Transport = .local
    /// blinkd 连不上时可用的 SSH 路径；本机 daemon 不需要回退。
    var sshFallback: (user: String, host: String)? = nil
    /// claude-code 是否跑在这台 Mac 上（本机 / isThisMac 的 blinkd）。true=本机贴图走原生
    /// （claude 直接读本机剪贴板）；false=远程，贴图要上传图床再插 URL。
    var isLocalMac: Bool = true
}

struct Session: Identifiable {
    let id: String
    var machineID: String
    var name: String
    var dir: String
    var initials: String
    var grad: [Color]
    var status: WorkStatus       // 只剩 休息 / 空闲 两档：不再探测「等你/干活中」那一套
    var lines: [TermLine]
    var chat: [ChatBlock] = []
    /// 真实的 tmux session 名（如 "cc-jack-talkai"）。设了就 attach 它，而不是新建。
    var tmuxName: String? = nil
    /// 枚举完成前的占位会话，不建终端后端。
    var placeholder: Bool = false

    /// owner = 会话名第一段（jack-talkai → jack），用来对上 iOS 配的头像。
    var owner: String { name.split(separator: "-").first.map(String.init) ?? name }
    /// 与 iOS 团队页一致，项目取最后一个连字符之后。
    var project: String {
        name.split(separator: "-").last.map(String.init) ?? name
    }
}

struct TeamMember: Identifiable {
    let id = UUID()
    var initials: String
    var grad: [Color]
    var title: String
    var sub: String
    var status: WorkStatus
    var note: String = ""
    var showMoon: Bool = false
}

enum TerminalMode { case terminal, chat }
enum InspectorMode: String { case employee, project, machine }

/// 员工列表的一组（真实会话），按员工/项目/机器聚合。
struct TeamGroup: Identifiable {
    let id: String
    let title: String
    let sub: String
    let sessions: [Session]
}

struct TeamSection: Identifiable {
    let id: String
    let title: String?
    let groups: [TeamGroup]
}

// MARK: - Gradients

enum Grad {
    static let blue   = [Color(hex: 0x4ea8ff), Color(hex: 0x8f8cff)]
    static let amber  = [Color(hex: 0xf5a83d), Color(hex: 0xff5a5c)]
    static let green  = [Color(hex: 0x40d68c), Color(hex: 0x63d3e8)]
    static let purple = [Color(hex: 0x8f8cff), Color(hex: 0x5a57c9)]
    static let slate  = [Color(hex: 0x757f8f), Color(hex: 0x4a515c)]
}
