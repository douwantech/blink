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

struct Machine: Identifiable {
    let id: String
    var name: String
    var host: String
    var initials: String
    var grad: [Color]
    var online: Bool = true
}

struct Session: Identifiable {
    let id: String
    var machineID: String
    var name: String
    var dir: String
    var initials: String
    var grad: [Color]
    var status: WorkStatus
    var lines: [TermLine]
    var chat: [ChatBlock] = []
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

// MARK: - Gradients

enum Grad {
    static let blue   = [Color(hex: 0x4ea8ff), Color(hex: 0x8f8cff)]
    static let amber  = [Color(hex: 0xf5a83d), Color(hex: 0xff5a5c)]
    static let green  = [Color(hex: 0x40d68c), Color(hex: 0x63d3e8)]
    static let purple = [Color(hex: 0x8f8cff), Color(hex: 0x5a57c9)]
    static let slate  = [Color(hex: 0x757f8f), Color(hex: 0x4a515c)]
}
