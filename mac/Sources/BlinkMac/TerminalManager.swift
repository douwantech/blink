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

// MARK: - SSH backend（系统 /usr/bin/ssh，本地 PTY，用用户自己的 ~/.ssh 密钥/agent）

@MainActor
final class SSHBackend: TerminalBackend {
    private let ptv: LocalProcessTerminalView
    private let target: String
    private let remoteScript: String
    var view: TerminalView { ptv }

    init(user: String, host: String, remoteScript: String) {
        target = user.isEmpty ? host : "\(user)@\(host)"
        self.remoteScript = remoteScript
        ptv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                       font: makeFont(), options: TerminalOptions.default)
        applyTheme(ptv)
        ptv.feed(text: "\r\n  连接 \(target) …\r\n\r\n")   // 连接期间给个反馈，别空白
        launch()
    }

    private func launch() {
        // 远端脚本 base64 落盘再跑，跟手机 sshCommand 一致，绕开本地 shell 抢先展开 $HOME/$(pwd)。
        let b64 = Data(remoteScript.utf8).base64EncodedString()
        let remote = "echo \(b64) | base64 -d > /tmp/.blinkmac-ssh-$$.sh && exec bash /tmp/.blinkmac-ssh-$$.sh"
        // 关键：经登录 shell 起 ssh（-lc），才能拿到 launchd 会话的 SSH_AUTH_SOCK(→ssh-agent) 和
        // 完整 PATH/keychain 上下文。Finder/Spotlight 起的 app 进程环境里没有 SSH_AUTH_SOCK，
        // 直接 spawn /usr/bin/ssh 会因子进程拿不到 agent/keychain 授权而连不上（表现为一片空白）。
        let ssh = "exec /usr/bin/ssh -tt -o StrictHostKeyChecking=accept-new \(target) -- '\(remote)'"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let shell = env["SHELL"] ?? "/bin/zsh"
        ptv.startProcess(executable: shell,
                         args: ["-lc", ssh],
                         environment: env.map { "\($0.key)=\($0.value)" },
                         execName: nil,
                         currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func sendText(_ s: String) { if ptv.process.running { ptv.process.send(data: [UInt8](s.utf8)[...]) } }
    func clear() { ptv.process.send(data: [0x0c as UInt8][...]) }
    func restart() { ptv.terminate(); launch() }
    func stop() { ptv.terminate() }
}

// MARK: - Manager

@MainActor
final class TerminalManager {
    private var backends: [String: TerminalBackend] = [:]

    func backend(for session: Session, machine: Machine) -> TerminalBackend {
        if let b = backends[session.id] { return b }
        let b: TerminalBackend
        switch machine.transport {
        case .local:
            b = LocalBackend(dir: session.dir)
        case .blinkd(let h, let p, let t):
            // 统一走 new-session -A：会话在就 attach、不在就建+claude resume（heal 自愈坏 session）。
            // 旧逻辑对带 tmuxName 的会话一律纯 attach，重启后 tmux server 空了 → 「can't find session」。
            let exec = BlinkdScript.tmuxClaude(title: session.name, workDir: expandDir(session.dir))
            b = RemoteBackend(host: h, port: p, token: t, exec: exec)
        case .ssh(let user, let host):
            // 系统 ssh + 远端 tmux+claude（resume-or-new）。dir 是远端路径，不在本地展开。
            // 空/~ 时用 "."（ssh 登录落点就是远端 $HOME），别用会被单引号挡住展开的 $HOME。
            let workDir = (session.dir.isEmpty || session.dir == "~") ? "." : session.dir
            let script = BlinkdScript.tmuxClaude(title: session.name, workDir: workDir)
            b = SSHBackend(user: user, host: host, remoteScript: script)
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
