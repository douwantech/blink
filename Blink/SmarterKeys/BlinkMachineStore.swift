import UIKit

final class BlinkMachine: Codable {
  let id: String
  var name: String
  var host: String
  var lanHost: String?
  var user: String

  init(id: String = UUID().uuidString, name: String = "", host: String, lanHost: String? = nil, user: String) {
    self.id = id
    self.name = name
    self.host = host
    self.lanHost = lanHost
    self.user = user
  }

  var displayName: String {
    name.isEmpty ? "\(user)@\(host)" : name
  }
}

enum HostReachability {
  private struct Cached { let reachable: Bool; let ts: Date }
  private static var cache: [String: Cached] = [:]
  private static let lock = NSLock()
  private static let ttl: TimeInterval = 30
  static let defaultTimeout: TimeInterval = 0.3

  static func isReachable(host: String, port: UInt16 = 22, timeout: TimeInterval = defaultTimeout) -> Bool {
    let key = "\(host):\(port)"
    let now = Date()
    lock.lock()
    if let c = cache[key], now.timeIntervalSince(c.ts) < ttl {
      lock.unlock()
      return c.reachable
    }
    lock.unlock()
    let ok = probe(host: host, port: port, timeout: timeout)
    lock.lock(); cache[key] = Cached(reachable: ok, ts: now); lock.unlock()
    return ok
  }

  static func invalidate() {
    lock.lock(); cache.removeAll(); lock.unlock()
  }

  private static func probe(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
    var hints = addrinfo(
      ai_flags: AI_NUMERICSERV,
      ai_family: AF_UNSPEC,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>? = nil
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
      return false
    }
    defer { freeaddrinfo(res) }
    for ai in sequence(first: first.pointee, next: { $0.ai_next?.pointee }) {
      if tryConnect(ai: ai, timeout: timeout) { return true }
    }
    return false
  }

  private static func tryConnect(ai: addrinfo, timeout: TimeInterval) -> Bool {
    let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
    if fd < 0 { return false }
    defer { close(fd) }
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let r = connect(fd, ai.ai_addr, ai.ai_addrlen)
    if r == 0 { return true }
    if errno != EINPROGRESS { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let n = poll(&pfd, 1, Int32(timeout * 1000))
    if n <= 0 { return false }
    if (pfd.revents & Int16(POLLOUT)) == 0 { return false }
    var sockErr: Int32 = 0
    var len: socklen_t = socklen_t(MemoryLayout<Int32>.size)
    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &len) < 0 { return false }
    return sockErr == 0
  }
}

@objc final class BlinkMachineStore: NSObject {
  @objc static let shared = BlinkMachineStore()

  private let kMachines = "BlinkMachineStore.machines"

  private override init() { super.init() }

