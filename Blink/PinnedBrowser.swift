import UIKit
import WebKit

struct PinnedTab: Codable, Equatable {
  var title: String
  var url: String
  var authUser: String?
  var authPassword: String?
}

struct BrowserTabItem {
  var title: String
  var url: String
  var authUser: String?
  var authPassword: String?
  var isTransient: Bool
}

final class PinnedTabsStore {
  static let shared = PinnedTabsStore()
  private let key = "PinnedTabsStore.tabs"

  var tabs: [PinnedTab] {
    get {
      guard let data = UserDefaults.standard.data(forKey: key),
            let arr = try? JSONDecoder().decode([PinnedTab].self, from: data) else {
        return []
      }
      return arr
    }
    set {
      let data = (try? JSONEncoder().encode(newValue)) ?? Data()
      UserDefaults.standard.set(data, forKey: key)
    }
  }
}

final class FloatingBrowserButton: UIButton {
  private static let kPosX = "FloatingBrowserButton.posX"
  private static let kPosY = "FloatingBrowserButton.posY"
  private var dragPan: UIPanGestureRecognizer!
  private var didMove = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupUI()
    dragPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    addGestureRecognizer(dragPan)
  }
  required init?(coder: NSCoder) { fatalError() }

  private func setupUI() {
    backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.9)
    let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    setImage(UIImage(systemName: "globe", withConfiguration: cfg), for: .normal)
    tintColor = .white
    layer.cornerRadius = 28
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.3
    layer.shadowRadius = 6
    layer.shadowOffset = CGSize(width: 0, height: 2)
  }

  func restorePosition(in container: UIView) {
    let d = UserDefaults.standard
    let safeArea = container.safeAreaInsets
    let defaultX = container.bounds.width - bounds.width - 16 - safeArea.right
    let defaultY = container.bounds.height - bounds.height - 120 - safeArea.bottom
    let x = d.object(forKey: Self.kPosX) as? CGFloat ?? defaultX
    let y = d.object(forKey: Self.kPosY) as? CGFloat ?? defaultY
    frame.origin = clampOrigin(CGPoint(x: x, y: y), in: container)
  }

  private func clampOrigin(_ p: CGPoint, in container: UIView) -> CGPoint {
    let insets = container.safeAreaInsets
    let minX = insets.left + 4
    let maxX = container.bounds.width - bounds.width - insets.right - 4
    let minY = insets.top + 4
    let maxY = container.bounds.height - bounds.height - insets.bottom - 4
    return CGPoint(
      x: min(max(p.x, minX), maxX),
      y: min(max(p.y, minY), maxY))
  }

  @objc private func panned(_ g: UIPanGestureRecognizer) {
    guard let container = superview else { return }
    let t = g.translation(in: container)
    switch g.state {
    case .began:
      didMove = false
    case .changed:
      let newOrigin = CGPoint(x: frame.origin.x + t.x, y: frame.origin.y + t.y)
      frame.origin = clampOrigin(newOrigin, in: container)
      g.setTranslation(.zero, in: container)
      if abs(t.x) > 1 || abs(t.y) > 1 { didMove = true }
    case .ended, .cancelled:
      if didMove {
        UserDefaults.standard.set(frame.origin.x, forKey: Self.kPosX)
        UserDefaults.standard.set(frame.origin.y, forKey: Self.kPosY)
        g.cancelsTouchesInView = true
      }
    default: break
    }
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let r = bounds.width / 2
    let dx = point.x - r, dy = point.y - r
    return dx * dx + dy * dy <= r * r
  }
}

