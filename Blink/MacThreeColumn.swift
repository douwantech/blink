//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Mac 大屏三栏布局（issue #5）：最左机器 rail + 中间会话列表 + 右侧终端。
// 仅 Designed-for-iPad（isiOSAppOnMac）主窗口启用；iPhone/iPad 保持原浮动栏布局。
//
////////////////////////////////////////////////////////////////////////////////

import UIKit

// MARK: - 机器 rail（最左常驻竖栏）

/// FloatingMachineBar 的常驻版：每台机器一个圆头像钮（在线绿点 + 当前白描边），
/// 底部固定 助手chat / 设置 两个入口。点头像切机器，长按换头像。
final class MacMachineRailView: UIView {
  static let railW: CGFloat = 68

  var onSelectMachine: ((String) -> Void)?
  var onEditAvatar: ((String) -> Void)?
  var onOpenAssistantChat: (() -> Void)?
  var onOpenSettings: (() -> Void)?

  private let scroll = UIScrollView()
  private let assistantButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private var machineIds: [String] = []
  private var dotViews: [String: UIView] = [:]
  private var probeInFlight = false
  private let palette: [UIColor] = [.systemOrange, .systemPink, .systemPurple, .systemTeal,
                                    .systemBlue, .systemGreen, .systemRed, .systemIndigo]

  init() {
    super.init(frame: .zero)
    backgroundColor = UIColor(white: 0.10, alpha: 1.0)

    scroll.showsVerticalScrollIndicator = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)

    assistantButton.setImage(UIImage(systemName: "sparkles"), for: .normal)
    assistantButton.tintColor = .systemPurple
    assistantButton.translatesAutoresizingMaskIntoConstraints = false
    assistantButton.addTarget(self, action: #selector(assistantTapped), for: .touchUpInside)
    addSubview(assistantButton)

    settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
    settingsButton.tintColor = .secondaryLabel
    settingsButton.translatesAutoresizingMaskIntoConstraints = false
    settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
    addSubview(settingsButton)

    let sep = UIView()
    sep.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    sep.translatesAutoresizingMaskIntoConstraints = false
    addSubview(sep)

    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: assistantButton.topAnchor, constant: -8),