  var machines: [BlinkMachine] {
    get {
      guard let data = UserDefaults.standard.data(forKey: kMachines),
            let arr = try? JSONDecoder().decode([BlinkMachine].self, from: data) else {
        return []
      }
      return arr
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: kMachines)
      }
    }
  }

  var currentMachine: BlinkMachine? { machines.first }

  @objc var hasAnyMachine: Bool { !machines.isEmpty }

  @objc func currentSshCommand(tmuxSession: String?) -> String? {
    sshCommand(forMachineId: nil, tmuxSession: tmuxSession)
  }

  @objc func sshCommand(forMachineId machineId: String?, tmuxSession: String?) -> String? {
    sshCommand(forMachineId: machineId, workDirId: nil, tmuxSession: tmuxSession)
  }

  @objc func sshCommand(forMachineId machineId: String?, workDirId: String?, tmuxSession: String?) -> String? {
    let arr = machines
    let m: BlinkMachine?
    if let id = machineId, let found = arr.first(where: { $0.id == id }) {
      m = found
    } else {
      m = currentMachine
    }
    guard let m else { return nil }

    let workPath = BlinkWorkDirStore.shared.workDir(forId: workDirId)?.path

    var session = Self.effectiveTmuxSessionName(workDirId: workDirId, tmuxSession: tmuxSession)
    session = session.replacingOccurrences(of: "\"", with: "\\\"")

    let detectSock = #"S=$(sh -c 'for p in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null) $TMPDIR/com.apple.launchd.*/Listeners /private/tmp/com.apple.launchd.*/Listeners $HOME/.ssh/agent.sock; do [ -S $p ] && { echo $p; break; }; done'); echo $(date) S=$S >> /tmp/blink-detect.log 2>/dev/null; case x$S in x) ;; *) export SSH_AUTH_SOCK=$S; tmux set-environment -g SSH_AUTH_SOCK $S 2>/dev/null;; esac;"#
    let tmuxCmd = "\(detectSock) PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin tmux new-session -A -s \(session)"
    let remoteCmd: String
    if let p = workPath, !p.isEmpty {
      let escaped = p.replacingOccurrences(of: "\"", with: "\\\"")
      remoteCmd = "cd \(escaped) && \(tmuxCmd)"
    } else {
      remoteCmd = tmuxCmd
    }
    return "ssh -t \(m.user)@\(Self.bestHost(for: m)) \"\(remoteCmd)\""
  }

  static func bestHost(for m: BlinkMachine) -> String {
    let lan = (m.lanHost ?? "").trimmingCharacters(in: .whitespaces)
    if lan.isEmpty { return m.host }
    return HostReachability.isReachable(host: lan) ? lan : m.host
  }

  @objc static func effectiveTmuxSessionName(workDirId: String?, tmuxSession: String?) -> String {
    if let s = tmuxSession, !s.isEmpty { return s }
    if let wid = workDirId, !wid.isEmpty { return "blink-\(wid.prefix(8))" }
    return "blink"
  }

  @objc func machineExists(forId machineId: String?) -> Bool {
    guard let id = machineId else { return false }
    return machines.contains { $0.id == id }
  }

  @objc var currentMachineId: String? { machines.first?.id }

  func addOrUpdate(_ machine: BlinkMachine) {
    var arr = machines
    if let idx = arr.firstIndex(where: { $0.id == machine.id }) {
      arr[idx] = machine
    } else {
      arr.append(machine)
    }
    machines = arr
  }

  func delete(id: String) {
    machines.removeAll { $0.id == id }
  }

  @objc static func presentAddMachineIfNeeded() {
    guard !shared.hasAnyMachine else { return }
    DispatchQueue.main.async {
      presentMachineList()
    }
  }

  @objc static func presentMachineList() {
    let scenes = UIApplication.shared.connectedScenes
    guard let window = scenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
    var top = window.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    let list = MachineListViewController()
    let nav = UINavigationController(rootViewController: list)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    top?.present(nav, animated: true)
  }
}

final class MachineListViewController: UITableViewController {
  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "机器"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(closeTapped)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .add, target: self, action: #selector(addTapped)
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }

  override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    BlinkMachineStore.shared.machines.count
  }

  override func tableView(_ tv: UITableView, titleForFooterInSection section: Int) -> String? {
    "点选机器进入编辑/删除。列表第一项即新建标签页的默认机器。\nAutoMac 公钥：\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGEpZhB+3m9GZYDzN3vi7cotb/32yyGMe3rp2/aHvZz0 blink-sim"
  }

  override func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let m = BlinkMachineStore.shared.machines[indexPath.row]
    cell.textLabel?.text = m.displayName
    cell.detailTextLabel?.text = "\(m.user)@\(m.host)"
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.accessoryType = .detailButton
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: true)
    let m = BlinkMachineStore.shared.machines[indexPath.row]
    pushForm(editing: m)
  }

  override func tableView(_ tv: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
    let m = BlinkMachineStore.shared.machines[indexPath.row]
    pushForm(editing: m)
  }

  @objc private func closeTapped() { dismiss(animated: true) }

  @objc private func addTapped() {
    pushForm(editing: nil)
  }

  private func pushForm(editing machine: BlinkMachine?) {
    let form = MachineFormViewController(editing: machine)
    navigationController?.pushViewController(form, animated: true)
  }
}

final class MachineFormViewController: UITableViewController, UITextFieldDelegate {
  private var machine: BlinkMachine
  private let isNew: Bool

  private let nameField = UITextField()
  private let hostField = UITextField()
  private let lanHostField = UITextField()
  private let userField = UITextField()

  init(editing machine: BlinkMachine?) {
    if let m = machine {
      self.machine = m
      self.isNew = false
    } else {
      self.machine = BlinkMachine(host: "", user: "")
      self.isNew = true
    }
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = isNew ? "添加机器" : "编辑机器"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .save, target: self, action: #selector(saveTapped)
    )