final class PinnedBrowserViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate {
  private let tabBarScroll = UIScrollView()
  private let tabStack = UIStackView()
  private let addTabButton = UIButton(type: .system)
  private let urlField = UITextField()
  private let backButton = UIButton(type: .system)
  private let forwardButton = UIButton(type: .system)
  private let reloadButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)
  private let progressBar = UIProgressView(progressViewStyle: .bar)
  private var webView: WKWebView!
  private var progressObs: NSKeyValueObservation?

  private var tabs: [BrowserTabItem] = []
  private var currentIndex: Int? = nil
  private var activeAuthUser: String?
  private var activeAuthPassword: String?
  private var lastLoadedURLString: String?

  init() {
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  func appendTransientTab(title: String, url: URL) {
    if !isViewLoaded {
      _ = view // force load
    }
    if let i = tabs.firstIndex(where: { $0.isTransient && $0.url == url.absoluteString }) {
      selectTab(at: i)
      return
    }
    let item = BrowserTabItem(title: title, url: url.absoluteString, authUser: nil, authPassword: nil, isTransient: true)
    tabs.append(item)
    rebuildTabBar()
    selectTab(at: tabs.count - 1)
    scrollTabsToEnd()
  }

  private func scrollTabsToEnd() {
    tabBarScroll.layoutIfNeeded()
    let maxX = max(0, tabBarScroll.contentSize.width - tabBarScroll.bounds.width)
    tabBarScroll.setContentOffset(CGPoint(x: maxX, y: 0), animated: true)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let topBar = UIView()
    topBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(topBar)

    let grabber = UIView()
    grabber.translatesAutoresizingMaskIntoConstraints = false
    grabber.backgroundColor = UIColor.tertiaryLabel
    grabber.layer.cornerRadius = 2.5
    topBar.addSubview(grabber)

    closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    closeButton.tintColor = .secondaryLabel
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(closeButton)

    tabBarScroll.translatesAutoresizingMaskIntoConstraints = false
    tabBarScroll.showsHorizontalScrollIndicator = false
    topBar.addSubview(tabBarScroll)

    tabStack.translatesAutoresizingMaskIntoConstraints = false
    tabStack.axis = .horizontal
    tabStack.spacing = 6
    tabStack.alignment = .center
    tabBarScroll.addSubview(tabStack)

    addTabButton.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
    addTabButton.tintColor = .systemIndigo
    addTabButton.addTarget(self, action: #selector(addTabTapped), for: .touchUpInside)
    addTabButton.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(addTabButton)

    let navBar = UIView()
    navBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(navBar)

    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
    forwardButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
    forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)
    reloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
    reloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)
    for b in [backButton, forwardButton, reloadButton] {
      b.tintColor = .label
      b.translatesAutoresizingMaskIntoConstraints = false
      navBar.addSubview(b)
    }

    urlField.translatesAutoresizingMaskIntoConstraints = false
    urlField.placeholder = "输入网址或搜索"
    urlField.borderStyle = .roundedRect
    urlField.autocapitalizationType = .none
    urlField.autocorrectionType = .no
    urlField.keyboardType = .URL
    urlField.returnKeyType = .go
    urlField.clearButtonMode = .whileEditing
    urlField.delegate = self
    urlField.font = .systemFont(ofSize: 14)
    navBar.addSubview(urlField)

    progressBar.translatesAutoresizingMaskIntoConstraints = false
    progressBar.progressTintColor = .systemIndigo
    progressBar.trackTintColor = .clear
    view.addSubview(progressBar)

    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)

    progressObs = webView.observe(\.estimatedProgress) { [weak self] wv, _ in
      self?.progressBar.setProgress(Float(wv.estimatedProgress), animated: true)
      if wv.estimatedProgress >= 1.0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          self?.progressBar.setProgress(0, animated: false)
        }
      }
    }

    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.heightAnchor.constraint(equalToConstant: 56),

      grabber.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 6),
      grabber.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      grabber.widthAnchor.constraint(equalToConstant: 36),
      grabber.heightAnchor.constraint(equalToConstant: 5),

      closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor, constant: 6),
      closeButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
      closeButton.widthAnchor.constraint(equalToConstant: 28),
      closeButton.heightAnchor.constraint(equalToConstant: 28),

      addTabButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor, constant: 6),
      addTabButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
      addTabButton.widthAnchor.constraint(equalToConstant: 28),
      addTabButton.heightAnchor.constraint(equalToConstant: 28),

      tabBarScroll.centerYAnchor.constraint(equalTo: topBar.centerYAnchor, constant: 6),
      tabBarScroll.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
      tabBarScroll.trailingAnchor.constraint(equalTo: addTabButton.leadingAnchor, constant: -6),
      tabBarScroll.heightAnchor.constraint(equalToConstant: 30),

      tabStack.topAnchor.constraint(equalTo: tabBarScroll.topAnchor),
      tabStack.bottomAnchor.constraint(equalTo: tabBarScroll.bottomAnchor),
      tabStack.leadingAnchor.constraint(equalTo: tabBarScroll.leadingAnchor),
      tabStack.trailingAnchor.constraint(equalTo: tabBarScroll.trailingAnchor),
      tabStack.heightAnchor.constraint(equalTo: tabBarScroll.heightAnchor),

      navBar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
      navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      navBar.heightAnchor.constraint(equalToConstant: 40),

      backButton.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 8),
      backButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
      backButton.widthAnchor.constraint(equalToConstant: 32),
      backButton.heightAnchor.constraint(equalToConstant: 32),

      forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
      forwardButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
      forwardButton.widthAnchor.constraint(equalToConstant: 32),
      forwardButton.heightAnchor.constraint(equalToConstant: 32),

      reloadButton.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -8),
      reloadButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
      reloadButton.widthAnchor.constraint(equalToConstant: 32),
      reloadButton.heightAnchor.constraint(equalToConstant: 32),

      urlField.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 6),
      urlField.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -6),
      urlField.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
      urlField.heightAnchor.constraint(equalToConstant: 30),

      progressBar.topAnchor.constraint(equalTo: navBar.bottomAnchor),
      progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      progressBar.heightAnchor.constraint(equalToConstant: 2),

      webView.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    tabs = PinnedTabsStore.shared.tabs.map {
      BrowserTabItem(title: $0.title, url: $0.url, authUser: $0.authUser, authPassword: $0.authPassword, isTransient: false)
    }
    rebuildTabBar()
    if !tabs.isEmpty {
      selectTab(at: 0)
    } else {
      showEmptyHint()
    }
  }

  deinit {
    progressObs?.invalidate()
  }

  private func showEmptyHint() {
    urlField.text = ""
    let label = UILabel()
    label.text = "还没有标签，点右上角 + 添加"
    label.textColor = .tertiaryLabel
    label.textAlignment = .center
    label.font = .systemFont(ofSize: 15)
    label.translatesAutoresizingMaskIntoConstraints = false
    webView.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
    ])
  }

  private func rebuildTabBar() {
    tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for (i, tab) in tabs.enumerated() {
      let title = tab.title.isEmpty ? tab.url : tab.title
      let chip = makeTabChip(title: title, index: i, selected: i == currentIndex, transient: tab.isTransient)
      tabStack.addArrangedSubview(chip)
    }
  }

  private func makeTabChip(title: String, index: Int, selected: Bool, transient: Bool) -> UIView {
    let chip = UIButton(type: .system)
    let visibleTitle = transient ? title + "  ✕" : title
    chip.setTitle(visibleTitle, for: .normal)
    chip.titleLabel?.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
    chip.setTitleColor(selected ? .white : .label, for: .normal)
    let bg: UIColor
    if selected {
      bg = transient ? UIColor.systemTeal : UIColor.systemIndigo
    } else {
      bg = transient ? UIColor.systemTeal.withAlphaComponent(0.2) : UIColor.secondarySystemFill
    }
    chip.backgroundColor = bg
    chip.layer.cornerRadius = 14
    chip.contentEdgeInsets = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
    chip.tag = index
    if transient {
      chip.addTarget(self, action: #selector(transientChipTapped(_:event:)), for: .touchUpInside)
    } else {
      chip.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
      let lp = UILongPressGestureRecognizer(target: self, action: #selector(tabLongPressed(_:)))
      lp.minimumPressDuration = 0.5
      chip.addGestureRecognizer(lp)
    }
    return chip
  }

  @objc private func transientChipTapped(_ sender: UIButton, event: UIEvent) {
    guard let touch = event.allTouches?.first else {
      selectTab(at: sender.tag); return
    }
    let p = touch.location(in: sender)
    if p.x > sender.bounds.width - 28 {
      closeTransientTab(at: sender.tag)
    } else {
      selectTab(at: sender.tag)
    }
  }

  private func closeTransientTab(at i: Int) {
    guard i >= 0, i < tabs.count, tabs[i].isTransient else { return }
    tabs.remove(at: i)
    if let cur = currentIndex {
      if cur == i {
        currentIndex = nil
        if !tabs.isEmpty {
          selectTab(at: min(i, tabs.count - 1))
        } else {
          webView.load(URLRequest(url: URL(string: "about:blank")!))
          lastLoadedURLString = nil
        }
      } else if cur > i {
        currentIndex = cur - 1
      }
    }
    rebuildTabBar()
  }

  @objc private func tabTapped(_ sender: UIButton) {
    selectTab(at: sender.tag)
  }

  @objc private func tabLongPressed(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began, let chip = g.view as? UIButton else { return }
    let i = chip.tag
    guard i >= 0, i < tabs.count, !tabs[i].isTransient else { return }
    let tab = tabs[i]
    let alert = UIAlertController(title: tab.title, message: tab.url, preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "编辑", style: .default) { [weak self] _ in
      self?.presentEditor(forIndex: i)
    })
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      guard let self else { return }
      self.tabs.remove(at: i)
      self.persistPinned()
      if let cur = self.currentIndex {
        if cur == i {
          self.currentIndex = self.tabs.isEmpty ? nil : min(i, self.tabs.count - 1)
          if let nc = self.currentIndex { self.selectTab(at: nc) } else { self.webView.load(URLRequest(url: URL(string: "about:blank")!)); self.lastLoadedURLString = nil }
        } else if cur > i {
          self.currentIndex = cur - 1
        }
      }
      self.rebuildTabBar()
    })
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let pop = alert.popoverPresentationController {
      pop.sourceView = chip
      pop.sourceRect = chip.bounds
    }
    present(alert, animated: true)
  }

  private func selectTab(at i: Int) {
    guard i >= 0, i < tabs.count else { return }
    currentIndex = i
    let tab = tabs[i]
    activeAuthUser = (tab.authUser?.isEmpty == false) ? tab.authUser : nil
    activeAuthPassword = (tab.authPassword?.isEmpty == false) ? tab.authPassword : nil
    urlField.text = tab.url
    if tab.url == lastLoadedURLString {
      rebuildTabBar()
      return
    }
    if let url = URL(string: tab.url), url.isFileURL {
      lastLoadedURLString = tab.url
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else if let url = Self.normalizeURL(tab.url) {
      lastLoadedURLString = tab.url
      webView.load(URLRequest(url: url))
    }
    rebuildTabBar()
  }

  private func persistPinned() {
    let pinned = tabs.filter { !$0.isTransient }.map {
      PinnedTab(title: $0.title, url: $0.url, authUser: $0.authUser, authPassword: $0.authPassword)
    }
    PinnedTabsStore.shared.tabs = pinned
  }

  @objc private func addTabTapped() {
    presentEditor(forIndex: nil)
  }

  private func presentEditor(forIndex i: Int?) {
    let existing = i.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil }
    let alert = UIAlertController(
      title: existing == nil ? "添加标签" : "编辑标签",
      message: nil,
      preferredStyle: .alert)
    alert.addTextField { tf in
      tf.placeholder = "名称（可空，会用网址）"
      tf.text = existing?.title
      tf.autocapitalizationType = .none
    }
    alert.addTextField { tf in
      tf.placeholder = "网址 (如 google.com)"
      tf.text = existing?.url ?? self.urlField.text
      tf.keyboardType = .URL
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
    }
    alert.addTextField { tf in
      tf.placeholder = "HTTP Basic 用户名（可空）"
      tf.text = existing?.authUser
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
    }
    alert.addTextField { tf in
      tf.placeholder = "HTTP Basic 密码（可空）"
      tf.text = existing?.authPassword
      tf.isSecureTextEntry = true
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
      guard let self else { return }
      let fields = alert.textFields ?? []
      let title = fields.indices.contains(0) ? (fields[0].text ?? "") : ""
      let url = fields.indices.contains(1) ? (fields[1].text ?? "") : ""
      let user = fields.indices.contains(2) ? (fields[2].text ?? "") : ""
      let pwd = fields.indices.contains(3) ? (fields[3].text ?? "") : ""
      let cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty else { return }
      let item = BrowserTabItem(
        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
        url: cleaned,
        authUser: user.isEmpty ? nil : user,
        authPassword: pwd.isEmpty ? nil : pwd,
        isTransient: false)
      if let i, self.tabs.indices.contains(i) {
        self.tabs[i] = item
      } else {
        if let lastPinned = self.tabs.lastIndex(where: { !$0.isTransient }) {
          self.tabs.insert(item, at: lastPinned + 1)
        } else {
          self.tabs.insert(item, at: 0)
        }
      }
      self.persistPinned()
      self.rebuildTabBar()
      let target: Int
      if let i = i {
        target = i
      } else if let last = self.tabs.lastIndex(where: { !$0.isTransient && $0.url == item.url }) {
        target = last
      } else {
        target = self.tabs.count - 1
      }
      self.selectTab(at: target)
    })
    present(alert, animated: true)
  }

  func webView(_ webView: WKWebView,
               didReceive challenge: URLAuthenticationChallenge,
               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    let method = challenge.protectionSpace.authenticationMethod
    let basicLike = method == NSURLAuthenticationMethodHTTPBasic
      || method == NSURLAuthenticationMethodHTTPDigest
      || method == NSURLAuthenticationMethodNTLM
    if basicLike, challenge.previousFailureCount == 0,
       let user = activeAuthUser, let pwd = activeAuthPassword {
      let cred = URLCredential(user: user, password: pwd, persistence: .forSession)
      completionHandler(.useCredential, cred)
      return
    }
    completionHandler(.performDefaultHandling, nil)
  }

  @objc private func backTapped() { webView.goBack() }
  @objc private func forwardTapped() { webView.goForward() }
  @objc private func reloadTapped() { webView.reload() }
  @objc private func closeTapped() { dismiss(animated: true) }

  func textFieldShouldReturn(_ tf: UITextField) -> Bool {
    tf.resignFirstResponder()
    if let raw = tf.text, let url = Self.normalizeURL(raw) {
      webView.load(URLRequest(url: url))
    }
    return true
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if let u = webView.url?.absoluteString { urlField.text = u }
  }

  static func normalizeURL(_ raw: String) -> URL? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("about:") {
      return URL(string: s)
    }
    if s.contains(".") && !s.contains(" ") {
      return URL(string: "https://" + s)
    }
    let query = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    return URL(string: "https://www.google.com/search?q=" + query)
  }
}