      assistantButton.centerXAnchor.constraint(equalTo: centerXAnchor),
      assistantButton.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -10),
      assistantButton.widthAnchor.constraint(equalToConstant: 32),
      assistantButton.heightAnchor.constraint(equalToConstant: 28),

      settingsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
      settingsButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
      settingsButton.widthAnchor.constraint(equalToConstant: 32),
      settingsButton.heightAnchor.constraint(equalToConstant: 28),

      sep.trailingAnchor.constraint(equalTo: trailingAnchor),
      sep.topAnchor.constraint(equalTo: topAnchor),
      sep.bottomAnchor.constraint(equalTo: bottomAnchor),
      sep.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  /// 按机器列表重建头像钮；currentId 白描边高亮。在线点先用缓存，随后后台探测刷新。
  func reload(currentId: String?) {
    scroll.subviews.forEach { $0.removeFromSuperview() }
    machineIds.removeAll()
    dotViews.removeAll()

    let machines = BlinkMachineStore.shared.machines
    let x = (Self.railW - 44) / 2
    var y: CGFloat = 0
    for (i, m) in machines.enumerated() {
      let b = UIButton(type: .custom)
      b.frame = CGRect(x: x, y: y, width: 44, height: 44)
      b.tag = i
      b.layer.cornerRadius = 22
      b.clipsToBounds = true
      b.imageView?.contentMode = .scaleAspectFill
      if let av = BlinkMachineStore.shared.avatarImage(forId: m.id) {
        b.setImage(Self.round(av, side: 44), for: .normal)
      } else {
        b.backgroundColor = palette[i % palette.count]
        let initial = String(m.displayName.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        b.setTitle(initial.isEmpty ? "?" : initial, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
      }
      let isCur = m.id == currentId
      b.layer.borderWidth = isCur ? 2.5 : 0
      b.layer.borderColor = UIColor.white.cgColor
      b.addTarget(self, action: #selector(machineTapped(_:)), for: .touchUpInside)
      b.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(machineLongPressed(_:))))
      scroll.addSubview(b)

      // 在线绿点：盖在头像右下角（描边同 rail 底色抠出圆环）
      let dot = UIView(frame: CGRect(x: x + 33, y: y + 33, width: 12, height: 12))
      dot.layer.cornerRadius = 6
      dot.layer.borderWidth = 2
      dot.layer.borderColor = backgroundColor?.cgColor
      dot.backgroundColor = .systemGray   // 未知=灰，探测后变绿/暗
      dot.isUserInteractionEnabled = false
      scroll.addSubview(dot)
      dotViews[m.id] = dot

      machineIds.append(m.id)
      y += 56
    }
    scroll.contentSize = CGSize(width: Self.railW, height: y)
    refreshOnlineDots()
  }

  /// 后台探测每台机器可达性（走 resolveHost 同款缓存），主线程刷新绿点
  private func refreshOnlineDots() {
    guard !probeInFlight else { return }
    probeInFlight = true
    let machines = BlinkMachineStore.shared.machines
    DispatchQueue.global(qos: .utility).async { [weak self] in
      var online: [String: Bool] = [:]
      for m in machines {
        let host = BlinkMachineStore.bestHost(for: m)
        let port: UInt16 = m.blinkdConfig.map { UInt16($0.port) } ?? 22
        online[m.id] = HostReachability.isReachable(host: host, port: port)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.probeInFlight = false
        for (id, ok) in online {
          self.dotViews[id]?.backgroundColor = ok ? .systemGreen : UIColor(white: 0.35, alpha: 1)
        }
      }
    }
  }

  static func round(_ img: UIImage, side: CGFloat) -> UIImage {
    let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
    return r.image { _ in
      UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
      img.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }.withRenderingMode(.alwaysOriginal)
  }

  @objc private func machineTapped(_ sender: UIButton) {
    guard machineIds.indices.contains(sender.tag) else { return }
    onSelectMachine?(machineIds[sender.tag])
  }

  @objc private func machineLongPressed(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began, let b = g.view as? UIButton,
          machineIds.indices.contains(b.tag) else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    onEditAvatar?(machineIds[b.tag])
  }

  @objc private func assistantTapped() { onOpenAssistantChat?() }
  @objc private func settingsTapped() { onOpenSettings?() }
}

// MARK: - 会话列表 sidebar（中栏）

/// 当前机器的所有会话铺成列表：头像 + 标题 + 目录 + 未读点，行尾 ✕ 关闭。
/// 顶部 header 显示机器名 / 连接方式 / 当前选用地址；底部「+ 新会话」。
final class MacSessionSidebarView: UIView, UITableViewDataSource, UITableViewDelegate {
  static let sidebarW: CGFloat = 288

  struct Item {
    let tag: Int          // index into SpaceController._viewportsKeys
    let title: String
    let subtitle: String
    let icon: UIImage?
    let unread: Bool
    let isCurrent: Bool
  }

  var onSelect: ((Int) -> Void)?
  var onClose: ((Int) -> Void)?
  var onNewSession: (() -> Void)?

  private let machineNameLabel = UILabel()
  private let transportBadge = UILabel()
  private let hostLabel = UILabel()
  private let table = UITableView(frame: .zero, style: .plain)
  private let newButton = UIButton(type: .system)
  private var items: [Item] = []

  init() {
    super.init(frame: .zero)
    backgroundColor = UIColor(white: 0.12, alpha: 1.0)

    machineNameLabel.font = .systemFont(ofSize: 17, weight: .bold)
    machineNameLabel.textColor = UIColor(white: 0.94, alpha: 1)

    transportBadge.font = .systemFont(ofSize: 11, weight: .bold)
    transportBadge.textColor = .systemTeal
    transportBadge.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.5).cgColor
    transportBadge.layer.borderWidth = 1
    transportBadge.layer.cornerRadius = 4
    transportBadge.textAlignment = .center

    hostLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    hostLabel.textColor = .secondaryLabel
    hostLabel.lineBreakMode = .byTruncatingMiddle

    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.rowHeight = 56
    table.dataSource = self
    table.delegate = self
    table.register(MacSessionCell.self, forCellReuseIdentifier: "cell")

    var cfg = UIButton.Configuration.plain()
    cfg.title = "＋ 新会话"
    cfg.baseForegroundColor = .systemTeal
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    newButton.configuration = cfg
    newButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    newButton.layer.cornerRadius = 8
    newButton.layer.borderWidth = 1
    newButton.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.4).cgColor
    newButton.addTarget(self, action: #selector(newTapped), for: .touchUpInside)

    let sep = UIView()
    sep.backgroundColor = UIColor.white.withAlphaComponent(0.08)

    [machineNameLabel, transportBadge, hostLabel, sep, table, newButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }

    let hairline = UIView()
    hairline.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    hairline.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hairline)

    NSLayoutConstraint.activate([
      machineNameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      machineNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

      transportBadge.centerYAnchor.constraint(equalTo: machineNameLabel.centerYAnchor),
      transportBadge.leadingAnchor.constraint(equalTo: machineNameLabel.trailingAnchor, constant: 8),
      transportBadge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
      transportBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
      transportBadge.heightAnchor.constraint(equalToConstant: 17),

      hostLabel.topAnchor.constraint(equalTo: machineNameLabel.bottomAnchor, constant: 4),
      hostLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      hostLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

      sep.topAnchor.constraint(equalTo: hostLabel.bottomAnchor, constant: 10),
      sep.leadingAnchor.constraint(equalTo: leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: trailingAnchor),
      sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

      table.topAnchor.constraint(equalTo: sep.bottomAnchor),
      table.leadingAnchor.constraint(equalTo: leadingAnchor),
      table.trailingAnchor.constraint(equalTo: trailingAnchor),
      table.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -8),

      newButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      newButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
      newButton.heightAnchor.constraint(equalToConstant: 36),

      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.topAnchor.constraint(equalTo: topAnchor),
      hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
      hairline.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  func reload(machineName: String?, transport: String?, items: [Item]) {
    machineNameLabel.text = machineName ?? "（无机器）"
    transportBadge.text = transport.map { "  \($0)  " }
    transportBadge.isHidden = transport == nil
    self.items = items
    table.reloadData()
    // 让当前行可见
    if let cur = items.firstIndex(where: { $0.isCurrent }) {
      table.scrollToRow(at: IndexPath(row: cur, section: 0), at: .none, animated: false)
    }
  }

  /// 地址解析是异步探测出来的，单独喂
  func updateHostLine(_ s: String?) {
    hostLabel.text = s
  }

  @objc private func newTapped() { onNewSession?() }

  // MARK: table
  func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

  func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MacSessionCell
    let item = items[indexPath.row]
    cell.configure(item: item)
    cell.onClose = { [weak self] in self?.onClose?(item.tag) }
    return cell
  }

  func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: false)
    onSelect?(items[indexPath.row].tag)
  }
}

/// sidebar 单行：头像 + 标题 + 目录 + 未读点 + ✕
final class MacSessionCell: UITableViewCell {
  var onClose: (() -> Void)?

  private let avatar = UIImageView()
  private let initialLabel = UILabel()
  private let titleLbl = UILabel()
  private let subtitleLbl = UILabel()
  private let unreadDot = UIView()
  private let closeButton = UIButton(type: .system)
  private let currentBar = UIView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none

    currentBar.backgroundColor = .systemTeal
    currentBar.layer.cornerRadius = 1.5
    currentBar.isHidden = true

    avatar.contentMode = .scaleAspectFill
    avatar.layer.cornerRadius = 16
    avatar.clipsToBounds = true

    initialLabel.font = .systemFont(ofSize: 16, weight: .bold)
    initialLabel.textColor = .white
    initialLabel.textAlignment = .center
    initialLabel.layer.cornerRadius = 16
    initialLabel.clipsToBounds = true

