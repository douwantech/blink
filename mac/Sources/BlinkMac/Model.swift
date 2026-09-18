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
    /// 手机上配成 SSH 的机器：Mac 版没有 SSH 客户端，只能列出来、点开给提示，连不了。
    case ssh(user: String, host: String)

    var isRemote: Bool { if case .blinkd = self { return true }; return false }
    /// Mac 端能否真正建连接（只有 blinkd / 本地能）。
    var connectable: Bool { if case .ssh = self { return false }; return true }
    /// 顶栏徽标文案：blinkd 连接直接带上实际 IP（本机 127.0.0.1 / 远程对应 IP），
    /// 一眼看清走的是哪台/哪条链路，不再只写「本地」这种模糊词。
    var badge: String {
        if case .blinkd(let host, _, _) = self { return "blinkd · \(host)" }
        return "blinkd"
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
    /// 这个员工现在在干嘛：读 claude 自己的 jsonl 得来（正在 Edit · xxx / 它最后说的话 / 你说：…）
    var doing: String = ""
    /// 上面那条距今多少秒（jsonl 的 mtime），-1 = 不知道
    var doingAgo: Int = -1

    /// owner = 会话名第一段（jack-talkai → jack），用来对上 iOS 配的头像。
    var owner: String { name.split(separator: "-").first.map(String.init) ?? name }
    /// project = 第一段之后（jack-talkai → talkai），用于按项目排序。
    var project: String {
        let parts = name.split(separator: "-", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : name
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

// MARK: - Gradients

enum Grad {
    static let blue   = [Color(hex: 0x4ea8ff), Color(hex: 0x8f8cff)]
    static let amber  = [Color(hex: 0xf5a83d), Color(hex: 0xff5a5c)]
    static let green  = [Color(hex: 0x40d68c), Color(hex: 0x63d3e8)]
    static let purple = [Color(hex: 0x8f8cff), Color(hex: 0x5a57c9)]
    static let slate  = [Color(hex: 0x757f8f), Color(hex: 0x4a515c)]
}
