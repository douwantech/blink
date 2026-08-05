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
    case .rest: return "点胶囊叫回来"
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
    var desc: String
    var status: TeamWorkStatus   // 探测前默认 .idle
    var probed = false
  }
  fileprivate struct Group {
    let employee: String
    let machineId: String
    let machineName: String
    let avatar: UIImage?
    var role: String?
    var rows: [ProjectRow]
    var resting: Bool
    /// 员工整体状态：休息优先，其次取各 tab 里最紧急的一档
    var status: TeamWorkStatus {
      if resting { return .rest }
      return rows.map(\.status).min(by: { $0.rawValue < $1.rawValue }) ?? .idle
    }
  }

  private var tabs: [TeamStatusTab]
  private var groups: [Group] = []
  private var roleMap: [String: String] = [:]
  private var byEmployee = true   // segmented：按员工 / 按项目

  private let bg = UIColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1)      // #0b0c0e
  private let panel = UIColor(red: 0.078, green: 0.086, blue: 0.106, alpha: 1)   // #14161b
  private let panel2 = UIColor(red: 0.102, green: 0.114, blue: 0.137, alpha: 1)  // #1a1d23
  private let sub = UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1)     // #8b95a5

  private let tableView = UITableView(frame: .zero, style: .grouped)
  private let statTiles: [StatTile]
  private let segmented = UISegmentedControl(items: ["按员工", "按项目"])
  private let subtitleLabel = UILabel()

  init(tabs: [TeamStatusTab]) {
    self.tabs = tabs
    self.statTiles = [.wait, .work, .idle, .rest].map { StatTile(status: $0) }
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
    let rc = UIRefreshControl()
    rc.tintColor = sub
    rc.addTarget(self, action: #selector(refreshTapped), for: .valueChanged)
    tableView.refreshControl = rc
    view.addSubview(tableView)
    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])

    // 表头：统计条 + 视图切换 + 更新时间
    let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 132))
    let stats = UIStackView(arrangedSubviews: statTiles)
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
    subtitleLabel.text = "正在探测各机器…"
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(subtitleLabel)

    NSLayoutConstraint.activate([
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
    ])
    tableView.tableHeaderView = header
  }

  @objc private func closeTapped() { dismiss(animated: true) }
  @objc private func segChanged() {
    byEmployee = segmented.selectedSegmentIndex == 0
    tableView.reloadData()
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
      map[k]?.rows.append(ProjectRow(tabKey: t.tabKey, project: t.project,
                                     desc: old?.desc ?? "", status: old?.status ?? .idle,
                                     probed: old?.probed ?? false))
      if !t.resting { map[k]?.resting = false }   // 全部 tab 都休息才算员工休息
    }
    groups = order.compactMap { map[$0] }
    updateStats()
    tableView.reloadData()
  }

  private func statusFor(tabKey: UUID) -> ProjectRow? {
    for g in groups { for r in g.rows where r.tabKey == tabKey { return r } }
    return nil
  }

  private func updateStats() {
    var n: [TeamWorkStatus: Int] = [:]
    for g in groups { n[g.status, default: 0] += 1 }
    for tile in statTiles { tile.setCount(n[tile.status] ?? 0) }
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
  private static let probeScript = """
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
  now=$(date +%s)
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^cc-' | while IFS= read -r s; do
    pc=$(tmux display-message -p -t "$s" '#{pane_current_command}' 2>/dev/null)
    act=$(tmux display-message -p -t "$s" '#{window_activity}' 2>/dev/null)
    idle=$(( now - ${act:-0} ))
    cap=$(tmux capture-pane -p -t "$s" 2>/dev/null | sed -e 's/[[:space:]]*$//')
    line=$(printf '%s\n' "$cap" | grep -E '^[[:space:]]*📋' | tail -1 | sed -E 's/^[[:space:]]*📋[[:space:]]*//' | cut -c1-160)
    if [ -z "$line" ]; then
      line=$(printf '%s\n' "$cap" | grep -E '[[:alnum:]]' \\
        | grep -vE 'shift\\+tab to cycle|\\? for shortcuts|bypass permissions|esc to interrupt\\)|new task\\? /clear' \\
        | grep -vE '^[[:space:]]*(⏵|⧉|❯|╭|╰|│|✻|✽|👾|─)' \\
        | grep -vE '▰|▱' \\
        | grep -vE '^[[:space:]]*(---)?📁|^[[:space:]]*🌿|^[[:space:]]*📋' \\
        | tail -1 | cut -c1-160)
    fi
    printf '%s\t%s\t%s\t%s\n' "$s" "$pc" "$idle" "$line"
  done
  echo '===ORG==='
  grep -E '^\\| \\*\\*' "$HOME/.blink/org.md" 2>/dev/null || true
  """

  private func probe() {
    let machineIds = Array(Set(tabs.map(\.machineId)))
    let machines = machineIds.compactMap { id in
      BlinkMachineStore.shared.machines.first { $0.id == id }
    }
    Task { [weak self] in
      var bySession: [String: (pc: String, idle: Int, line: String)] = [:]
      var roles: [String: String] = [:]
      var reached: Set<String> = []
      for m in machines {
        guard let out = try? await BlinkAssistantBackend.shared.execRemote(script: Self.probeScript, machine: m) else { continue }
        reached.insert(m.id)
        var inOrg = false
        for raw in out.split(separator: "\n", omittingEmptySubsequences: true) {
          let lineStr = String(raw)
          if lineStr == "===ORG===" { inOrg = true; continue }
          if inOrg {
            // | **tom** | CTO |
            let parts = lineStr.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
              let name = parts[0].replacingOccurrences(of: "*", with: "").lowercased()
              if !name.isEmpty && name != "员工" { roles[name] = parts[1] }
            }
          } else {
            let f = lineStr.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            bySession[String(f[0])] = (pc: String(f[1]), idle: Int(f[2]) ?? 0,
                                       line: f.count >= 4 ? String(f[3]) : "")
          }
        }
      }
      let sessions = bySession
      let roleTable = roles
      let reachedIds = reached
      await MainActor.run { [weak self] in
        self?.applyProbe(sessions: sessions, roles: roleTable, reachedMachines: reachedIds, machinesTotal: machines.count)
      }
    }
  }

  private static let shellNames: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]

  private func applyProbe(sessions: [String: (pc: String, idle: Int, line: String)],
                          roles: [String: String], reachedMachines: Set<String>, machinesTotal: Int) {
    roleMap = roles
    for gi in groups.indices {
      groups[gi].role = roles[groups[gi].employee.lowercased()]
      for ri in groups[gi].rows.indices {
        guard let tab = tabs.first(where: { $0.tabKey == groups[gi].rows[ri].tabKey }) else { continue }
        // 机器没够着（不同网/不在线）≠ 会话不存在，别误报「会话未启动」
        guard reachedMachines.contains(tab.machineId) else {
          groups[gi].rows[ri].status = .idle
          groups[gi].rows[ri].desc = "机器探测不到（不在同一网络?）"
          groups[gi].rows[ri].probed = true
          continue
        }
        guard let s = sessions[tab.outerSession] else {
          groups[gi].rows[ri].status = .idle
          groups[gi].rows[ri].desc = "会话未启动"
          groups[gi].rows[ri].probed = true
          continue
        }
        let st: TeamWorkStatus
        if s.pc.isEmpty || Self.shellNames.contains(s.pc) {
          st = .idle
        } else if s.idle < 90 {
          st = .work
        } else {
          st = .wait
        }
        groups[gi].rows[ri].status = st
        groups[gi].rows[ri].desc = st == .idle && Self.shellNames.contains(s.pc)
          ? "掉到 shell，点进去看报错" : s.line
        groups[gi].rows[ri].probed = true
      }
    }
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    subtitleLabel.text = reachedMachines.count == machinesTotal
      ? "更新 \(f.string(from: Date())) · \(machinesTotal) 台机器"
      : "更新 \(f.string(from: Date())) · \(reachedMachines.count)/\(machinesTotal) 台机器可达"
    updateStats()
    tableView.reloadData()
    tableView.refreshControl?.endRefreshing()
  }

  // MARK: 休息切换

  private func toggleRest(group g: Group) {
    let toRest = !g.resting
    for gi in groups.indices where groups[gi].employee == g.employee && groups[gi].machineId == g.machineId {
      groups[gi].resting = toRest
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

  private var employeeSections: [(status: TeamWorkStatus, items: [Group])] {
    [TeamWorkStatus.wait, .work, .idle, .rest].compactMap { st in
      let items = groups.filter { $0.status == st }
      return items.isEmpty ? nil : (st, items)
    }
  }

  private struct MemberEntry { let group: Group; let row: ProjectRow }
  private var projectSections: [(project: String, items: [MemberEntry])] {
    var order: [String] = []
    var map: [String: [MemberEntry]] = [:]
    for g in groups {
      for r in g.rows {
        if map[r.project] == nil { order.append(r.project); map[r.project] = [] }
        map[r.project]?.append(MemberEntry(group: g, row: r))
      }
    }
    // 每个项目组内按紧急度排；有等你的项目整组置顶
    for k in map.keys {
      map[k]?.sort { memberStatus($0).rawValue < memberStatus($1).rawValue }
    }
    return order.sorted { a, b in
      let sa = map[a]?.map { memberStatus($0).rawValue }.min() ?? 9
      let sb = map[b]?.map { memberStatus($0).rawValue }.min() ?? 9
      return sa != sb ? sa < sb : a < b
    }.map { ($0, map[$0] ?? []) }
  }
  private func memberStatus(_ e: MemberEntry) -> TeamWorkStatus {
    e.group.resting ? .rest : e.row.status
  }

  // MARK: UITableView

  func numberOfSections(in tableView: UITableView) -> Int {
    byEmployee ? employeeSections.count : projectSections.count
  }

  func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    byEmployee ? employeeSections[section].items.count : projectSections[section].items.count
  }

  func tableView(_ tv: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    if byEmployee {
      let s = employeeSections[section]
      return SectionHeader(symbol: s.status.symbol, color: s.status.color,
                           title: s.status.sectionTitle, hint: s.status.sectionHint)
    } else {
      let s = projectSections[section]
      let waitCount = s.items.filter { memberStatus($0) == .wait }.count
      let hint = waitCount > 0 ? "\(s.items.count) 人 · \(waitCount) 个等你" : "\(s.items.count) 人"
      return SectionHeader(symbol: "folder", color: UIColor.white.withAlphaComponent(0.75),
                           title: s.project, hint: hint)
    }
  }

  func tableView(_ tv: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 34 }
  func tableView(_ tv: UITableView, heightForFooterInSection section: Int) -> CGFloat { 6 }
  func tableView(_ tv: UITableView, viewForFooterInSection section: Int) -> UIView? {
    let v = UIView(); v.backgroundColor = .clear; return v
  }

  func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if byEmployee {
      let g = employeeSections[indexPath.section].items[indexPath.row]
      let cell = tv.dequeueReusableCell(withIdentifier: "emp", for: indexPath) as! EmployeeCardCell
      cell.configure(group: g, panel: panel, panel2: panel2, sub: sub)
      cell.onPillTap = { [weak self] in self?.toggleRest(group: g) }
      return cell
    } else {
      let e = projectSections[indexPath.section].items[indexPath.row]
      let cell = tv.dequeueReusableCell(withIdentifier: "mem", for: indexPath) as! MemberRowCell
      cell.configure(entry: (e.group, e.row), status: memberStatus(e), panel: panel, sub: sub)
      return cell
    }
  }

  func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: true)
    let key: UUID?
    if byEmployee {
      let g = employeeSections[indexPath.section].items[indexPath.row]
      key = (g.rows.first { $0.status == .wait } ?? g.rows.first)?.tabKey
    } else {
      key = projectSections[indexPath.section].items[indexPath.row].row.tabKey
    }
    guard let k = key else { return }
    dismiss(animated: true) { [onOpenTab] in onOpenTab?(k) }
  }

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
    private let card = UIView()
    private let avatarView = UIImageView()
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
      pill.addTarget(self, action: #selector(pillTapped), for: .touchUpInside)

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

      NSLayoutConstraint.activate([
        card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
        card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
        card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        avatarView.widthAnchor.constraint(equalToConstant: 34),
        avatarView.heightAnchor.constraint(equalToConstant: 34),
        col.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
        col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
        col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
        col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pillTapped() { onPillTap?() }

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
      nameLabel.text = g.employee
      roleChip.text = g.role
      roleChip.isHidden = (g.role ?? "").isEmpty
      machineLabel.text = "\(g.machineName) · \(g.rows.count) 个会话"
      pill.apply(st)

      projStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
      for r in g.rows {
        let line = UIView()
        line.backgroundColor = st == .wait ? TeamWorkStatus.wait.color.withAlphaComponent(0.08) : panel2
        line.layer.cornerRadius = 9
        let pn = UILabel()
        pn.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        pn.textColor = .white
        pn.text = r.project
        pn.setContentHuggingPriority(.required, for: .horizontal)
        pn.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pd = UILabel()
        pd.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pd.textColor = sub
        pd.text = r.probed ? r.desc : "探测中…"
        pd.lineBreakMode = .byTruncatingTail
        let h = UIStackView(arrangedSubviews: [pn, pd])
        h.axis = .horizontal
        h.spacing = 8
        h.alignment = .firstBaseline
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

      NSLayoutConstraint.activate([
        card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
        card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
        card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
        card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        avatarView.widthAnchor.constraint(equalToConstant: 24),
        avatarView.heightAnchor.constraint(equalToConstant: 24),
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
      card.backgroundColor = status == .wait
        ? TeamWorkStatus.wait.color.withAlphaComponent(0.08) : panel
      card.alpha = status == .rest ? 0.55 : 1
      avatarView.image = g.avatar ?? TeamStatusViewController.initialAvatar(for: g.employee, size: 24)
      nameLabel.text = g.employee
      roleChip.text = g.role
      roleChip.isHidden = (g.role ?? "").isEmpty
      descLabel.textColor = sub
      descLabel.text = status == .rest ? "休息中" : (r.probed ? r.desc : "探测中…")
      dot.backgroundColor = status.color
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
