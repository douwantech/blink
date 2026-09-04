import Foundation
import AppKit
import Network
import SwiftTerm

/// Swift client for the blinkd daemon (mac-daemon/main.go).
///
/// Wire protocol (client→server, BigEndian):
///   0x01 | u16 len | token       握手，必须第一帧
///   0x04 | u16 len | cmdline      指定这条连接跑的命令（auth 后，PTY 起之前；可选）
///   0x02 | u16 len | bytes        终端输入（键盘）
///   0x03 | u16 rows | u16 cols    窗口 resize（定长 4 字节，无 len 前缀）
/// server→client：裸 PTY 字节流，无帧。
@MainActor
final class BlinkdClient {
    private let conn: NWConnection
    private let token: String
    private let execCmd: String?
    private weak var terminal: TerminalView?
    private var handshakeSent = false
    private var ready = false                 // auth 已发出，之后才允许发其它帧
    private var pendingSize: (cols: Int, rows: Int)?

    var onStatus: ((String) -> Void)?

    init(host: String, port: UInt16, token: String, exec: String?, terminal: TerminalView) {
        self.token = token
        self.execCmd = exec
        self.terminal = terminal
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 7777
        let params = NWParameters.tcp
        conn = NWConnection(host: nwHost, port: nwPort, using: params)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onStatus?("已连接 blinkd")
                    self.handshake()
                case .failed(let e):
                    self.onStatus?("连接失败：\(e.localizedDescription)")
                case .waiting(let e):
                    self.onStatus?("等待连接：\(e.localizedDescription)")
                case .cancelled:
                    self.onStatus?("连接已关闭")
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
        receiveLoop()
    }

    func stop() { conn.cancel() }

    // MARK: Frames

    private func handshake() {
        guard !handshakeSent else { return }
        handshakeSent = true
        sendFrame(0x01, Array(token.utf8))                       // auth（必须第一帧）
        if let e = execCmd, !e.isEmpty {
            sendFrame(0x04, Array(e.utf8))                       // exec
        }
        ready = true
        if let s = pendingSize { sendResize(cols: s.cols, rows: s.rows); pendingSize = nil }
    }

    private func sendFrame(_ type: UInt8, _ payload: [UInt8]) {
        let n = UInt16(min(payload.count, 0xffff))
        var frame: [UInt8] = [type, UInt8(n >> 8), UInt8(n & 0xff)]
        frame.append(contentsOf: payload)
        conn.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    /// 终端输入（键盘/命令注入）。auth 前丢弃，避免抢在握手前发帧被 daemon 拒。
    func sendData(_ data: ArraySlice<UInt8>) {
        guard ready else { return }
        sendFrame(0x02, Array(data))
    }

    /// resize：0x03 + u16 rows + u16 cols（定长，无 len）。auth 前先缓存，握手后补发。
    func sendResize(cols: Int, rows: Int) {
        guard ready else { pendingSize = (cols, rows); return }
        let r = UInt16(max(1, min(rows, 0xffff)))
        let c = UInt16(max(1, min(cols, 0xffff)))
        let frame: [UInt8] = [0x03, UInt8(r >> 8), UInt8(r & 0xff), UInt8(c >> 8), UInt8(c & 0xff)]
        conn.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    // MARK: Receive (raw PTY bytes → terminal)

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let d = data, !d.isEmpty {
                    self.terminal?.feed(byteArray: [UInt8](d)[...])
                }
                if isComplete || error != nil {
                    self.onStatus?("会话结束")
                    return
                }
                self.receiveLoop()
            }
        }
    }
}

/// 一次性 blinkd exec：连接 → auth → exec → 收集全部输出直到连接关闭，返回字符串。
/// 用于枚举远端 `tmux list-sessions` 等只读命令（无 resize，不涉及帧序问题）。
enum BlinkdExec {
    static func run(host: String, port: UInt16, token: String, command: String,
                    timeout: TimeInterval = 6, finishMarker: String? = nil) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(rawValue: port) ?? 7777, using: .tcp)
            let lock = NSLock()
            var buf = Data()
            var finished = false
            func finish() {
                lock.lock(); let already = finished; finished = true; let out = buf; lock.unlock()
                if already { return }
                conn.cancel()
                cont.resume(returning: String(decoding: out, as: UTF8.self))
            }
            func frame(_ type: UInt8, _ payload: [UInt8]) -> Data {
                let n = UInt16(min(payload.count, 0xffff))
                return Data([type, UInt8(n >> 8), UInt8(n & 0xff)] + payload)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: frame(0x01, Array(token.utf8)), completion: .contentProcessed { _ in })
                    conn.send(content: frame(0x04, Array(command.utf8)), completion: .contentProcessed { _ in })
                case .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }
            func recv() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, err in
                    var hitMarker = false
                    if let d = data, !d.isEmpty {
                        lock.lock(); buf.append(d)
                        if let m = finishMarker { hitMarker = String(decoding: buf, as: UTF8.self).contains(m) }
                        lock.unlock()
                    }
                    if hitMarker || complete || err != nil { finish() } else { recv() }
                }
            }
            conn.start(queue: .global())
            recv()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }
}

/// A SwiftTerm view whose keyboard input and resizes go to a blinkd connection.
final class BlinkdTerminalView: TerminalView, TerminalViewDelegate {
    weak var client: BlinkdClient?

    func send(source: TerminalView, data: ArraySlice<UInt8>) { client?.sendData(data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { client?.sendResize(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