    configureField(nameField, placeholder: "可选，留空显示 user@host", value: machine.name, returnKey: .next, keyboard: .default)
    configureField(hostField, placeholder: "外网/Tailscale，如 mac.tail.ts.net", value: machine.host, returnKey: .next, keyboard: .URL)
    configureField(lanHostField, placeholder: "可选，局域网 IP，如 192.168.1.10", value: machine.lanHost ?? "", returnKey: .next, keyboard: .URL)
    configureField(userField, placeholder: "apple", value: machine.user, returnKey: .done, keyboard: .default)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if isNew {
      hostField.becomeFirstResponder()
    }
  }

  private func configureField(_ tf: UITextField, placeholder: String, value: String, returnKey: UIReturnKeyType, keyboard: UIKeyboardType) {
    tf.placeholder = placeholder
    tf.text = value
    tf.autocapitalizationType = .none
    tf.autocorrectionType = .no
    tf.spellCheckingType = .no
    tf.returnKeyType = returnKey
    tf.keyboardType = keyboard
    tf.delegate = self
    tf.clearButtonMode = .whileEditing
  }

  override func numberOfSections(in tv: UITableView) -> Int { isNew ? 1 : 2 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 4 : 1
  }
  override func tableView(_ tv: UITableView, titleForFooterInSection section: Int) -> String? {
    guard section == 0 else { return nil }
    return "填写内网主机后，连接时优先尝试内网（300ms 探测），不可达自动回退外网。\n登录使用 AutoMac 内置 SSH key。如需免密，把 AutoMac 公钥加到目标机器的 ~/.ssh/authorized_keys。"
  }

  override func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.section == 1 {
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      cell.textLabel?.text = "删除机器"
      cell.textLabel?.textColor = .systemRed
      cell.textLabel?.textAlignment = .center
      return cell
    }
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    cell.selectionStyle = .none
    let (label, field): (String, UITextField) = {
      switch indexPath.row {
      case 0: return ("名称", nameField)
      case 1: return ("外网", hostField)
      case 2: return ("内网", lanHostField)
      case 3: return ("用户", userField)
      default: return ("", UITextField())
      }
    }()
    let titleLabel = UILabel()
    titleLabel.text = label
    titleLabel.font = .systemFont(ofSize: 16)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    field.translatesAutoresizingMaskIntoConstraints = false
    field.font = .systemFont(ofSize: 16)
    cell.contentView.addSubview(titleLabel)
    cell.contentView.addSubview(field)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
      titleLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
      titleLabel.widthAnchor.constraint(equalToConstant: 60),

      field.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
      field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
      field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
      field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
    ])
    return cell
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === nameField { hostField.becomeFirstResponder() }
    else if textField === hostField { lanHostField.becomeFirstResponder() }
    else if textField === lanHostField { userField.becomeFirstResponder() }
    else { saveTapped() }
    return false
  }

  override func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: true)
    guard indexPath.section == 1 else { return }
    let alert = UIAlertController(title: "删除机器？", message: machine.displayName, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      guard let self else { return }
      BlinkMachineStore.shared.delete(id: self.machine.id)
      HostReachability.invalidate()
      self.navigationController?.popViewController(animated: true)
    })
    present(alert, animated: true)
  }

  @objc private func saveTapped() {
    let host = (hostField.text ?? "").trimmingCharacters(in: .whitespaces)
    let lan = (lanHostField.text ?? "").trimmingCharacters(in: .whitespaces)
    let user = (userField.text ?? "").trimmingCharacters(in: .whitespaces)
    let name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
    if host.isEmpty || user.isEmpty {
      let alert = UIAlertController(title: "缺少字段", message: "外网主机和用户必填", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "确定", style: .default))
      present(alert, animated: true)
      return
    }
    machine.name = name
    machine.host = host
    machine.lanHost = lan.isEmpty ? nil : lan
    machine.user = user
    BlinkMachineStore.shared.addOrUpdate(machine)
    HostReachability.invalidate()
    navigationController?.popViewController(animated: true)
  }
}

@objc protocol BlinkTabBarDelegate: AnyObject {
  func tabBarDidSelect(index: Int)
  func tabBarDidRequestNew()
  func tabBarDidRequestClose(index: Int)
  func tabBarDidRequestSettings()
  func tabBarDidRequestMachineFilter()
}

final class HorizontalOnlyScrollView: UIScrollView {
  override func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
    if gr === panGestureRecognizer, let pan = gr as? UIPanGestureRecognizer {
      let v = pan.velocity(in: self)
      if abs(v.y) > abs(v.x) { return false }
    }
    return super.gestureRecognizerShouldBegin(gr)
  }
}

@objc final class BlinkTabBar: UIView {
  @objc weak var delegate: BlinkTabBarDelegate?

  private let scrollView = HorizontalOnlyScrollView()
  private let stack = UIStackView()
  private let rowsStack = UIStackView()
  private let topRow = UIView()
  private let addButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private let filterChipButton = UIButton(type: .system)

  @objc init() {
    super.init(frame: .zero)
    setupUI()
  }
  required init?(coder: NSCoder) { fatalError() }

