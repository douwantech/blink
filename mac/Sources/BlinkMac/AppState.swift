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

    // 已关闭的会话 cc-<title>（本地记录 ∪ KV 全关墓碑）减去「手机又开了同名」的，隐藏它们。
    @Published var closedCC: Set<String> = []

    // 未读红点：会话处于「等你（完成）」且**自你上次看之后有新消息**（jsonl mtime 变大）→ 冒红点。
    // 「等你」橙标不再显示，直接用红点代替。信号用 claude 会话 jsonl 的 mtime：只有真写入新消息才更新，
    // 状态栏/光标重绘不碰文件（history_size 恒 0、session_activity 每秒乱跳，都不可靠）。
    @Published var currentActivity: [String: Int] = [:]   // tmuxName → 最近探到的 jsonl mtime
    private var lastSeenActivity: [String: Int] = [:]     // tmuxName → 你上次看时的 jsonl mtime
    @Published var appActive = true                       // 窗口是否在前台（正看着的会话算已看）

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

    /// 截图自测模式（BLINKMAC_CHATSHOT=1）：塞样例对话、直接进对话记录页，供命令行截图核对气泡布局。
    func chatShotIfNeeded() -> Bool {
        guard ProcessInfo.processInfo.environment["BLINKMAC_CHATSHOT"] == "1" else { return false }
        let img = ProcessInfo.processInfo.environment["BLINKMAC_CHATSHOT_IMG"] ?? ""
        machines = [Machine(id: "mbp", name: "mac", host: "本机", initials: "M", grad: Grad.blue, transport: .local)]
        // 走真实 blocks(from:) 清洗路径，顺便验证系统注入的图片元信息被丢掉。
        var pairs: [TranscriptPair] = [
            TranscriptPair(r: "you", t: "短消息"),
            TranscriptPair(r: "you", t: "[Image: original 3456x2168, displayed at 2000x1255. Multiply coordinates by 1.73 to map to original image.]"),
            TranscriptPair(r: "you", t: "让 command+D 可以执行这种切换，顺便把对话记录页做得好看一点。"),
            TranscriptPair(r: "claude", t: """
            ## 改完效果

            **Cmd-D** 现在来回切换终端 ↔ 对话记录，跟点底部「历史」等价，`openHistory()` 里做的。

            要点：
            - 走主菜单 key equivalent，焦点在 `SwiftTerm` 里也能触发
            - 短消息 hug、长消息换行，都*不撑满*

            | 机器 | 标签 |
            |---|---|
            | mac | 21 个活会话 |
            | xiaobai | 4 个 KV 标签 |

            你手上还剩四条：

            |     |                                |         |
            |-----|--------------------------------|---------|
            | **03** | RC 点「Apply in App Store Connect」 | 30 秒 |
            | **04** | 把 webhook token + `sk_` 给开发 | 1 分钟 |
            | **05** | 填 App 隐私标签 | 5 分钟 |
            | **06** | 补 810 号令涉税信息 | 3 分钟，只影响打款 |

            ```swift
            func openHistory() { mode = .chat }
            ```

            > 端到端都验过了，装好正式版。
            """),
            TranscriptPair(r: "you", t: "显示的还是不对，绿色的没有按长度来靠右对齐，图片还多了一些文字出来"),
        ]
        if !img.isEmpty {
            pairs.append(TranscriptPair(r: "you", t: "[Image #14] 这种是不是系统发的 [Image: source: \(img)]\n[Image: original 3456x2168, displayed at 2000x1255. Multiply coordinates by 1.73 to map to original image.]"))
        }
        let chat = AppState.blocks(from: pairs)
        sessions = [Session(id: "shot", machineID: "mbp", name: "jack-blink", dir: "~/Codes/Jack/blink",
                            initials: "JB", grad: Grad.green, status: .work, lines: [], chat: chat, tmuxName: "cc-jack-blink")]
        activeMachineID = "mbp"
        activeSessionID = "shot"
        mode = .chat
        return true
    }

    /// 截图自测：BLINKMAC_DOTSHOT=1 塞多机多会话、标几个未读红点，终端视图（看侧栏/机器栏/团队栏）。
    func dotShotIfNeeded() -> Bool {
        guard ProcessInfo.processInfo.environment["BLINKMAC_DOTSHOT"] == "1" else { return false }
        machines = [
            Machine(id: "mbp", name: "mac", host: "本机", initials: "M", grad: Grad.blue, online: true, transport: .local),
            Machine(id: "studio", name: "Mac Studio", host: "jack@studio", initials: "MS", grad: Grad.amber, online: true, transport: .local),
        ]
        func S(_ id: String, _ mid: String, _ name: String, _ st: WorkStatus) -> Session {
            Session(id: id, machineID: mid, name: name, dir: "~/Codes/Jack/blink",
                    initials: String(name.prefix(2)).uppercased(), grad: Grad.green,
                    status: st, probed: st, lines: [], tmuxName: "cc-" + name)
        }
        sessions = [
            S("mbp/cc-jack-blink", "mbp", "jack-blink", .work),
            S("mbp/cc-jack-printer", "mbp", "jack-printer", .wait),
            S("mbp/cc-jack-talkai", "mbp", "jack-talkai", .idle),
            S("studio/cc-bella-english", "studio", "bella-english", .wait),
            S("studio/cc-bella-life", "studio", "bella-life", .idle),
        ]
        // 处于 .wait 的（jack-printer / bella-english）没看过 → 自动冒红点
        activeMachineID = "mbp"
        activeSessionID = "mbp/cc-jack-blink"
        showTeam = true
        mode = .terminal
        return true
    }

    /// 由 RootView 的 .task 触发（从 init 里 spawn Task 不可靠）。
    func startup() async {
        if dotShotIfNeeded() { return }
        if chatShotIfNeeded() { return }
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
        loadClosed()                 // 已关闭标签（本地 + KV 墓碑），显示时过滤
        sessions.removeAll { $0.placeholder }   // 清掉 init 的「连接中…」占位
        await enumerateAll()         // 逐台并行枚举 + 探测真实会话（只 blinkd 机器）
        loadCloudTabs()              // 连不上的机器（SSH/离线）用 KV 里手机配的标签补上
        loadClosed()                 // 枚举/读 KV 后再算一次（openCC 可能变）
        if sessions.first(where: { $0.id == activeSessionID }) == nil { activeSessionID = "" }
        startPolling()               // 定时探测，完成的会话自动冒红点
    }

    /// 计算要隐藏的已关闭会话集合：本地记录 ∪ KV「全关」墓碑，减去 KV 里仍打开的（手机重新开了→解封）。
    /// 顺带清掉本地记录里已被手机重新打开的项，防止无限增长。
    func loadClosed() {
        let open = CloudTabStore.openCC()
        MacClosedStore.remove(open)   // 手机又开了同名 → 本地解封
        closedCC = MacClosedStore.all.union(CloudTabStore.fullyClosedCC()).subtracting(open)
    }

    /// 把 iCloud KV 里手机配置的标签并进来（所有机器），跟 iOS 显示同一份标签列表。
    /// 已实时枚举到的会话保留真实状态；没在跑 tmux 的配置标签补成「空闲」（点开会 new-session -A 起）。
    /// 按 cc-title 去重，不覆盖已有的活会话。
    func loadCloudTabs() {
        let tabs = CloudTabStore.tabs()
        guard !tabs.isEmpty else { return }
        let grads = [Grad.blue, Grad.amber, Grad.green, Grad.purple]
        for m in machines {
            // 这台机器已有的会话名（实时枚举 + 之前并进来的），避免重复。
            var seen = Set(sessions.filter { $0.machineID == m.id }.compactMap { $0.tmuxName?.lowercased() })
            let mine = tabs.filter { $0.machineId == m.id }
            var built: [Session] = []
            for t in mine {
                let full = "cc-" + t.ccName
                guard seen.insert(full.lowercased()).inserted else { continue }
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
                // 手机上配的是 SSH：用系统 /usr/bin/ssh + 用户自己的密钥连（跟手机同一套远端脚本）。
                transport = .ssh(user: cm.user, host: cm.host)
                let who = cm.user.isEmpty ? cm.host : "\(cm.user)@\(cm.host)"
                hostLabel = "SSH \(who)"
            }
            out.append(Machine(id: cm.id, name: name, host: hostLabel,
                               initials: String(name.prefix(2)).uppercased(),
                               grad: grads[i % grads.count],
                               online: true, transport: transport))
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
                let mid = m.id, tr = m.transport
                group.addTask {
                    let out = await AppState.exec(tr, BlinkdScript.listSessions(), timeout: 8, marker: nil)
                    return AppState.parseSessions(out, machineID: mid)
                }
            }
            for await real in group {
                guard let mid = real.first?.machineID else { continue }
                sessions.removeAll { $0.machineID == mid }
                sessions.append(contentsOf: real)
            }
        }
        await refreshStatuses()
    }

    /// 只探测状态、不重列会话（轮询用）：逐台并行跑 probeScript，更新各会话 probed/status。
    /// 完成的会话会从此变 .wait → hasUnseen 自动冒红点。
    func refreshStatuses() async {
        await withTaskGroup(of: (String, [String: (status: WorkStatus, activity: Int)]).self) { group in
            for m in machines {
                let mid = m.id, tr = m.transport
                group.addTask {
                    let out = await AppState.exec(tr, AppState.probeScript, timeout: 20, marker: "@TSB64E@")
                    return (mid, AppState.parseProbe(out))
                }
            }
            for await (mid, map) in group where !map.isEmpty {
                for i in sessions.indices where sessions[i].machineID == mid {
                    guard let name = sessions[i].tmuxName else { continue }
                    let probed = map[name]?.status ?? .idle
                    sessions[i].probed = probed
                    sessions[i].status = isResting(name) ? .rest : probed
                    if let act = map[name]?.activity { currentActivity[name] = act }
                }
            }
        }
        recomputeRestStatuses()   // 内含 refreshSeen（正看着的会话把 activity 记成已看）
    }

    private var pollTask: Task<Void, Never>?

    /// 定时轮询状态（每 12s），让完成的会话自动冒红点——不然只有手动刷新才更新。
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshStatuses()
            }
        }
    }

    /// 统一远端执行：blinkd 走 socket，ssh 走系统 /usr/bin/ssh，local 无。
    nonisolated static func exec(_ transport: Transport, _ command: String,
                                 timeout: TimeInterval, marker: String?) async -> String {
        switch transport {
        case .blinkd(let h, let p, let t):
            return await BlinkdExec.run(host: h, port: p, token: t, command: command,
                                        timeout: timeout, finishMarker: marker)
        case .ssh(let u, let h):
            return await SSHExec.run(user: u, host: h, command: command, timeout: timeout)
        case .local:
            return ""
        }
    }

    /// 枚举单台机器的会话并合并（只替换这台的，别动别的机器）。选机器/需要刷新单台时用。
    func loadSessions(for machine: Machine) async {
        guard machine.transport.connectable else { return }
        let out = await AppState.exec(machine.transport, BlinkdScript.listSessions(), timeout: 8, marker: nil)
        let real = AppState.parseSessions(out, machineID: machine.id)
        guard !real.isEmpty else {
            // 枚举不到（离线 / 无免密）→ 保留原有（可能是 KV 标签），别清空
            loadCloudTabs()
            return
        }
        sessions.removeAll { $0.machineID == machine.id }
        sessions.append(contentsOf: real)
        let out2 = await AppState.exec(machine.transport, AppState.probeScript, timeout: 20, marker: "@TSB64E@")
        let map = AppState.parseProbe(out2)
        for i in sessions.indices where sessions[i].machineID == machine.id {
            guard let name = sessions[i].tmuxName else { continue }
            let probed = map[name]?.status ?? .idle
            sessions[i].probed = probed
            sessions[i].status = isResting(name) ? .rest : probed
            if let act = map[name]?.activity { currentActivity[name] = act }
        }
        loadCloudTabs()      // 并回没在跑 tmux 的配置标签，跟 iOS 一致
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
            Task { @MainActor in self?.loadFavorites(); await self?.loadCloudRest(); self?.loadClosed() }
        }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: .main, using: reload)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main, using: reload)
        // 前台/后台：后台时会话完成也算「没看到」→ 照标红点。回前台顺带把正看着的清掉。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.appActive = true
                if self.mode == .terminal, !self.activeSessionID.isEmpty { self.markSeen(self.activeSessionID) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appActive = false }
        }
    }

    /// 从 iCloud KV + Blink 容器读跨设备休息状态（off-main），再重算各会话状态。
    func loadCloudRest() async {
        let (avail, mapping, resting) = await Task.detached(priority: .utility) {
            () -> (Bool, CloudRestStore.Mapping, Set<String>) in
            // 优先用 KV 的 tab 映射（可靠、无 TCC）；KV 拿不到再兜底读容器 plist。
            var m = CloudTabStore.mapping()
            if m.ccToUUIDs.isEmpty { m = CloudRestStore.loadMapping() }
            return (CloudRestStore.available, m, CloudRestStore.restingCCTitles(m))
        }.value
        cloudAvailable = avail
        cloudMapping = mapping
        cloudResting = resting
        recomputeRestStatuses()
    }

    // MARK: 未读红点

    /// 红点 = 处于「等你」且自上次看之后有新输出（当前 activity > 上次看时的 activity）。
    /// 上次没记过（nil）当 -1，这样首次探测到的等你会话也算未看 → 冒点。
    func hasUnseen(_ s: Session) -> Bool {
        guard s.status == .wait, let name = s.tmuxName else { return false }
        return (currentActivity[name] ?? 0) > (lastSeenActivity[name] ?? -1)
    }
    func machineHasUnseen(_ mid: String) -> Bool {
        sessions.contains { $0.machineID == mid && !isClosed($0) && hasUnseen($0) }
    }

    /// 看过了 → 把「上次看时的 history_size」推到当前值，红点消失（直到又有新内容）。
    /// 立刻用已知值清点，再异步探一次拿最新行数（兜住上次轮询到点开之间刚冒的内容）。
    func markSeen(_ sessionID: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }), let name = s.tmuxName else { return }
        lastSeenActivity[name] = currentActivity[name] ?? Int.max   // 没探到过就先当全看过，别误冒
        let tr = machines.first(where: { $0.id == s.machineID })?.transport
        guard let tr, tr.connectable else { return }
        Task { @MainActor in
            let out = await AppState.exec(tr, AppState.probeOneScript(session: name), timeout: 12, marker: "@TSB64E@")
            if let info = AppState.parseProbe(out)[name] {
                currentActivity[name] = info.activity
                lastSeenActivity[name] = info.activity   // 以点开那刻的最新行数为准
            }
        }
    }

    /// 每次状态定妥后：正看着的会话（前台+选中+终端）持续算已看。
    private func refreshSeen() {
        guard appActive, mode == .terminal,
              let name = sessions.first(where: { $0.id == activeSessionID })?.tmuxName else { return }
        lastSeenActivity[name] = currentActivity[name] ?? lastSeenActivity[name]
    }

    /// 按当前休息判定重算所有会话的 status（休息优先，否则用探测值）。
    func recomputeRestStatuses() {
        for i in sessions.indices {
            let name = sessions[i].tmuxName ?? sessions[i].id
            sessions[i].status = isResting(name) ? .rest : sessions[i].probed
        }
        refreshSeen()
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
PROJ="$HOME/.claude/projects"
BODY=$(
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^cc-' | while IFS= read -r s; do
  pc=$(tmux display-message -p -t "$s" '#{pane_current_command}' 2>/dev/null)
  busy=0
  tmux capture-pane -p -S -250 -t "$s" 2>/dev/null | tail -15 | grep -q 'esc to interrupt' && busy=1
  # act = 该会话 jsonl 的 mtime：只有真写入新消息才更新（状态栏/光标重绘不碰文件）。
  # 按会话 cwd 映射到 ~/.claude/projects/<enc> 里、customTitle 匹配的 jsonl（限本目录，够快）。
  cwd=$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)
  enc=$(printf '%s' "$cwd" | sed 's/[/.]/-/g')
  TITLE=${s#cc-}
  act=0
  F=$(grep -lF "\"customTitle\":\"$TITLE\"" "$PROJ/$enc"/*.jsonl "$PROJ/$enc"*/*.jsonl 2>/dev/null | head -1)
  [ -n "$F" ] && act=$(stat -f %m "$F" 2>/dev/null || stat -c %Y "$F" 2>/dev/null)
  printf '%s\t%s\t%s\t%s\n' "$s" "$pc" "$busy" "$act"
done
)
EB64=$(printf '%s' "$BODY" | base64 | tr -d '\n')
printf '@TSB64@%s@TSB64E@\n' "$EB64"
"""#

    func probe() {
        showToast("正在探测各机器…")
        Task { @MainActor in
            await self.enumerateAll()
            self.loadCloudTabs()      // 并回没在跑 tmux 的配置标签
            self.loadClosed()
            self.showToast("状态已更新")
        }
    }

    /// 刷新当前选中会话的状态（Cmd-R）。只探测当前这一个，不动其它会话。
    func refreshActive() async {
        let s = activeSession
        guard !s.placeholder, let name = s.tmuxName, activeMachine.transport.connectable else {
            showToast("当前没有可刷新的会话"); return
        }
        showToast("刷新「\(s.name)」…")
        let out = await AppState.exec(activeMachine.transport,
                                      AppState.probeOneScript(session: name),
                                      timeout: 15, marker: "@TSB64E@")
        let map = AppState.parseProbe(out)
        guard let info = map[name], let i = sessions.firstIndex(where: { $0.tmuxName == name }) else {
            showToast("刷新失败或会话已不存在"); return
        }
        sessions[i].probed = info.status
        sessions[i].status = isResting(name) ? .rest : info.status
        currentActivity[name] = info.activity
        await loadCloudRest()   // 顺带重拉云端休息状态
        loadFavorites()
        showToast("已刷新「\(s.name)」· \(sessions[i].status.label)")
    }

    /// 只探测单个会话的探测脚本（同 probeScript 但只跑一个 session）。
    static func probeOneScript(session: String) -> String {
        #"""
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
        PROJ="$HOME/.claude/projects"
        s='\#(session)'
        pc=$(tmux display-message -p -t "$s" '#{pane_current_command}' 2>/dev/null)
        busy=0
        tmux capture-pane -p -S -250 -t "$s" 2>/dev/null | tail -15 | grep -q 'esc to interrupt' && busy=1
        cwd=$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)
        enc=$(printf '%s' "$cwd" | sed 's/[/.]/-/g')
        TITLE=${s#cc-}
        act=0
        F=$(grep -lF "\"customTitle\":\"$TITLE\"" "$PROJ/$enc"/*.jsonl "$PROJ/$enc"*/*.jsonl 2>/dev/null | head -1)
        [ -n "$F" ] && act=$(stat -f %m "$F" 2>/dev/null || stat -c %Y "$F" 2>/dev/null)
        BODY=$(printf '%s\t%s\t%s\t%s\n' "$s" "$pc" "$busy" "$act")
        EB64=$(printf '%s' "$BODY" | base64 | tr -d '\n')
        printf '@TSB64@%s@TSB64E@\n' "$EB64"
        """#
    }

    /// 探测结果：状态 + session_activity（最后有输出的 unix 时间戳，判「有没有新输出」用）。
    nonisolated static func parseProbe(_ out: String) -> [String: (status: WorkStatus, activity: Int)] {
        guard let a = out.range(of: "@TSB64@"), let b = out.range(of: "@TSB64E@"),
              a.upperBound <= b.lowerBound else { return [:] }
        let b64 = out[a.upperBound..<b.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(b64)),
              let body = String(data: data, encoding: .utf8) else { return [:] }
        let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]
        var map: [String: (WorkStatus, Int)] = [:]
        for line in body.split(whereSeparator: { $0.isNewline }) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            let pc = f[1].trimmingCharacters(in: .whitespaces)
            let busy = f[2].trimmingCharacters(in: .whitespaces) == "1"
            let act = f.count >= 4 ? (Int(f[3].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
            let st: WorkStatus = (pc.isEmpty || shells.contains(pc)) ? .idle : (busy ? .work : .wait)
            map[String(f[0])] = (st, act)
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

    /// 该会话是否被「关闭」（本地记录 + KV 墓碑，且手机没重新开同名 → 见 loadClosed）。
    func isClosed(_ s: Session) -> Bool { closedCC.contains((s.tmuxName ?? s.id).lowercased()) }

    /// 侧栏只显示在岗会话，休息/已关闭的隐藏（同手机 tab 栏）——休息在右侧员工列表管理。
    var sidebarSessions: [Session] {
        sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil && !resting($0) && !isClosed($0) }
            .sorted { ($0.project, $0.owner) < ($1.project, $1.owner) }
    }

    var restingCount: Int {
        sessions.filter { $0.machineID == activeMachineID && resting($0) && !isClosed($0) }.count
    }

    func count(_ s: WorkStatus) -> Int {
        sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil && !isClosed($0) && $0.status == s }.count
    }

    /// 员工列表分组（真实会话）：按员工/项目/机器分组，含休息中的会话（在这里唤醒）。
    var teamGroups: [TeamGroup] {
        let mine = sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil && !isClosed($0) }
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
            let all = sessions.filter { $0.tmuxName != nil && !isClosed($0) }
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
        markSeen(id)   // 点进去看了 → 清红点
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

    /// 关闭一个标签：写 KV 墓碑同步到 iOS（有对应 tab UUID 时），本地也移除。
    /// 说明：blinkd 机器的会话是「实时枚举」出来的，关了下次刷新还会再枚举回来
    /// （tmux 还活着，关标签不 kill 远端进程，跟 iOS 一致）；SSH/离线机器的标签来自 KV，
    /// 写了墓碑后 iOS 和 Mac 都不再显示。
    func closeTab(sessionID: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        let full = (s.tmuxName ?? ("cc-" + s.name)).lowercased()
        let uuids = cloudMapping.ccToUUIDs[full] ?? []
        var synced = false
        for id in uuids where CloudTabStore.closeTab(id: id) { synced = true }
        MacClosedStore.add(full)        // 本地记一份，重启后仍隐藏（枚举/无墓碑的也挡得住）
        sessions.removeAll { $0.id == sessionID }
        if activeSessionID == sessionID { activeSessionID = sidebarSessions.first?.id ?? "" }
        loadClosed()                    // 立即纳入隐藏集
        Task { @MainActor in await self.loadCloudRest() }   // 刷新映射
        showToast(synced ? "已关闭「\(s.name)」并同步到手机" : "已关闭「\(s.name)」（本地）")
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

    // MARK: 历史 / 对话记录（同手机「历史」按钮：把中间切成聊天显示）

    /// 点「历史」：把中间从终端切成对话记录视图。先秒显本地缓存，再只拉游标之后的
    /// 新行增量追加（不每次整拉）。再点一次回终端（点左侧会话也回终端，见 selectSession）。
    func openHistory() {
        if mode == .chat { mode = .terminal; return }
        let s = activeSession
        guard !s.placeholder, let name = s.tmuxName, activeMachine.transport.connectable else {
            showToast("当前会话没有对话记录可看"); return
        }
        let title = name.hasPrefix("cc-") ? String(name.dropFirst(3)) : name
        let cacheKey = activeMachine.id + "/" + name
        mode = .chat

        // 1) 缓存秒显（有缓存直接铺出来，像聊天 App 一样进来就有历史）
        let cached = MacTranscriptStore.load(cacheKey)
        let sid = s.id
        if let c = cached, !c.pairs.isEmpty {
            setChat(sid, AppState.blocks(from: c.pairs))
        } else if let i = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[i].chat = [ChatBlock(role: "ASSISTANT", color: Theme.dim, text: "正在拉取对话记录…")]
        }

        // 2) 后台增量：同文件只拉 lines+1 之后的新行，换文件/无缓存才整拉最后 100 条
        let transport = activeMachine.transport
        Task { @MainActor in
            let out = await AppState.exec(
                transport,
                AppState.historyDeltaScript(title: title, cachedFile: cached?.file, cachedLines: cached?.lines ?? 0),
                timeout: 25, marker: "@TSB64E@")
            guard let d = AppState.parseTranscriptDelta(out) else {
                if cached == nil, let i = sessions.firstIndex(where: { $0.id == sid }) {
                    sessions[i].chat = [ChatBlock(role: "ASSISTANT", color: Theme.dim, text: "对话记录拉取失败。")]
                }
                return
            }
            if d.notFound {
                if cached?.pairs.isEmpty ?? true, let i = sessions.firstIndex(where: { $0.id == sid }) {
                    sessions[i].chat = [ChatBlock(role: "ASSISTANT", color: Theme.dim,
                        text: d.message.isEmpty ? "没读到这个会话的对话记录。" : d.message)]
                }
                return
            }
            // 合并缓存：整拉或换文件 → 替换；同文件 → 游标续接、pairs 追加
            var merged: TranscriptCache
            if d.full || cached == nil || cached!.file != d.file {
                merged = TranscriptCache(file: d.file, lines: d.total, pairs: d.pairs)
            } else {
                merged = cached!
                merged.file = d.file
                merged.lines = d.total
                merged.pairs += d.pairs
            }
            MacTranscriptStore.save(cacheKey, merged)
            // 有新内容、或之前没缓存可显时才重刷 UI（省得无谓重排）
            if !d.pairs.isEmpty || (cached?.pairs.isEmpty ?? true) {
                guard mode == .chat, let i = sessions.firstIndex(where: { $0.id == sid }) else { return }
                sessions[i].chat = merged.pairs.isEmpty
                    ? [ChatBlock(role: "ASSISTANT", color: Theme.dim, text: "没读到这个会话的对话记录。")]
                    : AppState.blocks(from: merged.pairs)
            }
        }
    }

    private func setChat(_ sid: String, _ blocks: [ChatBlock]) {
        guard let i = sessions.firstIndex(where: { $0.id == sid }) else { return }
        sessions[i].chat = blocks
    }

    /// 气泡正文切片：文本 / 图片。图片支持 markdown ![](url)、图床 http(s) 图片 URL、
    /// 本地绝对路径（如 transcript 里的 [Image: source: /Users/.../x.png]）。
    enum ChatSegment: Identifiable {
        case text(String)
        case remoteImage(URL)
        case localImage(String)
        var id: String {
            switch self {
            case .text(let t): return "t:" + String(t.prefix(24)) + "\(t.count)"
            case .remoteImage(let u): return "r:" + u.absoluteString
            case .localImage(let p): return "l:" + p
            }
        }
    }

    private static let imageRegex: NSRegularExpression? = {
        // 分支（含把整段连括号一起吃掉的包裹形式，避免留下 "[Image: source:" / "]" 碎字）：
        //  g1 = [Image: source: <path>] 的路径     g2 = markdown ![](url) 的 url
        //  g3 = 裸 http(s) 图片 URL                 g4 = 本地绝对路径图片
        //  另有 [Image #N] 占位：整体匹配、无捕获组 → 直接丢弃
        let p = #"\[Image:\s*source:\s*([^\]\s]+)\s*\]|\[Image\s*#\d+\]|!\[[^\]]*\]\(\s*([^)\s]+)\s*\)|(https?://[^\s)]+\.(?:png|jpe?g|gif|webp|bmp)(?:\?[^\s)]*)?)|(/(?:[^\s/]+/)+[^\s/]+\.(?:png|jpe?g|gif|webp|bmp))"#
        return try? NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }()

    nonisolated static func chatSegments(_ raw: String) -> [ChatSegment] {
        guard let re = imageRegex else { return [.text(raw)] }
        let ns = raw as NSString
        let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return [.text(raw)] }

        var out: [ChatSegment] = []
        var idx = 0
        func pushText(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.text(t)) }
        }
        func grp(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        for m in ms {
            if m.range.location > idx {
                pushText(ns.substring(with: NSRange(location: idx, length: m.range.location - idx)))
            }
            if let p = grp(m, 1) {                    // [Image: source: <path>]
                out.append(.localImage(p))
            } else if let mdURL = grp(m, 2) {          // markdown ![](url)
                if mdURL.hasPrefix("http"), let u = URL(string: mdURL) { out.append(.remoteImage(u)) }
                else if mdURL.hasPrefix("/") { out.append(.localImage(mdURL)) }
                else { pushText(mdURL) }
            } else if let httpURL = grp(m, 3), let u = URL(string: httpURL) {
                out.append(.remoteImage(u))
            } else if let local = grp(m, 4) {
                out.append(.localImage(local))
            }
            // 其余（[Image #N] 占位）：无捕获组 → 丢弃
            idx = m.range.location + m.range.length
        }
        if idx < ns.length { pushText(ns.substring(with: NSRange(location: idx, length: ns.length - idx))) }
        return out.isEmpty ? [.text(raw)] : out
    }

    /// (role,text) 缓存对 → 显示用 ChatBlock。清洗掉系统注入的图片元信息，
    /// 清完为空的整条丢掉（那种「只有一行系统图片说明」的消息不再显示）。
    nonisolated static func blocks(from pairs: [TranscriptPair]) -> [ChatBlock] {
        pairs.compactMap { p in
            let t = cleanTranscriptText(p.t)
            guard !t.isEmpty else { return nil }
            return ChatBlock(role: p.r == "you" ? "YOU" : "ASSISTANT",
                             color: p.r == "you" ? Theme.green2 : Theme.blue, text: t)
        }
    }

    /// 去掉 harness/系统在贴图时注入、非用户输入的文本：
    ///  · [Image: original 3456x2168, displayed at …. Multiply coordinates … map to original image.]
    ///  · [Image #N] 占位
    /// 注意保留 [Image: source: /path]（那是要渲染的真图）。
    nonisolated static func cleanTranscriptText(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(
            of: #"\[Image:\s*original\s+\d+x\d+[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"\[Image\s*#\d+\]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct TranscriptDelta {
        var file: String
        var total: Int
        var full: Bool
        var pairs: [TranscriptPair]
        var notFound: Bool
        var message: String
    }

    /// 远端增量拉 transcript：按 customTitle 在 ~/.claude/projects 定位 jsonl，
    /// 只 sed 出游标(cachedLines+1)之后的新行喂 jq，解析成「▶ You / ◆ Claude」块
    /// （同 iOS BlinkMachineStore.transcriptDeltaScript）。输出
    /// @TSB64@<b64(META\t<file>\t<total>\t<full>\n<正文>)>@TSB64E@。
    nonisolated static func historyDeltaScript(title: String, cachedFile: String?, cachedLines: Int) -> String {
        let safeFile = (cachedFile ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let cachedN = max(cachedLines, 0)
        return #"""
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
        TITLE='\#(title)'
        PROJ="$HOME/.claude/projects"
        pick_latest_by_mtime() {
          while read f; do
            [ -z "$f" ] && continue
            printf '%d\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" "$f"
          done | sort -rn | head -1 | cut -f2-
        }
        emit() { EB64=$(printf '%s' "$1" | base64 | tr -d '\n'); printf '@TSB64@%s@TSB64E@\n' "$EB64"; }
        if ! command -v jq >/dev/null 2>&1; then
          emit "$(printf 'META\tNOTFOUND\t0\t1\n⚠️ 这台机器没装 jq，读不了对话记录。ssh 上去 brew install jq')"
          exit 0
        fi
        F=$(grep -rilF "\"customTitle\":\"$TITLE\"" "$PROJ" --include='*.jsonl' 2>/dev/null | pick_latest_by_mtime)
        if [ -z "$F" ]; then
          emit "$(printf 'META\tNOTFOUND\t0\t1\n没找到这个会话的对话记录（customTitle『%s』未匹配）。到这个 cc 里跑一次 /title %s 固定命名后再看。' "$TITLE" "$TITLE")"
          exit 0
        fi
        BASE=$(basename "$F")
        TOTAL=$(wc -l < "$F" | tr -d ' ')
        START=1
        if [ "$BASE" = "\#(safeFile)" ] && [ \#(cachedN) -le "$TOTAL" ]; then
          START=$(( \#(cachedN) + 1 ))
        fi
        FULL=0
        [ "$START" -eq 1 ] && FULL=1
        BODY=""
        if [ "$START" -le "$TOTAL" ]; then
          BODY=$(sed -n "${START},${TOTAL}p" "$F" | jq -s -r --arg full "$FULL" '
            [.[] | select(.type=="user" or .type=="assistant")
              | (if (.message.content|type)=="string" then .message.content
                 else [.message.content[]? | select(.type=="text") | .text] | join("\n") end) as $raw
              | ($raw
                 | gsub("(?s)<system-reminder>.*?</system-reminder>";"")
                 | gsub("(?s)<task-notification>.*?</task-notification>";"")
                 | gsub("(?s)<local-command-stdout>.*?</local-command-stdout>";"")
                 | gsub("(?s)<local-command-stderr>.*?</local-command-stderr>";"")
                 | gsub("(?s)<command-name>.*?</command-name>";"")
                 | gsub("(?s)<command-message>.*?</command-message>";"")
                 | gsub("(?s)<command-args>.*?</command-args>";"")
                 | gsub("(?s)<bash-input>.*?</bash-input>";"")
                 | gsub("(?s)<bash-stdout>.*?</bash-stdout>";"")
                 | gsub("(?s)<bash-stderr>.*?</bash-stderr>";"")
                 | gsub("\\[Image: original [^\\]]*\\]";"")
                 | sub("^\\s+";"") | sub("\\s+$";"")) as $body
              | select(($body|length)>0)
              | select($body!="Continue from where you left off."
                       and $body!="No response requested."
                       and ($body|test("^\\[Request interrupted by user[^\\]]*\\]")|not))
              | {type:.type, body:$body}]
            | (if $full == "1" then .[-100:] else . end)
            | .[]
            | (if .type=="user" then "▶ You" else "◆ Claude" end), .body, ""
          ' 2>&1)
        fi
        if [ "$FULL" = "1" ] && [ -z "$BODY" ]; then
          BODY="（这个 session 里没有可显示的对话内容——可能是全新会话，或内容全是命令输出被过滤了）"
        fi
        emit "$(printf 'META\t%s\t%s\t%s\n' "$BASE" "$TOTAL" "$FULL"; printf '%s' "$BODY")"
        """#
    }

    /// 解析增量脚本输出：拆 @TSB64@…@TSB64E@ → base64 解码 → 首行 META 拿 file/total/full，
    /// 其余按「▶ You / ◆ Claude」行切成 (role,text) 对。NOTFOUND → notFound=true 带提示。
    nonisolated static func parseTranscriptDelta(_ out: String) -> TranscriptDelta? {
        guard let a = out.range(of: "@TSB64@"), let b = out.range(of: "@TSB64E@"),
              a.upperBound <= b.lowerBound else { return nil }
        let b64 = out[a.upperBound..<b.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(b64)),
              let body = String(data: data, encoding: .utf8) else { return nil }

        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let head = lines.first, head.hasPrefix("META\t") else { return nil }
        lines.removeFirst()
        let meta = head.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let base = meta.count > 1 ? meta[1] : ""
        let total = meta.count > 2 ? (Int(meta[2]) ?? 0) : 0
        let full = meta.count > 3 && meta[3] == "1"
        if base == "NOTFOUND" {
            let msg = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptDelta(file: "", total: 0, full: true, pairs: [], notFound: true, message: msg)
        }

        var pairs: [TranscriptPair] = []
        var role: String? = nil
        var buf: [String] = []
        func flush() {
            guard let r = role else { return }
            var ls = buf
            while let f = ls.first, f.trimmingCharacters(in: .whitespaces).isEmpty { ls.removeFirst() }
            while let l = ls.last, l.trimmingCharacters(in: .whitespaces).isEmpty { ls.removeLast() }
            let text = ls.joined(separator: "\n")
            if !text.isEmpty { pairs.append(TranscriptPair(r: r, t: text)) }
            buf = []
        }
        for line in lines {
            if line == "▶ You" { flush(); role = "you"; continue }
            if line == "◆ Claude" { flush(); role = "claude"; continue }
            if role == nil { continue }   // 跳过正文前的杂行（HEAD 等）
            buf.append(line)
        }
        flush()
        return TranscriptDelta(file: base, total: total, full: full, pairs: pairs, notFound: false, message: "")
    }

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
