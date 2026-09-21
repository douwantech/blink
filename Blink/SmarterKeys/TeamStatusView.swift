//
// TeamStatusView.swift
// 团队状态页：每个员工（tab）在忙哪个项目 / 等你拍板 / 空闲 / 休息，一屏看全。
// 数据两层：本地 tab 列表 + TabRestStore 秒出骨架；后台 ssh 探测各机器 tmux
// （pane 前台进程 + 最近活动时间 + 屏幕最后一行）回填 等你/干活中/空闲 三档和「正在做什么」。
// 状态胶囊既是显示也是开关：点一下在 休息 ↔ 在岗 之间切（写 TabRestStore）。
// 图标体系（用户定调，禁 emoji）：等你=bell 干活中=bolt 空闲=checkmark.circle 休息=moon.zzz
//

import UIKit

// MARK: - 数据模型

/// SpaceController 传进来的每个终端 tab 的静态描述
struct TeamStatusTab {
  let tabKey: UUID
  let machineId: String
  let machineName: String
  let employee: String       // tab 标题冒号前那截（workDir 名）
  let project: String        // 冒号后那截（session 后缀），没有就同 employee
  let outerSession: String   // cc-<TITLE>，远端探测按这个名字对号
  let avatar: UIImage?
  var resting: Bool
}

enum TeamWorkStatus: Int {
  case wait = 0   // claude 在跑但停着不动 → 大概率在等人
  case work = 1   // claude 在跑且最近有输出
  case idle = 2   // 掉到裸 shell / 会话没起
  case rest = 3   // 手动休息（TabRestStore）

  var label: String {
    switch self {
    case .wait: return "等你"
    case .work: return "干活中"
    case .idle: return "空闲"
    case .rest: return "休息中"
    }
  }
  var symbol: String {
    switch self {
    case .wait: return "bell"
    case .work: return "bolt"
    case .idle: return "checkmark.circle"
    case .rest: return "moon.zzz"
    }
  }
  var color: UIColor {
    switch self {
    case .wait: return UIColor(red: 0.96, green: 0.66, blue: 0.24, alpha: 1)
    case .work: return UIColor(red: 0.25, green: 0.84, blue: 0.55, alpha: 1)
    case .idle: return UIColor(red: 0.46, green: 0.50, blue: 0.56, alpha: 1)
    case .rest: return UIColor(red: 0.56, green: 0.55, blue: 1.00, alpha: 1)
    }
  }
  var sectionTitle: String {
    switch self {
    case .wait: return "等你拍板"
    case .work: return "干活中"
    case .idle: return "空闲"
    case .rest: return "休息中"
    }
  }
  var sectionHint: String {
    switch self {
    case .wait: return "卡在你这里，点进去回"
    case .work: return "不用管，让他们跑"
    case .idle: return "活干完了，可以派新活"
    case .rest: return "拨行尾月亮开关叫回来"
    }
  }
}

// MARK: - 页面

