import SwiftUI

@MainActor
final class AppState: ObservableObject {
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
        // blinkd 远程配置从环境变量注入（里程碑 3 E2E：本地起 daemon 时设这三个）。
        let env = ProcessInfo.processInfo.environment
        let btoken = env["BLINKD_TOKEN"] ?? ""
        let bhost = env["BLINKD_HOST"] ?? "127.0.0.1"
        let bport = UInt16(env["BLINKD_PORT"] ?? "7777") ?? 7777
        let studioTransport: Transport = btoken.isEmpty ? .local : .blinkd(host: bhost, port: bport, token: btoken)

        machines = [
            Machine(id: "mbp", name: "MacBook Pro", host: "jack@100.96.88.80", initials: "M", grad: Grad.blue, transport: .local),
            Machine(id: "studio", name: "Mac Studio",
                    host: btoken.isEmpty ? "jack@100.96.88.42" : "blinkd \(bhost):\(bport)",
                    initials: "S", grad: Grad.amber, transport: studioTransport),
        ]
        sessions = AppState.sampleSessions()
        if btoken.isEmpty {
            activeMachineID = "mbp"
            activeSessionID = "blink"
        } else {
            // 配了 blinkd 就直接落到远程机器，启动即连（也方便 E2E）
            activeMachineID = "studio"
            activeSessionID = "talkai"
        }
    }

    // MARK: Derived

    var activeMachine: Machine { machines.first { $0.id == activeMachineID } ?? machines[0] }
    var activeSession: Session { sessions.first { $0.id == activeSessionID } ?? sessions[0] }
    var sidebarSessions: [Session] { sessions.filter { $0.machineID == activeMachineID } }

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
        mutateActive { $0.status = $0.status == .rest ? .work : .rest }
        showToast("已切换当前会话 休息/在岗")
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
