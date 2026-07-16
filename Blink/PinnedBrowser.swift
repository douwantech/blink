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

struct RecentBrowserTab: Codable, Equatable {
  var title: String
  var url: String
  var createdAt: Date
}

final class RecentBrowserTabsStore {
  static let shared = RecentBrowserTabsStore()
  private let key = "RecentBrowserTabsStore.tabs"
  private let maxCount = 20

  var tabs: [RecentBrowserTab] {
    get {
      guard let data = UserDefaults.standard.data(forKey: key),
            let arr = try? JSONDecoder().decode([RecentBrowserTab].self, from: data) else {
        return []
      }
      // 过滤掉文件已经被系统清掉的（Caches 可能被回收）
      return arr.filter { url in
        guard let u = URL(string: url.url) else { return false }
        if u.isFileURL {
          return FileManager.default.fileExists(atPath: u.path)
        }
        return true
      }
    }
    set {
      var arr = newValue
      if arr.count > maxCount { arr.removeFirst(arr.count - maxCount) }
      let data = (try? JSONEncoder().encode(arr)) ?? Data()
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  func add(title: String, url: String) {
    var arr = tabs
    arr.removeAll { $0.url == url }
    arr.append(RecentBrowserTab(title: title, url: url, createdAt: Date()))
    tabs = arr
  }

  func remove(url: String) {
    tabs = tabs.filter { $0.url != url }
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

/// 方案 A：靠右的磨砂玻璃竖胶囊，合并「语音 + 浏览器」两个浮动钮，可拖动 + 记忆位置
final class FloatingDockBar: UIView {
  private static let kPosX = "FloatingDockBar.posX"
  private static let kPosY = "FloatingDockBar.posY"
  static let barW: CGFloat = 58
  static let barH: CGFloat = 322

  let micButton = UIButton(type: .system)
  let browserButton = UIButton(type: .system)
  let favoritesButton = UIButton(type: .system)
  let historyButton = UIButton(type: .system)
  let refreshButton = UIButton(type: .system)
  let sleepButton = UIButton(type: .system)
  private var dragPan: UIPanGestureRecognizer!
  private var didMove = false

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: Self.barW, height: Self.barH))
    setupUI()
    dragPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    addGestureRecognizer(dragPan)
  }
  required init?(coder: NSCoder) { fatalError() }

  private func setupUI() {
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    blur.frame = bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blur.isUserInteractionEnabled = false
    blur.layer.cornerRadius = 26
    blur.layer.cornerCurve = .continuous
    blur.clipsToBounds = true
    blur.layer.borderWidth = 1
    blur.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    addSubview(blur)

    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.4
    layer.shadowRadius = 12
    layer.shadowOffset = CGSize(width: 0, height: 6)

    let grip = UIView(frame: CGRect(x: (Self.barW - 26) / 2, y: 8, width: 26, height: 4))
    grip.backgroundColor = UIColor.white.withAlphaComponent(0.25)
    grip.layer.cornerRadius = 2
    grip.isUserInteractionEnabled = false
    addSubview(grip)

    // 从上到下：休息(😴) / 浏览器 / 收藏 / 查看历史 / 刷新 / 输入(mic)。输入钮放最下面最好按。
    let x = (Self.barW - 44) / 2
    _configCircle(sleepButton, icon: "moon.zzz.fill", color: .systemGray)
    sleepButton.frame = CGRect(x: x, y: 16, width: 44, height: 44)
    addSubview(sleepButton)

    _configCircle(browserButton, icon: "globe", color: .systemIndigo)
    browserButton.frame = CGRect(x: x, y: 66, width: 44, height: 44)
    addSubview(browserButton)

    _configCircle(favoritesButton, icon: "star.fill", color: .systemYellow)
    favoritesButton.frame = CGRect(x: x, y: 116, width: 44, height: 44)
    addSubview(favoritesButton)

    _configCircle(historyButton, icon: "clock.arrow.circlepath", color: .systemBlue)
    historyButton.frame = CGRect(x: x, y: 166, width: 44, height: 44)
    addSubview(historyButton)

    _configCircle(refreshButton, icon: "arrow.clockwise", color: .systemGreen)
    refreshButton.frame = CGRect(x: x, y: 216, width: 44, height: 44)
    addSubview(refreshButton)

    _configCircle(micButton, icon: "mic.fill", color: .systemTeal)
    micButton.frame = CGRect(x: x, y: 266, width: 44, height: 44)
    addSubview(micButton)
  }

  /// 当前 tab 是否「休息」：休息 → 😴 钮亮紫；否则暗灰。
  func setResting(_ resting: Bool) {
    UIView.animate(withDuration: 0.15) {
      self.sleepButton.backgroundColor = resting ? .systemIndigo : .systemGray
    }
    sleepButton.alpha = resting ? 1.0 : 0.7
  }

  /// 录音中：mic 钮换成停止图标 + 变红；停止后还原。
  func setMicRecording(_ recording: Bool) {
    let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    let name = recording ? "stop.fill" : "mic.fill"
    micButton.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
    UIView.animate(withDuration: 0.15) {
      self.micButton.backgroundColor = recording ? .systemRed : .systemTeal
    }
  }

  private func _configCircle(_ b: UIButton, icon: String, color: UIColor) {
    let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    b.setImage(UIImage(systemName: icon, withConfiguration: cfg), for: .normal)
    b.tintColor = .white
    b.backgroundColor = color
    b.layer.cornerRadius = 22
  }

  func restorePosition(in container: UIView) {
    let d = UserDefaults.standard
    let safe = container.safeAreaInsets
    let defaultX = container.bounds.width - Self.barW - 10 - safe.right
    let defaultY = (container.bounds.height - Self.barH) / 2
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
    return CGPoint(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
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
      }
    default: break
    }
  }
}

