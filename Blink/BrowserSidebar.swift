////////////////////////////////////////////////////////////////////////////////
//
//  BrowserSidebar — 浏览器左侧栏（分「后台」「原型」两组），对应鸿蒙平板版
//  harmony/pad/.../PadHome.ets 里的 browserSidebar()/adminList()/protoList()。
//
//    后台 = PinnedTabsStore 里钉住的管理后台（跟 iCloud / 鸿蒙同步的那份）
//    原型 = prototype.douwantech.com 目录（ProtoCatalog），默认「最近更新」混排，
//           分区做筛选标签，支持搜索；结果带本地缓存，没网也有列表。
//
//  自己不持有 WebView，点了哪条通过 onOpen 回调交给 PinnedBrowserViewController。
//
////////////////////////////////////////////////////////////////////////////////

import UIKit

final class BrowserSidebar: UIView, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {

  enum Segment: Int { case admin = 0, proto = 1 }

  // MARK: 对外回调
  var onOpen: ((_ url: String, _ title: String) -> Void)?
  var onEditPinned: ((Int) -> Void)?
  var onDeletePinned: ((Int) -> Void)?
  var onAddPinned: (() -> Void)?
  var onEditProtoAuth: (() -> Void)?

  /// 当前网页地址，用来给列表高亮
  var currentURL: String = "" {
    didSet { if currentURL != oldValue { table.reloadData() } }
  }

  private(set) var segment: Segment = .admin

  private let segControl = UISegmentedControl(items: ["后台", "原型"])
  private let searchField = UISearchTextField()
  private let chipScroll = UIScrollView()
  private let chipStack = UIStackView()
  private let table = UITableView(frame: .zero, style: .plain)
  private let footerLabel = UILabel()
  private let footerAction = UIButton(type: .system)
  private let footerAuth = UIButton(type: .system)
  private let hairline = UIView()
  private var searchTop: NSLayoutConstraint!
  private var chipHeight: NSLayoutConstraint!
  private var searchHeight: NSLayoutConstraint!

  private var pinned: [PinnedTab] = []
  private var protoItems: [ProtoItem] = []
  private var protoSections: [String] = []
  private var protoFilter = ""      // "" = 最近更新
  private var protoQuery = ""
  private var protoFetchedAt: Date?
  private var protoLoading = false
  private var protoMessage = ""

  private static let kSeg = "BrowserSidebar.segment"

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .secondarySystemBackground
    setupUI()
    segment = Segment(rawValue: UserDefaults.standard.integer(forKey: Self.kSeg)) ?? .admin
    segControl.selectedSegmentIndex = segment.rawValue
    reloadPinned()
    if let c = ProtoCatalog.loadCache() {
      protoItems = c.items
      protoSections = c.sections
      protoFetchedAt = c.fetchedAt
    }
    applySegment()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  // MARK: - 布局

