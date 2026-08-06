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
    var desc: String
    var status: TeamWorkStatus   // 探测前默认 .idle
    var probed = false
    var resting = false          // 休息按 tab（员工×项目）粒度，来自 TabRestStore
    var summary: TeamSummary?    // GLM 总结：在做/等你/上次（没回来前先显示最后一行）
    /// 行的展示状态：休息优先，其余用探测结果
    var effective: TeamWorkStatus { resting ? .rest : status }
  }
  fileprivate struct TeamSummary { let doing: String; let waiting: String; let last: String }
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
                                     probed: old?.probed ?? false, resting: t.resting))
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
  /// 输出整体 base64 包在 @TSB64@…@TSB64E@ 里（跟 transcriptDeltaScript 同款）：
  /// blinkd 走 PTY 会混进 \r 和回显噪音，裸文本没法按行解析，两种 transport 统一按标记捞。
  private static let probeScript = """
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
  now=$(date +%s)
  BODY=$(
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^cc-' | while IFS= read -r s; do
    pc=$(tmux display-message -p -t "$s" '#{pane_current_command}' 2>/dev/null)
    act=$(tmux display-message -p -t "$s" '#{window_activity}' 2>/dev/null)
    idle=$(( now - ${act:-0} ))
    cap=$(tmux capture-pane -p -t "$s" 2>/dev/null | sed -e 's/[[:space:]]*$//')
    content=$(printf '%s\n' "$cap" | grep -E '[[:alnum:]]' \\
        | grep -vE 'shift\\+tab to cycle|\\? for shortcuts|bypass permissions|esc to interrupt\\)|new task\\? /clear' \\
        | grep -vE '^[[:space:]]*(⏵|⧉|❯|╭|╰|│|✻|✽|👾|─)' \\
        | grep -vE '▰|▱')
    line=$(printf '%s\n' "$cap" | grep -E '^[[:space:]]*📋' | tail -1 | sed -E 's/^[[:space:]]*📋[[:space:]]*//' | cut -c1-160)
    if [ -z "$line" ]; then
      line=$(printf '%s\n' "$content" | grep -vE '^[[:space:]]*(---)?📁|^[[:space:]]*🌿|^[[:space:]]*📋' | tail -1 | cut -c1-160)
    fi
    tb64=$(printf '%s\n' "$content" | tail -60 | tail -c 3500 | base64 | tr -d '\n')
    printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$pc" "$idle" "$line" "$tb64"
  done
  echo '===ORG==='
  grep -E '^\\| \\*\\*' "$HOME/.blink/org.md" 2>/dev/null || true
  )
  EB64=$(printf '%s' "$BODY" | base64 | tr -d '\\n')
  printf '@TSB64@%s@TSB64E@\n' "$EB64"
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
  /// 串行会被一台挂起的 ssh（Tailscale 节点离线时 TCP 黑洞）卡住整页「探测中」。
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
    subtitleLabel.text = "正在探测 \(machines.count) 台机器…"
    for m in machines {
      Task { [weak self] in
        var sessions: [String: (pc: String, idle: Int, line: String, tail: String)] = [:]
        var roles: [String: String] = [:]
        var failure: String?
        do {
          let out = try await Self.withTimeout(20) {
            try await Self.exec(script: Self.probeScript, machine: m)
          }
          Self.log("probe \(m.displayName)(\(m.blinkdConfig != nil ? "blinkd" : "ssh")) OK, \(out.count) bytes")
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
              let f = lineStr.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
              guard f.count >= 3 else { continue }
              var tail = ""
              if f.count >= 5, let d = Data(base64Encoded: String(f[4])),
                 let t = String(data: d, encoding: .utf8) { tail = t }
              sessions[String(f[0])] = (pc: String(f[1]), idle: Int(f[2]) ?? 0,
                                        line: f.count >= 4 ? String(f[3]) : "", tail: tail)
            }
          }
        } catch {
          failure = error.localizedDescription
          Self.log("probe \(m.displayName)(\(m.blinkdConfig != nil ? "blinkd" : "ssh")) 失败: \(error)")
        }
        let s = sessions, r = roles, f = failure
        await MainActor.run { [weak self] in
          self?.applyMachine(machineId: m.id, sessions: s, roles: r, failure: f, gen: gen)
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

  // MARK: GLM 总结（在做/等你/上次）

  /// 同一段尾部内容只总结一次（跨刷新复用）
  private static var summaryCache: [String: TeamSummary] = [:]

  /// 复用语音清理的 GLM 配置（key/model/endpoint 都在 AITextPolisher）
  private func summarize(tabKey: UUID, session: String, tail: String, gen: Int) {
    let cacheKey = "\(session)|\(tail.hashValue)"
    if let hit = Self.summaryCache[cacheKey] {
      applySummary(tabKey: tabKey, hit, gen: gen)
      return
    }
    let apiKey = AITextPolisher.shared.apiKey
    guard !apiKey.isEmpty, let url = URL(string: AITextPolisher.shared.baseURL) else { return }
    let system = """
    你是终端里 Claude Code 员工会话的状态总结器。输入是会话屏幕最近的输出（已滤掉界面元素）。
    只输出严格 JSON（不要 markdown 代码块），格式：
    {"doing":"现在正在做的事","waiting":"正在等用户拍板/回复的具体事项，没有则空字符串","last":"最近一件已完成的事，没有则空字符串"}
    每个字段中文、不超过 22 字、口语直白、能让老板一眼看懂。分不清就把最后一段话概括进 doing。
    """
    let payload: [String: Any] = [
      "model": AITextPolisher.shared.model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": String(tail.suffix(3500))],
      ],
      "temperature": 0.2,
      "stream": false,
    ]
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 20
    req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
      guard let data,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else { return }
      var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.hasPrefix("```") {
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard let jd = text.data(using: .utf8),
            let j = try? JSONSerialization.jsonObject(with: jd) as? [String: String] else { return }
      let sm = TeamSummary(doing: j["doing"] ?? "", waiting: j["waiting"] ?? "", last: j["last"] ?? "")
      guard !(sm.doing.isEmpty && sm.waiting.isEmpty && sm.last.isEmpty) else { return }
      DispatchQueue.main.async {
        Self.summaryCache[cacheKey] = sm
        self?.applySummary(tabKey: tabKey, sm, gen: gen)
      }
    }.resume()
  }

  private func applySummary(tabKey: UUID, _ sm: TeamSummary, gen: Int) {
    guard gen == probeGeneration else { return }
    for gi in groups.indices {
      for ri in groups[gi].rows.indices where groups[gi].rows[ri].tabKey == tabKey {
        groups[gi].rows[ri].summary = sm
      }
    }
    tableView.reloadData()
  }

  /// 「等你 xx / 在做 xx / 上次 xx」的富文本（等你排最前、橙色；上次灰字）
  fileprivate static func summaryAttributed(_ sm: TeamSummary) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let boldFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    func append(_ tag: String, _ body: String, tagColor: UIColor, bodyColor: UIColor, bold: Bool = false) {
      guard !body.isEmpty else { return }
      if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
      out.append(NSAttributedString(string: tag + " ", attributes: [.font: boldFont, .foregroundColor: tagColor]))
      out.append(NSAttributedString(string: body, attributes: [.font: bold ? boldFont : font, .foregroundColor: bodyColor]))
    }
    let wait = TeamWorkStatus.wait.color
    append("等你", sm.waiting, tagColor: wait, bodyColor: wait, bold: true)
    append("在做", sm.doing, tagColor: UIColor.white.withAlphaComponent(0.45),
           bodyColor: UIColor.white.withAlphaComponent(0.85))
    append("上次", sm.last, tagColor: UIColor.white.withAlphaComponent(0.3),
           bodyColor: UIColor(red: 0.545, green: 0.584, blue: 0.647, alpha: 1))
    return out
  }

  /// 探测日志落 Documents/teamstatus.log，真机排查用（afc 可拉）
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

  private static let shellNames: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]

  /// 单台机器结果落地：只动这台机器的行，别台照旧（可能还在探测中）
  private func applyMachine(machineId: String, sessions: [String: (pc: String, idle: Int, line: String, tail: String)],
                            roles: [String: String], failure: String?, gen: Int) {
    guard gen == probeGeneration else { return }   // 旧一轮的迟到结果直接丢
    pendingMachines.remove(machineId)
    if failure == nil { probeReachedCount += 1 }
    if !roles.isEmpty { roleMap.merge(roles) { _, new in new } }

    for gi in groups.indices {
      if groups[gi].role == nil { groups[gi].role = roleMap[groups[gi].employee.lowercased()] }
      guard groups[gi].machineId == machineId else { continue }
      for ri in groups[gi].rows.indices {
        guard let tab = tabs.first(where: { $0.tabKey == groups[gi].rows[ri].tabKey }) else { continue }
        // 机器没够着（不同网/不在线）≠ 会话不存在，别误报「会话未启动」；带上具体报错好排查
        if let err = failure {
          groups[gi].rows[ri].status = .idle
          groups[gi].rows[ri].desc = "探测失败: \(String(err.prefix(90)))"
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
        // claude 活着且没休息的行,后台让 GLM 总结「在做/等你/上次」(同尾部内容有缓存)
        if st != .idle, !groups[gi].rows[ri].resting, !s.tail.isEmpty {
          summarize(tabKey: tab.tabKey, session: tab.outerSession, tail: s.tail, gen: gen)
        }
      }
    }

    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    if pendingMachines.isEmpty {
      subtitleLabel.text = probeReachedCount == probeMachinesTotal
        ? "更新 \(f.string(from: Date())) · \(probeMachinesTotal) 台机器"
        : "更新 \(f.string(from: Date())) · \(probeReachedCount)/\(probeMachinesTotal) 台机器可达"
      tableView.refreshControl?.endRefreshing()
    } else {
      subtitleLabel.text = "已回 \(probeMachinesTotal - pendingMachines.count)/\(probeMachinesTotal) 台，其余探测中…"
    }
    updateStats()
    tableView.reloadData()
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
    e.row.effective
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
      cell.onRowTap = { [weak self] key in self?.jumpToTab(key) }
      cell.onRowToggle = { [weak self] key, toRest in self?.toggleRest(tabKey: key, toRest: toRest) }
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
      guard g.status != .rest else { return }   // 全休息的员工卡:点了不跳 tab(用胶囊叫回来)
      let active = g.rows.filter { !$0.resting }
      key = (active.first { $0.status == .wait } ?? active.first)?.tabKey
    } else {
      let e = projectSections[indexPath.section].items[indexPath.row]
      guard memberStatus(e) != .rest else { return }   // 休息中的成员行同样不跳
      key = e.row.tabKey
    }
    guard let k = key else { return }
    jumpToTab(k)
  }

  private func jumpToTab(_ key: UUID) {
    dismiss(animated: true) { [onOpenTab] in onOpenTab?(key) }
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
    var onRowTap: ((UUID) -> Void)?
    var onRowToggle: ((UUID, Bool) -> Void)?     // (tabKey, 切到休息?) 行尾月亮开关
    private var rowInfoByTag: [Int: (key: UUID, resting: Bool)] = [:]
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

    @objc private func rowTapped(_ gr: UITapGestureRecognizer) {
      guard let v = gr.view, let info = rowInfoByTag[v.tag], !info.resting else { return }   // 休息行原地吞掉
      onRowTap?(info.key)
    }

    @objc private func rowToggleTapped(_ b: UIButton) {
      guard let info = rowInfoByTag[b.tag] else { return }
      onRowToggle?(info.key, !info.resting)
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
      nameLabel.text = g.employee
      roleChip.text = g.role
      roleChip.isHidden = (g.role ?? "").isEmpty
      let restCount = g.rows.filter(\.resting).count
      machineLabel.text = restCount > 0 && restCount < g.rows.count
        ? "\(g.machineName) · \(g.rows.count - restCount) 在岗 · \(restCount) 休息"
        : "\(g.machineName) · \(g.rows.count) 个会话"
      pill.apply(st)

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
          // 在岗：按自己的状态上彩色底（橙=等你 绿=干活 灰=空闲）
          line.backgroundColor = r.status.color.withAlphaComponent(0.13)
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
        if r.resting {
          pd.text = "休息中"
        } else if let sm = r.summary {
          pd.attributedText = TeamStatusViewController.summaryAttributed(sm)
        } else {
          pd.text = r.probed ? r.desc : "探测中…"
        }
        pd.lineBreakMode = .byTruncatingTail
        let sw = UIButton(type: .system)
        sw.tag = i
        sw.setImage(UIImage(systemName: r.resting ? "moon.zzz.fill" : "moon",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        sw.tintColor = r.resting ? TeamWorkStatus.rest.color : UIColor.white.withAlphaComponent(0.4)
        sw.addTarget(self, action: #selector(rowToggleTapped(_:)), for: .touchUpInside)
        sw.setContentHuggingPriority(.required, for: .horizontal)
        sw.setContentCompressionResistancePriority(.required, for: .horizontal)
        let h = UIStackView(arrangedSubviews: [pn, pd, sw])
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
      card.backgroundColor = status == .rest
        ? UIColor.white.withAlphaComponent(0.02)
        : status.color.withAlphaComponent(0.13)
      card.alpha = status == .rest ? 0.55 : 1
      avatarView.image = g.avatar ?? TeamStatusViewController.initialAvatar(for: g.employee, size: 24)
      nameLabel.text = g.employee
      roleChip.text = g.role
      roleChip.isHidden = (g.role ?? "").isEmpty
      descLabel.textColor = sub
      descLabel.numberOfLines = 0
      if status == .rest {
        descLabel.text = "休息中"
      } else if let sm = r.summary {
        descLabel.attributedText = TeamStatusViewController.summaryAttributed(sm)
      } else {
        descLabel.text = r.probed ? r.desc : "探测中…"
      }
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
