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
    /// 「离线使用」只在本次运行有效；下次启动仍提示登录。
    @Published var allowOfflineSession = false
    /// 员工 CLI 配置改动计数：TabAgentStore 现读磁盘，靠它触发列表重画
    @Published var agentTick = 0

    // 跨设备休息（正式版）：cloudAvailable=有共享 KV；cloudResting=休息中的 cc-title；
    // cloudMapping=cc-title↔tab UUID。dev 版 cloudAvailable=false → 回退本地 MacRestStore。
    @Published var cloudResting: Set<String> = []
    @Published var cloudAvailable = false
    var cloudMapping = CloudRestStore.Mapping()
    @Published var sharedActive: Set<String>? = nil

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
    private var directoryCheckSerial = 0
    private let localBlinkdConfig: (host: String, port: UInt16, token: String)?
    /// 本机那台机器（只有配了 ~/.config/blinkmac/config.json 才有）；没配就是 nil。
    private let initialMachine: Machine?

    init() {
        // blinkd 配置：环境变量优先，其次 ~/.config/blinkmac/config.json（双击 .app 用这个）。
        // 有配置 → 本机先当成单机跑，随后并入服务器清单；没有 → 空态起步，机器与
        // 公用标签全部等登录后的服务器快照填（#74：以前这里塞写死的示例机器/示例
        // 会话，新装的 Mac 登录了也只看得到假数据，真实清单反被丢掉）。
        let localConfig = AppState.blinkdConfig()
        localBlinkdConfig = localConfig
        if let cfg = localConfig {
            let local = Machine(id: "mbp", name: "MacBook Pro", host: "blinkd \(cfg.host):\(cfg.port)", initials: "M",
                                grad: Grad.blue, transport: .blinkd(host: cfg.host, port: cfg.port, token: cfg.token))
            initialMachine = local
            machines = [local]
            sessions = [Session(id: "loading", machineID: "mbp", name: "连接中…", dir: "", initials: "··",
                                grad: Grad.slate, status: .idle, lines: [], placeholder: true)]
            activeMachineID = "mbp"
            activeSessionID = "loading"
        } else {
            initialMachine = nil
            machines = []
            sessions = []
            activeMachineID = ""
            activeSessionID = ""
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
        ServerSync.shared.startForegroundPolling()
        BlinkdDiscovery.shared.start()   // 常驻 Bonjour 发现同网 blinkd，供 LAN 优先直连用
        if ServerSync.shared.hasSession {
          // 服务器快照 → sync 文件；落地后 watchSyncFile() 自动触发标签/机器 reload，
          // 不阻塞启动（首屏先用文件/KV 缓存）。
          Task { await ServerSync.shared.refresh() }
        }
        // 头像在独立后台任务里读（容器读可能被 TCC 卡住），不阻塞枚举/探测
        Task.detached(priority: .utility) { [weak self] in
            let a = BlinkAvatars.load()
            await MainActor.run { self?.avatars = a }
        }
        // #74：以前这里是 `guard case .blinkd = activeMachine.transport else { return }`
        // —— 没配本机 blinkd 时 activeMachine 是本地占位，直接 return，服务器清单永远
        // 建不出来（登录了也空列表）。现在统一跑：先建机器清单，再枚举、并标签。
        loadCloudMachines()          // 用服务器清单（sync 文件 / iCloud KV）扩展成多机
        await loadCloudRest()
        loadFavorites()
        startObservingCloud()
        loadClosed()                 // 已关闭标签（本地 + KV 墓碑），显示时过滤
        sessions.removeAll { $0.placeholder }   // 清掉 init 的「连接中…」占位
        await enumerateAll()         // 逐台并行枚举 + 探测真实会话（只 blinkd 机器）
        loadCloudTabs()              // 服务端公用标签是团队和坞的唯一数据源
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

    /// 「有 tmux 会话但同步文件里没标签」的会话 id（<machineID>/cc-…）。
    /// 手机、平板只显示同步文件里的标签，Mac 也照这个来，三端看到的一样（tmux 不动，只是不显示）。
    @Published var orphanHidden: Set<String> = []

    /// 每台机器各算各的：某台读不到标签时只放过那台，别把它的会话全藏了。
    /// （以前只算本机，于是 Jun、小白这些远程机器上自己起的会话 macOS 看得见、iPhone 看不见。）
    func computeOrphanHidden() {
        guard SyncConfig.available else { orphanHidden = []; return }
        var byMachine: [String: Set<String>] = [:]
        for t in CloudTabStore.tabs() {
            byMachine[t.machineId, default: []].insert("cc-" + t.ccName.lowercased())
        }
        orphanHidden = Set(sessions.filter { s in
            guard let name = s.tmuxName?.lowercased(),
                  let mine = byMachine[s.machineID], !mine.isEmpty else { return false }
            return !mine.contains(name)
        }.map(\.id))
    }

    /// 把没标签的 tmux 会话补成同步文件里的标签（三端一致），规则见 OrphanTabAdopter。
    ///
    /// 本机和远程机器都做。远程机器的工作目录**要在那台机器上** `test -d` 查
    /// —— 拿本机文件系统当准是错的，Jun 的 `/Users/mac/Codes/quan` 在这台 Mac 上根本不存在。
    /// 枚举和探目录是只读的，几台并行；写同步文件只做一次（读-改-写，并发会互相盖掉）。
    func adoptOrphanSessions() async {
        guard SyncConfig.available else { return }
        let targets = machines.map { (id: $0.id, isLocal: $0.isLocalMac, tr: $0.transport, fallback: $0.sshFallback) }
        var scans: [OrphanTabAdopter.Scan] = []
        await withTaskGroup(of: OrphanTabAdopter.Scan?.self) { group in
            for t in targets {
                group.addTask {
                    let out = await AppState.exec(t.tr, BlinkdScript.listSessionsCreated(), timeout: 8, marker: nil, fallback: t.fallback)
                    let live = OrphanTabAdopter.parseLive(out)
                    guard !live.isEmpty else { return nil }
                    // 没有待补的就别去探目录了：这条路每次回前台都会走，远程是一次 ssh 往返。
                    // 但仍要回一条 Scan —— adopt 得据此落下扫描基线，否则这台机器永远停在
                    // 「首次扫描」，以后在手机上关掉的标签会被当成孤儿又补回来。
                    let pend = OrphanTabAdopter.pending(machineId: t.id, isLocal: t.isLocal, live: live)
                    let dirs = pend.isEmpty ? Set<String>()
                        : await AppState.existingDirs(t.tr, OrphanTabAdopter.dirsToProbe(for: pend), fallback: t.fallback)
                    return OrphanTabAdopter.Scan(machineId: t.id, isLocal: t.isLocal,
                                                 live: live, existingDirs: dirs)
                }
            }
            for await s in group { if let s { scans.append(s) } }
        }
        guard !scans.isEmpty else { return }
        let snapshot = scans
        let r = await Task.detached(priority: .utility) { OrphanTabAdopter.adopt(snapshot) }.value
        let names = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.name) })
        NSLog("[adopt] 扫了 %@ 补成标签=%@ 跳过(无三端一致的工作目录)=%@",
              snapshot.map { "\(names[$0.machineId] ?? $0.machineId):\($0.live.count)" }.joined(separator: " "),
              r.adopted.joined(separator: ","), r.skipped.joined(separator: ","))
        guard !r.adopted.isEmpty else { return }
        await loadCloudRest()
        loadCloudTabs()
        loadClosed()
        showToast("已把 \(r.adopted.joined(separator: "、")) 补成标签，手机和平板也能看到")
    }

    /// 在目标机器上筛出真实存在的目录（一条命令查完，省往返）。
    /// 带单引号或换行的路径没法安全塞进命令，直接跳过——这种路径本来也过不了三端同名那关。
    nonisolated static func existingDirs(_ transport: Transport, _ paths: [String],
                                         fallback: (user: String, host: String)? = nil) async -> Set<String> {
        let safe = paths.filter { !$0.contains("'") && !$0.contains("\n") }
        guard !safe.isEmpty else { return [] }
        let list = safe.map { "'\($0)'" }.joined(separator: " ")
        let out = await exec(transport, "for p in \(list); do [ -d \"$p\" ] && echo \"$p\"; done",
                             timeout: 8, marker: nil, fallback: fallback)
        let found = out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(found)
    }

    /// 服务端公用标签是团队面板和坞的唯一名单；tmux 枚举只补工作目录。
    func loadCloudTabs() {
        let hadNoSessions = sessions.isEmpty
        let tabs = CloudTabStore.sharedTabs()
        sharedActive = CloudTabStore.sharedActiveSessions()
        let grads = [Grad.blue, Grad.amber, Grad.green, Grad.purple]
        let live = Dictionary(sessions.compactMap { s -> (String, Session)? in
            guard s.tmuxName != nil else { return nil }
            return (s.id.lowercased(), s)
        }, uniquingKeysWith: { first, _ in first })
        var built: [Session] = []
        for t in tabs where machines.contains(where: { $0.id == t.machineId }) {
            let full = "cc-" + t.ccName
            let id = "\(t.machineId)/\(full)"
            let old = live[id.lowercased()]
            let initials = String(t.ccName.replacingOccurrences(of: "-", with: "").prefix(2))
            if t.dir != "~", old?.dir != t.dir { term.rebuild(id) }
            built.append(Session(id: id, machineID: t.machineId, name: t.ccName,
                                 dir: t.dir != "~" ? t.dir : (old?.dir ?? "~"), initials: initials,
                                 grad: grads[built.count % grads.count],
                                 status: .idle, lines: [], tmuxName: full))
        }
        let kept = Set(built.map(\.id))
        for s in sessions where s.tmuxName != nil && !kept.contains(s.id) { term.rebuild(s.id) }
        sessions = built
        recomputeRestStatuses()
        if !kept.contains(activeSessionID) || resting(activeSession) {
            activeSessionID = built.first(where: { $0.machineID == activeMachineID && !resting($0) })?.id ?? ""
        }
        if hadNoSessions && activeSessionID.isEmpty,
           let first = built.first(where: { !resting($0) }) {
            activeMachineID = first.machineID
            activeSessionID = first.id
        }
    }

    /// 用 iCloud KV 的机器清单扩展本地机器列表（正式版签名才读得到 KV）。
    /// 本地 config.json 那台 = 这台 Mac，走 127.0.0.1 直连更快；KV 里 token 相同的那条即同一台，
    /// 套用手机上给它起的显示名，不重复列。KV 空（dev / 未同步）→ 保持本地单机不动。
    func loadCloudMachines() {
        let cloud = MacMachineStore.machines()
        // #74：以前这里 `guard let localConfig = localBlinkdConfig`，只要本机没配
        // ~/.config/blinkmac/config.json，服务器下发的机器全被丢掉（公用标签也跟着
        // 因为「machines 里没有对应机器」被过滤光）。本机配置现在只用于「认出自己」。
        guard !cloud.isEmpty else { return }
        let lp = localBlinkdConfig?.port
        let lt = localBlinkdConfig?.token
        let grads = [Grad.blue, Grad.amber, Grad.green, Grad.purple, Grad.slate]
        var out: [Machine] = []
        var thisMacId: String? = nil
        for (i, cm) in cloud.enumerated() {
            let name = cm.name.isEmpty ? "机器\(i + 1)" : cm.name
            let transport: Transport
            let hostLabel: String
            let isLocalMac: Bool
            if cm.transport != "ssh", let b = cm.blinkd {
                // 本机识别只看 token：配了本机 blinkd 的 Mac 才认得出清单里哪条是自己。
                // 没配的机器（新装 DMG 都算）没有本机概念，一律按普通远程机器连。
                let isThisMac = (lt != nil && b.token == lt)
                if isThisMac, let lp, let lt {
                    // 本机：回环优先（daemon 在同一台机器上时最快），但 daemon 常常只
                    // 监听 Tailscale 地址、回环没开 —— 所以要能回落到清单里的对外地址，
                    // 否则「识别成本机」反而连不上（#74）。
                    let loopback = "127.0.0.1"
                    transport = .blinkd(host: loopback, port: lp, token: lt,
                                        alt: (host: b.host, port: b.port))
                    hostLabel = "本机 · \(loopback):\(lp)"
                } else {
                    transport = .blinkd(host: b.host, port: b.port, token: b.token)
                    hostLabel = "blinkd \(b.host):\(b.port)"
                }
                isLocalMac = isThisMac
                if isThisMac { thisMacId = cm.id }
            } else if cm.transport == "blinkd" {
                // #25：声明走 blinkd 但三件套没同步过来（旧 KV 数据 / iOS 未升级物化）。
                // 这类机器只开 blinkd 没开 sshd——不静默降级 SSH（降级只会连不上，
                // 还掩盖「配置没同步」真因），标成 unconfigured：rail ⚠、header 写明、不可连。
                transport = .unconfigured
                hostLabel = "⚠ blinkd 未配置（更新手机 App 或补齐 Socket 配置）"
                isLocalMac = false
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
                               // rail 绿点只给 blinkd 在线（isRemote）；SSH 机器无 daemon 探测、
                               // 显示「ssh」小标，unconfigured 显示 ⚠（#25 降级可见性）
                               online: transport.isRemote,
                               transport: transport,
                               sshFallback: (cm.transport == "blinkd" && !isLocalMac && !cm.host.isEmpty)
                                 ? (user: cm.user, host: cm.host) : nil,
                               isLocalMac: isLocalMac))
        }
        guard !out.isEmpty else { return }
        // 清单里没有本机（这台 Mac 没配 daemon）→ 只有确实配了本机配置才把本机条目
        // 补在最前；否则服务器给什么就显示什么（#74）。
        if thisMacId == nil, let im = initialMachine {
            out.insert(im, at: 0)
            thisMacId = im.id
        }
        machines = out
        activeMachineID = thisMacId ?? out[0].id
    }

    /// 逐台并行枚举所有 blinkd 机器的会话，再逐台并行探测状态。
    /// 只传 Sendable 原语进 task（host/port/token/machineID），结果回到主 actor 合并。
    func enumerateAll() async {
        await withTaskGroup(of: [Session].self) { group in
            for m in machines {
                let mid = m.id, tr = m.transport, fallback = m.sshFallback
                group.addTask {
                    let out = await AppState.exec(tr, BlinkdScript.listSessions(), timeout: 8, marker: nil, fallback: fallback)
                    return AppState.parseSessions(out, machineID: mid)
                }
            }
            for await real in group {
                guard let mid = real.first?.machineID else { continue }
                sessions.removeAll { $0.machineID == mid }
                sessions.append(contentsOf: real)
            }
        }
        loadCloudTabs()
    }

    /// 统一执行：blinkd 走 socket，ssh 走系统 /usr/bin/ssh，local 走本机 shell。
    nonisolated static func exec(_ transport: Transport, _ command: String,
                                 timeout: TimeInterval, marker: String?,
                                 fallback: (user: String, host: String)? = nil) async -> String {
        switch transport {
        case .blinkd(let h, let p, let t, let alt):
            var out = await BlinkdExec.run(host: h, port: p, token: t, command: command,
                                           timeout: timeout, finishMarker: marker)
            // 本机 blinkd 回环没开时用备用地址再试一次（#74）。
            if out.isEmpty, let alt {
                out = await BlinkdExec.run(host: alt.host, port: alt.port, token: t, command: command,
                                           timeout: timeout, finishMarker: marker)
            }
            if out.isEmpty, let fallback {
                return await SSHExec.run(user: fallback.user, host: fallback.host,
                                         command: command, timeout: timeout)
            }
            return out
        case .ssh(let u, let h):
            return await SSHExec.run(user: u, host: h, command: command, timeout: timeout)
        case .unconfigured:
            return "⚠ 未配置 blinkd：请在手机上补齐 Socket 配置并同步"
        case .local:
            return await LocalExec.run(command: command, timeout: timeout)
        }
    }

    /// 枚举单台机器的会话并合并（只替换这台的，别动别的机器）。选机器/需要刷新单台时用。
    func loadSessions(for machine: Machine) async {
        guard machine.transport.connectable else { return }
        let out = await AppState.exec(machine.transport, BlinkdScript.listSessions(), timeout: 8,
                                      marker: nil, fallback: machine.sshFallback)
        let real = AppState.parseSessions(out, machineID: machine.id)
        guard !real.isEmpty else {
            // 枚举不到（离线 / 无免密）→ 保留原有（可能是 KV 标签），别清空
            loadCloudTabs()
            return
        }
        sessions.removeAll { $0.machineID == machine.id }
        sessions.append(contentsOf: real)
        loadCloudTabs()
    }

    private var observingCloud = false

    /// #25 顺带：KV 远端变更 / 回前台时重读机器清单。以前只在启动读一次，手机上改完
    /// 机器配置 Mac 端必须退出重开才生效。指纹（id/name/host/transport）没变就不动；
    /// 变了才重建；连接参数变化的机器需丢掉旧 backend（它持有旧 token / 旧错误页），
    /// 其他机器正在用的会话保持不动。当前选中的机器若还在清单里就保持选中。
    func reloadMachinesIfChanged() {
        let before = machines.map { "\($0.id)|\($0.name)|\($0.host)|\($0.transport.fingerprint)" }
        let previousTransports = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.transport.fingerprint) })
        let keepActive = activeMachineID
        loadCloudMachines()
        let after = machines.map { "\($0.id)|\($0.name)|\($0.host)|\($0.transport.fingerprint)" }
        guard before != after else {
            // 清单没变：loadCloudMachines 末尾会把 activeMachineID 重置回本机——恢复用户选择
            if machines.contains(where: { $0.id == keepActive }) { activeMachineID = keepActive }
            return
        }
        if machines.contains(where: { $0.id == keepActive }) { activeMachineID = keepActive }
        let changedIDs = Set(machines.compactMap { machine in
            previousTransports[machine.id].map { $0 != machine.transport.fingerprint } == true ? machine.id : nil
        })
        for session in sessions where changedIDs.contains(session.machineID) {
            term.rebuild(session.id)
        }
        Task { await enumerateAll(); loadCloudTabs() }   // 新机器补枚举 + KV 标签并进来
    }

    /// 实时监听休息变化：iCloud KV 外部变更（手机改了推过来）+ 回前台补拉
    /// （didChangeExternally 不可靠，Blink 自己也靠回前台 pull）。
    func startObservingCloud() {
        guard !observingCloud else { return }
        observingCloud = true
        NSUbiquitousKeyValueStore.default.synchronize()
        let reload: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.reloadMachinesIfChanged()   // #25 顺带：机器清单也跟手（以前要重启 Mac 才生效）
                self?.loadFavorites(); await self?.loadCloudRest(); self?.loadClosed()
                self?.loadCloudTabs()
            }
            Task { @MainActor in await ServerSync.shared.refresh() }   // 回前台：服务器有新版就落盘（304 即止）
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
                    self.reloadMachinesIfChanged()
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
        if let sharedActive { return !sharedActive.contains(s.name) }
        return s.owner.lowercased() != "tom"
    }

    // MARK: 真实状态探测（干活中/等你/空闲）


    func probe() {
        showToast("正在刷新…")
        Task { @MainActor in
            await ServerSync.shared.refresh()
            self.reloadMachinesIfChanged()
            await self.enumerateAll()
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
        loadCloudTabs()
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

    var activeMachine: Machine { machines.first { $0.id == activeMachineID } ?? machines.first ?? .placeholder }
    var activeSession: Session {
        sessions.first { $0.id == activeSessionID }
            ?? Session(id: "none", machineID: activeMachineID, name: "选择会话", dir: "",
                       initials: "", grad: Grad.slate, status: .idle, lines: [], placeholder: true)
    }
    func resting(_ s: Session) -> Bool { isResting(s) }

    /// 该会话是否被「关闭」（本地记录 + KV 墓碑，且手机没重新开同名 → 见 loadClosed）。
    func isClosed(_ s: Session) -> Bool {
        false // 公用标签由服务端管理，不进个人关闭墓碑。
    }

    /// 侧栏只显示在岗会话，休息/已关闭的隐藏（同手机 tab 栏）——休息在右侧员工列表管理。
    var sidebarSessions: [Session] {
        sessions.filter { $0.machineID == activeMachineID && $0.tmuxName != nil && !resting($0) && !isClosed($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var restingCount: Int {
        sessions.filter { $0.machineID == activeMachineID && resting($0) && !isClosed($0) }.count
    }

    /// 团队面板里列出来的会话总数（跨机器，含休息的）
    var sessionCount: Int {
        sessions.filter { $0.tmuxName != nil && !isClosed($0) }.count
    }

    func count(_ s: WorkStatus) -> Int {
        sessions.filter { $0.tmuxName != nil && $0.status == s }.count
    }

    /// 机器显示名（查不到就退回 id）
    func machineName(_ machineID: String) -> String {
        machines.first { $0.id == machineID }?.name ?? machineID
    }

    /// 三种视图都使用相同的「机器 × 员工」卡片，只改变外层分段。
    var teamSections: [TeamSection] {
        let all = sessions.filter { $0.tmuxName != nil && !isClosed($0) }
        func cards(_ rows: [Session]) -> [TeamGroup] {
            let keyed = Dictionary(grouping: rows) { "\($0.machineID)|\($0.owner)" }
            return keyed.map { key, values in
                let sorted = values.enumerated().sorted { a, b in
                    if resting(a.element) != resting(b.element) { return !resting(a.element) }
                    return a.offset < b.offset
                }.map(\.element)
                let first = sorted[0]
                let restCount = sorted.filter { resting($0) }.count
                let summary = restCount > 0 && restCount < sorted.count
                    ? "\(sorted.count - restCount) 在岗 · \(restCount) 休息" : "\(sorted.count) 个会话"
                return TeamGroup(id: key, title: "\(machineName(first.machineID)) · \(first.owner)",
                                 sub: summary, sessions: sorted)
            }.sorted { a, b in
                let ra = machines.firstIndex { $0.id == a.sessions[0].machineID } ?? Int.max
                let rb = machines.firstIndex { $0.id == b.sessions[0].machineID } ?? Int.max
                return ra != rb ? ra < rb : a.title < b.title
            }
        }
        switch inspector {
        case .employee:
            return [TeamSection(id: "employees", title: nil, groups: cards(all))]
        case .project:
            let names = Array(Set(all.map(\.project))).sorted { a, b in
                let ra = all.filter { $0.project == a }
                    .compactMap { s in machines.firstIndex { $0.id == s.machineID } }.min() ?? Int.max
                let rb = all.filter { $0.project == b }
                    .compactMap { s in machines.firstIndex { $0.id == s.machineID } }.min() ?? Int.max
                return ra != rb ? ra < rb : a < b
            }
            return names.map { name in
                TeamSection(id: "project-\(name)", title: name,
                            groups: cards(all.filter { $0.project == name }))
            }
        case .machine:
            return machines.compactMap { machine in
                let rows = all.filter { $0.machineID == machine.id }
                return rows.isEmpty ? nil : TeamSection(id: "machine-\(machine.id)",
                    title: machine.name, groups: cards(rows))
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
        let mine = sessions.filter { $0.machineID == machineID && $0.tmuxName != nil && !resting($0) }
        if let last = lastSessionByMachine[machineID], mine.contains(where: { $0.id == last }) {
            activeSessionID = last
        } else if !mine.contains(where: { $0.id == activeSessionID }) {
            activeSessionID = mine.first?.id ?? ""
        }
    }

    func selectSession(_ id: String) {
        directoryCheckSerial &+= 1
        let checkSerial = directoryCheckSerial
        activeSessionID = id
        // 选了哪台机器的会话，activeMachine 就跟到那台（终端连接用 activeMachine.transport）。
        if let s = sessions.first(where: { $0.id == id }) {
            activeMachineID = s.machineID
            lastSessionByMachine[s.machineID] = id   // 记住这台机器最后点的 tab（并落盘）
            // 已缓存的终端不会再次执行 tmux 启动脚本。每次点击都查询服务器上
            // 这个 pane 的真实目录，只有配置目录与实际目录不同时才重新连接。
            if s.dir.hasPrefix("/"), let m = machines.first(where: { $0.id == s.machineID }) {
                Task { @MainActor in
                    let status = await AppState.exec(
                        m.transport, BlinkdScript.directoryStatus(
                            session: s.tmuxName ?? "cc-\(s.name)", workDir: s.dir,
                            agent: self.agent(for: s)),
                        timeout: 8, marker: nil, fallback: m.sshFallback)
                    guard self.activeSessionID == id,
                          self.directoryCheckSerial == checkSerial else { return }
                    if status.contains("BLINK_DIR_MISMATCH") {
                        let reset = await AppState.exec(
                            m.transport, BlinkdScript.resetPane(s.tmuxName ?? "cc-\(s.name)"),
                            timeout: 12, marker: nil, fallback: m.sshFallback)
                        guard self.activeSessionID == id,
                              self.directoryCheckSerial == checkSerial else { return }
                        if reset.contains("BLINK_RESET_FAILED") {
                            self.showToast("\(s.name) 重进工作目录失败")
                            return
                        }
                        self.term.restart(id)
                    } else if status.contains("BLINK_DIR_MISSING") {
                        self.showToast("\(s.name) 的工作目录不存在：\(s.dir)")
                    }
                }
            }
        }
        mode = .terminal
    }

    /// 团队卡片直达标签；休息中的标签先在服务器唤醒，再切换终端。
    func openTeamSession(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id && $0.tmuxName != nil && !isClosed($0) }) else { return }
        guard isResting(session) else { selectSession(id); return }
        showToast("正在唤醒 \(session.name)…")
        Task { @MainActor in
            guard await ServerSync.shared.setResting(false, session: session.name) else {
                self.showToast("\(session.name) 未能唤醒，请稍后重试")
                return
            }
            self.loadCloudTabs()
            self.selectSession(id)
        }
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

    /// 与 iOS 一样，保存配置后重启当前 tmux pane，保留会话和工作目录。
    /// 重连时启动脚本会按标签名恢复对应 CLI 的对话。
    func setAgent(_ kind: AgentKind, for s: Session) {
        guard !s.placeholder else { return }
        guard agent(for: s) != kind else { return }
        let m = machines.first { $0.id == s.machineID } ?? activeMachine
        showToast("正在保存 \(s.name) 的模型…")
        let tr = m.transport
        let fallback = m.sshFallback
        let name = s.tmuxName ?? "cc-\(s.name)"
        Task { @MainActor in
            if ServerSync.shared.hasSession {
                guard await ServerSync.shared.setAgent(kind, machineId: s.machineID, title: s.name) else {
                    self.showToast("模型未保存到服务器，请稍后重试")
                    return
                }
            }
            TabAgentStore.setAgent(kind, machineId: s.machineID, title: s.name)
            self.agentTick &+= 1
            let result = await AppState.exec(tr, BlinkdScript.resetPane(name), timeout: 12,
                                             marker: nil, fallback: fallback)
            // 后端缓存了旧 CLI 启动脚本，必须重建才能让新配置生效。
            self.term.rebuild(s.id)
            self.agentTick &+= 1
            if result.contains("BLINK_RESET_FAILED") {
                self.showToast("\(s.name) 切换已保存，pane 重启失败；请刷新重连")
            } else if result.contains("BLINK_RESET_OK") || result.contains("BLINK_RESET_NO_SESSION") {
                self.showToast("\(s.name) 已切到 \(kind.label)")
            } else {
                self.showToast("\(s.name) 切换已保存，正在重连")
            }
        }
    }

    func toggleRest(sessionID: String) {
        guard let s = sessions.first(where: { $0.id == sessionID }) else { return }
        let now = !isResting(s)
        showToast("正在更新 \(s.name)…")
        Task { @MainActor in
            if await ServerSync.shared.setResting(now, session: s.name) {
                self.loadCloudTabs()
                self.showToast(now ? "\(s.name) 已休息" : "\(s.name) 已在岗")
            } else {
                self.showToast("休息状态未保存到服务器，请稍后重试")
            }
        }
    }

    /// 关闭一个标签：写 KV 墓碑同步到 iOS（有对应 tab UUID 时），本地也移除。
    /// 说明：blinkd 机器的会话是「实时枚举」出来的，关了下次刷新还会再枚举回来
    /// （tmux 还活着，关标签不 kill 远端进程，跟 iOS 一致）；SSH/离线机器的标签来自 KV，
    /// 写了墓碑后 iOS 和 Mac 都不再显示。
    func closeTab(sessionID: String) {
        showToast("公用标签由团队页的休息开关管理")
    }

    func toggleRestActive() {
        let s = activeSession
        guard !s.placeholder else { return }
        toggleRest(sessionID: s.id)
    }

    func reconnect() {
        if activeMachine.transport.isUnconfigured {
            showToast("⚠ 未配置 blinkd，无法重连；请先同步 Socket 配置")
            return
        }
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
        let fallback = activeMachine.sshFallback
        Task { @MainActor in
            let out = await AppState.exec(
                transport,
                AppState.historyDeltaScript(title: title, workDir: s.dir,
                                            cachedFile: cached?.file, cachedLines: cached?.lines ?? 0),
                timeout: 25, marker: "@TSB64E@", fallback: fallback)
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
            return ChatBlock(role: p.r == "you" ? "YOU" : (p.r == "codex" ? "CODEX" : (p.r == "codewhale" ? "CODEWHALE" : "ASSISTANT")),
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

    /// 远端增量拉 transcript：优先用 tmux pane 的 Claude PID 精确定位 jsonl，
    /// 只 sed 出游标(cachedLines+1)之后的新行喂 jq，解析成「▶ You / ◆ Claude」块
    /// （同 iOS BlinkMachineStore.transcriptDeltaScript）。输出
    /// @TSB64@<b64(META\t<file>\t<total>\t<full>\n<正文>)>@TSB64E@。
    nonisolated static func historyDeltaScript(title: String, workDir: String,
                                               cachedFile: String?, cachedLines: Int) -> String {
        let safeFile = (cachedFile ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let cachedN = max(cachedLines, 0)
        let safeTitle = title.replacingOccurrences(of: "'", with: "")
        let dirEncoded = workDir.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "'", with: "")
        let basename = (workDir as NSString).lastPathComponent.lowercased()
        let altTitle = safeTitle.hasPrefix("\(basename)-")
            ? String(safeTitle.dropFirst(basename.count + 1)) : safeTitle
        return #"""
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/bin
        TITLE='\#(safeTitle)'
        ALT='\#(altTitle)'
        TMUX_NAME='cc-\#(safeTitle)'
        PROJ="$HOME/.claude/projects"
        DIR="$PROJ/\#(dirEncoded)"
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
        # 先看这个 tab 的 pane 里跑的是哪个引擎：claude（默认）/ codewhale / codex。
        # 按进程树里可执行文件名判定（pane_pid 本身可能只是 shell，要继续往下找）。
        # 配置里的 deepseek/glm 档跑的也是 codewhale 这份 CLI，所以只认进程名。
        ACTIVE_ENGINE=claude
        ACTIVE_EPID=""
        active_engine_probe() {
          command -v tmux >/dev/null 2>&1 || return
          local pane pid child comm
          pane=$(tmux display-message -p -t "$TMUX_NAME" '#{pane_pid}' 2>/dev/null) || return
          case "$pane" in ''|*[!0-9]*) return;; esac
          local pending="$pane"
          while [ -n "$pending" ]; do
            pid=${pending%% *}
            if [ "$pending" = "$pid" ]; then pending=""; else pending=${pending#* }; fi
            comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's:.*/::')
            case "$comm" in
              codewhale) ACTIVE_ENGINE=codewhale; ACTIVE_EPID=$pid; return;;
              codex)     ACTIVE_ENGINE=codex;     ACTIVE_EPID=$pid; return;;
            esac
            for child in $(pgrep -P "$pid" 2>/dev/null); do
              case "$child" in ''|*[!0-9]*) continue;; esac
              pending="${pending:+$pending }$child"
            done
          done
        }
        # CodeWhale：进程持有自己会话的 offline_queue.lock，用 lsof 反查会话 id（argv 多数不带 resume）。
        # 正文优先读 checkpoints/<id>.json（跑着的 turn 只有它在更新），退回 sessions/<id>.json。
        active_codewhale_file() {
          [ -n "$ACTIVE_EPID" ] || return
          local sid="" f
          if command -v lsof >/dev/null 2>&1; then
            sid=$(lsof -p "$ACTIVE_EPID" 2>/dev/null | sed -n 's:.*/\([0-9a-f-]\{36\}\)\.offline_queue\.lock$:\1:p' | head -1)
          fi
          [ -n "$sid" ] || sid=$(ps -o command= -p "$ACTIVE_EPID" 2>/dev/null | sed -n 's:.* resume \([0-9a-f-]\{36\}\).*:\1:p' | head -1)
          [ -n "$sid" ] || return
          for f in "$HOME/.codewhale/sessions/checkpoints/$sid.json" "$HOME/.codewhale/sessions/$sid.json"; do
            [ -f "$f" ] && { printf '%s\n' "$f"; return; }
          done
        }
        # Codex：进程打开着的 rollout jsonl（FD 精确关联；进程退出后就没有了，不猜）。
        active_codex_file() {
          [ -n "$ACTIVE_EPID" ] || return
          command -v lsof >/dev/null 2>&1 || return
          lsof -nP -p "$ACTIVE_EPID" 2>/dev/null | awk '$NF ~ /\.codex\/sessions\/.*rollout-.*\.jsonl$/ {print $NF}' | head -1
        }
        active_engine_probe
        if [ "$ACTIVE_ENGINE" = "codewhale" ]; then
          CW=$(active_codewhale_file)
          if [ -z "$CW" ]; then
            emit "$(printf 'META\tNOTFOUND\t0\t1\n没定位到这个 CodeWhale 会话：pane 里没有 codewhale 进程，或它没持有会话锁。在这个 tab 里确认 codewhale 还在跑。')"
            exit 0
          fi
          CN=$(jq -r '.messages | length' "$CW" 2>/dev/null || echo 0)
          CB=$(jq -r '
            [.messages[]?
             | {r:.role, t:([.content[]? | select(.type=="text") | .text] | join("\n"))}
             | select((.t|length)>0)] | .[-100:]
            | .[] | (if .r=="user" then "▶ You" else "◆ CodeWhale" end), .t, ""' "$CW" 2>&1)
          emit "$(printf 'META\t%s\t%s\t1\n' "$(basename "$CW")" "$CN"; printf '%s' "$CB")"
          exit 0
        fi
        if [ "$ACTIVE_ENGINE" = "codex" ]; then
          XF=$(active_codex_file)
          if [ -z "$XF" ]; then
            emit "$(printf 'META\tNOTFOUND\t0\t1\n没定位到这个 Codex 会话：pane 里没有 codex 进程，或它没打开 rollout 文件。在这个 tab 里确认 codex 还在跑。')"
            exit 0
          fi
          XN=$(wc -l < "$XF" | tr -d ' ')
          XB=$(tail -n 400 "$XF" | jq -R -r '
            fromjson?
            | select(.type=="response_item") | .payload
            | select(.type=="message" and (.role=="user" or .role=="assistant"))
            | (if .role=="user" then "▶ You" else "◆ Codex" end),
              ([.content[]? | (.text // empty)] | join("\n")), ""' 2>&1)
          emit "$(printf 'META\t%s\t%s\t1\n' "$(basename "$XF")" "$XN"; printf '%s' "$XB")"
          exit 0
        fi
        active_session_file() {
          command -v tmux >/dev/null 2>&1 || return
          local pane pid child id file
          pane=$(tmux display-message -p -t "$TMUX_NAME" '#{pane_pid}' 2>/dev/null) || return
          case "$pane" in ''|*[!0-9]*) return;; esac
          local pending="$pane"
          while [ -n "$pending" ]; do
            pid=${pending%% *}
            if [ "$pending" = "$pid" ]; then pending=""; else pending=${pending#* }; fi
            if [ -f "$HOME/.claude/sessions/$pid.json" ]; then
              id=$(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$pid.json" 2>/dev/null)
              if printf '%s' "$id" | grep -Eq '^[0-9a-fA-F-]{36}$'; then
                file=$(find "$PROJ" -type f -name "$id.jsonl" -print -quit 2>/dev/null)
                if [ -n "$file" ]; then printf '%s\n' "$file"; return; fi
              fi
            fi
            for child in $(pgrep -P "$pid" 2>/dev/null); do
              case "$child" in ''|*[!0-9]*) continue;; esac
              pending="${pending:+$pending }$child"
            done
          done
        }
        F=$(active_session_file)
        if [ -z "$F" ]; then
          F=$(grep -ilF "\"customTitle\":\"$TITLE\"" "$DIR"/*.jsonl 2>/dev/null | pick_latest_by_mtime)
        fi
        if [ -z "$F" ] && [ "$ALT" != "$TITLE" ]; then
          F=$(grep -ilF "\"customTitle\":\"$ALT\"" "$DIR"/*.jsonl 2>/dev/null | pick_latest_by_mtime)
        fi
        if [ -z "$F" ]; then
          F=$(grep -ilF "\"customTitle\":\"$TITLE\"" "$DIR"*/*.jsonl 2>/dev/null | pick_latest_by_mtime)
        fi
        if [ -z "$F" ] && [ "$ALT" != "$TITLE" ]; then
          F=$(grep -ilF "\"customTitle\":\"$ALT\"" "$DIR"*/*.jsonl 2>/dev/null | pick_latest_by_mtime)
        fi
        if [ -z "$F" ]; then
          F=$(grep -rilF "\"customTitle\":\"$TITLE\"" "$PROJ" --include='*.jsonl' 2>/dev/null | pick_latest_by_mtime)
        fi
        if [ -z "$F" ] && [ "$ALT" != "$TITLE" ]; then
          F=$(grep -rilF "\"customTitle\":\"$ALT\"" "$PROJ" --include='*.jsonl' 2>/dev/null | pick_latest_by_mtime)
        fi
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
              | select(.turnOrigin != "scheduled" and .scheduledTaskId == null)
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
            if line.hasPrefix("◆ ") { flush(); role = String(line.dropFirst(2)).lowercased(); continue }
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
}
