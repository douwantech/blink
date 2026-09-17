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
    private var conn: NWConnection?
    private let host: String                   // Tailscale host/IP（也是匹配 LAN 记录的 key）
    private let port: UInt16
    private let token: String
    private let execCmd: String?
    private weak var terminal: TerminalView?
    private var handshakeSent = false
    private var ready = false                 // auth 已发出，之后才允许发其它帧
    private var receiveStarted = false
    private var pendingSize: (cols: Int, rows: Int)?

    // 候选通道：LAN 直连优先、Tailscale 兜底。逐个试，第一个 .ready 的用它。
    private var candidates: [(label: String, make: () -> NWConnection)] = []
    private var candidateIndex = 0
    private var connectTimeout: DispatchWorkItem?
    private var stopped = false

    var onStatus: ((String) -> Void)?
    /// 连上后回报实际用的通道标签（"LAN 直连" / "Tailscale"），UI 拿去显示当前连接方式。
    var onTransport: ((String) -> Void)?

    init(host: String, port: UInt16, token: String, exec: String?, terminal: TerminalView) {
        self.host = host
        self.port = port
        self.token = token
        self.execCmd = exec
        self.terminal = terminal
    }

    func start() {
        // 组候选：同网 Bonjour 发现到这台机器（按 Tailscale IP 对上）→ 先试 LAN 直连；再兜底 Tailscale。
        candidates = []
        if let lan = BlinkdDiscovery.shared.lanEndpoint(forTailscaleHost: host) {
            candidates.append(("LAN 直连", { NWConnection(to: lan, using: .tcp) }))
        }
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 7777
        candidates.append(("Tailscale", { NWConnection(host: NWEndpoint.Host(self.host), port: nwPort, using: .tcp) }))
        candidateIndex = 0
        tryConnect()
    }

    private func tryConnect() {
        guard !stopped else { return }
        guard candidateIndex < candidates.count else {
            onStatus?("连接失败：无可用通道")
            return
        }
        let cand = candidates[candidateIndex]
        let isLast = candidateIndex == candidates.count - 1
        let c = cand.make()
        conn = c
        onStatus?("连接中（\(cand.label)）…")
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.conn === c, !self.stopped else { return }
                switch state {
                case .ready:
                    self.connectTimeout?.cancel(); self.connectTimeout = nil
                    self.onStatus?("已连接 blinkd（\(cand.label)）")
                    self.onTransport?(cand.label)
                    self.startReceive()
                    self.handshake()
                case .failed:
                    self.connectTimeout?.cancel(); self.connectTimeout = nil
                    if !self.ready { self.advance(from: c) }
                case .waiting:
                    // 连不通常表现为 .waiting（无路由）——非最后候选就别干等，立刻回落下一个。
                    if !self.ready && !isLast { self.connectTimeout?.cancel(); self.advance(from: c) }
                default:
                    break
                }
            }
        }
        // 非最后候选给个短超时：卡在连接中就回落 Tailscale，别让 LAN 不通拖住终端。
        if !isLast {
            let to = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.conn === c, !self.ready, !self.stopped else { return }
                    self.advance(from: c)
                }
            }
            connectTimeout = to
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: to)
        }
        c.start(queue: .main)
    }

    private func advance(from c: NWConnection) {
        c.cancel()
        candidateIndex += 1
        tryConnect()
    }

    func stop() { stopped = true; connectTimeout?.cancel(); conn?.cancel() }

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
        conn?.send(content: Data(frame), completion: .contentProcessed { _ in })
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
        conn?.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    // MARK: Receive (raw PTY bytes → terminal)

    /// 只在选定通道 .ready 后启动一次；之后不再切换通道，故无陈旧接收问题。
    private func startReceive() {
        guard !receiveStarted else { return }
        receiveStarted = true
        receiveLoop()
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
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

/// 局域网 Bonjour 发现：常驻 browse `_blinkd._tcp`，维护 Tailscale IP → LAN 服务端点 的映射。
/// daemon 在 TXT 里带 `ts=<tailscaleIP>`，这样一条 LAN 记录能对上客户端已按 Tailscale IP 配置的机器。
/// 线程安全（NSLock），既给 @MainActor 的 BlinkdClient 用，也给 nonisolated 的 BlinkdExec 用。
final class BlinkdDiscovery: @unchecked Sendable {
    static let shared = BlinkdDiscovery()

    private let q = DispatchQueue(label: "blinkd.discovery")
    private let lock = NSLock()
    private var byTS: [String: NWEndpoint] = [:]
    private var browser: NWBrowser?

    func start() {
        q.async { [self] in
            guard browser == nil else { return }
            let params = NWParameters()
            params.includePeerToPeer = false
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_blinkd._tcp", domain: nil), using: params)
            b.browseResultsChangedHandler = { [weak self] results, _ in self?.rebuild(results) }
            b.start(queue: q)
            browser = b
        }
    }

    private func rebuild(_ results: Set<NWBrowser.Result>) {
        var map: [String: NWEndpoint] = [:]
        for r in results {
            guard case .service = r.endpoint else { continue }
            guard case let .bonjour(txt) = r.metadata else { continue }
            if case let .string(ts) = txt.getEntry(for: "ts"), !ts.isEmpty {
                map[ts] = r.endpoint   // 连接用服务端点，Network.framework 自己解析到当前 LAN IP
            }
        }
        lock.lock(); byTS = map; lock.unlock()
    }

    /// 该 Tailscale host/IP 对应的机器是否在本局域网被发现；有就返回其 LAN 服务端点。
    func lanEndpoint(forTailscaleHost host: String) -> NWEndpoint? {
        lock.lock(); defer { lock.unlock() }
        return byTS[host]
    }
}

/// 一次性 blinkd exec：连接 → auth → exec → 收集全部输出直到连接关闭，返回字符串。
/// 用于枚举远端 `tmux list-sessions` 等只读命令（无 resize，不涉及帧序问题）。
enum BlinkdExec {
    static func run(host: String, port: UInt16, token: String, command: String,
                    timeout: TimeInterval = 6, finishMarker: String? = nil) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            // 枚举/探测也优先走 LAN 直连（这是每 12s 轮询、占 Tailscale 最多的路径）：
            // 同网 Bonjour 发现到就直连 LAN 端点，没发现再走 Tailscale host。发现即 daemon 在线，够可靠；
            // 万一失败，本轮超时返回空，下一轮轮询自会重试。
            let conn: NWConnection
            if let lan = BlinkdDiscovery.shared.lanEndpoint(forTailscaleHost: host) {
                conn = NWConnection(to: lan, using: .tcp)
            } else {
                conn = NWConnection(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(rawValue: port) ?? 7777, using: .tcp)
            }
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
    /// 远程会话：贴图时上传图床、把 URL 打进终端（本机=false，走原生粘贴让 claude 读本机剪贴板）。
    var uploadImageOnPaste = false
    var onToast: ((String) -> Void)?

    override func paste(_ sender: Any) {
        if uploadImageOnPaste,
           ImageHostUploader.handlePaste(NSPasteboard.general,
                                         send: { [weak self] s in self?.client?.sendData([UInt8](s.utf8)[...]) },
                                         toast: onToast) {
            return
        }
        super.paste(sender)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { client?.sendData(data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { client?.sendResize(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    // Cmd+悬停下划线、Cmd+点击打开（linkHighlightMode 默认 .hoverWithModifier）。
    // 之前是空实现→点了没反应；用默认处理器开 http/https/file。
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        TerminalView.openDefaultLink(link)
    }
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