/// 独立的「切换机器」浮动条：靠左的磨砂玻璃竖胶囊，每台机器一个头像钮，
/// 点一下直接切到那台机器；长按换头像。可拖动 + 记忆位置，随机器增减自适应高度。
final class FloatingMachineBar: UIView {
  private static let kPosX = "FloatingMachineBar.posX"
  private static let kPosY = "FloatingMachineBar.posY"
  static let barW: CGFloat = 58

  /// 点机器钮 → 切到该机器
  var onSelectMachine: ((String) -> Void)?
  /// 长按机器钮 → 给该机器换头像
  var onEditAvatar: ((String) -> Void)?

  private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private var machineButtons: [UIButton] = []
  private var machineIds: [String] = []
  private var dragPan: UIPanGestureRecognizer!
  private var didMove = false
  private let palette: [UIColor] = [.systemOrange, .systemPink, .systemPurple, .systemTeal,
                                    .systemBlue, .systemGreen, .systemRed, .systemIndigo]

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: Self.barW, height: 72))
    blur.frame = bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blur.isUserInteractionEnabled = false
    blur.layer.cornerRadius = 26
    blur.layer.cornerCurve = .continuous
    blur.clipsToBounds = true
    blur.layer.borderWidth = 1
    blur.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    addSubview(blur)

    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.4
    layer.shadowRadius = 12
    layer.shadowOffset = CGSize(width: 0, height: 6)

    dragPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    addGestureRecognizer(dragPan)
  }
  required init?(coder: NSCoder) { fatalError() }

  /// 按当前机器列表重建头像钮；currentId 高亮
  func reload(currentId: String?) {
    machineButtons.forEach { $0.removeFromSuperview() }
    machineButtons.removeAll()
    machineIds.removeAll()

    let machines = BlinkMachineStore.shared.machines
    if machines.isEmpty { isHidden = true; return }
    // 必须尊重设置里的开关：reload 会在 viewDidLayoutSubviews / 机器变更时被反复调用，
    // 之前这里无条件 isHidden = false，把设置里关掉的状态又冲开了（重启后机器条照样冒出来）。
    isHidden = !BlinkMachineStore.showMachineBar

    let grip = UIView(frame: CGRect(x: (Self.barW - 26) / 2, y: 8, width: 26, height: 4))
    grip.backgroundColor = UIColor.white.withAlphaComponent(0.25)
    grip.layer.cornerRadius = 2
    grip.isUserInteractionEnabled = false
    grip.tag = 9911

    let x = (Self.barW - 44) / 2
    var y: CGFloat = 18
    for (i, m) in machines.enumerated() {
      let b = UIButton(type: .custom)
      b.frame = CGRect(x: x, y: y, width: 44, height: 44)
      b.tag = i
      b.layer.cornerRadius = 22
      b.clipsToBounds = true
      b.imageView?.contentMode = .scaleAspectFill
      if let av = BlinkMachineStore.shared.avatarImage(forId: m.id) {
        b.setImage(_round(av), for: .normal)
        b.backgroundColor = .clear
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
      b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
      b.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
      addSubview(b)
      machineButtons.append(b)
      machineIds.append(m.id)
      y += 50
    }
    // 高度自适应
    let h = 50 * CGFloat(machines.count) + 22
    let oldOrigin = frame.origin
    bounds.size = CGSize(width: Self.barW, height: h)
    frame.origin = oldOrigin
    // grip 加回来（bounds 变了也没事，它锚在顶部）
    addSubview(grip)
    if let c = superview { frame.origin = clampOrigin(frame.origin, in: c) }
  }

  private func _round(_ img: UIImage) -> UIImage {
    let side: CGFloat = 44
    let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
    return r.image { _ in
      let rect = CGRect(x: 0, y: 0, width: side, height: side)
      UIBezierPath(ovalIn: rect).addClip()
      img.draw(in: rect)
    }.withRenderingMode(.alwaysOriginal)
  }

  @objc private func tapped(_ sender: UIButton) {
    guard machineIds.indices.contains(sender.tag) else { return }
    onSelectMachine?(machineIds[sender.tag])
  }

  @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began, let b = g.view as? UIButton,
          machineIds.indices.contains(b.tag) else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    onEditAvatar?(machineIds[b.tag])
  }

  func restorePosition(in container: UIView) {
    let d = UserDefaults.standard
    let safe = container.safeAreaInsets
    let defaultX = safe.left + 10
    let defaultY = (container.bounds.height - bounds.height) / 2
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
    return CGPoint(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
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
      }
    default: break
    }
  }
}

