import SwiftUI
import AppKit
import SwiftTerm

/// Owns one real local PTY-backed SwiftTerm view per session, kept alive
/// across session switches. Milestone 2: local shell (真终端). The blinkd
/// remote transport swaps in behind the same interface in milestone 3.
@MainActor
final class TerminalManager {
    private var views: [String: LocalProcessTerminalView] = [:]

    func view(for session: Session) -> LocalProcessTerminalView {
        if let v = views[session.id] { return v }
        let tv = makeView()
        views[session.id] = tv
        startShell(tv, dir: session.dir)
        return tv
    }

    private func makeView() -> LocalProcessTerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                          font: font, options: TerminalOptions.default)
        tv.nativeBackgroundColor = NSColor(srgbRed: 0x10/255.0, green: 0x10/255.0, blue: 0x10/255.0, alpha: 1)
        tv.nativeForegroundColor = NSColor(srgbRed: 0xF0/255.0, green: 0xF0/255.0, blue: 0xF0/255.0, alpha: 1)
        tv.caretColor = NSColor(srgbRed: 0x3f/255.0, green: 0xde/255.0, blue: 0xe9/255.0, alpha: 1)
        return tv
    }

    private func startShell(_ tv: LocalProcessTerminalView, dir: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let expanded = (dir as NSString).expandingTildeInPath
        let cwd = FileManager.default.fileExists(atPath: expanded)
            ? expanded
            : FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let envArr = env.map { "\($0.key)=\($0.value)" }
        tv.startProcess(executable: shell, args: ["-l"], environment: envArr,
                        execName: nil, currentDirectory: cwd)
    }

    /// Inject text into a session's PTY (used by the composer).
    func send(_ sessionID: String, text: String) {
        guard let v = views[sessionID], v.process.running else { return }
        v.process.send(data: [UInt8](text.utf8)[...])
    }

    /// Ctrl-L clear.
    func clear(_ sessionID: String) {
        guard let v = views[sessionID] else { return }
        v.process.send(data: [0x0c as UInt8][...])
    }

    /// Reconnect = tear down the shell and relaunch a fresh one.
    func restart(_ session: Session) {
        if let old = views[session.id] { old.terminate() }
        let tv = makeView()
        views[session.id] = tv
        startShell(tv, dir: session.dir)
    }
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
        let tv = state.term.view(for: state.activeSession)
        if tv.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            tv.frame = nsView.bounds
            tv.autoresizingMask = [.width, .height]
            nsView.addSubview(tv)
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(tv) }
        }
    }
}