  private func setupUI() {
    segControl.translatesAutoresizingMaskIntoConstraints = false
    segControl.addTarget(self, action: #selector(segChanged), for: .valueChanged)
    addSubview(segControl)

    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.placeholder = "搜索原型"
    searchField.font = .systemFont(ofSize: 14)
    searchField.returnKeyType = .search
    searchField.delegate = self
    searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
    addSubview(searchField)

    chipScroll.translatesAutoresizingMaskIntoConstraints = false
    chipScroll.showsHorizontalScrollIndicator = false
    addSubview(chipScroll)
    chipStack.translatesAutoresizingMaskIntoConstraints = false
    chipStack.axis = .horizontal
    chipStack.spacing = 6
    chipStack.alignment = .center
    chipScroll.addSubview(chipStack)

    table.translatesAutoresizingMaskIntoConstraints = false
    table.dataSource = self
    table.delegate = self
    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 56
    table.keyboardDismissMode = .onDrag
    addSubview(table)

    hairline.translatesAutoresizingMaskIntoConstraints = false
    hairline.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
    addSubview(hairline)

    footerLabel.translatesAutoresizingMaskIntoConstraints = false
    footerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    footerLabel.textColor = .tertiaryLabel
    addSubview(footerLabel)

    footerAuth.translatesAutoresizingMaskIntoConstraints = false
    footerAuth.tintColor = .secondaryLabel
    footerAuth.setImage(UIImage(systemName: "person.circle"), for: .normal)
    footerAuth.addTarget(self, action: #selector(authTapped), for: .touchUpInside)
    addSubview(footerAuth)

    footerAction.translatesAutoresizingMaskIntoConstraints = false
    footerAction.tintColor = .systemIndigo
    footerAction.addTarget(self, action: #selector(footerTapped), for: .touchUpInside)
    addSubview(footerAction)

    NSLayoutConstraint.activate([
      segControl.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      segControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      segControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      segControl.heightAnchor.constraint(equalToConstant: 30),

      searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

      chipScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
      chipScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      chipScroll.trailingAnchor.constraint(equalTo: trailingAnchor),

      chipStack.topAnchor.constraint(equalTo: chipScroll.topAnchor),
      chipStack.bottomAnchor.constraint(equalTo: chipScroll.bottomAnchor),
      chipStack.leadingAnchor.constraint(equalTo: chipScroll.leadingAnchor, constant: 10),
      chipStack.trailingAnchor.constraint(equalTo: chipScroll.trailingAnchor, constant: -10),
      chipStack.heightAnchor.constraint(equalTo: chipScroll.heightAnchor),

      table.topAnchor.constraint(equalTo: chipScroll.bottomAnchor, constant: 4),
      table.leadingAnchor.constraint(equalTo: leadingAnchor),
      table.trailingAnchor.constraint(equalTo: trailingAnchor),
      table.bottomAnchor.constraint(equalTo: hairline.topAnchor),

      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),
      hairline.heightAnchor.constraint(equalToConstant: 0.5),

      footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      footerLabel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),

      footerAction.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      footerAction.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
      footerAction.widthAnchor.constraint(equalToConstant: 30),
      footerAction.heightAnchor.constraint(equalToConstant: 30),

      footerAuth.trailingAnchor.constraint(equalTo: footerAction.leadingAnchor, constant: -2),
      footerAuth.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
      footerAuth.widthAnchor.constraint(equalToConstant: 30),
      footerAuth.heightAnchor.constraint(equalToConstant: 30),

      footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: footerAuth.leadingAnchor, constant: -6),
    ])
    // 「后台」那一面不需要搜索框和分区标签，高度压成 0
    searchTop = searchField.topAnchor.constraint(equalTo: segControl.bottomAnchor, constant: 8)
    searchHeight = searchField.heightAnchor.constraint(equalToConstant: 32)
    chipHeight = chipScroll.heightAnchor.constraint(equalToConstant: 28)
    NSLayoutConstraint.activate([searchTop, searchHeight, chipHeight])
  }

  // MARK: - 数据

  func reloadPinned() {
    pinned = PinnedTabsStore.shared.tabs
    updateSegTitles()
    if segment == .admin { table.reloadData() }
  }

  /// 目录 10 分钟内拉过就不重拉（底部刷新按钮可手动拉）
  func refreshProtoIfStale() {
    if let at = protoFetchedAt, Date().timeIntervalSince(at) < 600 { return }
    refreshProto()
  }

  func refreshProto() {
    guard !protoLoading else { return }
    protoLoading = true
    protoMessage = ""
    updateFooter()
    ProtoCatalog.fetch { [weak self] result in
      guard let self else { return }
      self.protoLoading = false
      switch result {
      case .ok(let c):
        ProtoCatalog.saveCache(c)
        self.protoItems = c.items
        self.protoSections = c.sections
        self.protoFetchedAt = c.fetchedAt
        if !self.protoFilter.isEmpty && !c.sections.contains(self.protoFilter) { self.protoFilter = "" }
        self.protoMessage = ""
      case .noauth(let m), .error(let m):
        self.protoMessage = m
      }
      self.updateSegTitles()
      self.rebuildChips()
      self.updateFooter()
      if self.segment == .proto { self.table.reloadData() }
    }
  }

