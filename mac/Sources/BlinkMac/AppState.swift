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

    // 跨设备休息（正式版）：cloudAvailable=有共享 KV；cloudResting=休息中的 cc-title；
    // cloudMapping=cc-title↔tab UUID。dev 版 cloudAvailable=false → 回退本地 MacRestStore。
    @Published var cloudResting: Set<String> = []
    @Published var cloudAvailable = false
    var cloudMapping = CloudRestStore.Mapping()

    // 收藏短语（跟手机同一套 iCloud KV，正式版跨设备同步）
    @Published var favorites: [String] = []
    @Published var showFavorites = false

    func loadFavorites() { favorites = FavoritesStore.entries(cloud: cloudAvailable) }

    /// 发一条收藏到当前终端并回车（同手机 dock 收藏钮）。
    func sendFavorite(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard !activeSession.placeholder, !activeSessionID.isEmpty else { showToast("先选一个会话"); return }
        term.send(activeSessionID, text: t + "\r")
        FavoritesStore.incrementUse(t, cloud: cloudAvailable)
        loadFavorites()
        showFavorites = false
        showToast("已发送到 cc-\(activeSession.name)")
    }

    func addFavorite(_ text: String) {
        FavoritesStore.add(text, cloud: cloudAvailable); loadFavorites()
    }
    func removeFavorite(_ text: String) {
        FavoritesStore.remove(text, cloud: cloudAvailable); loadFavorites()
    }

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
        guard case .blinkd = activeMachine.transport else { return }
        loadCloudMachines()          // 用 iCloud KV 的机器清单扩展成多机（正式版才有）
        await loadCloudRest()
        loadFavorites()
        startObservingCloud()
        sessions.removeAll { $0.placeholder }   // 清掉 init 的「连接中…」占位
        await enumerateAll()         // 逐台并行枚举 + 探测真实会话（只 blinkd 机器）
        loadCloudTabs()              // 连不上的机器（SSH/离线）用 KV 里手机配的标签补上
        if sessions.first(where: { $0.id == activeSessionID }) == nil { activeSessionID = "" }
    }

    /// 用 iCloud KV 里手机的标签补齐「没有活会话」的机器（SSH 连不上、或 blinkd 离线枚举为空）。
    /// 已经枚举到真实会话的机器不动 —— 那份是活的、带真实状态，比配置快照准。
    func loadCloudTabs() {
        let tabs = CloudTabStore.tabs()
        guard !tabs.isEmpty else { return }
        let grads = [Grad.blue, Grad.amber, Grad.green, Grad.purple]
        for m in machines {
            if sessions.contains(where: { $0.machineID == m.id }) { continue }   // 有活会话就不覆盖
            let mine = tabs.filter { $0.machineId == m.id }
            guard !mine.isEmpty else { continue }
            var seen = Set<String>()
            var built: [Session] = []
            for t in mine {
                let full = "cc-" + t.ccName
                guard seen.insert(full).inserted else { continue }   // 同机去重
                let initials = String(t.ccName.replacingOccurrences(of: "-", with: "").prefix(2))
                built.append(Session(id: "\(m.id)/\(full)", machineID: m.id, name: t.ccName,
                                     dir: t.dir.isEmpty ? "~" : t.dir, initials: initials,
                                     grad: grads[built.count % grads.count],
                                     status: .idle, probed: .idle, lines: [], tmuxName: full))
            }
            sessions.append(contentsOf: built)
        }
        recomputeRestStatuses()   // 休息叠加（这些标签若在手机上被标了休息，也照样隐藏）
    }

    /// 用 iCloud KV 的机器清单扩展本地机器列表（正式版签名才读得到 KV）。
    /// 本地 config.json 那台 = 这台 Mac，走 127.0.0.1 直连更快；KV 里 token 相同的那条即同一台，
    /// 套用手机上给它起的显示名，不重复列。KV 空（dev / 未同步）→ 保持本地单机不动。
    func loadCloudMachines() {
        let cloud = MacMachineStore.machines()
        guard !cloud.isEmpty, case .blinkd(let lh, let lp, let lt) = machines.first?.transport else { return }
        let grads = [Grad.blue, Grad.amber, Grad.green, Grad.purple, Grad.slate]
        var out: [Machine] = []
        var thisMacId: String? = nil
        for (i, cm) in cloud.enumerated() {
            let name = cm.name.isEmpty ? "机器\(i + 1)" : cm.name
            let transport: Transport
            let hostLabel: String
            if let b = cm.blinkd {
                let isThisMac = (b.token == lt)
                // 这台 Mac 走本地直连（config.json 那台），其余 blinkd 机器走 KV 里的地址（tsnet）。
                transport = isThisMac ? .blinkd(host: lh, port: lp, token: lt)
                                      : .blinkd(host: b.host, port: b.port, token: b.token)
                hostLabel = isThisMac ? "本机 · \(b.host):\(b.port)" : "blinkd \(b.host):\(b.port)"
                if isThisMac { thisMacId = cm.id }
            } else {
                // 手机上配的是 SSH：列出来但连不了（BlinkMac 只有 blinkd 传输），点开给提示。
                transport = .ssh(user: "", host: cm.host)
                hostLabel = "SSH \(cm.host) · Mac 暂不支持"
            }
            out.append(Machine(id: cm.id, name: name, host: hostLabel,
                               initials: String(name.prefix(2)).uppercased(),
                               grad: grads[i % grads.count],
                               online: transport.connectable, transport: transport))
        }
        guard !out.isEmpty else { return }
        // 手机清单里没有这台 Mac（没配本地 daemon）→ 把本地那台保留在最前。
        if thisMacId == nil, let local = machines.first {
            out.insert(local, at: 0)
            thisMacId = local.id
        }
        machines = out
        activeMachineID = thisMacId ?? out[0].id
    }

    /// 逐台并行枚举所有 blinkd 机器的会话，再逐台并行探测状态。
    /// 只传 Sendable 原语进 task（host/port/token/machineID），结果回到主 actor 合并。
    func enumerateAll() async {
        await withTaskGroup(of: [Session].self) { group in
            for m in machines {
                guard case .blinkd(let h, let p, let t) = m.transport else { continue }
                let mid = m.id
                group.addTask {
                    let out = await BlinkdExec.run(host: h, port: p, token: t, command: BlinkdScript.listSessions())
                    return AppState.parseSessions(out, machineID: mid)
                }
            }
            for await real in group {
                guard let mid = real.first?.machineID else { continue }
                sessions.removeAll { $0.machineID == mid }
                sessions.append(contentsOf: real)
            }
        }
        await withTaskGroup(of: (String, [String: WorkStatus]).self) { group in
            for m in machines {
                guard case .blinkd(let h, let p, let t) = m.transport else { continue }
                let mid = m.id
                group.addTask {
                    let out = await BlinkdExec.run(host: h, port: p, token: t,
                                                   command: AppState.probeScript, timeout: 20, finishMarker: "@TSB64E@")
                    return (mid, AppState.parseProbe(out))
                }
            }
            for await (mid, map) in group where !map.isEmpty {
                for i in sessions.indices where sessions[i].machineID == mid {
                    guard let name = sessions[i].tmuxName else { continue }
                    let probed = map[name] ?? .idle
                    sessions[i].probed = probed
                    sessions[i].status = isResting(name) ? .rest : probed
                }
            }
        }
        recomputeRestStatuses()
    }

    /// 枚举单台机器的会话并合并（只替换这台的，别动别的机器）。选机器/需要刷新单台时用。
    func loadSessions(for machine: Machine) async {
        guard case .blinkd(let h, let p, let t) = machine.transport else { return }
        let out = await BlinkdExec.run(host: h, port: p, token: t, command: BlinkdScript.listSessions())
        let real = AppState.parseSessions(out, machineID: machine.id)
        sessions.removeAll { $0.machineID == machine.id }
        guard !real.isEmpty else { return }
        sessions.append(contentsOf: real)
        await probeStatuses(host: h, port: p, token: t, machineID: machine.id)
        recomputeRestStatuses()
    }

    private var observingCloud = false

    /// 实时监听休息变化：iCloud KV 外部变更（手机改了推过来）+ 回前台补拉
    /// （didChangeExternally 不可靠，Blink 自己也靠回前台 pull）。
    func startObservingCloud() {
        guard !observingCloud else { return }
        observingCloud = true
        NSUbiquitousKeyValueStore.default.synchronize()
        let reload: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.loadFavorites(); await self?.loadCloudRest() }
        }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: .main, using: reload)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main, using: reload)
    }

    /// 从 iCloud KV + Blink 容器读跨设备休息状态（off-main），再重算各会话状态。
    func loadCloudRest() async {
        let (avail, mapping, resting) = await Task.detached(priority: .utility) {
            () -> (Bool, CloudRestStore.Mapping, Set<String>) in
            let m = CloudRestStore.loadMapping()
            return (CloudRestStore.available, m, CloudRestStore.restingCCTitles(m))
        }.value
        cloudAvailable = avail
        cloudMapping = mapping
        cloudResting = resting
        recomputeRestStatuses()
    }

    /// 按当前休息判定重算所有会话的 status（休息优先，否则用探测值）。
    func recomputeRestStatuses() {
        for i in sessions.indices {
            let name = sessions[i].tmuxName ?? sessions[i].id
            sessions[i].status = isResting(name) ? .rest : sessions[i].probed
        }
    }

    /// 会话是否休息：有云映射的以云为准，没云映射的（手机上没对应 tab）用本地。
    func isResting(_ tmuxName: String) -> Bool {
        if cloudResting.contains(tmuxName) { return true }
        if cloudAvailable, cloudMapping.ccToUUIDs[tmuxName.lowercased()] != nil { return false }
        return MacRestStore.isResting(tmuxName)
    }

    // MARK: 真实状态探测（干活中/等你/空闲）

    /// 一条 blinkd exec 遍历所有 cc-* 会话：pane_current_command + 底部有没有
    /// "esc to interrupt"(busy)。分类同 iOS：裸 shell→空闲、busy→干活、否则→等你。
    nonisolated static let probeScript = #"""
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
        Task { @MainActor in await self.enumerateAll(); showToast("状态已更新") }
    }

    /// 刷新当前选中会话的状态（Cmd-R）。只探测当前这一个，不动其它会话。
    func refreshActive() async {
        let s = activeSession
        guard !s.placeholder, let name = s.tmuxName,
              case .blinkd(let h, let p, let t) = activeMachine.transport else {
            showToast("当前没有可刷新的会话"); return
        }
        showToast("刷新「\(s.name)」…")
        let out = await BlinkdExec.run(host: h, port: p, token: t,
                                       command: AppState.probeOneScript(session: name),
                                       timeout: 15, finishMarker: "@TSB64E@")
        let map = AppState.parseProbe(out)
        guard let st = map[name], let i = sessions.firstIndex(where: { $0.tmuxName == name }) else {
            showToast("刷新失败或会话已不存在"); return
        }
        sessions[i].probed = st
        sessions[i].status = isResting(name) ? .rest : st
        await loadCloudRest()   // 顺带重拉云端休息状态
        loadFavorites()
        showToast("已刷新「\(s.name)」· \(sessions[i].status.label)")
    }

    /// 只探测单个会话的探测脚本（同 probeScript 但只跑一个 session）。
    static func probeOneScript(session: String) -> String {
        #"""
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
        s='\#(session)'
        pc=$(tmux display-message -p -t "$s" '#{pane_current_command}' 2>/dev/null)
        busy=0
        tmux capture-pane -p -S -250 -t "$s" 2>/dev/null | tail -15 | grep -q 'esc to interrupt' && busy=1
        BODY=$(printf '%s\t%s\t%s\n' "$s" "$pc" "$busy")
        EB64=$(printf '%s' "$BODY" | base64 | tr -d '\n')
        printf '@TSB64@%s@TSB64E@\n' "$EB64"
        """#
    }

    func probeStatuses() async {
        guard case .blinkd(let h, let p, let t) = activeMachine.transport else { return }
        await probeStatuses(host: h, port: p, token: t, machineID: activeMachineID)
    }

    /// 探测某一台机器的会话状态（只动这台的会话）。
    func probeStatuses(host: String, port: UInt16, token: String, machineID: String) async {
        let out = await BlinkdExec.run(host: host, port: port, token: token,
                                       command: AppState.probeScript, timeout: 20, finishMarker: "@TSB64E@")
        let map = AppState.parseProbe(out)
        guard !map.isEmpty else { return }
        for i in sessions.indices where sessions[i].machineID == machineID {
            guard let name = sessions[i].tmuxName else { continue }
            let probed = map[name] ?? .idle
            sessions[i].probed = probed
            sessions[i].status = isResting(name) ? .rest : probed
        }
    }

    nonisolated static func parseProbe(_ out: String) -> [String: WorkStatus] {
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

    nonisolated static func parseSessions(_ out: String, machineID: String) -> [Session] {
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
            // id 必须跨机器唯一（TerminalManager 按 id 建后端），用 <machineID>/<tmuxName>；tmuxName 仍是裸 cc- 名。
            result.append(Session(id: "\(machineID)/\(full)", machineID: machineID, name: title,
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
    private func resting(_ s: Session) -> Bool { isResting(s.tmuxName ?? s.id) }

    /// 侧栏只显示在岗会话，休息的隐藏（同手机 tab 栏）——休息在右侧员工列表管理。
    var sidebarSessions: [Session] {
        sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil && !resting($0) }
            .sorted { ($0.project, $0.owner) < ($1.project, $1.owner) }
    }

    var restingCount: Int {
        sessions.filter { $0.machineID == activeMachineID && resting($0) }.count
    }

    func count(_ s: WorkStatus) -> Int {
        sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil && $0.status == s }.count
    }

    /// 员工列表分组（真实会话）：按员工/项目/机器分组，含休息中的会话（在这里唤醒）。
    var teamGroups: [TeamGroup] {
        let mine = sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil }
        func summary(_ ss: [Session]) -> String {
            let w = ss.filter { $0.status == .wait }.count
            let r = ss.filter { $0.status == .rest }.count
            var parts = ["\(ss.count) 会话"]
            if w > 0 { parts.append("\(w) 等你") }
            if r > 0 { parts.append("\(r) 休息") }
            return parts.joined(separator: " · ")
        }
        func build(_ keyed: [(String, Session)]) -> [TeamGroup] {
            var order: [String] = []; var map: [String: [Session]] = [:]
            for (k, s) in keyed { if map[k] == nil { order.append(k) }; map[k, default: []].append(s) }
            return order.map { k in
                let ss = (map[k] ?? []).sorted { $0.name < $1.name }
                return TeamGroup(id: k, title: k, sub: summary(ss), sessions: ss)
            }.sorted { $0.title < $1.title }
        }
        switch inspector {
        case .employee: return build(mine.map { ($0.owner, $0) })
        case .project:  return build(mine.map { ($0.project, $0) })
        case .machine:
            // 「按机器」跨所有机器分组，这样其它机器也一眼看到（点行会切到对应机器的会话）。
            let all = sessions.filter { $0.tmuxName != nil }
            let nameOf: (String) -> String = { mid in self.machines.first { $0.id == mid }?.name ?? mid }
            var order: [String] = []; var map: [String: [Session]] = [:]
            for s in all { if map[s.machineID] == nil { order.append(s.machineID) }; map[s.machineID, default: []].append(s) }
            return order.map { mid in
                let ss = (map[mid] ?? []).sorted { $0.name < $1.name }
                return TeamGroup(id: mid, title: nameOf(mid), sub: summary(ss), sessions: ss)
            }
        }
    }

    // MARK: Actions

    func selectMachine(_ id: String) {
        activeMachineID = id
        // 指到这台机器的一个在岗会话（没有就置空，等用户点选）——避免终端拿旧机器的 transport 连错。
        activeSessionID = sidebarSessions.first(where: { $0.machineID == id })?.id ?? ""
        Task { @MainActor in await self.loadSessions(for: self.activeMachine) }
    }

    func selectSession(_ id: String) {
        activeSessionID = id
        // 选了哪台机器的会话，activeMachine 就跟到那台（终端连接用 activeMachine.transport）。
        if let s = sessions.first(where: { $0.id == id }) { activeMachineID = s.machineID }
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

    /// 切换某个会话的休息（隐藏/唤醒）。正式版写 iCloud KV（同步到手机），否则写本地。
    func toggleRest(sessionID: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        let name = s.tmuxName ?? s.id
        let now = !isResting(name)
        // 有云映射 → 写 KV，Blink 收到 iCloud 变更后同步到手机；写不成（无对应 tab）回退本地。
        if cloudAvailable, CloudRestStore.setResting(cc: name, on: now, mapping: cloudMapping) {
            if now { cloudResting.insert(name) } else { cloudResting.remove(name) }
        } else {
            _ = MacRestStore.toggle(name)
        }
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[i].status = now ? .rest : sessions[i].probed
        }
    }

    func toggleRestActive() {
        let s = activeSession
        guard !s.placeholder else { return }
        toggleRest(sessionID: s.id)
        showToast(resting(s) ? "已休息，从列表隐藏（🌙 里可唤醒）" : "已唤醒")
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