final class TeamStatusViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  var onOpenTab: ((UUID) -> Void)?
  var onToggleRest: ((UUID, Bool) -> Void)?

  fileprivate struct ProjectRow {
    let tabKey: UUID
    let project: String
    var status: TeamWorkStatus   // 只剩 休息 / 空闲 两档
    var resting = false          // 休息按 tab（员工×项目）粒度，来自 TabRestStore
    var agent: AgentKind = .claude   // 这个 tab 开起来进哪个 CLI（行尾齿轮改）
    /// 行的展示状态：休息优先
    var effective: TeamWorkStatus { resting ? .rest : status }
  }
  fileprivate struct Group {
    let employee: String
    let machineId: String
    let machineName: String
    let avatar: UIImage?
    var role: String?
    var rows: [ProjectRow]
    var resting: Bool   // 全部项目都休息才 true（部分休息的人留在在岗段，行内分别显示）
    /// 员工整体状态：只看没休息的项目行，取最紧急一档；全休息 → .rest
    var status: TeamWorkStatus {
      let active = rows.filter { !$0.resting }
      if active.isEmpty { return .rest }
      return active.map(\.status).min(by: { $0.rawValue < $1.rawValue }) ?? .idle
    }
  }

  private var tabs: [TeamStatusTab]
  private var groups: [Group] = []
  private var roleMap: [String: String] = [:]
  /// segmented：按员工（状态分段卡片）/ 按项目（项目分段成员行）/ 按机器（旧在岗休息面板形态，行尾开关）
  private enum ViewMode: Int { case employee = 0, project, machine }
  private var mode: ViewMode = .employee

  private let bg = UIColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1)      // #0b0c0e
  private let panel = UIColor(red: 0.078, green: 0.086, blue: 0.106, alpha: 1)   // #14161b
  private let panel2 = UIColor(red: 0.102, green: 0.114, blue: 0.137, alpha: 1)  // #1a1d23
  private let sub = UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1)     // #8b95a5

  private let tableView = UITableView(frame: .zero, style: .grouped)
  private let statTiles: [StatTile]
  private let segmented = UISegmentedControl(items: ["按员工", "按项目", "按机器"])
  private let subtitleLabel = UILabel()

  init(tabs: [TeamStatusTab]) {
    self.tabs = tabs
    // 等你/干活/空闲 三个格子跟着探测一起去掉了（那三档本来就不准），只留「休息」
    self.statTiles = [StatTile(status: .rest)]
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = bg
    title = "团队"
    setupNav()
    setupTable()
    rebuildGroups()
    probe()
  }

  private func setupNav() {
    let ap = UINavigationBarAppearance()
    ap.configureWithOpaqueBackground()
    ap.backgroundColor = bg
    ap.titleTextAttributes = [.foregroundColor: UIColor.white]
    navigationItem.standardAppearance = ap
    navigationItem.scrollEdgeAppearance = ap
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(closeTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(refreshTapped))
    navigationItem.leftBarButtonItem?.tintColor = .white
    navigationItem.rightBarButtonItem?.tintColor = .white
  }

  private func setupTable() {
    tableView.backgroundColor = bg
    tableView.separatorStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.register(EmployeeCardCell.self, forCellReuseIdentifier: "emp")
    tableView.register(MemberRowCell.self, forCellReuseIdentifier: "mem")
    tableView.register(MachineRowCell.self, forCellReuseIdentifier: "mch")
    let rc = UIRefreshControl()
    rc.tintColor = sub
    rc.addTarget(self, action: #selector(refreshTapped), for: .valueChanged)
    tableView.refreshControl = rc

    // 列表上左右横扫 = 切换 按员工/按项目/按机器（表格只吃竖向滚动，横扫是空闲手势）
    let swipeL = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
    swipeL.direction = .left
    let swipeR = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
    swipeR.direction = .right
    tableView.addGestureRecognizer(swipeL)
    tableView.addGestureRecognizer(swipeR)
    view.addSubview(tableView)

    // 固定表头（挂在 view 上而不是 tableHeaderView）：统计条 + 视图切换 + 更新时间。
    // 切视图的推入动画只加在 tableView.layer 上，表头因此纹丝不动。
    let header = UIView()
    header.backgroundColor = bg
    header.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header)
    let stats = UIStackView(arrangedSubviews: statTiles + [UIView()])
    stats.axis = .horizontal
    stats.distribution = .fillEqually
    stats.spacing = 8
    stats.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(stats)

    segmented.selectedSegmentIndex = 0
    segmented.selectedSegmentTintColor = panel2
    segmented.backgroundColor = panel
    segmented.setTitleTextAttributes([.foregroundColor: sub], for: .normal)
    segmented.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
    segmented.addTarget(self, action: #selector(segChanged), for: .valueChanged)
    segmented.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(segmented)

    subtitleLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
    subtitleLabel.textColor = sub
    subtitleLabel.textAlignment = .center
    subtitleLabel.text = "正在读取角色表…"
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(subtitleLabel)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: 132),

      stats.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
      stats.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      stats.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
      stats.heightAnchor.constraint(equalToConstant: 58),
      segmented.topAnchor.constraint(equalTo: stats.bottomAnchor, constant: 10),
      segmented.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      segmented.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
      subtitleLabel.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
      subtitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      subtitleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),

      tableView.topAnchor.constraint(equalTo: header.bottomAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }

  @objc private func closeTapped() { dismiss(animated: true) }
  @objc private func segChanged() {
    mode = ViewMode(rawValue: segmented.selectedSegmentIndex) ?? .employee
    tableView.reloadData()
  }

  /// 左滑=下一个视图，右滑=上一个；带同方向推入动画，segmented 跟着走
  @objc private func swiped(_ g: UISwipeGestureRecognizer) {
    let step = g.direction == .left ? 1 : -1
    guard let next = ViewMode(rawValue: mode.rawValue + step) else { return }   // 两端到头不循环
    mode = next
    segmented.selectedSegmentIndex = next.rawValue
    let t = CATransition()
    t.type = .push
    t.subtype = g.direction == .left ? .fromRight : .fromLeft
    t.duration = 0.22
    t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    tableView.layer.add(t, forKey: "modeSwipe")
    tableView.reloadData()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
  @objc private func refreshTapped() { probe() }

  // MARK: 分组 & 统计

  private func rebuildGroups() {
    // 按 机器+员工 分组；组内保持 tab 原顺序
    var order: [String] = []
    var map: [String: Group] = [:]
    for t in tabs {
      let k = "\(t.machineId)|\(t.employee)"
      if map[k] == nil {
        order.append(k)
        map[k] = Group(employee: t.employee, machineId: t.machineId, machineName: t.machineName,
                       avatar: t.avatar, role: roleMap[t.employee.lowercased()],
                       rows: [], resting: true)
      }
      let old = statusFor(tabKey: t.tabKey)
      let agent = TabAgentStore.shared.agent(
        machineId: t.machineId, title: TabAgentStore.title(fromOuterSession: t.outerSession))
      map[k]?.rows.append(ProjectRow(tabKey: t.tabKey, project: t.project,
                                     status: old?.status ?? .idle, resting: t.resting,
                                     agent: agent))
      if !t.resting { map[k]?.resting = false }   // 全部 tab 都休息才算员工休息
    }
    // 顺序跟机器列表一致：先按机器在 BlinkMachineStore.machines 里的位次，再按员工名
    let ranks = Self.machineRanks()
    groups = order.compactMap { map[$0] }.sorted { a, b in
      let ra = ranks[a.machineId] ?? Int.max
      let rb = ranks[b.machineId] ?? Int.max
      return ra != rb ? ra < rb : a.employee < b.employee
    }
    updateStats()
    tableView.reloadData()
  }

  /// 读取日志落 Documents/teamstatus.log，真机排查用（afc 可拉）
  private static func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(s)\n"
    guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = dir.appendingPathComponent("teamstatus.log")
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile()
      h.write(Data(line.utf8))
      try? h.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }

  /// machineId → 在机器列表里的位次（团队面板各档的排序都以它为准）
  private static func machineRanks() -> [String: Int] {
    var r: [String: Int] = [:]
    for (i, m) in BlinkMachineStore.shared.machines.enumerated() { r[m.id] = i }
    return r
  }

  private func statusFor(tabKey: UUID) -> ProjectRow? {
    for g in groups { for r in g.rows where r.tabKey == tabKey { return r } }
    return nil
  }

  private func updateStats() {
    var resting = 0
    for g in groups { resting += g.rows.filter(\.resting).count }
    for tile in statTiles { tile.setCount(resting) }
  }

  // MARK: 远端探测

  /// 每台机器一条 ssh：列出所有 cc-* session 的 前台进程 / 距上次活动秒数 / 屏幕最后一行，
  /// 末尾附带 ~/.blink/org.md 的 role 表。
  /// 「在做什么」两级抓取：优先取转录里最后一个 `📋 <当前任务>` 行（员工 CLAUDE.md
  /// 规范 footer，一句话任务摘要）；没有再回退到"滤壳后的最后一行内容"。
  /// 壳 = claude TUI 底部状态栏（⏵⏵ auto mode / shift+tab / bypass permissions）、
  /// 输入框（❯ ╭ ╰ │）、分隔线 ─、自定义 statusline（👾 名片行 / CTX ▰▱ 用量条）、
  /// ---📁/🌿 footer 行、"new task? /clear" 提示。✻ spinner 的 (esc to interrupt) 行
  /// 滤掉，但 `· Working… (5m · ↓ 13k tokens)` 计时行保留——它就是干活实况。
  /// 输出整体 base64 包在 @TSB64@…@TSB64E@ 里（跟 transcriptDeltaScript 同款）：
  /// blinkd 走 PTY 会混进 \r 和回显噪音，裸文本没法按行解析，两种 transport 统一按标记捞。
  /// 只读 ~/.blink/org.md 里的角色表（员工卡上那个小职位标签）。
  /// 会话状态探测、读 claude 记录都拿掉了：前者分档不准，后者用户不要。
  private static let probeScript = """
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
  BODY=$(grep -E '^\\| \\*\\*' "$HOME/.blink/org.md" 2>/dev/null || true)
  EB64=$(printf '%s' "$BODY" | base64 | tr -d '\\n')
  printf '@TSB64@%s@TSB64E@\\n' "$EB64"
  """

  /// 按机器 transport 执行探测脚本：blinkd 机器走 BlinkdExecOnce（远程登录关着也通），
  /// 其余走 ssh execRemote；两边都从 @TSB64@ 标记里解 base64 拿干净输出。
  private static func exec(script: String, machine m: BlinkMachine) async throws -> String {
    let raw: String
    if let cfg = m.blinkdConfig {
      raw = try await withCheckedThrowingContinuation { cont in
        BlinkdExecOnce.run(host: cfg.host, port: cfg.port, token: cfg.token, script: script) { r in
          cont.resume(with: r)
        }
      }
    } else {
      raw = try await BlinkAssistantBackend.shared.execRemote(script: script, machine: m)
    }
    guard let r1 = raw.range(of: "@TSB64@"),
          let r2 = raw.range(of: "@TSB64E@", range: r1.upperBound..<raw.endIndex) else {
      throw NSError(domain: "TeamStatusProbe", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "回包无标记: …\(String(raw.suffix(80)))"])
    }
    let b64 = String(raw[r1.upperBound..<r2.lowerBound]).filter {
      $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "="
    }
    guard let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf8) else {
      throw NSError(domain: "TeamStatusProbe", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "payload base64 解码失败"])
    }
    return s
  }

  /// 并行探测：每台机器各自一个 Task + 20s 硬超时，谁先回来先刷谁的行。
  /// 串行会被一台挂起的 ssh（Tailscale 节点离线时 TCP 黑洞）卡住整页「读取中」。
  private var probeGeneration = 0
  private var pendingMachines: Set<String> = []
  private var probeMachinesTotal = 0
  private var probeReachedCount = 0

  private func probe() {
    let machineIds = Array(Set(tabs.map(\.machineId)))
    let machines = machineIds.compactMap { id in
      BlinkMachineStore.shared.machines.first { $0.id == id }
    }
    probeGeneration += 1
    let gen = probeGeneration
    pendingMachines = Set(machines.map(\.id))
    probeMachinesTotal = machines.count
    probeReachedCount = 0
    subtitleLabel.text = "正在读取 \(machines.count) 台机器…"
    for m in machines {
      Task { [weak self] in

        var roles: [String: String] = [:]
        var failure: String?
        do {
          let out = try await Self.withTimeout(20) {
            try await Self.exec(script: Self.probeScript, machine: m)
          }
          Self.log("probe \(m.displayName)(\(m.blinkdConfig != nil ? "blinkd" : "ssh")) OK, \(out.count) bytes")
          for raw in out.split(separator: "\n", omittingEmptySubsequences: true) {
            // | **tom** | CTO |
            let parts = String(raw).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
              let name = parts[0].replacingOccurrences(of: "*", with: "").lowercased()
              if !name.isEmpty && name != "员工" { roles[name] = parts[1] }
            }
          }
        } catch {
          failure = error.localizedDescription
          Self.log("probe \(m.displayName)(\(m.blinkdConfig != nil ? "blinkd" : "ssh")) 失败: \(error)")
        }
        let r = roles, f = failure
        await MainActor.run { [weak self] in
          self?.applyMachine(machineId: m.id, roles: r, failure: f, gen: gen)
        }
      }
    }
  }

  /// 单个 op 的硬超时；超时后原任务可能还在后台跑完（execRemote 不可取消），结果直接丢弃
  private static func withTimeout<T: Sendable>(_ seconds: Double,
                                               _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await op() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw NSError(domain: "TeamStatusProbe", code: 8,
                      userInfo: [NSLocalizedDescriptionKey: "连接超时(\(Int(seconds))s)"])
      }
      let r = try await group.next()!
      group.cancelAll()
      return r
    }
  }

  /// 单台机器结果落地：只并这台机器带回来的角色表
  private func applyMachine(machineId: String, roles: [String: String], failure: String?, gen: Int) {
    guard gen == probeGeneration else { return }   // 旧一轮的迟到结果直接丢
    pendingMachines.remove(machineId)
    if failure == nil { probeReachedCount += 1 }
    if !roles.isEmpty { roleMap.merge(roles) { _, new in new } }
    for gi in groups.indices where groups[gi].role == nil {
      groups[gi].role = roleMap[groups[gi].employee.lowercased()]
    }

    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    if pendingMachines.isEmpty {
      subtitleLabel.text = probeReachedCount == probeMachinesTotal
        ? "更新 \(f.string(from: Date())) · \(probeMachinesTotal) 台机器"
        : "更新 \(f.string(from: Date())) · \(probeReachedCount)/\(probeMachinesTotal) 台机器可达"
      tableView.refreshControl?.endRefreshing()
    } else {
      subtitleLabel.text = "已回 \(probeMachinesTotal - pendingMachines.count)/\(probeMachinesTotal) 台，其余读取中…"
    }
    updateStats()
    tableView.reloadData()
  }

  // MARK: CLI 选择（行尾齿轮）

  /// 这个员工（机器 × tab）下次开会话进 claude / codex / deepseek。
  /// 只改配置，不动已经跑着的 tmux 会话——那里面 claude 的上下文还在，
  /// 要换得先把 cc-<TITLE> 关掉重开，所以这里只提示一句。
  private func pickAgent(tabKey: UUID, anchor: UIView) {
    guard let t = tabs.first(where: { $0.tabKey == tabKey }) else { return }
    let title = TabAgentStore.title(fromOuterSession: t.outerSession)
    let cur = TabAgentStore.shared.agent(machineId: t.machineId, title: title)
    let ac = UIAlertController(title: "\(t.employee) · \(t.project)",
                               message: "下次打开这个会话时进哪个 CLI", preferredStyle: .actionSheet)
    for k in AgentKind.allCases {
      let a = UIAlertAction(title: k == cur ? "\(k.label)（当前）" : k.label, style: .default) { [weak self] _ in
        guard let self, k != cur else { return }
        TabAgentStore.shared.setAgent(k, machineId: t.machineId, title: title)
        for gi in self.groups.indices {
          for ri in self.groups[gi].rows.indices where self.groups[gi].rows[ri].tabKey == tabKey {
            self.groups[gi].rows[ri].agent = k
          }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.tableView.reloadData()
        // 直接切：把远端那个 tmux 会话杀掉，终端那边自动重连时就会用新 CLI 重跑启动脚本。
        // 不杀的话 `tmux new-session -A` 只 attach 回原来那个，里面跑的还是旧的。
        guard let m = BlinkMachineStore.shared.machines.first(where: { $0.id == t.machineId }) else { return }
        let kill = """
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
        tmux kill-session -t \(t.outerSession) 2>/dev/null
        printf '@TSB64@@TSB64E@\\n'
        """
        Task { [weak self] in
          _ = try? await Self.exec(script: kill, machine: m)
          await MainActor.run {
            self?.toast("已切到 \(k.label)，会话正在用它重开")
          }
        }
      }
      if k == cur { a.setValue(true, forKey: "checked") }
      ac.addAction(a)
    }
    ac.addAction(UIAlertAction(title: "取消", style: .cancel))
    ac.popoverPresentationController?.sourceView = anchor
    ac.popoverPresentationController?.sourceRect = anchor.bounds
    present(ac, animated: true)
  }

  /// 一闪而过的提示条（切 CLI 这类操作用，不打断操作）
  private func toast(_ msg: String) {
    let lb = PaddedLabel()
    lb.insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    lb.text = msg
    lb.font = .systemFont(ofSize: 13, weight: .medium)
    lb.textColor = .white
    lb.backgroundColor = UIColor.black.withAlphaComponent(0.85)
    lb.layer.cornerRadius = 10
    lb.clipsToBounds = true
    lb.numberOfLines = 0
    lb.textAlignment = .center
    lb.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(lb)
    NSLayoutConstraint.activate([
      lb.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      lb.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
      lb.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
    ])
    UIView.animate(withDuration: 0.2, delay: 1.6, options: []) { lb.alpha = 0 } completion: { _ in
      lb.removeFromSuperview()
    }
  }

  // MARK: 休息切换

  /// 单行（员工×项目）切换：只动这一个 tab 的休息状态
  private func toggleRest(tabKey: UUID, toRest: Bool) {
    for gi in groups.indices {
      for ri in groups[gi].rows.indices where groups[gi].rows[ri].tabKey == tabKey {
        groups[gi].rows[ri].resting = toRest
        groups[gi].resting = groups[gi].rows.allSatisfy(\.resting)
      }
    }
    if let ti = tabs.firstIndex(where: { $0.tabKey == tabKey }) { tabs[ti].resting = toRest }
    onToggleRest?(tabKey, toRest)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    updateStats()
    tableView.reloadData()
  }

  private func toggleRest(group g: Group) {
    let toRest = !g.resting
    for gi in groups.indices where groups[gi].employee == g.employee && groups[gi].machineId == g.machineId {
      groups[gi].resting = toRest
      for ri in groups[gi].rows.indices { groups[gi].rows[ri].resting = toRest }
    }
    for ti in tabs.indices where tabs[ti].machineId == g.machineId && tabs[ti].employee == g.employee {
      tabs[ti].resting = toRest
      onToggleRest?(tabs[ti].tabKey, toRest)
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    updateStats()
    tableView.reloadData()
  }

  // MARK: 视图数据（按员工 = 状态分段；按项目 = 项目分段）

  /// 原来按 等你拍板/干活中/空闲/休息中 分四段——探测出来的档位不准，分段等于把人乱放，
  /// 现在一段列全，顺序就是 groups 的顺序。
  private var employeeSections: [(status: TeamWorkStatus, items: [Group])] {
    groups.isEmpty ? [] : [(.work, groups)]
  }

  private struct MemberEntry { let group: Group; let row: ProjectRow }
  private var projectSections: [(project: String, items: [MemberEntry])] {
    var order: [String] = []
    var map: [String: [MemberEntry]] = [:]
    for g in groups {
      for r in g.rows {
        // 项目按名字合并：不同机器上的同一个项目放一组（成员行里带机器名区分）
        let k = r.project
        if map[k] == nil { order.append(k); map[k] = [] }
        map[k]?.append(MemberEntry(group: g, row: r))
      }
    }
    // 每个项目组内按紧急度排；有等你的项目整组置顶
    for k in map.keys {
      map[k]?.sort { memberStatus($0).rawValue < memberStatus($1).rawValue }
    }
    // 一组里混着几台机器，用组里最靠前的那台定位次，跟机器列表同序
    let ranks = Self.machineRanks()
    return order.sorted { a, b in
      let ra = map[a]?.map { ranks[$0.group.machineId] ?? Int.max }.min() ?? Int.max
      let rb = map[b]?.map { ranks[$0.group.machineId] ?? Int.max }.min() ?? Int.max
      return ra != rb ? ra < rb : a < b
    }.map { ($0, map[$0] ?? []) }
  }
  private func memberStatus(_ e: MemberEntry) -> TeamWorkStatus {
    e.row.effective
  }

  /// 按机器：机器分 section，行=tab（员工×项目），在岗排前休息沉底（旧在岗/休息面板并入这里）
  private var machineSections: [(machine: String, items: [MemberEntry])] {
    var order: [String] = []
    var map: [String: [MemberEntry]] = [:]
    // groups 已经按机器列表排过序，这里照它的顺序收就行
    for g in groups {
      if map[g.machineName] == nil { order.append(g.machineName); map[g.machineName] = [] }
      for r in g.rows { map[g.machineName]?.append(MemberEntry(group: g, row: r)) }
    }
    for k in map.keys {
      map[k]?.sort {
        if $0.row.resting != $1.row.resting { return !$0.row.resting }
        return $0.row.effective.rawValue < $1.row.effective.rawValue
      }
    }
    return order.map { ($0, map[$0] ?? []) }
  }

  // MARK: UITableView

  func numberOfSections(in tableView: UITableView) -> Int {
    switch mode {
    case .employee: return employeeSections.count
    case .project:  return projectSections.count
    case .machine:  return machineSections.count
    }
  }

  func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch mode {
    case .employee: return employeeSections[section].items.count
    case .project:  return projectSections[section].items.count
    case .machine:  return machineSections[section].items.count
    }
  }

  func tableView(_ tv: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    switch mode {
    case .employee:
      return nil
    case .project:
      let s = projectSections[section]
      let waitCount = s.items.filter { memberStatus($0) == .wait }.count
      let hint = waitCount > 0 ? "\(s.items.count) 人 · \(waitCount) 个等你" : "\(s.items.count) 人"
      return SectionHeader(symbol: "folder", color: UIColor.white.withAlphaComponent(0.75),
                           title: s.project, hint: hint)
    case .machine:
      let s = machineSections[section]
      let restCount = s.items.filter { $0.row.resting }.count
      let hint = restCount > 0 ? "\(s.items.count) 个 tab · \(restCount) 休息" : "\(s.items.count) 个 tab"
      return SectionHeader(symbol: "desktopcomputer", color: UIColor.white.withAlphaComponent(0.75),
                           title: s.machine, hint: hint)
    }
  }

  func tableView(_ tv: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    mode == .employee ? 0 : 34
  }
  func tableView(_ tv: UITableView, heightForFooterInSection section: Int) -> CGFloat { 6 }
  func tableView(_ tv: UITableView, viewForFooterInSection section: Int) -> UIView? {
    let v = UIView(); v.backgroundColor = .clear; return v
  }

  func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    switch mode {
    case .employee:
      let g = employeeSections[indexPath.section].items[indexPath.row]
      let cell = tv.dequeueReusableCell(withIdentifier: "emp", for: indexPath) as! EmployeeCardCell
      cell.configure(group: g, panel: panel, panel2: panel2, sub: sub)
      cell.onRowTap = nil   // 点击跳 tab 已去掉（cell 复用，必须显式清掉旧闭包）
      cell.onRowToggle = { [weak self] key, toRest in self?.toggleRest(tabKey: key, toRest: toRest) }
      cell.onRowAgent = { [weak self] key, anchor in self?.pickAgent(tabKey: key, anchor: anchor) }
      return cell
    case .project:
      let e = projectSections[indexPath.section].items[indexPath.row]
      let cell = tv.dequeueReusableCell(withIdentifier: "mem", for: indexPath) as! MemberRowCell
      cell.configure(entry: (e.group, e.row), status: memberStatus(e), panel: panel, sub: sub)
      return cell
    case .machine:
      let e = machineSections[indexPath.section].items[indexPath.row]
      let cell = tv.dequeueReusableCell(withIdentifier: "mch", for: indexPath) as! MachineRowCell
      cell.configure(entry: (e.group, e.row), status: memberStatus(e), panel: panel, sub: sub)
      cell.onToggle = { [weak self] key, toRest in self?.toggleRest(tabKey: key, toRest: toRest) }
      return cell
    }
  }

  // 点击跳 tab 已去掉：页面纯看状态 + 拨休息开关，不再响应行选中。
  // 要恢复：实现 didSelectRowAt → dismiss 后 onOpenTab?(key)。

  // MARK: - 内部小控件

  /// 顶部统计块：彩色数字 + 图标 + 文案
  final class StatTile: UIView {
    let status: TeamWorkStatus
    private let numLabel = UILabel()
    init(status: TeamWorkStatus) {
      self.status = status
      super.init(frame: .zero)
      backgroundColor = UIColor(red: 0.078, green: 0.086, blue: 0.106, alpha: 1)
      layer.cornerRadius = 12
      layer.borderWidth = 1
      layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor

      numLabel.font = .monospacedSystemFont(ofSize: 19, weight: .bold)
      numLabel.textColor = status.color
      numLabel.textAlignment = .center
      numLabel.text = "0"

      let icon = UIImageView(image: UIImage(systemName: status.symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)))
      icon.tintColor = status.color
      let cap = UILabel()
      cap.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
      cap.textColor = UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1)
      cap.text = status.label
      let capRow = UIStackView(arrangedSubviews: [icon, cap])
      capRow.axis = .horizontal
      capRow.spacing = 3
      capRow.alignment = .center

      let col = UIStackView(arrangedSubviews: [numLabel, capRow])
      col.axis = .vertical
      col.alignment = .center
      col.spacing = 1
      col.translatesAutoresizingMaskIntoConstraints = false
      addSubview(col)
      NSLayoutConstraint.activate([
        col.centerXAnchor.constraint(equalTo: centerXAnchor),
        col.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func setCount(_ n: Int) { numLabel.text = "\(n)" }
  }

  /// 分段头：图标 + 标题 + 灰色提示
  final class SectionHeader: UIView {
    init(symbol: String, color: UIColor, title: String, hint: String) {
      super.init(frame: .zero)
      let icon = UIImageView(image: UIImage(systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
      icon.tintColor = color
      let t = UILabel()
      t.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
      t.textColor = .white
      t.text = title
      let h = UILabel()
      h.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
      h.textColor = UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1)
      h.text = "· " + hint
      let row = UIStackView(arrangedSubviews: [icon, t, h, UIView()])
      row.axis = .horizontal
      row.spacing = 6
      row.alignment = .center
      row.translatesAutoresizingMaskIntoConstraints = false
      addSubview(row)
      NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
        row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      ])
    }
    required init?(coder: NSCoder) { fatalError() }
  }

  /// 状态胶囊按钮：显示状态 + 点击切休息/在岗
  final class StatusPill: UIButton {
    func apply(_ st: TeamWorkStatus) {
      var cfg = UIButton.Configuration.plain()
      cfg.image = UIImage(systemName: st.symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
      cfg.imagePadding = 4
      cfg.attributedTitle = AttributedString(st.label, attributes: AttributeContainer([
        .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .bold)]))
      cfg.baseForegroundColor = st.color
      cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
      configuration = cfg
      layer.cornerRadius = 12
      layer.borderWidth = 1
      layer.borderColor = st.color.withAlphaComponent(0.55).cgColor
      backgroundColor = st == .idle || st == .rest ? .clear : st.color.withAlphaComponent(0.1)
    }
  }

  /// 无头像时按名字生成渐变首字头像（配色对齐 tab 栏同款）
  static let avatarPalette: [(UIColor, UIColor)] = [
    (UIColor(red: 0.30, green: 0.55, blue: 1, alpha: 1), UIColor(red: 0.54, green: 0.36, blue: 1, alpha: 1)),
    (UIColor(red: 1, green: 0.48, blue: 0.35, alpha: 1), UIColor(red: 1, green: 0.36, blue: 0.63, alpha: 1)),
    (UIColor(red: 0.23, green: 0.63, blue: 1, alpha: 1), UIColor(red: 0.22, green: 0.82, blue: 0.75, alpha: 1)),
    (UIColor(red: 0.54, green: 0.36, blue: 1, alpha: 1), UIColor(red: 0.30, green: 0.82, blue: 1, alpha: 1)),
    (UIColor(red: 1, green: 0.62, blue: 0.26, alpha: 1), UIColor(red: 1, green: 0.36, blue: 0.63, alpha: 1)),
    (UIColor(red: 0.22, green: 0.82, blue: 0.75, alpha: 1), UIColor(red: 0.30, green: 0.55, blue: 1, alpha: 1)),
  ]
  static func initialAvatar(for title: String, size: CGFloat) -> UIImage {
    let seed = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    let pair = avatarPalette[abs(seed) % avatarPalette.count]
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    return UIGraphicsImageRenderer(size: rect.size).image { ctx in
      UIBezierPath(ovalIn: rect).addClip()
      if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [pair.0.cgColor, pair.1.cgColor] as CFArray, locations: [0, 1]) {
        ctx.cgContext.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size, y: size), options: [])
      }
      let initial = String(title.prefix(1)).uppercased()
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: size * 0.46, weight: .bold),
        .foregroundColor: UIColor.white,
      ]
      let ts = (initial as NSString).size(withAttributes: attrs)
      (initial as NSString).draw(at: CGPoint(x: (size - ts.width) / 2, y: (size - ts.height) / 2), withAttributes: attrs)
    }
  }

  // MARK: 员工卡片 cell

  final class EmployeeCardCell: UITableViewCell {
    var onPillTap: (() -> Void)?
    var onRowTap: ((UUID) -> Void)?
    var onRowToggle: ((UUID, Bool) -> Void)?     // (tabKey, 切到休息?) 行尾月亮开关
    var onRowAgent: ((UUID, UIView) -> Void)?    // 行尾齿轮：这个员工进 claude / codex / deepseek
    private var rowInfoByTag: [Int: (key: UUID, resting: Bool)] = [:]
    private let card = UIView()
    private let avatarView = UIImageView()
    /// 头像右下角的 CLI mark；这个人名下几个 tab 配的不一样时不挂（挂了也代表不了谁）
    private let agentBadge = UIImageView()
    private let nameLabel = UILabel()
    private let roleChip = PaddedLabel()
    private let machineLabel = UILabel()
    private let pill = StatusPill()
    private let projStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
      super.init(style: style, reuseIdentifier: reuseIdentifier)
      backgroundColor = .clear
      selectionStyle = .none

      card.layer.cornerRadius = 14
      card.layer.borderWidth = 1
      card.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(card)

      avatarView.layer.cornerRadius = 17
      avatarView.clipsToBounds = true
      avatarView.contentMode = .scaleAspectFill
      nameLabel.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
      nameLabel.textColor = .white
      roleChip.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
      roleChip.textColor = UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1)
      roleChip.backgroundColor = UIColor.white.withAlphaComponent(0.07)
      roleChip.layer.cornerRadius = 6
      roleChip.clipsToBounds = true
      machineLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
      machineLabel.textColor = UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1)
      // 胶囊改纯状态显示;切换粒度在每一行的月亮开关上,不再整人总切
      pill.isUserInteractionEnabled = false
      // 胶囊尺寸只由内容决定;不设的话 row1 分配余量时会把胶囊拉宽(有角色标签的卡尤其明显)
      pill.setContentHuggingPriority(.required, for: .horizontal)
      pill.setContentCompressionResistancePriority(.required, for: .horizontal)

      let nameRow = UIStackView(arrangedSubviews: [nameLabel, roleChip, UIView()])
      nameRow.axis = .horizontal
      nameRow.spacing = 6
      nameRow.alignment = .center
      let who = UIStackView(arrangedSubviews: [nameRow, machineLabel])
      who.axis = .vertical
      who.spacing = 1
      let row1 = UIStackView(arrangedSubviews: [avatarView, who, pill])
      row1.axis = .horizontal
      row1.spacing = 9
      row1.alignment = .center

      projStack.axis = .vertical
      projStack.spacing = 5

      let col = UIStackView(arrangedSubviews: [row1, projStack])
      col.axis = .vertical
      col.spacing = 8
      col.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(col)
      agentBadge.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(agentBadge)

      NSLayoutConstraint.activate([
        card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
        card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
        card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        avatarView.widthAnchor.constraint(equalToConstant: 34),
        avatarView.heightAnchor.constraint(equalToConstant: 34),
        // 圆标压在头像右下角，往外探出头像边长的 13%
        agentBadge.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 34 * 0.13),
        agentBadge.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 34 * 0.13),
        col.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
        col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
        col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
        col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pillTapped() { onPillTap?() }

    @objc private func rowTapped(_ gr: UITapGestureRecognizer) {
      guard let v = gr.view, let info = rowInfoByTag[v.tag], !info.resting else { return }   // 休息行原地吞掉
      onRowTap?(info.key)
    }

    @objc private func rowToggleTapped(_ b: UIButton) {
      guard let info = rowInfoByTag[b.tag] else { return }
      onRowToggle?(info.key, !info.resting)
    }

    @objc private func rowAgentTapped(_ b: UIButton) {
      guard let info = rowInfoByTag[b.tag] else { return }
      onRowAgent?(info.key, b)
    }

    fileprivate func configure(group g: Group, panel: UIColor, panel2: UIColor, sub: UIColor) {
      card.backgroundColor = panel
      let st = g.status
      card.alpha = st == .rest ? 0.55 : 1
      if st == .rest {
        card.layer.borderColor = TeamWorkStatus.rest.color.withAlphaComponent(0.45).cgColor
      } else if st == .wait {
        card.layer.borderColor = TeamWorkStatus.wait.color.withAlphaComponent(0.45).cgColor
      } else {
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
      }
      avatarView.image = g.avatar ?? TeamStatusViewController.initialAvatar(for: g.employee, size: 34)
      // 名下几个 tab 配的 CLI 一致才挂 mark；混着配就留空，具体看下面每一行
      let kinds = Set(g.rows.map(\.agent))
      if kinds.count == 1, let k = kinds.first {
        agentBadge.image = AgentMark.badge(k, size: 17, ring: panel)
        agentBadge.isHidden = false
      } else {
        agentBadge.isHidden = true
      }
      // 跨机器一起列，名字前面带上机器名（「tom · talkai」）好区分
      nameLabel.text = "\(g.machineName) · \(g.employee)"
      roleChip.text = g.role
      roleChip.isHidden = (g.role ?? "").isEmpty
      let restCount = g.rows.filter(\.resting).count
      machineLabel.text = restCount > 0 && restCount < g.rows.count
        ? "\(g.rows.count - restCount) 在岗 · \(restCount) 休息"
        : "\(g.rows.count) 个会话"
      pill.isHidden = true   // 等你/干活中/空闲 探测不准，不显示

      projStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
      // 在岗的排前面（按紧急度），休息的沉底；组内保持原顺序
      let ordered = g.rows.enumerated().sorted { a, b in
        if a.element.resting != b.element.resting { return !a.element.resting }
        if a.element.status.rawValue != b.element.status.rawValue {
          return a.element.status.rawValue < b.element.status.rawValue
        }
        return a.offset < b.offset
      }.map(\.element)
      rowInfoByTag.removeAll()
      for (i, r) in ordered.enumerated() {
        let line = UIView()
        line.layer.cornerRadius = 9
        line.tag = i
        line.isUserInteractionEnabled = true
        line.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(rowTapped(_:))))
        rowInfoByTag[i] = (r.tabKey, r.resting)
        if r.resting {
          // 休息：压到近黑 + 紫字，跟在岗行拉开对比
          line.backgroundColor = UIColor.white.withAlphaComponent(0.02)
          line.alpha = 0.55
        } else {
          line.backgroundColor = UIColor.white.withAlphaComponent(0.05)
        }
        let pn = UILabel()
        pn.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        pn.textColor = r.resting ? TeamWorkStatus.rest.color : .white
        pn.text = r.project
        pn.setContentHuggingPriority(.required, for: .horizontal)
        pn.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pd = UILabel()
        pd.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pd.numberOfLines = 0
        pd.textColor = r.resting ? TeamWorkStatus.rest.color.withAlphaComponent(0.75)
                                 : UIColor.white.withAlphaComponent(0.72)
        pd.text = r.resting ? "休息中" : ""
        pd.isHidden = !r.resting
        pd.lineBreakMode = .byTruncatingTail
        let sw = UIButton(type: .system)
        sw.tag = i
        sw.setImage(UIImage(systemName: r.resting ? "moon.zzz.fill" : "moon",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        sw.tintColor = r.resting ? TeamWorkStatus.rest.color : UIColor.white.withAlphaComponent(0.4)
        sw.addTarget(self, action: #selector(rowToggleTapped(_:)), for: .touchUpInside)
        sw.setContentHuggingPriority(.required, for: .horizontal)
        sw.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 行尾齿轮：配这个员工开起来进哪个 CLI；不是默认 claude 就在齿轮前挂个名字小标签
        let gear = UIButton(type: .system)
        gear.tag = i
        gear.setImage(UIImage(systemName: "gearshape",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        gear.tintColor = r.agent == .claude ? UIColor.white.withAlphaComponent(0.4)
                                            : AgentMark.brand(r.agent)
        gear.addTarget(self, action: #selector(rowAgentTapped(_:)), for: .touchUpInside)
        gear.setContentHuggingPriority(.required, for: .horizontal)
        gear.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 这行没头像，就把同一颗 mark 直接摆在齿轮前面，跟上面的头像角标是一套东西
        let agentMark = UIImageView(image: AgentMark.badge(r.agent, size: 13, ring: panel))
        agentMark.setContentHuggingPriority(.required, for: .horizontal)
        agentMark.setContentCompressionResistancePriority(.required, for: .horizontal)
        let h = UIStackView(arrangedSubviews: [pn, pd, agentMark, gear, sw])
        h.axis = .horizontal
        h.spacing = 8
        h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(h)
        NSLayoutConstraint.activate([
          h.topAnchor.constraint(equalTo: line.topAnchor, constant: 6),
          h.bottomAnchor.constraint(equalTo: line.bottomAnchor, constant: -6),
          h.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 9),
          h.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -9),
        ])
        projStack.addArrangedSubview(line)
      }
    }
  }

  // MARK: 项目视图成员行 cell

  final class MemberRowCell: UITableViewCell {
    private let card = UIView()
    private let avatarView = UIImageView()
    private let agentBadge = UIImageView()
    private let nameLabel = UILabel()
    private let roleChip = PaddedLabel()
    private let descLabel = UILabel()
    private let dot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
      super.init(style: style, reuseIdentifier: reuseIdentifier)
      backgroundColor = .clear
      selectionStyle = .none
      card.layer.cornerRadius = 10
      card.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(card)

      avatarView.layer.cornerRadius = 12
      avatarView.clipsToBounds = true
      avatarView.contentMode = .scaleAspectFill
      nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
      nameLabel.textColor = .white
      roleChip.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
      roleChip.textColor = UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1)
      roleChip.backgroundColor = UIColor.white.withAlphaComponent(0.07)
      roleChip.layer.cornerRadius = 6
      roleChip.clipsToBounds = true
      descLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      descLabel.lineBreakMode = .byTruncatingTail
      dot.layer.cornerRadius = 3.5

      let nameRow = UIStackView(arrangedSubviews: [nameLabel, roleChip, UIView()])
      nameRow.axis = .horizontal
      nameRow.spacing = 5
      nameRow.alignment = .center
      let mid = UIStackView(arrangedSubviews: [nameRow, descLabel])
      mid.axis = .vertical
      mid.spacing = 1
      let row = UIStackView(arrangedSubviews: [avatarView, mid, dot])
      row.axis = .horizontal
      row.spacing = 8
      row.alignment = .center
      row.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(row)
      agentBadge.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(agentBadge)

      NSLayoutConstraint.activate([
        card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
        card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
        card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
        card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        avatarView.widthAnchor.constraint(equalToConstant: 24),
        avatarView.heightAnchor.constraint(equalToConstant: 24),
        agentBadge.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 24 * 0.13),
        agentBadge.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 24 * 0.13),
        dot.widthAnchor.constraint(equalToConstant: 7),
        dot.heightAnchor.constraint(equalToConstant: 7),
        row.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
        row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7),
        row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
        row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      ])
    }
    required init?(coder: NSCoder) { fatalError() }

    fileprivate func configure(entry: (group: Group, row: ProjectRow), status: TeamWorkStatus, panel: UIColor, sub: UIColor) {
      let (g, r) = entry
      card.backgroundColor = status == .rest
        ? UIColor.white.withAlphaComponent(0.02)
        : UIColor.white.withAlphaComponent(0.05)
      card.alpha = status == .rest ? 0.55 : 1
      dot.isHidden = true   // 状态圆点去掉：探测不准
      avatarView.image = g.avatar ?? TeamStatusViewController.initialAvatar(for: g.employee, size: 24)
      agentBadge.image = AgentMark.badge(r.agent, size: 13, ring: panel)
      // 一组里混着好几台机器，名字前面带上机器名才分得清
      nameLabel.text = "\(g.machineName) · \(g.employee)"
      roleChip.text = g.role
      roleChip.isHidden = (g.role ?? "").isEmpty
      descLabel.textColor = sub
      descLabel.numberOfLines = 0
      descLabel.text = status == .rest ? "休息中" : ""
      descLabel.isHidden = status != .rest
      dot.backgroundColor = status.color
    }
  }

  // MARK: 机器视图行 cell（旧「员工在岗/休息」面板并入：行尾 UISwitch，开=在岗）

  final class MachineRowCell: UITableViewCell {
    var onToggle: ((UUID, Bool) -> Void)?   // (tabKey, 切换后是否休息)
    private let card = UIView()
    private let avatarView = UIImageView()
    private let agentBadge = UIImageView()
    private let nameLabel = UILabel()
    private let projectChip = PaddedLabel()
    private let descLabel = UILabel()
    private let toggle = UISwitch()
    private var tabKey: UUID?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
      super.init(style: style, reuseIdentifier: reuseIdentifier)
      backgroundColor = .clear
      selectionStyle = .none
      card.layer.cornerRadius = 10
      card.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(card)

      avatarView.layer.cornerRadius = 12
      avatarView.clipsToBounds = true
      avatarView.contentMode = .scaleAspectFill
      nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
      nameLabel.textColor = .white
      projectChip.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
      projectChip.textColor = UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1)
      projectChip.backgroundColor = UIColor.white.withAlphaComponent(0.07)
      projectChip.layer.cornerRadius = 6
      projectChip.clipsToBounds = true
      descLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      descLabel.lineBreakMode = .byTruncatingTail
      toggle.onTintColor = UIColor(red: 0.30, green: 0.78, blue: 0.47, alpha: 1)
      toggle.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
      toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
      toggle.setContentHuggingPriority(.required, for: .horizontal)
      toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

      let nameRow = UIStackView(arrangedSubviews: [nameLabel, projectChip, UIView()])
      nameRow.axis = .horizontal
      nameRow.spacing = 5
      nameRow.alignment = .center
      let mid = UIStackView(arrangedSubviews: [nameRow, descLabel])
      mid.axis = .vertical
      mid.spacing = 1
      let row = UIStackView(arrangedSubviews: [avatarView, mid, toggle])
      row.axis = .horizontal
      row.spacing = 8
      row.alignment = .center
      row.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(row)
      agentBadge.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(agentBadge)

      NSLayoutConstraint.activate([
        card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
        card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
        card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
        card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        avatarView.widthAnchor.constraint(equalToConstant: 24),
        avatarView.heightAnchor.constraint(equalToConstant: 24),
        agentBadge.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 24 * 0.13),
        agentBadge.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 24 * 0.13),
        row.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
        row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7),
        row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
        row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
      ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleChanged() {
      guard let k = tabKey else { return }
      onToggle?(k, !toggle.isOn)   // 开=在岗，关=休息
    }

    fileprivate func configure(entry: (group: Group, row: ProjectRow), status: TeamWorkStatus, panel: UIColor, sub: UIColor) {
      let (g, r) = entry
      tabKey = r.tabKey
      // 开关要保持全亮可点，休息态只压暗文字/底色，不动整卡 alpha
      card.backgroundColor = status == .rest
        ? UIColor.white.withAlphaComponent(0.02)
        : UIColor.white.withAlphaComponent(0.05)
      avatarView.image = g.avatar ?? TeamStatusViewController.initialAvatar(for: g.employee, size: 24)
      avatarView.alpha = status == .rest ? 0.45 : 1
      agentBadge.image = AgentMark.badge(r.agent, size: 13, ring: panel)
      agentBadge.alpha = avatarView.alpha
      nameLabel.textColor = status == .rest ? UIColor.white.withAlphaComponent(0.45) : .white
      nameLabel.text = g.employee
      projectChip.text = r.project
      descLabel.numberOfLines = 1
      if status == .rest {
        descLabel.textColor = TeamWorkStatus.rest.color.withAlphaComponent(0.8)
        descLabel.text = "休息中 · 打开开关叫回来"
      } else {
        descLabel.textColor = sub
        descLabel.text = ""
      }
      toggle.setOn(!r.resting, animated: false)
    }
  }

  /// 带内边距的小标签（role chip 用）
  final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
      let s = super.intrinsicContentSize
      return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
  }
}
