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
    /// 员工 CLI 配置改动计数：TabAgentStore 现读磁盘，靠它触发列表重画
    @Published var agentTick = 0

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

    /// 每个 blinkd 会话实际用的连接通道（sessionID → "LAN 直连" / "Tailscale"），状态栏据此标记。
    @Published var transportBySession: [String: String] = [:]

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
        // 远程会话贴图上传图床时，把进度/结果 toast 冒出来（需 self 全初始化后再接）。
        term.onToast = { [weak self] m in Task { @MainActor in self?.showToast(m) } }
        term.onTransport = { [weak self] sid, kind in Task { @MainActor in self?.transportBySession[sid] = kind } }
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

    /// 由 RootView 的 .task 触发（从 init 里 spawn Task 不可靠）。
    func startup() async {
        if chatShotIfNeeded() { return }
        BlinkdDiscovery.shared.start()   // 常驻 Bonjour 发现同网 blinkd，供 LAN 优先直连用
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
        await adoptOrphanSessions()  // 本机没标签的会话补成标签（三端一致）
        loadCloudTabs()              // 连不上的机器（SSH/离线）用 KV 里手机配的标签补上
        loadClosed()                 // 枚举/读 KV 后再算一次（openCC 可能变）
        if sessions.first(where: { $0.id == activeSessionID }) == nil { activeSessionID = "" }
    }

    /// 计算要隐藏的已关闭会话集合：本地记录 ∪ KV「全关」墓碑，减去 KV 里仍打开的（手机重新开了→解封）。
    /// 顺带清掉本地记录里已被手机重新打开的项，防止无限增长。
    func loadClosed() {
        let open = CloudTabStore.openCC()
        MacClosedStore.remove(open)   // 手机又开了同名 → 本地解封
        closedCC = MacClosedStore.all.union(CloudTabStore.fullyClosedCC()).subtracting(open)
        computeOrphanHidden()
    }

    /// 本机上「有 tmux 会话但同步文件里没标签」的会话 id（<machineID>/cc-…）。
    /// 手机、平板只显示同步文件里的标签，Mac 也照这个来，三端看到的一样（tmux 不动，只是不显示）。
    @Published var orphanHidden: Set<String> = []

    func computeOrphanHidden() {
        guard SyncConfig.available, let local = machines.first(where: { $0.isLocalMac }) else {
            orphanHidden = []; return
        }
        let mine = Set(CloudTabStore.tabs().filter { $0.machineId == local.id }.map { "cc-" + $0.ccName.lowercased() })
        guard !mine.isEmpty else { orphanHidden = []; return }   // 读不到本机标签时别把会话全藏了
        orphanHidden = Set(sessions.filter {
            $0.machineID == local.id && $0.tmuxName != nil && !mine.contains($0.tmuxName!.lowercased())
        }.map(\.id))
    }

    /// 本机 Mac：把没标签的 tmux 会话补成同步文件里的标签（三端一致），规则见 OrphanTabAdopter。
    func adoptOrphanSessions() async {
        guard SyncConfig.available,
              let m = machines.first(where: { $0.isLocalMac }), m.transport.connectable else { return }
        let out = await AppState.exec(m.transport, BlinkdScript.listSessionsCreated(), timeout: 8, marker: nil)
        // PTY 输出行尾是 \r\n，Swift 里它是一个 Character，按 "\n" 切不开，要用 isNewline
        let live: [(title: String, created: Double)] = out.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: "\t")
            guard p.count >= 2, p[0].hasPrefix("cc-"),
                  let t = Double(p[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return (String(p[0].dropFirst(3)).lowercased(), t)
        }
        guard !live.isEmpty else { return }
        let mid = m.id
        let r = await Task.detached(priority: .utility) { OrphanTabAdopter.adopt(machineId: mid, live: live) }.value
        NSLog("[adopt] 本机会话=%d 补成标签=%@ 跳过(无三端一致的工作目录)=%@", live.count, r.adopted.joined(separator: ","), r.skipped.joined(separator: ","))
        guard !r.adopted.isEmpty else { return }
        await loadCloudRest()
        loadCloudTabs()
        loadClosed()
        showToast("已把 \(r.adopted.joined(separator: "、")) 补成标签，手机和平板也能看到")
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
                                     status: .idle, lines: [], tmuxName: full))
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
        guard !cloud.isEmpty, case .blinkd(_, let lp, let lt) = machines.first?.transport else { return }
        let grads = [Grad.blue, Grad.amber, Grad.green, Grad.purple, Grad.slate]
        var out: [Machine] = []
        var thisMacId: String? = nil
        for (i, cm) in cloud.enumerated() {
            let name = cm.name.isEmpty ? "机器\(i + 1)" : cm.name
            let transport: Transport
            let hostLabel: String
            let isLocalMac: Bool
            if let b = cm.blinkd {
                let isThisMac = (b.token == lt)
                // 这台 Mac 连自己的 daemon 走 127.0.0.1 回环（daemon 双模式在 0.0.0.0 也监听），
                // 不绕 Tailscale/tsnet；其余 blinkd 机器才走 KV 里的地址（tsnet）。
                let loopback = "127.0.0.1"
                transport = isThisMac ? .blinkd(host: loopback, port: lp, token: lt)
                                      : .blinkd(host: b.host, port: b.port, token: b.token)
                hostLabel = isThisMac ? "本机 · \(loopback):\(lp)" : "blinkd \(b.host):\(b.port)"
                isLocalMac = isThisMac
                if isThisMac { thisMacId = cm.id }
            } else {
                // 手机上配的是 SSH：用系统 /usr/bin/ssh + 用户自己的密钥连（跟手机同一套远端脚本）。
                transport = .ssh(user: cm.user, host: cm.host)
                let who = cm.user.isEmpty ? cm.host : "\(cm.user)@\(cm.host)"
                hostLabel = "SSH \(who)"
                isLocalMac = false
            }
            out.append(Machine(id: cm.id, name: name, host: hostLabel,
                               initials: String(name.prefix(2)).uppercased(),
                               grad: grads[i % grads.count],
                               online: true, transport: transport, isLocalMac: isLocalMac))
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
        recomputeRestStatuses()
        computeOrphanHidden()
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
        loadCloudTabs()      // 并回没在跑 tmux 的配置标签，跟 iOS 一致
        recomputeRestStatuses()
        computeOrphanHidden()
    }

    private var observingCloud = false

    /// 实时监听休息变化：iCloud KV 外部变更（手机改了推过来）+ 回前台补拉
    /// （didChangeExternally 不可靠，Blink 自己也靠回前台 pull）。
    func startObservingCloud() {
        guard !observingCloud else { return }
        observingCloud = true
        NSUbiquitousKeyValueStore.default.synchronize()
        let reload: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.loadFavorites(); await self?.loadCloudRest(); self?.loadClosed()
                await self?.adoptOrphanSessions()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: .main, using: reload)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main, using: reload)
        watchSyncFile()
    }

    private var syncDirSource: DispatchSourceFileSystemObject?
    private var syncReloadPending = false

    /// 盯三端共用的同步目录 `~/.blink/sync`：手机 / 平板改了标签、关闭、休息会整份换掉 blink_config.json
    /// （写临时文件再 rename，文件 inode 会变，所以盯目录而不是文件）。变了就重载标签、关闭、休息。
    private func watchSyncFile() {
        let dir = (SyncConfig.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.syncReloadPending else { return }
            self.syncReloadPending = true
            // 一次换文件会连着触发几次，攒 0.5s 再重载
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.syncReloadPending = false
                Task { @MainActor in
                    self.loadFavorites()
                    await self.loadCloudRest()
                    self.loadCloudTabs()
                    self.loadClosed()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        syncDirSource = src
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

    /// 按当前休息判定重算所有会话的 status（休息优先，否则用探测值）。
    func recomputeRestStatuses() {
        for i in sessions.indices {
            sessions[i].status = isResting(sessions[i]) ? .rest : .idle
        }
    }

    /// 会话键：`<machineId>/cc-<title>` 小写（按机器区分同名会话，见 CloudRestStore.Mapping）。
    func restKey(_ s: Session) -> String { CloudRestStore.key(machineId: s.machineID, cc: s.tmuxName ?? s.id) }

    /// 会话是否休息：有云映射的以云为准，没云映射的（手机上没对应 tab）用本地。
    func isResting(_ s: Session) -> Bool {
        let key = restKey(s)
        if cloudResting.contains(key) { return true }
        if cloudAvailable, cloudMapping.ccToUUIDs[key] != nil { return false }
        return MacRestStore.isResting(s.tmuxName ?? s.id)
    }

    // MARK: 真实状态探测（干活中/等你/空闲）


    func probe() {
        showToast("正在刷新…")
        Task { @MainActor in
            await self.enumerateAll()
            self.loadCloudTabs()      // 并回没在跑 tmux 的配置标签
            self.loadClosed()
            self.showToast("已更新")
        }
    }

    /// 刷新当前选中会话的状态（Cmd-R）。只探测当前这一个，不动其它会话。
    func refreshActive() async {
        let s = activeSession
        guard !s.placeholder, s.tmuxName != nil else {
            showToast("当前没有可刷新的会话"); return
        }
        showToast("刷新「\(s.name)」…")
        await loadSessions(for: activeMachine)
        await loadCloudRest()   // 顺带重拉云端休息状态
        loadFavorites()
        showToast("已刷新「\(s.name)」")
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
                                  status: resting ? .rest : .idle,
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
    func resting(_ s: Session) -> Bool { isResting(s) }

    /// 该会话是否被「关闭」（本地记录 + KV 墓碑，且手机没重新开同名 → 见 loadClosed）。
    func isClosed(_ s: Session) -> Bool {
        closedCC.contains((s.tmuxName ?? s.id).lowercased()) || orphanHidden.contains(s.id)
    }

    /// 侧栏只显示在岗会话，休息/已关闭的隐藏（同手机 tab 栏）——休息在右侧员工列表管理。
    var sidebarSessions: [Session] {
        sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil && !resting($0) && !isClosed($0) }
            .sorted { ($0.project, $0.owner) < ($1.project, $1.owner) }
    }

    var restingCount: Int {
        sessions.filter { $0.machineID == activeMachineID && resting($0) && !isClosed($0) }.count
    }

    /// 团队面板里列出来的会话总数（跨机器，含休息的）
    var sessionCount: Int {
        sessions.filter { $0.tmuxName != nil && !isClosed($0) }.count
    }

    func count(_ s: WorkStatus) -> Int {
        sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil && !isClosed($0) && $0.status == s }.count
    }

    /// 机器显示名（查不到就退回 id）
    func machineName(_ machineID: String) -> String {
        machines.first { $0.id == machineID }?.name ?? machineID
    }

    /// 员工列表分组（真实会话）：按员工/项目/机器分组，含休息中的会话（在这里唤醒）。
    var teamGroups: [TeamGroup] {
        // 三档都跨机器列全（团队面板是「看所有人在干嘛」，不该被当前机器挡住）
        let all = sessions.filter { $0.tmuxName != nil && !isClosed($0) }
        func summary(_ ss: [Session]) -> String {
            let w = ss.filter { $0.status == .wait }.count
            let r = ss.filter { $0.status == .rest }.count
            var parts = ["\(ss.count) 会话"]
            if w > 0 { parts.append("\(w) 等你") }
            if r > 0 { parts.append("\(r) 休息") }
            return parts.joined(separator: " · ")
        }
        // 分组顺序跟左边机器列表一致：先按机器在 machines 里的位次，再按标题。
        // 按项目那档一组里混着几台机器，用组里最靠前的那台定位次。
        let machineRank: (String) -> Int = { [self] mid in
            machines.firstIndex { $0.id == mid } ?? machines.count
        }
        func build(_ keyed: [(String, Session)]) -> [TeamGroup] {
            var order: [String] = []; var map: [String: [Session]] = [:]
            for (k, s) in keyed { if map[k] == nil { order.append(k) }; map[k, default: []].append(s) }
            return order.map { k in
                // 在岗的排前面，休息的沉底；同一档按名字
                let ss = (map[k] ?? []).sorted {
                    let ra = $0.status == .rest, rb = $1.status == .rest
                    return ra != rb ? !ra : $0.name < $1.name
                }
                return TeamGroup(id: k, title: k, sub: summary(ss), sessions: ss)
            }.sorted { a, b in
                let ra = a.sessions.map { machineRank($0.machineID) }.min() ?? Int.max
                let rb = b.sessions.map { machineRank($0.machineID) }.min() ?? Int.max
                return ra != rb ? ra < rb : a.title < b.title
            }
        }
        // 机器名（按员工/按机器都要拿）
        let nameOf: (String) -> String = { [self] mid in machineName(mid) }
        switch inspector {
        case .employee:
            // 同名员工在不同机器上是两个人，所以 key 带机器，标题前缀机器名
            // （「tom · talkai」）。点行仍会切到对应机器的会话。
            return build(all.map { ("\(nameOf($0.machineID)) · \($0.owner)", $0) })
        case .project:
            // 项目按名字合并：不同机器上的同一个项目放一组（行里带机器名区分）
            return build(all.map { ($0.project, $0) })
        case .machine:
            var order: [String] = []; var map: [String: [Session]] = [:]
            for s in all { if map[s.machineID] == nil { order.append(s.machineID) }; map[s.machineID, default: []].append(s) }
            order.sort { machineRank($0) < machineRank($1) }   // 跟左边机器列表同序
            return order.map { mid in
                let ss = (map[mid] ?? []).sorted {
                    let ra = $0.status == .rest, rb = $1.status == .rest
                    return ra != rb ? !ra : $0.name < $1.name
                }
                return TeamGroup(id: mid, title: nameOf(mid), sub: summary(ss), sessions: ss)
            }
        }
    }

    // MARK: Actions

    /// 每台机器上次选的 tab（machineID → sessionID）：切回该机器时恢复，不再总跳第一个。
    /// 落 UserDefaults，重启也记得。didSet 里同步写盘。
    private static let lastSessionKey = "BlinkMac.lastSessionByMachine"
    private var lastSessionByMachine: [String: String] =
        (UserDefaults.standard.dictionary(forKey: AppState.lastSessionKey) as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(lastSessionByMachine, forKey: AppState.lastSessionKey) }
    }

    func selectMachine(_ id: String) {
        activeMachineID = id
        // 先用当前已有会话恢复（切换要即时），再等这台机器重枚举完确认一次——
        // loadSessions 会把这台的会话整段 removeAll+重加，不二次恢复就会被冲回第一个。
        restoreActiveSession(for: id)
        Task { @MainActor in
            await self.loadSessions(for: self.activeMachine)
            self.restoreActiveSession(for: id)
        }
    }

    /// 恢复某机器上次选中的会话：记得且还在（含休息中，只要没关）→ 用它；
    /// 否则当前选中若已是这台机器的有效会话就保持；再否则落到该机器第一个可选会话；都没有→置空。
    /// 置空是为了避免终端拿旧机器的 transport 连错。
    private func restoreActiveSession(for machineID: String) {
        let mine = sessions.filter { $0.machineID == machineID && $0.tmuxName != nil && !isClosed($0) }
        if let last = lastSessionByMachine[machineID], mine.contains(where: { $0.id == last }) {
            activeSessionID = last
        } else if !mine.contains(where: { $0.id == activeSessionID }) {
            activeSessionID = mine.first(where: { !resting($0) })?.id ?? mine.first?.id ?? ""
        }
    }

    func selectSession(_ id: String) {
        activeSessionID = id
        // 选了哪台机器的会话，activeMachine 就跟到那台（终端连接用 activeMachine.transport）。
        if let s = sessions.first(where: { $0.id == id }) {
            activeMachineID = s.machineID
            lastSessionByMachine[s.machineID] = id   // 记住这台机器最后点的 tab（并落盘）
        }
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
    // MARK: 每个员工进哪个 CLI（团队列表行尾齿轮）

    /// 读这个会话配的 CLI。agentTick 参与 body 计算，改完列表才会重画。
    func agent(for s: Session) -> AgentKind {
        _ = agentTick
        return TabAgentStore.agent(machineId: s.machineID, title: s.name)
    }

    /// 只改配置，不动已经跑着的 tmux 会话——里面 claude 的上下文还在，
    /// 要换得先把 cc-<TITLE> 关掉重开，所以这里只提示一句。
    /// 换 CLI：存配置 → 把远端那个 tmux 会话杀掉 → 重连。
    ///
    /// 不杀会话的话 `tmux new-session -A` 只会 attach 回原来那个，里面跑的还是旧 CLI，
    /// 环境变量也是旧的。杀掉后重连会重跑一遍启动脚本，新 CLI 立刻起来。
    /// claude / DeepSeek 那两档杀了不心疼：启动脚本会按 customTitle 把上一轮的
    /// 会话 resume 回来，上下文还在；codex 没有这套，等于开个新的。
    func setAgent(_ kind: AgentKind, for s: Session) {
        guard agent(for: s) != kind else { return }
        TabAgentStore.setAgent(kind, machineId: s.machineID, title: s.name)
        agentTick &+= 1
        let m = machines.first { $0.id == s.machineID } ?? activeMachine
        // 这里不能拿 transport.connectable 当门槛：SSH 机器照样能跑命令（AppState.exec
        // 走系统 /usr/bin/ssh），之前挡在外面的结果是只改了配置、会话没重开，
        // 看着就像「切了没反应」。真正的前提只有一条：得知道 tmux 会话名。
        showToast("\(s.name) 切到 \(kind.label)，正在重开…")
        let tr = m.transport
        let name = s.tmuxName
        Task { @MainActor in
            if let name {
                _ = await AppState.exec(tr, "\(BlinkdScript.bootPath); tmux kill-session -t \(name) 2>/dev/null; echo done",
                                        timeout: 12, marker: nil)
            }
            // 必须 rebuild 不能 restart：后端里存的是建它时拼好的启动脚本，
            // restart 会拿旧脚本（旧 CLI）重跑，看着就像"切了没反应"。
            self.term.rebuild(s.id)
            self.agentTick &+= 1   // 触发 TerminalContainer 重新取 view → 用新配置建后端
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.showToast("\(s.name) 已用 \(kind.label) 重开")
        }
    }

    func toggleRest(sessionID: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        let name = s.tmuxName ?? s.id
        let key = restKey(s)
        let now = !isResting(s)
        // 有映射 → 写三端共用的同步文件（+KV），手机、平板跟着变；写不成（无对应 tab）回退本地。
        if cloudAvailable, CloudRestStore.setResting(key: key, on: now, mapping: cloudMapping) {
            if now { cloudResting.insert(key) } else { cloudResting.remove(key) }
        } else {
            _ = MacRestStore.toggle(name)
        }
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[i].status = now ? .rest : .idle
        }
    }

    /// 关闭一个标签：写 KV 墓碑同步到 iOS（有对应 tab UUID 时），本地也移除。
    /// 说明：blinkd 机器的会话是「实时枚举」出来的，关了下次刷新还会再枚举回来
    /// （tmux 还活着，关标签不 kill 远端进程，跟 iOS 一致）；SSH/离线机器的标签来自 KV，
    /// 写了墓碑后 iOS 和 Mac 都不再显示。
    func closeTab(sessionID: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        let full = (s.tmuxName ?? ("cc-" + s.name)).lowercased()
        let uuids = cloudMapping.ccToUUIDs[CloudRestStore.key(machineId: s.machineID, cc: full)] ?? []
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