  private var visibleProto: [ProtoItem] {
    let q = protoQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var arr = protoItems.filter { it in
      (protoFilter.isEmpty || it.section == protoFilter) &&
      (q.isEmpty || it.title.lowercased().contains(q) || it.desc.lowercased().contains(q)
       || it.section.lowercased().contains(q))
    }
    if protoFilter.isEmpty {
      // 最近更新：日期倒序，同日期保持原顺序
      arr = arr.enumerated().sorted { a, b in
        a.element.updated == b.element.updated ? a.offset < b.offset : a.element.updated > b.element.updated
      }.map { $0.element }
    }
    return arr
  }

  // MARK: - 分段 / 标签

  @objc private func segChanged() {
    segment = Segment(rawValue: segControl.selectedSegmentIndex) ?? .admin
    UserDefaults.standard.set(segment.rawValue, forKey: Self.kSeg)
    applySegment()
    if segment == .proto { refreshProtoIfStale() }
  }

  private func applySegment() {
    let isProto = segment == .proto
    searchField.isHidden = !isProto
    chipScroll.isHidden = !isProto
    searchHeight.constant = isProto ? 32 : 0
    searchTop.constant = isProto ? 8 : 0
    chipHeight.constant = isProto ? 28 : 0
    updateSegTitles()
    rebuildChips()
    updateFooter()
    table.reloadData()
  }

  private func updateSegTitles() {
    segControl.setTitle("后台 \(pinned.count)", forSegmentAt: 0)
    segControl.setTitle("原型 \(protoItems.count)", forSegmentAt: 1)
  }