final class PinnedBrowserViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate {
  private let tabBarScroll = UIScrollView()
  private let tabStack = UIStackView()
  private let addTabButton = UIButton(type: .system)
  private let manageTabsButton = UIButton(type: .system)
  private let urlBar = UIView()
  private let urlField = UITextField()
  private let urlLockIcon = UIImageView()
  private let urlSpinner = UIActivityIndicatorView(style: .medium)
  private let urlReloadButton = UIButton(type: .system)
  private let backButton = UIButton(type: .system)
  private let forwardButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)
  // Mac 浏览器缩放控件（底部栏右侧「− 100% +」）
  private let zoomOutButton = UIButton(type: .system)
  private let zoomInButton = UIButton(type: .system)
  private let zoomLabel = UILabel()
  // Mac 浏览器窗口最大化按钮（浮层 ↔ 全屏）
  private let maximizeButton = UIButton(type: .system)
  var onToggleMaximize: (() -> Void)?
  private(set) var isMaximized = false
  /// Mac 大屏判据（真机 isiOSAppOnMac；模拟器可 BlinkForceMacLayout 强开测试），与三栏一致
  private var isMacBrowser: Bool {
    ProcessInfo.processInfo.isiOSAppOnMac || UserDefaults.standard.bool(forKey: "BlinkForceMacLayout")
  }
  private let bottomBar = UIView()
  private let progressBar = UIProgressView(progressViewStyle: .bar)
  private var webView: WKWebView!
  private var progressObs: NSKeyValueObservation?
  private var loadingObs: NSKeyValueObservation?
  private var titleObs: NSKeyValueObservation?
  private var canGoBackObs: NSKeyValueObservation?
  private var canGoForwardObs: NSKeyValueObservation?
  private var emptyStateView: UIView?

  private var tabs: [BrowserTabItem] = []
  private var currentIndex: Int? = nil
  private var activeAuthUser: String?
  private var activeAuthPassword: String?
  private var lastLoadedURLString: String?

  init() {
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  func appendTransientTab(title: String, url: URL, persistent: Bool = false) {
    if !isViewLoaded {
      _ = view // force load
    }
    let urlString = url.absoluteString
    if let i = tabs.firstIndex(where: { $0.isTransient && $0.url == urlString }) {
      selectTab(at: i)
      return
    }
    let item = BrowserTabItem(title: title, url: urlString, authUser: nil, authPassword: nil, isTransient: true)
    tabs.append(item)
    if persistent {
      RecentBrowserTabsStore.shared.add(title: title, url: urlString)
    }
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

    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = .secondaryLabel
    closeButton.backgroundColor = .secondarySystemFill
    closeButton.layer.cornerRadius = 15
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

    addTabButton.setImage(UIImage(systemName: "plus"), for: .normal)
    addTabButton.tintColor = .systemIndigo
    addTabButton.backgroundColor = .secondarySystemFill
    addTabButton.layer.cornerRadius = 15
    addTabButton.addTarget(self, action: #selector(addTabTapped), for: .touchUpInside)
    addTabButton.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(addTabButton)

    manageTabsButton.setImage(UIImage(systemName: "list.bullet"), for: .normal)
    manageTabsButton.tintColor = .secondaryLabel
    manageTabsButton.backgroundColor = .secondarySystemFill
    manageTabsButton.layer.cornerRadius = 15
    manageTabsButton.addTarget(self, action: #selector(manageTabsTapped), for: .touchUpInside)
    manageTabsButton.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(manageTabsButton)

    // Mac：顶栏加窗口最大化按钮（浮层 ↔ 占满整个 Blink 窗口），放在 list 按钮左边
    if isMacBrowser {
      maximizeButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
      maximizeButton.tintColor = .secondaryLabel
      maximizeButton.backgroundColor = .secondarySystemFill
      maximizeButton.layer.cornerRadius = 15
      maximizeButton.addTarget(self, action: #selector(maximizeTapped), for: .touchUpInside)
      maximizeButton.translatesAutoresizingMaskIntoConstraints = false
      topBar.addSubview(maximizeButton)
      NSLayoutConstraint.activate([
        maximizeButton.topAnchor.constraint(equalTo: topBar.topAnchor),
        maximizeButton.trailingAnchor.constraint(equalTo: manageTabsButton.leadingAnchor, constant: -8),
        maximizeButton.widthAnchor.constraint(equalToConstant: 30),
        maximizeButton.heightAnchor.constraint(equalToConstant: 30),
      ])
    }

    urlBar.translatesAutoresizingMaskIntoConstraints = false
    urlBar.backgroundColor = .secondarySystemFill
    urlBar.layer.cornerRadius = 16
    view.addSubview(urlBar)

    urlLockIcon.translatesAutoresizingMaskIntoConstraints = false
    urlLockIcon.contentMode = .scaleAspectFit
    urlLockIcon.tintColor = .secondaryLabel
    urlLockIcon.preferredSymbolConfiguration = .init(pointSize: 12, weight: .medium)
    urlBar.addSubview(urlLockIcon)

    urlSpinner.translatesAutoresizingMaskIntoConstraints = false
    urlSpinner.hidesWhenStopped = true
    urlSpinner.color = .secondaryLabel
    urlBar.addSubview(urlSpinner)

    urlField.translatesAutoresizingMaskIntoConstraints = false
    urlField.placeholder = "搜索或输入网址"
    urlField.borderStyle = .none
    urlField.backgroundColor = .clear
    urlField.autocapitalizationType = .none
    urlField.autocorrectionType = .no
    urlField.keyboardType = .URL
    urlField.returnKeyType = .go
    urlField.clearButtonMode = .whileEditing
    urlField.delegate = self
    urlField.font = .systemFont(ofSize: 14)
    urlField.textAlignment = .center
    urlField.addTarget(self, action: #selector(urlFieldDidBeginEditing), for: .editingDidBegin)
    urlField.addTarget(self, action: #selector(urlFieldDidEndEditing), for: .editingDidEnd)
    urlBar.addSubview(urlField)

    urlReloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
    urlReloadButton.tintColor = .secondaryLabel
    urlReloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)
    urlReloadButton.translatesAutoresizingMaskIntoConstraints = false
    urlBar.addSubview(urlReloadButton)

    progressBar.translatesAutoresizingMaskIntoConstraints = false
    progressBar.progressTintColor = .systemIndigo
    progressBar.trackTintColor = .clear
    progressBar.alpha = 0
    view.addSubview(progressBar)

    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    // 允许 HTML5 <video> 内联渲染/播放（iPhone 默认 false，会导致历史页里的视频整个不显示）
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)

    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.backgroundColor = .secondarySystemBackground
    view.addSubview(bottomBar)

    let topBorder = UIView()
    topBorder.translatesAutoresizingMaskIntoConstraints = false
    topBorder.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
    bottomBar.addSubview(topBorder)

    backButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
    backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
    forwardButton.setImage(UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
    forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)
    for b in [backButton, forwardButton] {
      b.tintColor = .label
      b.translatesAutoresizingMaskIntoConstraints = false
      bottomBar.addSubview(b)
    }

    progressObs = webView.observe(\.estimatedProgress) { [weak self] wv, _ in
      guard let self else { return }
      let p = Float(wv.estimatedProgress)
      self.progressBar.setProgress(p, animated: true)
      if p >= 1.0 {
        UIView.animate(withDuration: 0.25, delay: 0.15, options: []) {
          self.progressBar.alpha = 0
        } completion: { _ in
          self.progressBar.setProgress(0, animated: false)
        }
      } else if self.progressBar.alpha < 1 {
        UIView.animate(withDuration: 0.15) { self.progressBar.alpha = 1 }
      }
    }
    loadingObs = webView.observe(\.isLoading) { [weak self] wv, _ in
      self?.updateLoadingChrome(loading: wv.isLoading)
    }
    titleObs = webView.observe(\.title) { [weak self] wv, _ in
      guard let self, let cur = self.currentIndex, self.tabs.indices.contains(cur) else { return }
      if let t = wv.title, !t.isEmpty, self.tabs[cur].title.isEmpty {
        // 仅 transient tab 才用页面 title 顶替显示，pinned tab 用户填的就别覆盖
        if self.tabs[cur].isTransient {
          self.tabs[cur].title = t
          self.rebuildTabBar()
        }
      }
    }
    canGoBackObs = webView.observe(\.canGoBack) { [weak self] wv, _ in
      self?.backButton.isEnabled = wv.canGoBack
      self?.backButton.alpha = wv.canGoBack ? 1 : 0.3
    }
    canGoForwardObs = webView.observe(\.canGoForward) { [weak self] wv, _ in
      self?.forwardButton.isEnabled = wv.canGoForward
      self?.forwardButton.alpha = wv.canGoForward ? 1 : 0.3
    }
    backButton.isEnabled = false; backButton.alpha = 0.3
    forwardButton.isEnabled = false; forwardButton.alpha = 0.3
    updateLockIcon(forURLString: nil)

    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.heightAnchor.constraint(equalToConstant: 76),

      closeButton.topAnchor.constraint(equalTo: topBar.topAnchor),
      closeButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
      closeButton.widthAnchor.constraint(equalToConstant: 30),
      closeButton.heightAnchor.constraint(equalToConstant: 30),

      addTabButton.topAnchor.constraint(equalTo: topBar.topAnchor),
      addTabButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
      addTabButton.widthAnchor.constraint(equalToConstant: 30),
      addTabButton.heightAnchor.constraint(equalToConstant: 30),

      manageTabsButton.topAnchor.constraint(equalTo: topBar.topAnchor),
      manageTabsButton.trailingAnchor.constraint(equalTo: addTabButton.leadingAnchor, constant: -8),
      manageTabsButton.widthAnchor.constraint(equalToConstant: 30),
      manageTabsButton.heightAnchor.constraint(equalToConstant: 30),

      tabBarScroll.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
      tabBarScroll.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
      tabBarScroll.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
      tabBarScroll.heightAnchor.constraint(equalToConstant: 38),

      tabStack.topAnchor.constraint(equalTo: tabBarScroll.topAnchor),
      tabStack.bottomAnchor.constraint(equalTo: tabBarScroll.bottomAnchor),
      tabStack.leadingAnchor.constraint(equalTo: tabBarScroll.leadingAnchor),
      tabStack.trailingAnchor.constraint(equalTo: tabBarScroll.trailingAnchor),
      tabStack.heightAnchor.constraint(equalTo: tabBarScroll.heightAnchor),

      urlBar.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
      urlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      urlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      urlBar.heightAnchor.constraint(equalToConstant: 32),

      urlLockIcon.leadingAnchor.constraint(equalTo: urlBar.leadingAnchor, constant: 10),
      urlLockIcon.centerYAnchor.constraint(equalTo: urlBar.centerYAnchor),
      urlLockIcon.widthAnchor.constraint(equalToConstant: 14),
      urlLockIcon.heightAnchor.constraint(equalToConstant: 14),

      urlSpinner.centerXAnchor.constraint(equalTo: urlLockIcon.centerXAnchor),
      urlSpinner.centerYAnchor.constraint(equalTo: urlLockIcon.centerYAnchor),

      urlReloadButton.trailingAnchor.constraint(equalTo: urlBar.trailingAnchor, constant: -6),
      urlReloadButton.centerYAnchor.constraint(equalTo: urlBar.centerYAnchor),
      urlReloadButton.widthAnchor.constraint(equalToConstant: 28),
      urlReloadButton.heightAnchor.constraint(equalToConstant: 28),

      urlField.leadingAnchor.constraint(equalTo: urlLockIcon.trailingAnchor, constant: 6),
      urlField.trailingAnchor.constraint(equalTo: urlReloadButton.leadingAnchor, constant: -6),
      urlField.centerYAnchor.constraint(equalTo: urlBar.centerYAnchor),
      urlField.heightAnchor.constraint(equalToConstant: 28),

      progressBar.topAnchor.constraint(equalTo: urlBar.bottomAnchor, constant: 2),
      progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      progressBar.heightAnchor.constraint(equalToConstant: 1.5),

      webView.topAnchor.constraint(equalTo: urlBar.bottomAnchor, constant: 6),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bottomBar.heightAnchor.constraint(equalToConstant: 56),

      topBorder.topAnchor.constraint(equalTo: bottomBar.topAnchor),
      topBorder.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
      topBorder.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
      topBorder.heightAnchor.constraint(equalToConstant: 0.5),

      backButton.centerYAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 22),
      backButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 36),
      backButton.widthAnchor.constraint(equalToConstant: 44),
      backButton.heightAnchor.constraint(equalToConstant: 44),

      forwardButton.centerYAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 22),
      forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 48),
      forwardButton.widthAnchor.constraint(equalToConstant: 44),
      forwardButton.heightAnchor.constraint(equalToConstant: 44),
    ])

    // Mac 大屏：底部栏右侧放缩放控件（网页放大/缩小）。iPhone/iPad 触屏用系统 pinch，不占位置。
    if isMacBrowser {
      _setupBrowserZoomControls()
    }

    let pinned = PinnedTabsStore.shared.tabs.map {
      BrowserTabItem(title: $0.title, url: $0.url, authUser: $0.authUser, authPassword: $0.authPassword, isTransient: false)
    }
    let recent = RecentBrowserTabsStore.shared.tabs.map {
      BrowserTabItem(title: $0.title, url: $0.url, authUser: nil, authPassword: nil, isTransient: true)
    }
    tabs = pinned + recent
    rebuildTabBar()
    if !tabs.isEmpty {
      selectTab(at: 0)
    } else {
      showEmptyHint()
    }
  }

  // MARK: - Mac 浏览器缩放（webView.pageZoom + Cmd ± 0）
  private func _setupBrowserZoomControls() {
    let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    zoomOutButton.setImage(UIImage(systemName: "minus.magnifyingglass", withConfiguration: cfg), for: .normal)
    zoomOutButton.addTarget(self, action: #selector(browserZoomOut), for: .touchUpInside)
    zoomInButton.setImage(UIImage(systemName: "plus.magnifyingglass", withConfiguration: cfg), for: .normal)
    zoomInButton.addTarget(self, action: #selector(browserZoomIn), for: .touchUpInside)
    zoomLabel.text = "100%"
    zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    zoomLabel.textColor = .secondaryLabel
    zoomLabel.textAlignment = .center
    zoomLabel.isUserInteractionEnabled = true
    zoomLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(browserZoomReset)))  // 点百分比＝重置 100%
    for v in [zoomOutButton, zoomInButton] { v.tintColor = .label }
    for v in [zoomOutButton, zoomInButton, zoomLabel] as [UIView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      bottomBar.addSubview(v)
    }
    NSLayoutConstraint.activate([
      zoomInButton.centerYAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 22),
      zoomInButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -36),
      zoomInButton.widthAnchor.constraint(equalToConstant: 44),
      zoomInButton.heightAnchor.constraint(equalToConstant: 44),
      zoomLabel.centerYAnchor.constraint(equalTo: zoomInButton.centerYAnchor),
      zoomLabel.trailingAnchor.constraint(equalTo: zoomInButton.leadingAnchor, constant: -2),
      zoomLabel.widthAnchor.constraint(equalToConstant: 46),
      zoomOutButton.centerYAnchor.constraint(equalTo: zoomInButton.centerYAnchor),
      zoomOutButton.trailingAnchor.constraint(equalTo: zoomLabel.leadingAnchor, constant: -2),
      zoomOutButton.widthAnchor.constraint(equalToConstant: 44),
      zoomOutButton.heightAnchor.constraint(equalToConstant: 44),
    ])
  }

  /// pageZoom 是 WKWebView 级别的强制缩放（不受网页 viewport user-scalable 限制），
  /// 且跨导航/切 tab 保持。范围 50%~300%。
  private func _applyBrowserZoom(_ z: CGFloat) {
    guard webView != nil else { return }
    let clamped = max(0.5, min(3.0, (z * 10).rounded() / 10))
    webView.pageZoom = clamped
    zoomLabel.text = "\(Int((clamped * 100).rounded()))%"
  }
  @objc private func browserZoomIn() { _applyBrowserZoom(webView.pageZoom + 0.1) }
  @objc private func browserZoomOut() { _applyBrowserZoom(webView.pageZoom - 0.1) }
  @objc private func browserZoomReset() { _applyBrowserZoom(1.0) }

  /// Mac 浏览器标准缩放快捷键：⌘+ / ⌘= 放大、⌘- 缩小、⌘0 重置。
  override var keyCommands: [UIKeyCommand]? {
    guard isMacBrowser else { return nil }
    let mk: (String, Selector) -> UIKeyCommand = { input, sel in
      let c = UIKeyCommand(input: input, modifierFlags: .command, action: sel)
      c.wantsPriorityOverSystemBehavior = true
      return c
    }
    return [
      mk("=", #selector(browserZoomIn)),
      mk("+", #selector(browserZoomIn)),
      mk("-", #selector(browserZoomOut)),
      mk("0", #selector(browserZoomReset)),
      mk("r", #selector(browserReload)),   // ⌘R 刷新当前页
    ]
  }

  // MARK: - Mac 浏览器窗口最大化（浮层 ↔ 全屏）
  @objc private func maximizeTapped() { onToggleMaximize?() }

  /// ⌘R 刷新：总是重新加载当前页（区别于顶栏按钮 reloadTapped 的 reload/stop 切换）。
  @objc private func browserReload() { webView.reload() }

  /// 由 SpaceController 在切换呈现方式后调，更新按钮图标（最大化 ⇄ 还原）。
  func setMaximized(_ maxed: Bool) {
    isMaximized = maxed
    let name = maxed ? "arrow.down.forward.and.arrow.up.backward" : "arrow.up.left.and.arrow.down.right"
    maximizeButton.setImage(UIImage(systemName: name), for: .normal)
  }

  private func updateLoadingChrome(loading: Bool) {
    if loading {
      urlSpinner.startAnimating()
      urlLockIcon.isHidden = true
      urlReloadButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    } else {
      urlSpinner.stopAnimating()
      urlLockIcon.isHidden = false
      urlReloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
    }
  }

  private func updateLockIcon(forURLString s: String?) {
    let name: String
    let raw = s ?? ""
    if raw.hasPrefix("https://") { name = "lock.fill" }
    else if raw.hasPrefix("http://") { name = "exclamationmark.triangle.fill" }
    else if raw.hasPrefix("file://") { name = "doc.text.fill" }
    else { name = "globe" }
    urlLockIcon.image = UIImage(systemName: name)
    urlLockIcon.tintColor = (name == "exclamationmark.triangle.fill") ? .systemOrange : .secondaryLabel
  }

  @objc private func urlFieldDidBeginEditing() {
    urlField.textAlignment = .left
    DispatchQueue.main.async { [weak self] in self?.urlField.selectAll(nil) }
  }

  @objc private func urlFieldDidEndEditing() {
    urlField.textAlignment = .center
  }

  deinit {
    progressObs?.invalidate()
    loadingObs?.invalidate()
    titleObs?.invalidate()
    canGoBackObs?.invalidate()
    canGoForwardObs?.invalidate()
  }

  private func showEmptyHint() {
    urlField.text = ""
    emptyStateView?.removeFromSuperview()
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    let icon = UIImageView(image: UIImage(systemName: "rectangle.stack.badge.plus"))
    icon.tintColor = .tertiaryLabel
    icon.preferredSymbolConfiguration = .init(pointSize: 38, weight: .regular)
    icon.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(icon)
    let label = UILabel()
    label.text = "还没有标签\n点右上角 + 添加常用网址"
    label.numberOfLines = 0
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.font = .systemFont(ofSize: 14)
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    webView.addSubview(container)
    NSLayoutConstraint.activate([
      container.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
      container.centerYAnchor.constraint(equalTo: webView.centerYAnchor, constant: -40),
      icon.topAnchor.constraint(equalTo: container.topAnchor),
      icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    emptyStateView = container
  }

  private func hideEmptyHint() {
    emptyStateView?.removeFromSuperview()
    emptyStateView = nil
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
    let truncated = title.count > 16 ? String(title.prefix(15)) + "…" : title
    let displayTitle = transient ? "  " + truncated + "      " : truncated
    chip.setTitle(displayTitle, for: .normal)
    chip.titleLabel?.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .regular)
    let accent: UIColor = transient ? .systemTeal : .systemIndigo
    let fg: UIColor = selected ? .white : .label
    let bg: UIColor = selected ? accent : .secondarySystemFill
    chip.setTitleColor(fg, for: .normal)
    chip.backgroundColor = bg
    chip.layer.cornerRadius = 17
    chip.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
    chip.tag = index
    if transient {
      let leadIcon = UIImageView(image: UIImage(systemName: "doc.text"))
      leadIcon.tintColor = fg
      leadIcon.preferredSymbolConfiguration = .init(pointSize: 12, weight: .medium)
      leadIcon.translatesAutoresizingMaskIntoConstraints = false
      chip.addSubview(leadIcon)
      let xIcon = UIImageView(image: UIImage(systemName: "xmark"))
      xIcon.tintColor = fg.withAlphaComponent(0.85)
      xIcon.preferredSymbolConfiguration = .init(pointSize: 11, weight: .semibold)
      xIcon.translatesAutoresizingMaskIntoConstraints = false
      chip.addSubview(xIcon)
      NSLayoutConstraint.activate([
        leadIcon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        leadIcon.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
        leadIcon.widthAnchor.constraint(equalToConstant: 13),
        leadIcon.heightAnchor.constraint(equalToConstant: 13),
        xIcon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        xIcon.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
        xIcon.widthAnchor.constraint(equalToConstant: 12),
        xIcon.heightAnchor.constraint(equalToConstant: 12),
      ])
      chip.addTarget(self, action: #selector(transientChipTapped(_:event:)), for: .touchUpInside)
    } else {
      chip.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
      let lp = UILongPressGestureRecognizer(target: self, action: #selector(tabLongPressed(_:)))
      lp.minimumPressDuration = 0.5
      chip.addGestureRecognizer(lp)
    }
    if selected {
      chip.layer.shadowColor = accent.cgColor
      chip.layer.shadowRadius = 4
      chip.layer.shadowOpacity = 0.25
      chip.layer.shadowOffset = CGSize(width: 0, height: 1)
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
    let removedURL = tabs[i].url
    tabs.remove(at: i)
    RecentBrowserTabsStore.shared.remove(url: removedURL)
    if let u = URL(string: removedURL), u.isFileURL,
       u.path.contains("BlinkTranscripts") {
      try? FileManager.default.removeItem(at: u)
    }
    if let cur = currentIndex {
      if cur == i {
        currentIndex = nil
        if !tabs.isEmpty {
          selectTab(at: min(i, tabs.count - 1))
        } else {
          webView.load(URLRequest(url: URL(string: "about:blank")!))
          lastLoadedURLString = nil
          urlField.text = ""
          updateLockIcon(forURLString: nil)
          showEmptyHint()
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
    hideEmptyHint()
    currentIndex = i
    let tab = tabs[i]
    activeAuthUser = (tab.authUser?.isEmpty == false) ? tab.authUser : nil
    activeAuthPassword = (tab.authPassword?.isEmpty == false) ? tab.authPassword : nil
    urlField.text = tab.url
    updateLockIcon(forURLString: tab.url)
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

  @objc private func manageTabsTapped() {
    let vc = PinnedTabsManagerViewController()
    vc.onClose = { [weak self] in self?.reloadPinnedTabsFromStore() }
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  private func reloadPinnedTabsFromStore() {
    let newPinned: [BrowserTabItem] = PinnedTabsStore.shared.tabs.map {
      BrowserTabItem(title: $0.title, url: $0.url, authUser: $0.authUser, authPassword: $0.authPassword, isTransient: false)
    }
    let transients = tabs.filter { $0.isTransient }
    let prevURL = currentIndex.flatMap { tabs.indices.contains($0) ? tabs[$0].url : nil }
    tabs = newPinned + transients
    rebuildTabBar()
    if let url = prevURL, let i = tabs.firstIndex(where: { $0.url == url }) {
      currentIndex = i
      rebuildTabBar()
    } else if tabs.isEmpty {
      currentIndex = nil
      urlField.text = ""
      updateLockIcon(forURLString: nil)
      lastLoadedURLString = nil
      webView.load(URLRequest(url: URL(string: "about:blank")!))
      showEmptyHint()
    } else {
      selectTab(at: 0)
    }
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
  @objc private func reloadTapped() {
    if webView.isLoading {
      webView.stopLoading()
    } else {
      webView.reload()
    }
  }
  @objc private func closeTapped() { dismiss(animated: true) }

  func textFieldShouldReturn(_ tf: UITextField) -> Bool {
    tf.resignFirstResponder()
    if let raw = tf.text, let url = Self.normalizeURL(raw) {
      webView.load(URLRequest(url: url))
    }
    return true
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if let u = webView.url?.absoluteString {
      urlField.text = u
      updateLockIcon(forURLString: u)
    }
    if let u = webView.url, u.isFileURL, u.path.contains("BlinkTranscripts") {
      let js = "window.scrollTo(0, document.documentElement.scrollHeight);"
      webView.evaluateJavaScript(js, completionHandler: nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak webView] in
        webView?.evaluateJavaScript(js, completionHandler: nil)
      }
    }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    if let u = webView.url?.absoluteString {
      updateLockIcon(forURLString: u)
    }
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

final class PinnedTabsManagerViewController: UITableViewController {
  var onClose: (() -> Void)?
  private var items: [PinnedTab] = []

  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "固定标签"
    items = PinnedTabsStore.shared.tabs
    navigationItem.leftBarButtonItem = editButtonItem
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped)),
      UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(addTapped)),
    ]
    tableView.allowsSelectionDuringEditing = true
  }

  @objc private func doneTapped() {
    onClose?()
    dismiss(animated: true)
  }

  @objc private func addTapped() {
    presentEditor(forIndex: nil)
  }

  private func save() {
    PinnedTabsStore.shared.tabs = items
  }

  override func numberOfSections(in tv: UITableView) -> Int { items.isEmpty ? 1 : 1 }

  override func tableView(_ tv: UITableView, titleForFooterInSection section: Int) -> String? {
    "拖动排序，左滑删除，点击编辑。\n网址前可加 https://，留空时自动补。\nHTTP Basic 用户名/密码会在加载需要鉴权的页面时自动填入。"
  }

  override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let it = items[ip.row]
    let title = it.title.isEmpty ? it.url : it.title
    cell.textLabel?.text = title
    cell.textLabel?.font = .systemFont(ofSize: 16, weight: .medium)
    cell.detailTextLabel?.text = it.title.isEmpty ? nil : it.url
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.detailTextLabel?.font = .systemFont(ofSize: 12)
    cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
    if it.authUser?.isEmpty == false {
      cell.imageView?.image = UIImage(systemName: "lock.fill")
      cell.imageView?.tintColor = .systemIndigo
    } else {
      cell.imageView?.image = UIImage(systemName: "bookmark.fill")
      cell.imageView?.tintColor = .systemIndigo
    }
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    presentEditor(forIndex: ip.row)
  }

  override func tableView(_ tv: UITableView, canMoveRowAt ip: IndexPath) -> Bool { true }

  override func tableView(_ tv: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
    let item = items.remove(at: from.row)
    items.insert(item, at: to.row)
    save()
  }

  override func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
    if editingStyle == .delete {
      items.remove(at: ip.row)
      save()
      tv.deleteRows(at: [ip], with: .automatic)
    }
  }

  private func presentEditor(forIndex i: Int?) {
    let existing = i.flatMap { items.indices.contains($0) ? items[$0] : nil }
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
      tf.text = existing?.url
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
      let title = (fields.indices.contains(0) ? (fields[0].text ?? "") : "").trimmingCharacters(in: .whitespacesAndNewlines)
      let url = (fields.indices.contains(1) ? (fields[1].text ?? "") : "").trimmingCharacters(in: .whitespacesAndNewlines)
      let user = fields.indices.contains(2) ? (fields[2].text ?? "") : ""
      let pwd = fields.indices.contains(3) ? (fields[3].text ?? "") : ""
      guard !url.isEmpty else { return }
      let item = PinnedTab(
        title: title,
        url: url,
        authUser: user.isEmpty ? nil : user,
        authPassword: pwd.isEmpty ? nil : pwd)
      if let i = i, self.items.indices.contains(i) {
        self.items[i] = item
        self.tableView.reloadRows(at: [IndexPath(row: i, section: 0)], with: .none)
      } else {
        self.items.append(item)
        self.tableView.insertRows(at: [IndexPath(row: self.items.count - 1, section: 0)], with: .automatic)
      }
      self.save()
    })
    present(alert, animated: true)
  }
}