  private func setupUI() {
    backgroundColor = UIColor(white: 0.12, alpha: 1.0)

    settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
    settingsButton.tintColor = .systemBlue
    settingsButton.translatesAutoresizingMaskIntoConstraints = false
    settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

    addButton.setImage(UIImage(systemName: "plus"), for: .normal)
    addButton.tintColor = .systemBlue
    addButton.translatesAutoresizingMaskIntoConstraints = false
    addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

    var chipCfg = UIButton.Configuration.plain()
    chipCfg.title = "全部"
    chipCfg.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
    chipCfg.imagePadding = 4
    chipCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 10)
    chipCfg.baseForegroundColor = .systemTeal
    filterChipButton.configuration = chipCfg
    filterChipButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    filterChipButton.layer.cornerRadius = 6
    filterChipButton.layer.borderWidth = 1
    filterChipButton.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.5).cgColor
    filterChipButton.translatesAutoresizingMaskIntoConstraints = false
    filterChipButton.addTarget(self, action: #selector(filterTapped), for: .touchUpInside)

    topRow.translatesAutoresizingMaskIntoConstraints = false
    topRow.addSubview(settingsButton)
    topRow.addSubview(filterChipButton)
    topRow.addSubview(addButton)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsHorizontalScrollIndicator = false
    stack.axis = .horizontal
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stack)

    rowsStack.axis = .vertical
    rowsStack.spacing = 2
    rowsStack.translatesAutoresizingMaskIntoConstraints = false
    rowsStack.addArrangedSubview(topRow)
    rowsStack.addArrangedSubview(scrollView)
    addSubview(rowsStack)

    NSLayoutConstraint.activate([
      settingsButton.leadingAnchor.constraint(equalTo: topRow.leadingAnchor, constant: 8),
      settingsButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      settingsButton.widthAnchor.constraint(equalToConstant: 32),
      settingsButton.heightAnchor.constraint(equalToConstant: 28),

      filterChipButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 6),
      filterChipButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      filterChipButton.heightAnchor.constraint(equalToConstant: 26),

      addButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: -8),
      addButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 32),
      addButton.heightAnchor.constraint(equalToConstant: 28),

      topRow.heightAnchor.constraint(equalToConstant: 28),

      rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
      stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])
  }

  @objc private func settingsTapped() {
    delegate?.tabBarDidRequestSettings()
  }

  @objc func reload(titles: [String], unread: [Bool], currentIndex: Int) {
    reload(titles: titles, unread: unread, tags: Array(0..<titles.count), filterTitle: nil, currentTag: currentIndex)
  }

  @objc func reload(titles: [String], unread: [Bool], tags: [Int], filterTitle: String?, currentTag: Int) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

    var newCfg = filterChipButton.configuration
    newCfg?.title = filterTitle ?? "全部"
    filterChipButton.configuration = newCfg

    var visibleIndexOfCurrent = -1
    for (i, title) in titles.enumerated() {
      let isUnread = i < unread.count && unread[i]
      let tag = i < tags.count ? tags[i] : i
      let btn = makeTabButton(title: title, index: tag, isCurrent: tag == currentTag, hasUnread: isUnread)
      if tag == currentTag { visibleIndexOfCurrent = i }
      stack.addArrangedSubview(btn)
    }
    layoutIfNeeded()
    if visibleIndexOfCurrent >= 0 {
      scrollToVisibleTab(at: visibleIndexOfCurrent, animated: true)
    }
  }

  private func scrollToVisibleTab(at visibleIndex: Int, animated: Bool) {
    guard stack.arrangedSubviews.indices.contains(visibleIndex) else { return }
    let btn = stack.arrangedSubviews[visibleIndex]
    let frameInScroll = btn.convert(btn.bounds, to: scrollView)
    let pad: CGFloat = 24
    let target = frameInScroll.insetBy(dx: -pad, dy: 0)
    scrollView.scrollRectToVisible(target, animated: animated)
  }

  @objc private func filterTapped() {
    delegate?.tabBarDidRequestMachineFilter()
  }

  private func makeTabButton(title: String, index: Int, isCurrent: Bool, hasUnread: Bool) -> UIButton {
    var cfg = UIButton.Configuration.plain()
    cfg.title = title
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: hasUnread ? 18 : 12)
    cfg.baseForegroundColor = isCurrent ? .label : .secondaryLabel
    let btn = UIButton(configuration: cfg)
    btn.titleLabel?.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
    btn.layer.cornerRadius = 6
    btn.layer.masksToBounds = false
    btn.backgroundColor = isCurrent ? UIColor.systemBlue.withAlphaComponent(0.18) : .clear
    btn.tag = index
    btn.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(tabLongPressed(_:)))
    longPress.minimumPressDuration = 0.4
    btn.addGestureRecognizer(longPress)
    if hasUnread {
      let dot = UIView()
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.backgroundColor = .systemRed
      dot.layer.cornerRadius = 4
      dot.isUserInteractionEnabled = false
      btn.addSubview(dot)
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 8),
        dot.heightAnchor.constraint(equalToConstant: 8),
        dot.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -4),
        dot.topAnchor.constraint(equalTo: btn.topAnchor, constant: 4),
      ])
    }
    return btn
  }

  @objc private func tabTapped(_ sender: UIButton) {
    delegate?.tabBarDidSelect(index: sender.tag)
  }

  @objc private func tabLongPressed(_ rec: UILongPressGestureRecognizer) {
    guard rec.state == .began, let btn = rec.view as? UIButton else { return }
    delegate?.tabBarDidRequestClose(index: btn.tag)
  }

  @objc private func addTapped() {
    delegate?.tabBarDidRequestNew()
  }
}