  private func rebuildChips() {
    chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard segment == .proto else { return }
    for (i, name) in (["最近更新"] + protoSections).enumerated() {
      let key = i == 0 ? "" : name
      let b = UIButton(type: .system)
      b.setTitle(name, for: .normal)
      b.titleLabel?.font = .systemFont(ofSize: 12)
      let on = protoFilter == key
      b.setTitleColor(on ? .white : .secondaryLabel, for: .normal)
      b.backgroundColor = on ? .systemIndigo : .tertiarySystemFill
      b.layer.cornerRadius = 13
      b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 11, bottom: 4, right: 11)
      b.tag = i
      b.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
      b.heightAnchor.constraint(equalToConstant: 26).isActive = true
      chipStack.addArrangedSubview(b)
    }
  }

  @objc private func chipTapped(_ sender: UIButton) {
    protoFilter = sender.tag == 0 ? "" : protoSections[sender.tag - 1]
    rebuildChips()
    table.reloadData()
  }

  @objc private func searchChanged() {
    protoQuery = searchField.text ?? ""
    table.reloadData()
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }

  // MARK: - 底部栏

  private func updateFooter() {
    if segment == .proto {
      footerAuth.isHidden = false
      footerAction.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
      if protoLoading {
        footerLabel.text = "更新中…"
      } else if let at = protoFetchedAt {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        footerLabel.text = "\(protoItems.count) 页 · \(f.string(from: at)) 更新"
          + (protoMessage.isEmpty ? "" : " · 刷新失败")
      } else {
        footerLabel.text = protoMessage.isEmpty ? "" : protoMessage
      }
    } else {
      footerAuth.isHidden = true
      footerAction.setImage(UIImage(systemName: "plus"), for: .normal)
      footerLabel.text = "长按编辑 · 与鸿蒙同步"
    }
  }

  @objc private func footerTapped() {
    if segment == .proto { refreshProto() } else { onAddPinned?() }
  }

  @objc private func authTapped() { onEditProtoAuth?() }

  // MARK: - 列表

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    segment == .admin ? pinned.count : visibleProto.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "row")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "row")
    cell.backgroundColor = .clear
    cell.selectionStyle = .none
    cell.accessoryView = nil
    cell.textLabel?.numberOfLines = 2
    cell.detailTextLabel?.numberOfLines = 1
    cell.detailTextLabel?.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    cell.detailTextLabel?.textColor = .tertiaryLabel

    if segment == .admin {
      let t = pinned[indexPath.row]
      cell.textLabel?.font = .systemFont(ofSize: 14)
      cell.textLabel?.text = t.title.isEmpty ? host(t.url) : t.title
      cell.detailTextLabel?.text = host(t.url)
      cell.imageView?.image = UIImage(systemName: "globe")
      cell.imageView?.tintColor = Self.accents[indexPath.row % Self.accents.count]
      if let u = t.authUser, !u.isEmpty {
        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = .quaternaryLabel
        lock.preferredSymbolConfiguration = .init(pointSize: 10, weight: .medium)
        lock.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        cell.accessoryView = lock
      }
      cell.contentView.backgroundColor = same(currentURL, t.url)
        ? UIColor.systemIndigo.withAlphaComponent(0.12) : .clear
    } else {
      let it = visibleProto[indexPath.row]
      cell.textLabel?.font = .systemFont(ofSize: 13)
      cell.textLabel?.text = it.title
      let date = it.updated.count >= 10 ? String(it.updated.dropFirst(5).prefix(5)) : ""
      cell.detailTextLabel?.text = date + (protoFilter.isEmpty && !it.section.isEmpty ? "  ·  \(it.section)" : "")
      cell.imageView?.image = nil
      if it.isNew {
        let badge = UILabel(frame: CGRect(x: 0, y: 0, width: 20, height: 16))
        badge.text = "新"
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textAlignment = .center
        badge.textColor = .black
        badge.backgroundColor = .systemOrange
        badge.layer.cornerRadius = 4
        badge.layer.masksToBounds = true
        cell.accessoryView = badge
      }
      cell.contentView.backgroundColor = same(currentURL, it.url)
        ? UIColor.systemIndigo.withAlphaComponent(0.12) : .clear
    }
    cell.contentView.layer.cornerRadius = 9
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if segment == .admin {
      guard pinned.indices.contains(indexPath.row) else { return }
      let t = pinned[indexPath.row]
      onOpen?(t.url, t.title)
    } else {
      let arr = visibleProto
      guard arr.indices.contains(indexPath.row) else { return }
      onOpen?(arr[indexPath.row].url, arr[indexPath.row].title)
    }
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                 point: CGPoint) -> UIContextMenuConfiguration? {
    guard segment == .admin, pinned.indices.contains(indexPath.row) else { return nil }
    let i = indexPath.row
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      UIMenu(children: [
        UIAction(title: "编辑", image: UIImage(systemName: "pencil")) { _ in self?.onEditPinned?(i) },
        UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
          self?.onDeletePinned?(i)
        },
      ])
    }
  }

  // 「原型」那一面的空列表提示（拉取中 / 没账号 / 失败）
  func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
    guard segment == .proto, visibleProto.isEmpty else { return nil }
    let l = UILabel()
    l.numberOfLines = 0
    l.textAlignment = .center
    l.font = .systemFont(ofSize: 12)
    l.textColor = .tertiaryLabel
    l.text = protoLoading ? "正在拉取原型目录…"
      : (protoMessage.isEmpty ? (protoQuery.isEmpty ? "还没有原型目录" : "没有匹配的原型") : protoMessage)
    l.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 60)
    return l
  }

  // MARK: - 小工具

  private static let accents: [UIColor] = [.systemIndigo, .systemTeal, .systemPink, .systemOrange,
                                           .systemGreen, .systemPurple]

  private func host(_ url: String) -> String {
    URL(string: url)?.host ?? url
  }

  private func same(_ a: String, _ b: String) -> Bool {
    func strip(_ u: String) -> String {
      var s = u.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
      if s.hasSuffix("/") { s.removeLast() }
      return s
    }
    return !a.isEmpty && !b.isEmpty && strip(a) == strip(b)
  }
}