    titleLbl.font = .systemFont(ofSize: 15, weight: .medium)
    titleLbl.textColor = UIColor(white: 0.94, alpha: 1)

    subtitleLbl.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    subtitleLbl.textColor = .secondaryLabel
    subtitleLbl.lineBreakMode = .byTruncatingMiddle

    unreadDot.backgroundColor = .systemRed
    unreadDot.layer.cornerRadius = 4
    unreadDot.isHidden = true

    closeButton.setImage(UIImage(systemName: "xmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)), for: .normal)
    closeButton.tintColor = UIColor(white: 0.55, alpha: 1)
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    [currentBar, avatar, initialLabel, titleLbl, subtitleLbl, unreadDot, closeButton].forEach {
      contentView.addSubview($0)
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = contentView.bounds.width
    currentBar.frame = CGRect(x: 0, y: 10, width: 3, height: contentView.bounds.height - 20)
    avatar.frame = CGRect(x: 14, y: 12, width: 32, height: 32)
    initialLabel.frame = avatar.frame
    closeButton.frame = CGRect(x: w - 36, y: (contentView.bounds.height - 28) / 2, width: 28, height: 28)
    let textX: CGFloat = 54
    let textW = closeButton.frame.minX - textX - 14
    titleLbl.frame = CGRect(x: textX, y: 9, width: textW, height: 20)
    subtitleLbl.frame = CGRect(x: textX, y: 31, width: textW, height: 16)
    unreadDot.frame = CGRect(x: textX + min(titleLbl.intrinsicContentSize.width, textW) + 6, y: 15, width: 8, height: 8)
  }

  func configure(item: MacSessionSidebarView.Item) {
    titleLbl.text = item.title
    subtitleLbl.text = item.subtitle
    unreadDot.isHidden = !item.unread
    currentBar.isHidden = !item.isCurrent
    contentView.backgroundColor = item.isCurrent ? UIColor.systemTeal.withAlphaComponent(0.12) : .clear
    titleLbl.font = .systemFont(ofSize: 15, weight: item.isCurrent ? .semibold : .medium)
    if let icon = item.icon {
      avatar.image = icon
      avatar.isHidden = false
      initialLabel.isHidden = true
    } else {
      avatar.isHidden = true
      initialLabel.isHidden = false
      let initial = String(item.title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
      initialLabel.text = initial.isEmpty ? "?" : initial
      initialLabel.backgroundColor = MacSessionCell.color(for: item.title)
    }
    setNeedsLayout()
  }

  private static func color(for s: String) -> UIColor {
    let palette: [UIColor] = [.systemOrange, .systemPink, .systemPurple, .systemTeal,
                              .systemBlue, .systemGreen, .systemRed, .systemIndigo]
    var h = 0
    for u in s.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0x7fffffff }
    return palette[h % palette.count]
  }

  @objc private func closeTapped() { onClose?() }
}

// MARK: - 底部状态栏（终端列下方）

/// 窄屏放不下的元信息：tmux 会话名 · 传输方式 · 选用地址(来源) · 编码；右侧快捷键提示。
final class MacStatusBarView: UIView {
  static let barH: CGFloat = 24

  private let leftLabel = UILabel()
  private let rightLabel = UILabel()

  init() {
    super.init(frame: .zero)
    backgroundColor = UIColor(white: 0.12, alpha: 1.0)

    let hairline = UIView()
    hairline.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    hairline.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hairline)

    leftLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    leftLabel.textColor = .secondaryLabel
    leftLabel.lineBreakMode = .byTruncatingTail
    rightLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    rightLabel.textColor = UIColor(white: 0.40, alpha: 1)
    rightLabel.textAlignment = .right
    rightLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    [leftLabel, rightLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }

    NSLayoutConstraint.activate([
      hairline.topAnchor.constraint(equalTo: topAnchor),
      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

      leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      leftLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      leftLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightLabel.leadingAnchor, constant: -12),

      rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  func update(left: String, right: String) {
    leftLabel.text = left
    rightLabel.text = right
  }
}