// MARK: - WorkDir

final class BlinkWorkDir: Codable {
  let id: String
  var name: String
  var path: String

  init(id: String = UUID().uuidString, name: String = "", path: String) {
    self.id = id
    self.name = name
    self.path = path
  }

  var displayName: String {
    name.isEmpty ? path : name
  }
}

@objc final class BlinkWorkDirStore: NSObject {
  @objc static let shared = BlinkWorkDirStore()
  private let kKey = "BlinkWorkDirStore.workDirs"

  private override init() {
    super.init()
    let seeds: [BlinkWorkDir] = [
      BlinkWorkDir(id: "seed-blink", name: "blink", path: "/Users/apple/Codes/IPHONE/blink"),
      BlinkWorkDir(id: "seed-talkai", name: "talkAI", path: "/Users/apple/Codes/IPHONE/talkai"),
    ]
    if let data = try? JSONEncoder().encode(seeds) {
      UserDefaults.standard.register(defaults: [kKey: data])
    }
  }

  var workDirs: [BlinkWorkDir] {
    get {
      guard let data = UserDefaults.standard.data(forKey: kKey),
            let arr = try? JSONDecoder().decode([BlinkWorkDir].self, from: data) else {
        return []
      }
      return arr
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: kKey)
      }
    }
  }

  func workDir(forId id: String?) -> BlinkWorkDir? {
    guard let id else { return nil }
    return workDirs.first { $0.id == id }
  }

  func addOrUpdate(_ wd: BlinkWorkDir) {
    var arr = workDirs
    if let idx = arr.firstIndex(where: { $0.id == wd.id }) {
      arr[idx] = wd
    } else {
      arr.append(wd)
    }
    workDirs = arr
  }

  func delete(id: String) {
    workDirs.removeAll { $0.id == id }
  }

  @discardableResult
  func duplicate(id: String) -> BlinkWorkDir? {
    var arr = workDirs
    guard let src = arr.first(where: { $0.id == id }) else { return nil }
    let copy = BlinkWorkDir(name: src.name.isEmpty ? "" : "\(src.name) 副本", path: src.path)
    if let idx = arr.firstIndex(where: { $0.id == id }) {
      arr.insert(copy, at: idx + 1)
    } else {
      arr.append(copy)
    }
    workDirs = arr
    return copy
  }
}

final class WorkDirListViewController: UITableViewController {
  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "工作目录"
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped))
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    BlinkWorkDirStore.shared.workDirs.count
  }
  override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
    "新建标签时可选这里的目录，ssh 后会先 cd 进去再起 tmux。"
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let wd = BlinkWorkDirStore.shared.workDirs[ip.row]
    cell.textLabel?.text = wd.displayName
    cell.detailTextLabel?.text = wd.path
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.accessoryType = .detailButton
    return cell
  }

  override func tableView(_ tv: UITableView, accessoryButtonTappedForRowWith ip: IndexPath) {
    let wd = BlinkWorkDirStore.shared.workDirs[ip.row]
    let form = WorkDirFormViewController(editing: wd)
    navigationController?.pushViewController(form, animated: true)
  }

  override func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
    if editingStyle == .delete {
      let wd = BlinkWorkDirStore.shared.workDirs[ip.row]
      BlinkWorkDirStore.shared.delete(id: wd.id)
      tv.deleteRows(at: [ip], with: .automatic)
    }
  }

  override func tableView(_ tv: UITableView, leadingSwipeActionsConfigurationForRowAt ip: IndexPath) -> UISwipeActionsConfiguration? {
    let wd = BlinkWorkDirStore.shared.workDirs[ip.row]
    let dup = UIContextualAction(style: .normal, title: "复制") { [weak self] _, _, done in
      guard let self else { done(false); return }
      let copy = BlinkWorkDirStore.shared.duplicate(id: wd.id)
      tv.reloadData()
      done(true)
      if let copy {
        self.navigationController?.pushViewController(WorkDirFormViewController(editing: copy), animated: true)
      }
    }
    dup.backgroundColor = .systemBlue
    dup.image = UIImage(systemName: "doc.on.doc")
    let copyPath = UIContextualAction(style: .normal, title: "复制路径") { _, _, done in
      UIPasteboard.general.string = wd.path
      done(true)
    }
    copyPath.backgroundColor = .systemGray
    copyPath.image = UIImage(systemName: "doc.on.clipboard")
    return UISwipeActionsConfiguration(actions: [dup, copyPath])
  }

  @objc private func addTapped() {
    let form = WorkDirFormViewController(editing: nil)
    navigationController?.pushViewController(form, animated: true)
  }
}

