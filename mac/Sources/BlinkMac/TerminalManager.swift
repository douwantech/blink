import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Backend abstraction

@MainActor
protocol TerminalBackend: AnyObject {
    var view: TerminalView { get }
    func sendText(_ s: String)
    func clear()
    func restart()
    func stop()
}

private func makeFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) }

private func applyTheme(_ tv: TerminalView) {
    tv.nativeBackgroundColor = NSColor(srgbRed: 0x10/255.0, green: 0x10/255.0, blue: 0x10/255.0, alpha: 1)
    tv.nativeForegroundColor = NSColor(srgbRed: 0xF0/255.0, green: 0xF0/255.0, blue: 0xF0/255.0, alpha: 1)
    tv.caretColor = NSColor(srgbRed: 0x3f/255.0, green: 0xde/255.0, blue: 0xe9/255.0, alpha: 1)
}

private func expandDir(_ dir: String) -> String {
    let e = (dir as NSString).expandingTildeInPath
    return FileManager.default.fileExists(atPath: e) ? e : FileManager.default.homeDirectoryForCurrentUser.path
}

// MARK: - Local PTY backend (SwiftTerm LocalProcessTerminalView)

@MainActor
final class LocalBackend: TerminalBackend {
    private let ptv: LocalProcessTerminalView
    private let dir: String
    var view: TerminalView { ptv }

    init(dir: String) {
        self.dir = dir
        ptv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                       font: makeFont(), options: TerminalOptions.default)
        applyTheme(ptv)
        launch()
    }

    private func launch() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let envArr = env.map { "\($0.key)=\($0.value)" }
        ptv.startProcess(executable: shell, args: ["-l"], environment: envArr,
                         execName: nil, currentDirectory: expandDir(dir))
    }

    func sendText(_ s: String) { if ptv.process.running { ptv.process.send(data: [UInt8](s.utf8)[...]) } }
    func clear() { ptv.process.send(data: [0x0c as UInt8][...]) }
    func restart() { ptv.terminate(); launch() }
    func stop() { ptv.terminate() }
}

// MARK: - Remote blinkd backend

@MainActor
final class RemoteBackend: TerminalBackend {
    private let tv: BlinkdTerminalView
    private let host: String
    private let port: UInt16
    private let token: String
    private let execCmd: String
    private var client: BlinkdClient?
    var view: TerminalView { tv }

    init(host: String, port: UInt16, token: String, exec: String) {
        self.host = host; self.port = port; self.token = token
        execCmd = exec
        tv = BlinkdTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                font: makeFont(), options: TerminalOptions.default)
        applyTheme(tv)
        tv.terminalDelegate = tv
        connect()
    }

    private func connect() {
        let c = BlinkdClient(host: host, port: port, token: token, exec: execCmd, terminal: tv)
        tv.client = c
        client = c
        c.start()
    }

    func sendText(_ s: String) { client?.sendData([UInt8](s.utf8)[...]) }
    func clear() { client?.sendData([0x0c as UInt8][...]) }
    func restart() { client?.stop(); connect() }
    func stop() { client?.stop() }
}

// MARK: - Info backend（只显示一段提示，不建任何进程/连接）

@MainActor
final class InfoBackend: TerminalBackend {
    private let tv: BlinkdTerminalView
    var view: TerminalView { tv }

    init(message: String) {
        tv = BlinkdTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                font: makeFont(), options: TerminalOptions.default)
        applyTheme(tv)
        tv.terminalDelegate = tv   // 没有 client，键盘输入无处可去（只读展示）
        let body = message.replacingOccurrences(of: "\n", with: "\r\n")
        tv.feed(text: "\r\n  " + body + "\r\n")
    }

    func sendText(_ s: String) {}
    func clear() {}
    func restart() {}
    func stop() {}
}

// MARK: - Manager

@MainActor
final class TerminalManager {
    private var backends: [String: TerminalBackend] = [:]

    func backend(for session: Session, machine: Machine) -> TerminalBackend {
        // 连不了的机器（手机配成 SSH）：按机器缓存一份提示，不跟别的机器串。
        if case .ssh(let user, let host) = machine.transport {
            let key = "ssh-info/\(machine.id)"
            if let b = backends[key] { return b }
            let who = user.isEmpty ? host : "\(user)@\(host)"
            let b = InfoBackend(message:
                "「\(machine.name)」在手机上配的是 SSH（\(who)）。\n" +
                "BlinkMac 目前只能连 blinkd（Socket）机器，没有 SSH 客户端。\n\n" +
                "想在 Mac 上用它：手机 → 机器 → 这台 → 连接方式改成 Socket，\n" +
                "填上这台机器 blinkd daemon 的地址/端口/token，就会自动出现。")
            backends[key] = b
            return b
        }
        if let b = backends[session.id] { return b }
        let b: TerminalBackend
        switch machine.transport {
        case .local:
            b = LocalBackend(dir: session.dir)
        case .blinkd(let h, let p, let t):
            // 枚举出来的真实会话 attach 它；否则按 title 新建 tmux+claude
            let exec = session.tmuxName.map { BlinkdScript.attach($0) }
                ?? BlinkdScript.tmuxClaude(title: session.name, workDir: expandDir(session.dir))
            b = RemoteBackend(host: h, port: p, token: t, exec: exec)
        case .ssh:
            b = InfoBackend(message: "SSH 机器，Mac 暂不支持连接。")   // 兜底（正常走上面按机器缓存那条）
        }
        backends[session.id] = b
        return b
    }

    func view(for session: Session, machine: Machine) -> TerminalView {
        backend(for: session, machine: machine).view
    }

    func send(_ sessionID: String, text: String) { backends[sessionID]?.sendText(text) }
    func clear(_ sessionID: String) { backends[sessionID]?.clear() }
    func restart(_ sessionID: String) { backends[sessionID]?.restart() }
}

// MARK: - SwiftUI bridge

struct TerminalContainer: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0x10/255.0, green: 0x10/255.0, blue: 0x10/255.0, alpha: 1).cgColor
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let tv = state.term.view(for: state.activeSession, machine: state.activeMachine)
        if tv.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            tv.frame = nsView.bounds
            tv.autoresizingMask = [.width, .height]
            nsView.addSubview(tv)
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(tv) }
        }
    }
}
