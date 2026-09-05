import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var avatars: [String: NSImage] = [:]   // owner(小写) → 真头像
    func avatar(_ owner: String) -> NSImage? { avatars[owner.lowercased()] }

    @Published var machines: [Machine]
    @Published var sessions: [Session]
    @Published var activeMachineID: String
    @Published var activeSessionID: String
    @Published var mode: TerminalMode = .terminal
    @Published var inspector: InspectorMode = .employee
    @Published var draft: String = ""
    @Published var recording = false
    @Published var reconnecting = false
    @Published var toast: String?
    @Published var showTeam = true

    /// Real local PTY terminals (SwiftTerm), one per session.
    let term = TerminalManager()

    private var toastTask: Task<Void, Never>?

    init() {
        // blinkd 配置：环境变量优先，其次 ~/.config/blinkmac/config.json（双击 .app 用这个）。
        // 有配置 → 本机走 blinkd 枚举真实会话；没有 → 本地示例数据。
        if let cfg = AppState.blinkdConfig() {
            machines = [
                Machine(id: "mbp", name: "MacBook Pro", host: "blinkd \(cfg.host):\(cfg.port)", initials: "M",
                        grad: Grad.blue, transport: .blinkd(host: cfg.host, port: cfg.port, token: cfg.token)),
            ]
            sessions = [Session(id: "loading", machineID: "mbp", name: "连接中…", dir: "", initials: "··",
                                grad: Grad.slate, status: .idle, lines: [], placeholder: true)]
            activeMachineID = "mbp"
            activeSessionID = "loading"
        } else {
            machines = [
                Machine(id: "mbp", name: "MacBook Pro", host: "本地 shell", initials: "M", grad: Grad.blue, transport: .local),
                Machine(id: "studio", name: "Mac Studio", host: "jack@100.96.88.42", initials: "S", grad: Grad.amber, transport: .local),
            ]
            sessions = AppState.sampleSessions()
            activeMachineID = "mbp"
            activeSessionID = "blink"
        }
    }

    /// 读 blinkd 配置：环境变量 BLINKD_TOKEN/HOST/PORT，其次 ~/.config/blinkmac/config.json。
    static func blinkdConfig() -> (host: String, port: UInt16, token: String)? {
        let env = ProcessInfo.processInfo.environment
        if let t = env["BLINKD_TOKEN"], !t.isEmpty {
            return (env["BLINKD_HOST"] ?? "127.0.0.1", UInt16(env["BLINKD_PORT"] ?? "7777") ?? 7777, t)
        }
        let path = NSHomeDirectory() + "/.config/blinkmac/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["token"] as? String, !t.isEmpty else { return nil }
        let host = (obj["host"] as? String) ?? "127.0.0.1"
        let port: UInt16 = (obj["port"] as? Int).map { UInt16(truncatingIfNeeded: $0) }
            ?? UInt16((obj["port"] as? String) ?? "") ?? 7777
        return (host, port, t)
    }

    /// 由 RootView 的 .task 触发（从 init 里 spawn Task 不可靠）。
    func startup() async {
        // 头像在独立后台任务里读（容器读可能被 TCC 卡住），不阻塞枚举/探测
        Task.detached(priority: .utility) { [weak self] in
            let a = BlinkAvatars.load()
            await MainActor.run { self?.avatars = a }
        }
        guard case .blinkd(let h, let p, let t) = activeMachine.transport else { return }
        await loadRealSessions(host: h, port: p, token: t)
    }

    // MARK: 枚举真实会话

    func loadRealSessions(host: String, port: UInt16, token: String) async {
        let out = await BlinkdExec.run(host: host, port: port, token: token, command: BlinkdScript.listSessions())
        let real = AppState.parseSessions(out)
        guard !real.isEmpty else {
            showToast("未枚举到 cc-* 会话（检查 blinkd host/token）")
            return
        }
        sessions = real
        activeSessionID = ""   // 不自动 attach，等用户点选（避免误连别人的会话）
        await probeStatuses(host: host, port: port, token: token)   // 真实状态探测
    }

    // MARK: 真实状态探测（干活中/等你/空闲）

    /// 一条 blinkd exec 遍历所有 cc-* 会话：pane_current_command + 底部有没有
    /// "esc to interrupt"(busy)。分类同 iOS：裸 shell→空闲、busy→干活、否则→等你。
    static let probeScript = #"""
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
BODY=$(
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^cc-' | while IFS= read -r s; do
  pc=$(tmux display-message -p -t "$s" '#{pane_current_command}' 2>/dev/null)
  busy=0
  tmux capture-pane -p -S -250 -t "$s" 2>/dev/null | tail -15 | grep -q 'esc to interrupt' && busy=1
  printf '%s\t%s\t%s\n' "$s" "$pc" "$busy"
done
)
EB64=$(printf '%s' "$BODY" | base64 | tr -d '\n')
printf '@TSB64@%s@TSB64E@\n' "$EB64"
"""#

    func probe() {
        showToast("正在探测各机器…")
        Task { @MainActor in await self.probeStatuses(); showToast("状态已更新") }
    }

    func probeStatuses() async {
        guard case .blinkd(let h, let p, let t) = activeMachine.transport else { return }
        await probeStatuses(host: h, port: p, token: t)
    }

    func probeStatuses(host: String, port: UInt16, token: String) async {
        let out = await BlinkdExec.run(host: host, port: port, token: token,
                                       command: AppState.probeScript, timeout: 20, finishMarker: "@TSB64E@")
        let map = AppState.parseProbe(out)
        guard !map.isEmpty else { return }
        for i in sessions.indices {
            guard let name = sessions[i].tmuxName else { continue }
            let probed = map[name] ?? .idle
            sessions[i].probed = probed
            sessions[i].status = MacRestStore.isResting(name) ? .rest : probed
        }
    }

    static func parseProbe(_ out: String) -> [String: WorkStatus] {
        guard let a = out.range(of: "@TSB64@"), let b = out.range(of: "@TSB64E@"),
              a.upperBound <= b.lowerBound else { return [:] }
        let b64 = out[a.upperBound..<b.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(b64)),
              let body = String(data: data, encoding: .utf8) else { return [:] }
        let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]
        var map: [String: WorkStatus] = [:]
        for line in body.split(whereSeparator: { $0.isNewline }) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            let pc = f[1].trimmingCharacters(in: .whitespaces)
            let busy = f[2].trimmingCharacters(in: .whitespaces) == "1"
            map[String(f[0])] = (pc.isEmpty || shells.contains(pc)) ? .idle : (busy ? .work : .wait)
        }
        return map
    }

    static func parseSessions(_ out: String) -> [Session] {
        let grads = [Grad.blue, Grad.amber, Grad.green, Grad.purple]
        var result: [Session] = []
        // PTY 输出行尾是 \r\n（Swift 里是单个 grapheme），用 isNewline 才分得开
        for line in out.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let full = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard full.hasPrefix("cc-") else { continue }
            let path = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            let title = String(full.dropFirst(3))
            let initials = String(title.replacingOccurrences(of: "-", with: "").prefix(2))
            let resting = MacRestStore.isResting(full)
            result.append(Session(id: full, machineID: "mbp", name: title,
                                  dir: path.isEmpty ? "~" : path, initials: initials,
                                  grad: grads[result.count % grads.count],
                                  status: resting ? .rest : .work, probed: .work,
                                  lines: [], tmuxName: full))
        }
        return result
    }

    // MARK: Derived

    var activeMachine: Machine { machines.first { $0.id == activeMachineID } ?? machines[0] }
    var activeSession: Session {
        sessions.first { $0.id == activeSessionID }
            ?? Session(id: "none", machineID: activeMachineID, name: "选择会话", dir: "",
                       initials: "", grad: Grad.slate, status: .idle, lines: [], placeholder: true)
    }
    var sidebarSessions: [Session] {
        sessions.filter { $0.machineID == activeMachineID }
            .sorted { ($0.project, $0.owner) < ($1.project, $1.owner) }   // 按项目排序
    }

    func count(_ s: WorkStatus) -> Int { sessions.filter { $0.status == s }.count }

    var teamItems: [TeamMember] {
        switch inspector {
        case .employee:
            return [
                TeamMember(initials: "汤", grad: Grad.amber, title: "tangyuan", sub: "QA · Mac mini",
                           status: .wait, note: "练口语 · #22 STT 空结果，卡在 review"),
                TeamMember(initials: "T", grad: Grad.green, title: "toma", sub: "PM · Mac Studio", status: .work),
                TeamMember(initials: "老", grad: Grad.slate, title: "laoda", sub: "老板 · MacBook", status: .idle),
            ]
        case .project:
            return [
                TeamMember(initials: "练", grad: Grad.blue, title: "练口语", sub: "3 人在跑 · 1 等你", status: .wait),
                TeamMember(initials: "印", grad: Grad.green, title: "AI-Printer", sub: "你 · 干活中", status: .work),
                TeamMember(initials: "B", grad: Grad.purple, title: "Blink", sub: "你 · 干活中", status: .work),
            ]
        case .machine:
            return [
                TeamMember(initials: "M", grad: Grad.blue, title: "MacBook Pro", sub: "2 会话在岗", status: .work, showMoon: true),
                TeamMember(initials: "S", grad: Grad.amber, title: "Mac Studio", sub: "休息中", status: .rest, showMoon: true),
            ]
        }
    }

    // MARK: Actions

    func selectMachine(_ id: String) {
        activeMachineID = id
        if let first = sessions.first(where: { $0.machineID == id }) {
            activeSessionID = first.id
        }
    }

    func selectSession(_ id: String) {
        activeSessionID = id
        mode = .terminal
    }

    private func mutateActive(_ f: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        f(&sessions[i])
    }

    func send() {
        guard !draft.isEmpty else { return }
        term.send(activeSessionID, text: draft + "\r")   // 注入真实 PTY
        draft = ""
    }

    func toggleRecording() {
        if recording {
            recording = false
            draft += (draft.isEmpty ? "" : " ") + "帮我把这个改动 commit 一下"
            showToast("识别完成 · 已填入输入框")
        } else {
            recording = true
        }
    }

    func toggleRestActive() {
        let s = activeSession
        guard !s.placeholder else { return }
        let name = s.tmuxName ?? s.id
        let nowResting = MacRestStore.toggle(name)   // 持久化到 UserDefaults
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[i].status = nowResting ? .rest : sessions[i].probed
        }
        showToast(nowResting ? "已标记休息（本机持久）" : "已恢复在岗")
    }

    func reconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        term.restart(activeSessionID)   // 本地=重开 shell；blinkd=重连
        let id = activeSessionID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            reconnecting = false
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].status = .work }
            showToast("已重连 · 重开 shell")
        }
    }

    func newSession() {
        let nid = "sh\(Int(Date().timeIntervalSince1970))"
        sessions.append(Session(id: nid, machineID: activeMachineID, name: "shell", dir: "~",
                                initials: "sh", grad: Grad.green, status: .idle,
                                lines: [TermLine(text: "新会话 · 裸 shell，输入命令启动 claude", color: Theme.dim)]))
        activeSessionID = nid
        showToast("新会话已建")
    }

    func toggleMode() { mode = (mode == .chat) ? .terminal : .chat }

    func showToast(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Sample data

    static func sampleSessions() -> [Session] {
        let blinkLines: [TermLine] = [
            TermLine(text: "~/Codes/Jack/blink  bin ✳", color: Theme.dim),
            TermLine(prefix: "$", prefixColor: Theme.sub, text: "claude --resume \"cc-blink\"", color: Theme.sub),
            TermLine(prefix: "●", prefixColor: Theme.work, text: "Read(Blink/SmarterKeys/BlinkMachineStore.swift)"),
            TermLine(text: "  ⎿ Read 240 lines", color: Theme.dim),
            TermLine(prefix: "●", prefixColor: Theme.blue, text: "刷新脚本三处 claude 启动都加上了 --dangerously-skip-permissions。"),
            TermLine(prefix: "●", prefixColor: Theme.work, text: "Bash(xcodebuild -scheme Blink build)"),
            TermLine(text: "  ⎿ ** BUILD SUCCEEDED **", color: Theme.work),
            TermLine(prefix: "✻", prefixColor: Theme.purple, text: "Compacting conversation… (94% context)", color: Theme.purple, italic: true),
            TermLine(prefix: ">", prefixColor: Theme.green2, text: "烧到我手机上", color: Theme.green2),
        ]
        let blinkChat: [ChatBlock] = [
            ChatBlock(role: "YOU", color: Theme.green2, text: "让刷新时调用的脚本调用 Claude，并加上 skip dangerous 这个 flag。"),
            ChatBlock(role: "ASSISTANT", color: Theme.blue, text: "好的，刷新按钮重连跑的是 innerScript() 那段 resume-or-new 脚本。三处 claude 启动分支都加了 --dangerously-skip-permissions，iOS 和鸿蒙逐字一致。已 build 成功。"),
            ChatBlock(role: "YOU", color: Theme.green2, text: "烧到我手机上"),
        ]
        return [
            Session(id: "blink", machineID: "mbp", name: "blink", dir: "~/Codes/Jack/blink",
                    initials: "bl", grad: Grad.blue, status: .work, lines: blinkLines, chat: blinkChat),
            Session(id: "printer", machineID: "mbp", name: "printer", dir: "~/Codes/Jack/AI-Printer",
                    initials: "pr", grad: Grad.green, status: .work, lines: [
                        TermLine(prefix: "●", prefixColor: Theme.work, text: "Edit(worker/task.go)"),
                        TermLine(text: "  ⎿ Updated 3 hunks", color: Theme.dim),
                        TermLine(prefix: "●", prefixColor: Theme.blue, text: "部署 updater 中…"),
                    ], chat: [ChatBlock(role: "ASSISTANT", color: Theme.blue, text: "正在部署 product_updater…")]),
            Session(id: "agent", machineID: "mbp", name: "agent-tasks", dir: "~/Codes/Jack/agent",
                    initials: "ag", grad: Grad.slate, status: .idle, lines: [
                        TermLine(text: "掉回裸 shell · 无 claude 进程", color: Theme.dim),
                    ]),
            Session(id: "talkai", machineID: "studio", name: "talkai", dir: "~/Codes/Jack/AI-Talkai",
                    initials: "ta", grad: Grad.amber, status: .wait, lines: [
                        TermLine(prefix: "●", prefixColor: Theme.blue, text: "要不要建/更新 PR？"),
                        TermLine(text: "  1. 建 PR   2. 先不建", color: Theme.dim),
                        TermLine(text: "  ▍等待你的选择…", color: Theme.wait),
                    ], chat: [ChatBlock(role: "ASSISTANT", color: Theme.blue, text: "要不要建/更新 PR？")]),
            Session(id: "huum", machineID: "studio", name: "huum", dir: "~/Codes/Jack/huum-studio",
                    initials: "hu", grad: Grad.blue, status: .wait, lines: [
                        TermLine(prefix: "●", prefixColor: Theme.blue, text: "权限确认：写入 matomo 表？"),
                        TermLine(text: "  Yes / Yes,别再问 / No", color: Theme.dim),
                    ]),
            Session(id: "sim", machineID: "studio", name: "blink-sim", dir: "~/Codes/Jack/blink",
                    initials: "bs", grad: Grad.purple, status: .rest, lines: [
                        TermLine(text: "休息中 · 你手动标记，不再提醒", color: Theme.dim),
                    ]),
        ]
    }
}