final class WorkDirFormViewController: UITableViewController, UITextFieldDelegate {
  private var wd: BlinkWorkDir
  private let isNew: Bool
  private let nameField = UITextField()
  private let pathField = UITextField()
  var onSaved: ((BlinkWorkDir) -> Void)?

  init(editing wd: BlinkWorkDir?) {
    if let wd {
      self.wd = wd
      self.isNew = false
    } else {
      self.wd = BlinkWorkDir(path: "")
      self.isNew = true
    }
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = isNew ? "添加工作目录" : "编辑工作目录"
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

    [nameField, pathField].forEach {
      $0.autocapitalizationType = .none
      $0.autocorrectionType = .no
      $0.spellCheckingType = .no
      $0.delegate = self
      $0.font = .systemFont(ofSize: 16)
      $0.translatesAutoresizingMaskIntoConstraints = false
      $0.clearButtonMode = .whileEditing
    }
    nameField.placeholder = "可选名称（如 blink）"
    nameField.text = wd.name
    nameField.returnKeyType = .next
    pathField.placeholder = "/Users/apple/Codes/blink 或 ~/Codes/blink"
    pathField.text = wd.path
    pathField.returnKeyType = .done
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if isNew { pathField.becomeFirstResponder() }
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { 2 }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    cell.selectionStyle = .none
    let (label, field): (String, UITextField) = ip.row == 0 ? ("名称", nameField) : ("路径", pathField)
    let titleLabel = UILabel()
    titleLabel.text = label
    titleLabel.font = .systemFont(ofSize: 16)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    cell.contentView.addSubview(titleLabel)
    cell.contentView.addSubview(field)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
      titleLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
      titleLabel.widthAnchor.constraint(equalToConstant: 60),
      field.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
      field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
      field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
      field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
    ])
    return cell
  }

  func textFieldShouldReturn(_ tf: UITextField) -> Bool {
    if tf === nameField { pathField.becomeFirstResponder() } else { saveTapped() }
    return false
  }

  @objc private func saveTapped() {
    let path = (pathField.text ?? "").trimmingCharacters(in: .whitespaces)
    if path.isEmpty {
      let a = UIAlertController(title: "缺少字段", message: "路径必填", preferredStyle: .alert)
      a.addAction(UIAlertAction(title: "确定", style: .default))
      present(a, animated: true)
      return
    }
    wd.name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
    wd.path = path
    BlinkWorkDirStore.shared.addOrUpdate(wd)
    onSaved?(wd)
    navigationController?.popViewController(animated: true)
  }
}

final class BlinkSessionPreset: Codable {
  let id: String
  var machineId: String
  var workDirId: String?
  var baseName: String

  init(id: String = UUID().uuidString, machineId: String, workDirId: String?, baseName: String) {
    self.id = id
    self.machineId = machineId
    self.workDirId = workDirId
    self.baseName = baseName
  }

  var sessionName: String {
    let m = BlinkMachineStore.shared.machines.first { $0.id == machineId }
    let w = workDirId.flatMap { id in BlinkWorkDirStore.shared.workDirs.first { $0.id == id } }
    let mPart = BlinkSessionPreset.sanitize(m.flatMap { $0.name.isEmpty ? $0.user : $0.name } ?? "x")
    let wPart = BlinkSessionPreset.sanitize(w.map { ($0.path as NSString).lastPathComponent } ?? "home")
    let bPart = BlinkSessionPreset.sanitize(baseName.isEmpty ? "blink" : baseName)
    return "\(mPart)-\(wPart)-\(bPart)"
  }

  private static func sanitize(_ s: String) -> String {
    s
      .replacingOccurrences(of: ":", with: "_")
      .replacingOccurrences(of: ".", with: "_")
      .replacingOccurrences(of: " ", with: "_")
  }

  var displayTitle: String {
    let m = BlinkMachineStore.shared.machines.first { $0.id == machineId }
    let w = workDirId.flatMap { id in BlinkWorkDirStore.shared.workDirs.first { $0.id == id } }
    let mName: String = m.flatMap { $0.name.isEmpty ? $0.user : $0.name } ?? "?"
    let wName: String = w.map { ($0.path as NSString).lastPathComponent } ?? "home"
    let base = baseName.isEmpty ? "blink" : baseName
    return "\(base) · \(mName)/\(wName)"
  }
}

@objc final class BlinkSessionPresetStore: NSObject {
  @objc static let shared = BlinkSessionPresetStore()
  private let kKey = "BlinkSessionPresetStore.presets"

  private override init() { super.init() }

  var presets: [BlinkSessionPreset] {
    get {
      guard let data = UserDefaults.standard.data(forKey: kKey),
            let arr = try? JSONDecoder().decode([BlinkSessionPreset].self, from: data) else {
        return []
      }
      return arr
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: kKey)
      }
    }
  }

  @discardableResult
  func upsert(machineId: String, workDirId: String?, baseName: String) -> BlinkSessionPreset {
    let cleanBase = baseName.trimmingCharacters(in: .whitespaces)
    var arr = presets
    if let existing = arr.first(where: { $0.machineId == machineId && $0.workDirId == workDirId && $0.baseName == cleanBase }) {
      return existing
    }
    let p = BlinkSessionPreset(machineId: machineId, workDirId: workDirId, baseName: cleanBase)
    arr.append(p)
    presets = arr
    return p
  }

  func delete(id: String) {
    presets.removeAll { $0.id == id }
  }
}

final class NewTabViewController: UITableViewController {
  private var machineId: String?
  private var workDirId: String?
  private var tmuxName: String?
  var onCreate: ((String, String?, String?) -> Void)?
  var customTitle: String = "新建标签"
  var actionTitle: String = "创建"

  init(machineId: String? = nil, workDirId: String? = nil, tmuxName: String? = nil) {
    super.init(style: .insetGrouped)
    self.machineId = machineId ?? BlinkMachineStore.shared.currentMachineId
    self.workDirId = workDirId
    self.tmuxName = tmuxName
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = customTitle
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(closeTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: actionTitle, style: .done, target: self, action: #selector(createTapped))
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 2 }
  override func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
    s == 0 ? "已有会话" : "新建"
  }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    if s == 0 {
      return max(BlinkSessionPresetStore.shared.presets.count, 1)
    }
    return 3
  }
  override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
    s == 1 ? "tmux 会话名：相同名字会 attach 进已存在的会话，否则新建。组合会保存到上方列表。" : nil
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    if ip.section == 0 {
      let presets = BlinkSessionPresetStore.shared.presets
      if presets.isEmpty {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = "暂无（在下方填一组并点 \(actionTitle)）"
        cell.textLabel?.textColor = .secondaryLabel
        cell.textLabel?.font = .systemFont(ofSize: 14)
        cell.selectionStyle = .none
        return cell
      }
      let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
      let p = presets[ip.row]
      cell.textLabel?.text = p.displayTitle
      cell.detailTextLabel?.text = p.sessionName
      cell.detailTextLabel?.textColor = .secondaryLabel
      cell.accessoryType = .disclosureIndicator
      return cell
    }
    let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
    cell.accessoryType = .disclosureIndicator
    switch ip.row {
    case 0:
      cell.textLabel?.text = "机器"
      let m = BlinkMachineStore.shared.machines.first { $0.id == machineId }
      cell.detailTextLabel?.text = m.map { $0.displayName } ?? "（必选）"
      cell.detailTextLabel?.textColor = (m == nil) ? .systemRed : .secondaryLabel
    case 1:
      cell.textLabel?.text = "工作目录"
      let w = BlinkWorkDirStore.shared.workDirs.first { $0.id == workDirId }
      cell.detailTextLabel?.text = w.map { $0.displayName } ?? "（默认 home）"
    case 2:
      cell.textLabel?.text = "tmux 会话"
      cell.detailTextLabel?.text = (tmuxName?.isEmpty == false) ? tmuxName : "（自动 blink）"
    default: break
    }
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    if ip.section == 0 {
      let presets = BlinkSessionPresetStore.shared.presets
      guard !presets.isEmpty, ip.row < presets.count else { return }
      let p = presets[ip.row]
      let cb = onCreate
      dismiss(animated: true) {
        cb?(p.machineId, p.workDirId, p.sessionName)
      }
      return
    }
    switch ip.row {
    case 0:
      let picker = NewTabMachinePickerViewController(currentId: machineId)
      picker.onSelect = { [weak self] id in
        self?.machineId = id
        self?.tableView.reloadData()
      }
      navigationController?.pushViewController(picker, animated: true)
    case 1:
      let picker = NewTabWorkDirPickerViewController(currentId: workDirId)
      picker.onSelect = { [weak self] id in
        self?.workDirId = id
        self?.tableView.reloadData()
      }
      navigationController?.pushViewController(picker, animated: true)
    case 2:
      promptTmuxName()
    default: break
    }
  }

  override func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
    guard editingStyle == .delete, ip.section == 0 else { return }
    let presets = BlinkSessionPresetStore.shared.presets
    guard !presets.isEmpty, ip.row < presets.count else { return }
    BlinkSessionPresetStore.shared.delete(id: presets[ip.row].id)
    tv.reloadData()
  }

  override func tableView(_ tv: UITableView, canEditRowAt ip: IndexPath) -> Bool {
    ip.section == 0 && !BlinkSessionPresetStore.shared.presets.isEmpty
  }

  private func promptTmuxName() {
    let alert = UIAlertController(title: "tmux 会话名", message: "存在则 attach，不存在则新建。留空使用默认。", preferredStyle: .alert)
    alert.addTextField { [weak self] tf in
      tf.text = self?.tmuxName ?? ""
      tf.placeholder = "blink"
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
      tf.spellCheckingType = .no
      tf.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
      let v = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
      self?.tmuxName = v.isEmpty ? nil : v
      self?.tableView.reloadData()
    })
    present(alert, animated: true)
  }

  @objc private func closeTapped() { dismiss(animated: true) }

  @objc private func createTapped() {
    guard let mid = machineId else {
      let a = UIAlertController(title: "请先选机器", message: nil, preferredStyle: .alert)
      a.addAction(UIAlertAction(title: "确定", style: .default))
      present(a, animated: true)
      return
    }
    let preset = BlinkSessionPresetStore.shared.upsert(
      machineId: mid,
      workDirId: workDirId,
      baseName: tmuxName ?? ""
    )
    let cb = onCreate
    dismiss(animated: true) {
      cb?(preset.machineId, preset.workDirId, preset.sessionName)
    }
  }
}

final class NewTabMachinePickerViewController: UITableViewController {
  private let currentId: String?
  var onSelect: ((String) -> Void)?

  init(currentId: String?) {
    self.currentId = currentId
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "选机器"
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    BlinkMachineStore.shared.machines.count
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let m = BlinkMachineStore.shared.machines[ip.row]
    cell.textLabel?.text = m.displayName
    cell.detailTextLabel?.text = "\(m.user)@\(m.host)"
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.accessoryType = (m.id == currentId) ? .checkmark : .none
    return cell
  }
  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    onSelect?(BlinkMachineStore.shared.machines[ip.row].id)
    navigationController?.popViewController(animated: true)
  }
}

final class NewTabWorkDirPickerViewController: UITableViewController {
  private let currentId: String?
  var onSelect: ((String?) -> Void)?

  init(currentId: String?) {
    self.currentId = currentId
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "选工作目录"
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped))
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    BlinkWorkDirStore.shared.workDirs.count + 1  // +1 for "无"
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    if ip.row == 0 {
      cell.textLabel?.text = "（无 / home）"
      cell.detailTextLabel?.text = "不 cd"
      cell.detailTextLabel?.textColor = .secondaryLabel
      cell.accessoryType = (currentId == nil) ? .checkmark : .none
    } else {
      let wd = BlinkWorkDirStore.shared.workDirs[ip.row - 1]
      cell.textLabel?.text = wd.displayName
      cell.detailTextLabel?.text = wd.path
      cell.detailTextLabel?.textColor = .secondaryLabel
      cell.accessoryType = (wd.id == currentId) ? .checkmark : .none
    }
    return cell
  }
  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    if ip.row == 0 {
      onSelect?(nil)
    } else {
      onSelect?(BlinkWorkDirStore.shared.workDirs[ip.row - 1].id)
    }
    navigationController?.popViewController(animated: true)
  }

  @objc private func addTapped() {
    let form = WorkDirFormViewController(editing: nil)
    form.onSaved = { [weak self] wd in
      self?.onSelect?(wd.id)
      DispatchQueue.main.async {
        self?.navigationController?.popViewController(animated: true)
      }
    }
    navigationController?.pushViewController(form, animated: true)
  }
}
