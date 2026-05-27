//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////
@objc protocol CommandsHUDViewDelegate: NSObjectProtocol {
  func currentTerm() -> TermController?
  func spaceController() -> SpaceController?
}


import MBProgressHUD
import SwiftUI
import WebKit

extension Notification.Name {
  static let blinkActiveSessionDidChange = Notification.Name("BlinkActiveSessionDidChange")
}


// MARK: UIViewController
class SpaceController: UIViewController {
  
  struct UIState: UserActivityCodable {
    var keys: [UUID] = []
    var currentKey: UUID? = nil
    var bgColor: CodableColor? = nil
    
    static var activityType: String { "space.ctrl.ui.state" }
  }

  final private lazy var _viewportsController = UIPageViewController(
    transitionStyle: .scroll,
    navigationOrientation: .horizontal
  )
  
  var sceneRole: UISceneSession.Role = UISceneSession.Role.windowApplication
  
  private var _viewportsKeys = [UUID]() {
    didSet {
      _persistTabsToStore()
      _reloadTabBar()
    }
  }

  private var _currentKey: UUID? = nil {
    didSet {
      guard oldValue != _currentKey else { return }
      if let key = _currentKey {
        let term: TermController = SessionRegistry.shared[key]
        term.meta.hasUnread = false
      }
      TabStateStore.shared.update { $0.currentId = self._currentKey }
      _reloadTabBar()
      NotificationCenter.default.post(name: .blinkActiveSessionDidChange, object: nil)
    }
  }

  private func _persistTabsToStore() {
    let entries: [TabEntry] = _viewportsKeys.map { key in
      let term: TermController = SessionRegistry.shared[key]
      let p = term.mcpParams
      return TabEntry(id: key,
                      machineId: p?.machineId,
                      workDirId: p?.workDirId,
                      tmuxSession: p?.tmuxSession,
                      useTmux: p?.useTmux)
    }
    TabStateStore.shared.update { state in
      state.tabs = entries
    }
  }

  private func _restoreFromStore() {
    let snap = TabStateStore.shared.snapshot()
    guard !snap.tabs.isEmpty else { return }
    for entry in snap.tabs {
      let term: TermController = SessionRegistry.shared[entry.id]
      if term.mcpParams == nil,
         entry.machineId != nil || entry.workDirId != nil || entry.tmuxSession != nil {
        let p = MCPParams()
        p.machineId = entry.machineId
        p.workDirId = entry.workDirId
        p.tmuxSession = entry.tmuxSession
        p.useTmux = entry.useTmux ?? false
        term.bindRestoredMcpParams(p)
      }
    }
    let keys = snap.tabs.map { $0.id }
    _viewportsKeys = keys
    if let cur = snap.currentId, keys.contains(cur) {
      _currentKey = cur
    } else {
      _currentKey = keys.first
    }
  }
  
  private var _hud: MBProgressHUD? = nil
  
  private var _overlay = UIView()
  private var _spaceControllerAnimating: Bool = false
  var stuckKeyCode: KeyCode? = nil
  
  private var _snippetsVC: SnippetsViewController? = nil
  private var _blinkMenu: BlinkMenu? = nil
  private var _bottomTapAreaView = UIView()
  private var _floatingBrowserButton = FloatingBrowserButton(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
  private var _floatingBrowserButtonPlaced = false
  private var _pinnedBrowserVC: PinnedBrowserViewController?
  private lazy var _floatingMicButton: UIButton = {
    let b = UIButton(type: .system)
    let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    b.setImage(UIImage(systemName: "mic.fill", withConfiguration: cfg), for: .normal)
    b.tintColor = .white
    b.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.95)
    b.layer.cornerRadius = 28
    b.layer.shadowColor = UIColor.black.cgColor
    b.layer.shadowOpacity = 0.3
    b.layer.shadowRadius = 6
    b.layer.shadowOffset = CGSize(width: 0, height: 2)
    b.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
    b.isHidden = true
    return b
  }()

  // Snips Input Mode tracking
  private var _isSnipsInputModeActive: Bool = false {
    didSet {
      guard _isSnipsInputModeActive != oldValue else { return }
      _configureCapabilitiesForSnipsInputMode(_isSnipsInputModeActive)
    }
  }

  var isSnipsInputModeActive: Bool {
    _isSnipsInputModeActive
  }

  // Capability flags - independent state that controls what's allowed
  private var canTerminalBecomeFirstResponder: Bool = true {
    didSet {
      guard canTerminalBecomeFirstResponder != oldValue else { return }
      currentTerm()?.shouldBlockFirstResponder = !canTerminalBecomeFirstResponder
    }
  }

  private var canDisplayHUD: Bool = true {
    didSet {
      guard canDisplayHUD != oldValue else { return }
      if !canDisplayHUD {
        _hud?.hide(animated: false)
      }
    }
  }

  private var canSwitchPages: Bool = true {
    didSet {
      guard canSwitchPages != oldValue else { return }
      _setPageViewControllerScrollEnabled(canSwitchPages)
    }
  }

  // Configure capabilities based on input mode
  private func _configureCapabilitiesForSnipsInputMode(_ active: Bool) {
    canTerminalBecomeFirstResponder = !active
    canDisplayHUD = !active
    canSwitchPages = !active
  }

  private func _setPageViewControllerScrollEnabled(_ enabled: Bool) {
    // Find and enable/disable scroll gesture recognizers
    for view in _viewportsController.view.subviews {
      if let scrollView = view as? UIScrollView {
        scrollView.isScrollEnabled = enabled
      }
    }
  }
  
  var safeFrame: CGRect {
    _overlay.frame
  }
  
  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    
    guard let window = view.window
    else {
      return
    }
    
    _snippetsVC?.view.frame = _overlay.frame
    
    if let menu = _blinkMenu {
      let size = _overlay.frame.size;
      let menuSize = menu.layout(for: size)
      
      menu.frame = CGRect(
        x: size.width * 0.5 - menuSize.width * 0.5,
        y: _overlay.frame.size.height - menuSize.height - 20,
        width: menuSize.width,
        height: menuSize.height
      )
      self.view.bringSubviewToFront(menu)
    }
        
    FaceCamManager.update(in: self)
    PipFaceCamManager.update(in: self)
   
    DispatchQueue.main.async {
      self.forEachActive { t in
        if t.viewIsLoaded && t.view?.superview == nil {
          _ = t.removeFromContainer()
        }
      }
    }
    let windowBounds = window.bounds
    let height: CGFloat = 22
    _bottomTapAreaView.frame = CGRect(x: windowBounds.width * 0.5 - 250, y: windowBounds.height - height, width: 250 * 2, height: height)
//    _bottomTapAreaView.backgroundColor = UIColor.red
    self.view.bringSubviewToFront(_bottomTapAreaView);

    let safeTop = view.safeAreaInsets.top
    let tabH: CGFloat = 64
    _statusBarBg.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: safeTop)
    _tabBar.frame = CGRect(x: 0, y: safeTop, width: view.bounds.width, height: tabH)
    view.bringSubviewToFront(_statusBarBg)
    if let v = _viewportsController.view {
      v.frame = CGRect(
        x: 0,
        y: safeTop + tabH,
        width: view.bounds.width,
        height: max(0, view.bounds.height - safeTop - tabH)
      )
    }
    view.bringSubviewToFront(_tabBar)
    if !_floatingBrowserButtonPlaced {
      _floatingBrowserButton.restorePosition(in: view)
      _floatingBrowserButtonPlaced = true
    }
    view.bringSubviewToFront(_floatingBrowserButton)
    _layoutFloatingMicButton()
    view.bringSubviewToFront(_floatingMicButton)
  }

  private func _layoutFloatingMicButton() {
    let insets = view.safeAreaInsets
    let size: CGFloat = 56
    let x = view.bounds.width - size - 16 - insets.right
    let y = view.bounds.height - size - 16 - insets.bottom
    _floatingMicButton.frame = CGRect(x: x, y: y, width: size, height: size)
  }

  @objc private func _voiceInputAutoShowChanged() {
    DispatchQueue.main.async { [weak self] in self?._updateFloatingMicVisibility() }
  }

  @objc private func _keyboardDidShowForMic() {
    // input panel 已经弹出来了，mic 没必要显示
    if !SmarterTermInput.voiceInputAutoShow {
      SmarterTermInput.voiceInputAutoShow = true
    } else {
      _updateFloatingMicVisibility()
    }
  }

  @objc private func _keyboardDidHideForMic() {
    // 不管是 voice、系统键盘，还是滑动 dismiss，input 一收起就把 mic 显出来
    if SmarterTermInput.voiceInputAutoShow {
      SmarterTermInput.voiceInputAutoShow = false
    } else {
      _updateFloatingMicVisibility()
    }
  }

  private func _updateFloatingMicVisibility() {
    _floatingMicButton.isHidden = SmarterTermInput.voiceInputAutoShow
    if !_floatingMicButton.isHidden {
      view.bringSubviewToFront(_floatingMicButton)
    }
  }

  @objc private func _unhideVoiceInput() {
    SmarterTermInput.voiceInputAutoShow = true
    _focusOnShell()
  }

  @objc func _openPinnedBrowser() {
    _presentSharedBrowser()
  }

  @discardableResult
  private func _presentSharedBrowser() -> PinnedBrowserViewController {
    let vc = _pinnedBrowserVC ?? PinnedBrowserViewController()
    _pinnedBrowserVC = vc
    if vc.presentingViewController != nil {
      return vc
    }
    if let sheet = vc.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.selectedDetentIdentifier = .large
      sheet.prefersGrabberVisible = false
      sheet.preferredCornerRadius = 16
      sheet.prefersScrollingExpandsWhenScrolledToEdge = false
    }
    vc.modalPresentationStyle = .pageSheet
    var top: UIViewController = self
    while let presented = top.presentedViewController { top = presented }
    top.present(vc, animated: true)
    return vc
  }

  private func forEachActive(block:(TermController) -> ()) {
    for key in _viewportsKeys {
      if let ctrl: TermController = SessionRegistry.shared.sessionFromIndexWith(key: key) {
        block(ctrl)
      }
    }
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    #if targetEnvironment(macCatalyst)
    guard let appBundleUrl = Bundle.main.builtInPlugInsURL else {
      return
    }
    
    let helperBundleUrl = appBundleUrl.appendingPathComponent("AppKitBridge.bundle")
    
    guard let bundle = Bundle(url: helperBundleUrl) else {
      return
    }
    
    bundle.load()
    
    guard let object = NSClassFromString("AppBridge") as? NSObjectProtocol else {
      return
    }
    
    let selector = NSSelectorFromString("tuneStyle")
    object.perform(selector)
    #endif
  }
  
  private func setupOverlayConstraints() {
    // Overlay positioning to wrap safe areas and keyboard.
    let keyboardGuide = view.keyboardLayoutGuide
    
    _overlay.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      _overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      _overlay.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      _overlay.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      _overlay.bottomAnchor.constraint(equalTo: keyboardGuide.topAnchor)
    ])
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func _setupAppearance() {
    self.view.tintColor = .cyan
    switch BLKDefaults.keyboardStyle() {
    case .light:
      overrideUserInterfaceStyle = .light
    case .dark:
      overrideUserInterfaceStyle = .dark
    default:
      overrideUserInterfaceStyle = .unspecified
    }
  }
  
  private let _tabBar = BlinkTabBar()
  private let _statusBarBg: UIView = {
    let v = UIView()
    v.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
    v.isUserInteractionEnabled = false
    return v
  }()
  private static let kTabFilterMachineId = "BlinkTabFilterMachineId"
  private var _tabFilterMachineId: String? {
    get { UserDefaults.standard.string(forKey: SpaceController.kTabFilterMachineId) }
    set {
      if let v = newValue {
        UserDefaults.standard.set(v, forKey: SpaceController.kTabFilterMachineId)
      } else {
        UserDefaults.standard.removeObject(forKey: SpaceController.kTabFilterMachineId)
      }
    }
  }

  public override func viewDidLoad() {
    super.viewDidLoad()

    _setupAppearance()

    view.isOpaque = true

    _viewportsController.view.isOpaque = true
    _viewportsController.dataSource = self
    _viewportsController.delegate = self


    addChild(_viewportsController)

    _statusBarBg.translatesAutoresizingMaskIntoConstraints = true
    _statusBarBg.autoresizingMask = [.flexibleWidth]
    view.addSubview(_statusBarBg)

    _tabBar.delegate = self
    _tabBar.translatesAutoresizingMaskIntoConstraints = true
    _tabBar.autoresizingMask = [.flexibleWidth]
    view.addSubview(_tabBar)

    if let v = _viewportsController.view {
      v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      v.layoutMargins = .zero
      v.frame = view.bounds
      view.addSubview(v)
    }

    _viewportsController.didMove(toParent: self)

    _overlay.isUserInteractionEnabled = false
    view.addSubview(_overlay)

    _registerForNotifications()

    setupOverlayConstraints()
    
    if _viewportsKeys.isEmpty {
      _restoreFromStore()
    }
    if _viewportsKeys.isEmpty {
      _newShellAction(animated: false)
    } else if let key = _currentKey {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = self
      // term.layoutProvider = self
      term.bgColor = view.backgroundColor ?? .black
      _viewportsController.setViewControllers([term], direction: .forward, animated: false)
    }
    _sortTabsByMachineAndDir()
        
    self.view.addSubview(_bottomTapAreaView)

    _floatingBrowserButton.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
    _floatingBrowserButton.addTarget(self, action: #selector(_openPinnedBrowser), for: .touchUpInside)
    view.addSubview(_floatingBrowserButton)

    _floatingMicButton.addTarget(self, action: #selector(_unhideVoiceInput), for: .touchUpInside)
    view.addSubview(_floatingMicButton)
    NotificationCenter.default.addObserver(self, selector: #selector(_voiceInputAutoShowChanged), name: .voiceInputAutoShowChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(_keyboardDidShowForMic), name: UIResponder.keyboardDidShowNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(_keyboardDidHideForMic), name: UIResponder.keyboardDidHideNotification, object: nil)
    _updateFloatingMicVisibility()

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleQuickActionsAction))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.numberOfTouchesRequired = 1
    _bottomTapAreaView.addGestureRecognizer(doubleTap)
    
    NotificationCenter.default.addObserver(self, selector: #selector(_geoTrackStateChanged), name: NSNotification.Name.BLGeoTrackStateChange, object: nil)
    
//    view.addSubview(_faceCam)
//    addChild(_faceCam.controller)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { self.alertSubscriptionGroupViolation() }

    view.bringSubviewToFront(_tabBar)
  }

  func alertSubscriptionGroupViolation() {
    // NOTE: Added just in case, as I have seen in RevCat some users ending up in both groups (bc
    // things can still be selected outside the App).
    let msg = """
You may be in two different subscription groups and hence, you may end up overpaying for Blink.
Please go to your subscriptions and cancel one of them!
"""
    
    if EntitlementsManager.shared.groupsCheckViolation() {
      let ctrl = UIAlertController(title: "Important!", message: msg, preferredStyle: .alert)
      ctrl.addAction(UIAlertAction(title: "Ok", style: .default))
      self.present(ctrl, animated: true)
    }
  }
  
  func showAlert(msg: String) {
    let ctrl = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
    ctrl.addAction(UIAlertAction(title: "Ok", style: .default))
    self.present(ctrl, animated: true)
  }
  
  func _registerForNotifications() {
    let nc = NotificationCenter.default
    
    nc.addObserver(self,
                   selector: #selector(_didBecomeKeyWindow),
                   name: UIWindow.didBecomeKeyNotification,
                   object: nil)
    
    nc.addObserver(self, selector:#selector(_didBecomeKeyWindow), name: UIApplication.didBecomeActiveNotification, object: nil)
    
    nc.addObserver(self, selector: #selector(_setupAppearance),
                   name: NSNotification.Name(rawValue: BKAppearanceChanged),
                   object: nil)
    
    nc.addObserver(self, selector: #selector(_UISceneDidEnterBackgroundNotification(_:)),
                   name: UIScene.didEnterBackgroundNotification, object: nil)
    
    nc.addObserver(self, selector: #selector(_UISceneWillEnterForegroundNotification(_:)),
                   name: UIScene.willEnterForegroundNotification, object: nil)

    nc.addObserver(self, selector: #selector(_activeSessionDidChange),
                   name: .blinkActiveSessionDidChange, object: nil)

    nc.addObserver(self, selector: #selector(_tabAttention(_:)),
                   name: NSNotification.Name("BlinkTabAttention"), object: nil)

    nc.addObserver(self, selector: #selector(_flushTabStateStore),
                   name: UIApplication.willResignActiveNotification, object: nil)
    nc.addObserver(self, selector: #selector(_flushTabStateStore),
                   name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  @objc private func _flushTabStateStore() {
    TabStateStore.shared.flushNow()
  }

  @objc private func _activeSessionDidChange() {
    DispatchQueue.main.async { [weak self] in self?._reloadTabBar() }
  }

  @objc private func _tabAttention(_ n: Notification) {
    guard let term = n.object as? TermController else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self._viewportsKeys.contains(term.meta.key) else { return }
      if term.meta.key == self._currentKey { return }
      term.meta.hasUnread = true
      self._reloadTabBar()
    }
  }
                   
  @objc func _UISceneDidEnterBackgroundNotification(_ n: Notification) {
    guard let scene = n.object as? UIWindowScene,
          view.window?.windowScene === scene
    else {
      return
    }
    
    let currentTerm = currentTerm()
    
    forEachActive { ctrl in
      if ctrl.viewIsLoaded && ctrl !== currentTerm {
        _ = ctrl.removeFromContainer()
      }
    }
  }
  
  @objc func _UISceneWillEnterForegroundNotification(_ n: Notification) {
    guard let scene = n.object as? UIWindowScene
    else {
      return
    }
    
    #if targetEnvironment(macCatalyst)
    
    if scene.session.persistentIdentifier.hasPrefix("NSMenuBarScene") {
      KBTracker.shared.input?.reportStateWithSelection()
      return
    }
    
    #endif
    
    if scene.session.role == .windowExternalDisplayNonInteractive,
      let sharedWindow = ShadowWindow.shared,
       sharedWindow === view.window,
       let ctrl = sharedWindow.spaceController.currentTerm() {
      
      ctrl.resumeIfNeeded()
    }
    
    guard view.window?.windowScene === scene
    else {
      return
    }
    
    forEachActive { ctrl in
      if ctrl.viewIsLoaded {
        ctrl.placeToContainer()
      }
    }
   
    currentTerm()?.resumeIfNeeded()
   
    #if targetEnvironment(macCatalyst)
    #else
    if view.window === KBTracker.shared.input?.window {
      KBTracker.shared.input?.reportStateWithSelection()
    }
    #endif
  }
    
  @objc func _didBecomeKeyWindow() {
    guard
      presentedViewController == nil,
      let window = view.window,
      window.isKeyWindow
    else {
      currentDevice?.blur()
      return
    }
    
    _focusOnShell()
  }
  
  func _createTerminal(
    userActivity: NSUserActivity?,
    animated: Bool,
    sessionPayload: TermSessionPayload,
    completion: ((Bool) -> Void)? = nil)
  {
    let term = TermController(sceneRole: sceneRole, sessionPayload: sessionPayload)
    term.delegate = self
    //term.layoutProvider = self
    term.userActivity = userActivity
    term.bgColor = view.backgroundColor ?? .black
    
    SessionRegistry.shared.track(session: term)

    if let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)?.advanced(by: 1) {
      _viewportsKeys.insert(term.meta.key, at: idx)
    } else {
      _viewportsKeys.insert(term.meta.key, at: _viewportsKeys.count)
    }

    _currentKey = term.meta.key
    _sortTabsByMachineAndDir()

    _viewportsController.setViewControllers([term], direction: .forward, animated: animated) { (didComplete) in
      self._displayHUD()
      self._attachInputToCurrentTerm()
      completion?(didComplete)
    }
  }
  
  func _closeCurrentSpace() {
    currentTerm()?.terminate()
    _removeCurrentSpace()
  }
  
  private func _removeCurrentSpace(attachInput: Bool = true) {
    guard
      let currentKey = _currentKey,
      let idx = _viewportsKeys.firstIndex(of: currentKey)
    else {
      return
    }
    currentTerm()?.delegate = nil
    SessionRegistry.shared.remove(forKey: currentKey)
    _viewportsKeys.remove(at: idx)
    if _viewportsKeys.isEmpty {
      _newShellAction(animated: false)
      return
    }

    let direction: UIPageViewController.NavigationDirection
    let term: TermController
    
    if idx < _viewportsKeys.endIndex {
      direction = .forward
      term = SessionRegistry.shared[_viewportsKeys[idx]]
    } else {
      direction = .reverse
      term = SessionRegistry.shared[_viewportsKeys[idx - 1]]
    }
    term.bgColor = view.backgroundColor ?? .black
    
    self._currentKey = term.meta.key
    
    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([term], direction: direction, animated: true) { (didComplete) in
      self._displayHUD()
      if attachInput {
        self._attachInputToCurrentTerm()
      }
      self._spaceControllerAnimating = false
    }
  }
  
  @objc func _focusOnShell() {
    _attachInputToCurrentTerm()
  }
  
  
  private func _attachInputToCurrentTerm() {
    // Check capability flag instead of mode directly
    guard canTerminalBecomeFirstResponder else {
      return
    }
    currentTerm()?.activateInput()
  }
  
  var currentDevice: TermDevice? {
    currentTerm()?.termDevice
  }
  
  private func _displayHUD() {
    _hud?.hide(animated: false)

    // Check capability flag instead of mode directly
    guard canDisplayHUD else {
      return
    }

    guard let term = currentTerm() else {
      return
    }
    
    if let bgColor = term.view.backgroundColor, bgColor != .clear {
      view.backgroundColor = bgColor
      _viewportsController.view.backgroundColor = bgColor
      view.window?.backgroundColor = bgColor
    }

    let title = term.title?.isEmpty == true ? nil : term.title
    let pageNum = _viewportsKeys.firstIndex(of: term.meta.key)
    var sceneTitle = "[\(pageNum == nil ? 1 : pageNum! + 1) of \(_viewportsKeys.count)] \(title ?? "blink")"
    if !(term.termView.rows == 0 && term.termView.cols == 0) {
      sceneTitle += " | \(term.termView.cols)×\(term.termView.rows)"
    }
    view.window?.windowScene?.title = sceneTitle
    self.view.setNeedsLayout()
  }
  
}

// MARK: UIStateRestorable
extension SpaceController: UIStateRestorable {
  func restore(withState state: UIState) {
    if let bgColor = UIColor(codableColor: state.bgColor) {
      view.backgroundColor = bgColor
    }
  }

  func dumpUIState() -> UIState {
    return UIState(keys: [],
            currentKey: nil,
            bgColor: CodableColor(uiColor: view.backgroundColor)
    )
  }

  @objc static func onDidDiscardSceneSessions(_ sessions: Set<UISceneSession>) {
    // Intentionally no-op. SessionRegistry has its own _cleanLostSessions sweep
    // that reconciles orphan session files. The NSUserActivity path is no
    // longer authoritative for tab keys (TabStateStore is), so discarding a
    // scene must not touch the registry — that would wipe live tabs.
  }
}

// MARK: UIPageViewControllerDelegate
extension SpaceController: UIPageViewControllerDelegate {
  public func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool) {
    guard completed else {
      return
    }

    guard let termController = pageViewController.viewControllers?.first as? TermController
    else {
      return
    }
    termController.resumeIfNeeded()
    _currentKey = termController.meta.key
    // swipe 跨到了另一台机器：同步 filter 到新机器
    if let curFilter = _tabFilterMachineId,
       let mid = termController.mcpParams?.machineId,
       mid != curFilter {
      _tabFilterMachineId = mid
      _reloadTabBar()
    }
    _displayHUD()
    _attachInputToCurrentTerm()

  }
}

// MARK: UIPageViewControllerDataSource
extension SpaceController: UIPageViewControllerDataSource {
  private func _controller(controller: UIViewController, advancedBy: Int) -> UIViewController? {
    guard let ctrl = controller as? TermController else { return nil }
    let key = ctrl.meta.key
    let filtered = _filteredViewportsKeys()
    if let pos = filtered.firstIndex(of: key)?.advanced(by: advancedBy),
       filtered.indices.contains(pos) {
      let newCtrl: TermController = SessionRegistry.shared[filtered[pos]]
      newCtrl.delegate = self
      newCtrl.bgColor = view.backgroundColor ?? .black
      return newCtrl
    }
    // 越界：filter 非 nil + ≥2 台机器 → 跨到下一台机器的端点 tab
    guard let curFilter = _tabFilterMachineId else { return nil }
    let machineIds = _machineIdsWithTabs()
    guard machineIds.count > 1,
          let curMid = machineIds.firstIndex(of: curFilter) else { return nil }
    let nextMid = (curMid + (advancedBy > 0 ? 1 : -1) + machineIds.count) % machineIds.count
    let nextFilterId = machineIds[nextMid]
    let nextFiltered = _viewportsKeys.filter { k in
      let t: TermController = SessionRegistry.shared[k]
      return t.mcpParams?.machineId == nextFilterId
    }
    guard let targetKey = (advancedBy > 0 ? nextFiltered.first : nextFiltered.last) else { return nil }
    let newCtrl: TermController = SessionRegistry.shared[targetKey]
    newCtrl.delegate = self
    newCtrl.bgColor = view.backgroundColor ?? .black
    return newCtrl
  }
  
  public func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
    _controller(controller: viewController, advancedBy: -1)
  }

  public func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
    _controller(controller: viewController, advancedBy: 1)
  }
  
}

// MARK: TermControlDelegate
extension SpaceController: TermControlDelegate {
  
  func terminalHangup(control: TermController) {
    if currentTerm() == control {
      _closeCurrentSpace()
    }
  }
  
  func terminalDidResize(control: TermController) {
    if currentTerm() == control {
      _displayHUD()
    }
  }
}

// MARK: General tunning

extension SpaceController {
  public override var prefersStatusBarHidden: Bool { false }
  public override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  public override var prefersHomeIndicatorAutoHidden: Bool { true }
}


// MARK: Commands

extension SpaceController {
  
  var foregroundActive: Bool {
    view.window?.windowScene?.activationState == UIScene.ActivationState.foregroundActive
  }
  
  public override var keyCommands: [UIKeyCommand]? {
    guard
      let input = KBTracker.shared.input,
      foregroundActive
    else {
      return nil
    }
    
    if let keyCode = stuckKeyCode {
      return [UIKeyCommand(input: "", modifierFlags: keyCode.modifierFlags, action: #selector(onStuckOpCommand))]
    }
    
    return input.blinkKeyCommands
  }
  
  @objc func onStuckOpCommand() {
    stuckKeyCode = nil
    presentedViewController?.dismiss(animated: true)
    _focusOnShell()
  }
  
  @objc func _onBlinkCommand(_ cmd: BlinkCommand) {
    guard foregroundActive,
          let input = currentDevice?.view?.browserView ?? currentDevice?.view?.webView else {
      return
    }
    
//    input.reportStateReset()
    switch cmd.bindingAction {
    case .hex(let hex, stringInput: _, comment: _):
      input.reportHex(hex)
    case .press(let keyCode, mods: let mods):
      input.reportPress(UIKeyModifierFlags(rawValue: mods), keyId: keyCode.id)
    case .command(let c):
      _onCommand(c)
    default:
      break;
    }
  }
  
  @objc func _onShortcut(_ event: UICommand) {
    guard
      let propertyList = event.propertyList as? [String:String],
      let cmd = Command(rawValue: propertyList["Command"]!)
    else {
      return
    }
    _onCommand(cmd)
  }
  
  func _onCommand(_ cmd: Command) {
    guard foregroundActive else {
      return
    }

    switch cmd {
    case .configShow: showConfigAction()
    case .snippetsShow: showSnippetsAction()
    case .scratchShow: showScratchAction()
    case .toggleQuickActions: toggleQuickActionsAction()
    case .toggleGeoTrack: toggleGeoTrack()
    case .tab1: _moveToShell(idx: 0)
    case .tab2: _moveToShell(idx: 1)
    case .tab3: _moveToShell(idx: 2)
    case .tab4: _moveToShell(idx: 3)
    case .tab5: _moveToShell(idx: 4)
    case .tab6: _moveToShell(idx: 5)
    case .tab7: _moveToShell(idx: 6)
    case .tab8: _moveToShell(idx: 7)
    case .tab9: _moveToShell(idx: 8)
    case .tab10: _moveToShell(idx: 9)
    case .tab11: _moveToShell(idx: 10)
    case .tab12: _moveToShell(idx: 11)
    case .tabClose: _closeCurrentSpace()
    case .tabMoveToOtherWindow: _moveToOtherWindowAction()
    case .toggleKeyCast: _toggleKeyCast()
    case .tabNew: _newShellAction()
    case .tabNext: _advanceShell(by: 1)
    case .tabPrev: _advanceShell(by: -1)
    case .tabNextCycling: _advanceShellCycling(by: 1)
    case .tabPrevCycling: _advanceShellCycling(by: -1)
    case .tabLast: _moveToLastShell()
    case .windowClose: _closeWindowAction()
    case .windowFocusOther: _focusOtherWindowAction()
    case .windowNew: _newWindowAction()
    case .clipboardCopy: KBTracker.shared.input?.copy(self)
    case .clipboardCopyRaw: KBTracker.shared.input?.copyRaw(self)
    case .clipboardPaste: KBTracker.shared.input?.paste(self)
    case .selectionGoogle: KBTracker.shared.input?.googleSelection(self)
    case .selectionStackOverflow: KBTracker.shared.input?.soSelection(self)
    case .selectionShare: KBTracker.shared.input?.shareSelection(self)
    case .zoomIn: currentTerm()?.termView.increaseFontSize()
    case .zoomOut: currentTerm()?.termView.decreaseFontSize()
    case .zoomReset: currentTerm()?.termView.resetFontSize()
    case .hideKeyboard: KBTracker.shared.input?.resignFirstResponder()

    }
  }
  
  @objc func focusOnShellAction() {
    KBTracker.shared.input?.reset()
    _focusOnShell()
  }
  
  @objc public func scaleWithPich(_ pinch: UIPinchGestureRecognizer) {
    currentTerm()?.scaleWithPich(pinch)
  }
  
  private func _newShellAction(command: String = "", animated: Bool = true) {
    let params = MCPParams()
    if !command.isEmpty {
      params.initialCommand = command
    }
    let payload = MCPSessionPayload(params: params)
    _createTerminal(userActivity: nil, animated: animated, sessionPayload: payload)
  }

  fileprivate func _newShellWithMachine(_ machineId: String, workDirId: String?, tmuxSession: String?) {
    let params = MCPParams()
    params.machineId = machineId
    params.workDirId = workDirId
    params.tmuxSession = tmuxSession
    let payload = MCPSessionPayload(params: params)
    _createTerminal(userActivity: nil, animated: true, sessionPayload: payload)
  }

  @objc func newShellAction() {
    _newShellAction()
  }

  @objc func closeShellAction() {
    _closeCurrentSpace()
  }

  @objc func dumpTranscriptForCurrentShell() {
    guard let oldTerm = currentTerm(),
          let p = oldTerm.mcpParams,
          let machineId = p.machineId, !machineId.isEmpty,
          let baseName = p.tmuxSession, !baseName.isEmpty,
          let cmd = BlinkMachineStore.shared.transcriptCommand(
            forMachineId: machineId, workDirId: p.workDirId, baseName: baseName) else { return }

    let oldKey = _currentKey
    let params = MCPParams()
    params.initialCommand = cmd
    let payload = MCPSessionPayload(params: params)

    UIPasteboard.general.string = "__BLINK_TRANSCRIPT_PENDING__"

    _createTerminal(userActivity: nil, animated: false, sessionPayload: payload) { [weak self] _ in
      guard let self else { return }
      let scratchKey = self._currentKey
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        guard let scratchKey,
              let webView = (SessionRegistry.shared[scratchKey] as TermController).termDevice.view?.webView else {
          self._finishTranscriptDump(scratchKey: scratchKey, oldKey: oldKey, text: "[scratch webView 不存在]")
          return
        }
        webView.evaluateJavaScript("typeof term_setClipboardWrite === 'function' ? (term_setClipboardWrite(true), 'enabled') : 'no function'") { _, _ in
          self._pollPasteboardForTranscript(scratchKey: scratchKey, oldKey: oldKey,
                                            deadline: Date(timeIntervalSinceNow: 5))
        }
      }
    }
  }

  private func _pollPasteboardForTranscript(scratchKey: UUID?, oldKey: UUID?, deadline: Date) {
    let pb = UIPasteboard.general.string ?? ""
    if pb != "__BLINK_TRANSCRIPT_PENDING__" && !pb.isEmpty {
      let text: String
      if let data = Data(base64Encoded: pb), let decoded = String(data: data, encoding: .utf8) {
        text = decoded
      } else {
        text = pb
      }
      _finishTranscriptDump(scratchKey: scratchKey, oldKey: oldKey, text: text)
      return
    }
    if Date() > deadline {
      _finishTranscriptDump(scratchKey: scratchKey, oldKey: oldKey, text: "[超时未拿到剪贴板内容]")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?._pollPasteboardForTranscript(scratchKey: scratchKey, oldKey: oldKey, deadline: deadline)
    }
  }

  private func _pollTranscriptSentinel(scratchKey: UUID?, deadline: Date,
                                       callback: @escaping (String) -> Void) {
    guard let scratchKey else { callback(""); return }
    let term: TermController = SessionRegistry.shared[scratchKey]
    guard let webView = term.termDevice.view?.webView else {
      callback(""); return
    }
    let js = """
    (function(){
      try {
        var t = window.t;
        var sb0 = t && t.scrollbackRows_ && t.scrollbackRows_.length > 0 ? t.scrollbackRows_[5] : null;
        var xr0 = document.querySelectorAll('x-row')[5];
        var info = '[url=' + location.href.split('/').pop() +
          ' hasT=' + (!!t) +
          ' alt=' + (!!(t && t.alternateScreen_ && t.screen_ === t.alternateScreen_)) +
          ' sb=' + (t && t.scrollbackRows_ ? t.scrollbackRows_.length : -1) +
          ' priLen=' + (t && t.primaryScreen_ ? t.primaryScreen_.rowsArray.length : -1) +
          ' xrow=' + document.querySelectorAll('x-row').length +
          ' sb5_nodeName=' + (sb0 ? sb0.nodeName : 'NULL') +
          ' sb5_text=' + (sb0 ? '"' + (sb0.textContent || '').substring(0,40) + '"' : 'NULL') +
          ' xr5_outerHTML=' + (xr0 ? xr0.outerHTML.substring(0,80) : 'NULL') +
          ' bodyTextLen=' + document.body.textContent.length + ']';
        var rows = [];
        if (t && t.scrollbackRows_ && t.screen_ && t.screen_.rowsArray) {
          var sb = t.scrollbackRows_, vis = t.screen_.rowsArray;
          for (var i = 0; i < sb.length; i++) {
            rows.push((sb[i] && sb[i].textContent ? sb[i].textContent : '').replace(/\\u00A0/g,' ').replace(/\\s+$/,''));
          }
          for (var i = 0; i < vis.length; i++) {
            rows.push((vis[i] && vis[i].textContent ? vis[i].textContent : '').replace(/\\u00A0/g,' ').replace(/\\s+$/,''));
          }
        } else {
          rows = Array.from(document.querySelectorAll('x-row')).map(function(r){
            return (r.textContent || '').replace(/\\u00A0/g,' ').replace(/\\s+$/,'');
          });
        }
        return info + '\\n' + rows.join('\\n');
      } catch(e) { return '[js error: ' + e.message + ']'; }
    })()
    """
    webView.evaluateJavaScript(js) { [weak self] result, _ in
      guard let self else { return }
      let text = (result as? String) ?? ""
      if text.contains("===END_TRANSCRIPT===") {
        callback(text)
        return
      }
      if Date() > deadline {
        let visible = text
          .replacingOccurrences(of: " ", with: "·")
          .replacingOccurrences(of: "\t", with: "→")
        let trimmedLines = visible.components(separatedBy: "\n").map { line -> String in
          let stripped = line.replacingOccurrences(of: "·", with: "").trimmingCharacters(in: .whitespaces)
          return stripped.isEmpty ? "<空>" : line
        }
        let info = "[超时] count=\(text.count) lines=\(trimmedLines.count)\n---hterm dump (·=空格)---\n\(trimmedLines.joined(separator: "\n"))"
        callback(info)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        self._pollTranscriptSentinel(scratchKey: scratchKey, deadline: deadline, callback: callback)
      }
    }
  }

  private func _finishTranscriptDump(scratchKey: UUID?, oldKey: UUID?, text: String) {
    let cleaned = _extractTranscriptBody(from: text)

    guard let scratchKey, let oldKey,
          let oldIdx = _viewportsKeys.firstIndex(of: oldKey) else {
      _presentTranscriptModal(text: cleaned)
      return
    }

    let oldTerm: TermController = SessionRegistry.shared[oldKey]
    _currentKey = oldKey
    _viewportsController.setViewControllers([oldTerm], direction: .reverse, animated: false) { [weak self] _ in
      guard let self else { return }
      let scratch: TermController = SessionRegistry.shared[scratchKey]
      scratch.delegate = nil
      scratch.terminate()
      if let idx = self._viewportsKeys.firstIndex(of: scratchKey) {
        self._viewportsKeys.remove(at: idx)
      }
      SessionRegistry.shared.remove(forKey: scratchKey)
      _ = oldIdx
      self._sortTabsByMachineAndDir()
      self._displayHUD()
      self._attachInputToCurrentTerm()
      self._presentTranscriptModal(text: cleaned)
    }
  }

  private func _extractTranscriptBody(from raw: String) -> String {
    guard let endRange = raw.range(of: "===END_TRANSCRIPT===") else {
      return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let lines = raw[..<endRange.lowerBound].components(separatedBy: "\n")
    var start = 0
    for (i, line) in lines.enumerated() {
      if line.hasPrefix("=== ") && line.contains(".jsonl") { start = i; break }
      if line.contains("NOT_FOUND") { start = i; break }
    }
    return lines[start..<lines.count].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func _presentTranscriptModal(text: String) {
    let body = text.isEmpty ? "<empty>" : text
    let html = TranscriptViewController.htmlFor(transcript: body)
    let cacheRoot = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = cacheRoot.appendingPathComponent("BlinkTranscripts", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = Int(Date().timeIntervalSince1970)
    let file = dir.appendingPathComponent("blink-transcript-\(stamp).html")
    do {
      try html.write(to: file, atomically: true, encoding: .utf8)
    } catch {
      let vc = TranscriptViewController(text: body)
      let nav = UINavigationController(rootViewController: vc)
      nav.modalPresentationStyle = .pageSheet
      present(nav, animated: true)
      return
    }
    let label = _transcriptTabLabel(forCurrentTerm: currentTerm())
    let vc = _presentSharedBrowser()
    vc.appendTransientTab(title: label, url: file, persistent: true)
  }

  private func _transcriptTabLabel(forCurrentTerm term: TermController?) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let time = f.string(from: Date())
    if let name = term?.mcpParams?.tmuxSession, !name.isEmpty {
      return "\(name) \(time)"
    }
    return "对话记录 \(time)"
  }

  @objc func reloadCurrentShell() {
    guard let oldTerm = currentTerm(),
          let oldKey = _currentKey,
          let oldIdx = _viewportsKeys.firstIndex(of: oldKey),
          let p = oldTerm.mcpParams,
          let machineId = p.machineId, !machineId.isEmpty else { return }

    let params = MCPParams()
    params.machineId = machineId
    params.workDirId = p.workDirId
    params.tmuxSession = p.tmuxSession
    params.useTmux = p.useTmux
    let payload = MCPSessionPayload(params: params)

    let newTerm = TermController(sceneRole: sceneRole, sessionPayload: payload)
    newTerm.delegate = self
    newTerm.bgColor = view.backgroundColor ?? .black
    SessionRegistry.shared.track(session: newTerm)

    _viewportsKeys.insert(newTerm.meta.key, at: oldIdx + 1)
    _currentKey = newTerm.meta.key

    _viewportsController.setViewControllers([newTerm], direction: .forward, animated: true) { _ in
      let stale: TermController = SessionRegistry.shared[oldKey]
      stale.delegate = nil
      stale.terminate()
      if let removeIdx = self._viewportsKeys.firstIndex(of: oldKey) {
        self._viewportsKeys.remove(at: removeIdx)
      }
      SessionRegistry.shared.remove(forKey: oldKey)
      self._sortTabsByMachineAndDir()
      self._displayHUD()
      self._attachInputToCurrentTerm()
    }
  }

  fileprivate func _reloadTabBar() {
    var titles: [String] = []
    var unread: [Bool] = []
    var tags: [Int] = []

    let allMachineIds = BlinkMachineStore.shared.machines.map { $0.id }
    let usedIds: [String] = _viewportsKeys.compactMap {
      (SessionRegistry.shared[$0] as TermController).mcpParams?.machineId
    }
    var filterId = _tabFilterMachineId
    let stale = filterId == nil
      || !(filterId.map { allMachineIds.contains($0) } ?? false)
      || (!usedIds.isEmpty && !(filterId.map { usedIds.contains($0) } ?? false))
    if stale {
      filterId = usedIds.first ?? allMachineIds.first
      if filterId != nil {
        _tabFilterMachineId = filterId
      }
    }
    let curIndex = _currentKey.flatMap { _viewportsKeys.firstIndex(of: $0) } ?? -1
    for (idx, key) in _viewportsKeys.enumerated() {
      let term: TermController = SessionRegistry.shared[key]
      let title: String
      if let p = term.mcpParams {
        let workDir = BlinkWorkDirStore.shared.workDir(forId: p.workDirId)
        let dirPart = (workDir?.name.isEmpty == false) ? workDir!.name : ""
        var sessionPart = (p.tmuxSession?.isEmpty == false) ? p.tmuxSession! : ""
        if !dirPart.isEmpty && !sessionPart.isEmpty {
          if let lastDash = sessionPart.lastIndex(of: "-") {
            sessionPart = String(sessionPart[sessionPart.index(after: lastDash)...])
          }
          if sessionPart == dirPart { sessionPart = "" }
        }
        let composed: String
        if !dirPart.isEmpty && !sessionPart.isEmpty {
          composed = "\(dirPart):\(sessionPart)"
        } else if !dirPart.isEmpty {
          composed = dirPart
        } else if !sessionPart.isEmpty {
          composed = sessionPart
        } else {
          composed = BlinkMachineStore.effectiveTmuxSessionName(
            workDirId: p.workDirId, tmuxSession: p.tmuxSession)
        }
        term.meta.tabTitle = composed
        title = composed
      } else {
        title = term.meta.tabTitle ?? "Tab \(idx + 1)"
      }
      let mid = term.mcpParams?.machineId
      if let f = filterId, mid != f { continue }
      titles.append(title)
      unread.append(term.meta.hasUnread)
      tags.append(idx)
    }
    let chipTitle: String
    if let fid = filterId, let m = BlinkMachineStore.shared.machines.first(where: { $0.id == fid }) {
      chipTitle = m.displayName
    } else {
      chipTitle = "全部"
    }
    _tabBar.reload(titles: titles, unread: unread, tags: tags, filterTitle: chipTitle, currentTag: curIndex)
  }

  private func _focusOtherWindowAction() {
    
    var sessions = _activeSessions()
    
    guard
      sessions.count > 1,
      let session = view.window?.windowScene?.session,
      let idx = sessions.firstIndex(of: session)?.advanced(by: 1)
    else  {
      if currentTerm()?.termView.isFocused() == true {
        currentTerm()?.resignInput()
      } else {
        _focusOnShell()
      }
      return
    }

    if
      let shadowWindow = ShadowWindow.shared,
      let shadowScene = shadowWindow.windowScene,
      let window = self.view.window,
      shadowScene == window.windowScene,
      shadowWindow !== window {
      shadowWindow.makeKeyAndVisible()
      shadowWindow.spaceController._focusOnShell()
      return
    }
          
    sessions = sessions.filter { $0.role != .windowExternalDisplayNonInteractive }
    
    let nextSession: UISceneSession
    if idx < sessions.endIndex {
      nextSession = sessions[idx]
    } else {
      nextSession = sessions[0]
    }
    
    if
      let scene = nextSession.scene as? UIWindowScene,
      let delegate = scene.delegate as? SceneDelegate,
      let window = delegate.window,
      let spaceCtrl = window.rootViewController as? SpaceController {

      if window.isKeyWindow {
        spaceCtrl._focusOnShell()
      } else {
        window.makeKeyAndVisible()
      }
    } else {
      UIApplication.shared.requestSceneSessionActivation(nextSession, userActivity: nil, options: nil, errorHandler: nil)
    }
  }
  
  private func _moveToOtherWindowAction() {
    var sessions = _activeSessions()
    
    guard
      sessions.count > 1,
      let session = view.window?.windowScene?.session,
      let idx = sessions.firstIndex(of: session)?.advanced(by: 1),
      let term = currentTerm(),
      _spaceControllerAnimating == false
    else  {
        return
    }
    
    if
      let shadowWindow = ShadowWindow.shared,
      let shadowScene = shadowWindow.windowScene,
      let window = self.view.window,
      shadowScene == window.windowScene,
      shadowWindow !== window {

      term.prepareForWindowMove()
      _removeCurrentSpace(attachInput: false)
      shadowWindow.makeKey()
      shadowWindow.spaceController._addTerm(term: term)
      return
    }
          
    sessions = sessions.filter { $0.role != .windowExternalDisplayNonInteractive }
    
    let nextSession: UISceneSession
    if idx < sessions.endIndex {
      nextSession = sessions[idx]
    } else {
      nextSession = sessions[0]
    }
    
    guard
      let nextScene = nextSession.scene as? UIWindowScene,
      let delegate = nextScene.delegate as? SceneDelegate,
      let nextWindow = delegate.window,
      let nextSpaceCtrl = nextWindow.rootViewController as? SpaceController,
      nextSpaceCtrl._spaceControllerAnimating == false
    else {
      return
    }


    term.prepareForWindowMove()
    _removeCurrentSpace(attachInput: false)
    nextSpaceCtrl._addTerm(term: term)
    nextWindow.makeKey()
  }
  
  func _toggleKeyCast() {
    BLKDefaults.setKeycasts(!BLKDefaults.isKeyCastsOn())
    BLKDefaults.save()
  }
  
  func _activeSessions() -> [UISceneSession] {
    Array(UIApplication.shared.openSessions)
      .filter({ $0.scene?.activationState == .foregroundActive || $0.scene?.activationState == .foregroundInactive })
      .sorted(by: { $0.persistentIdentifier < $1.persistentIdentifier })
  }
  
  @objc func _newWindowAction() {
    let options = UIWindowScene.ActivationRequestOptions()
    options.requestingScene = self.view.window?.windowScene
    
    UIApplication
      .shared
      .requestSceneSessionActivation(nil,
                                     userActivity: nil,
                                     options: options,
                                     errorHandler: nil)
  }
  
  @objc func _closeWindowAction() {
    guard
      let session = view.window?.windowScene?.session,
      session.role == .windowApplication // Can't close windows on external monitor
    else {
      return
    }
    
    // try to focus on other session before closing
    _focusOtherWindowAction()
    
    UIApplication
      .shared
      .requestSceneSessionDestruction(session,
                                      options: nil,
                                      errorHandler: nil)
  }
  
  @objc func showConfigAction() {
    if let shadowWindow = ShadowWindow.shared,
      view.window == shadowWindow {
      
      _ = currentDevice?.view?.webView.resignFirstResponder()
      
      let spCtrl = shadowWindow.windowScene?.windows.first?.rootViewController as? SpaceController
      spCtrl?.showConfigAction()
      
      return
    }

    DispatchQueue.main.async {
      self.currentTerm()?.resignInput()
      let navCtrl = UINavigationController()
      navCtrl.navigationBar.prefersLargeTitles = true
      let s = SettingsHostingController.createSettings(nav: navCtrl, onDismiss: {
        [weak self] in self?.focusOnShellAction()
      })
      navCtrl.setViewControllers([s], animated: false)
      self.present(navCtrl, animated: true, completion: nil)
    }
  }
  
//  @objc func showWalkthroughAction() {
//    if self.view.window == ShadowWindow.shared {
//      return
//    }
//    DispatchQueue.main.async {
//      _ = KBTracker.shared.input?.resignFirstResponder()
//      let ctrl = UIHostingController(rootView: WalkthroughView(urlHandler: blink_openurl,
//                                                               dismissHandler: { self.dismiss(animated: true) })
//      )
//      ctrl.modalPresentationStyle = .formSheet
//      self.present(ctrl, animated: false)
//    }
//  }
  
  @objc func showSnippetsAction() {
    if let _ = _snippetsVC {
      return
    }
    self.presentSnippetsController()
    if let _ = self._interactiveSpaceController()._blinkMenu {
      self.toggleQuickActionsAction()
    }
  }

  @objc func showScratchAction() {
    if let _ = _snippetsVC {
      return
    }
    self.presentSnippetsControllerWithScratch()
    // if let _ = self._interactiveSpaceController()._blinkMenu {
    //   self.toggleQuickActionsAction()
    // }
  }

  private func _toggleQuickActionActionWith(receiver: SpaceController) {
    if let menu = _blinkMenu {
      _blinkMenu = nil
      UIView.animate(withDuration: 0.15) {
        menu.alpha = 0
      } completion: { _ in
        menu.removeFromSuperview()
      }
    } else {
      let menu = BlinkMenu()
      self.view.addSubview(menu.tapToCloseView)
      
      var ids: [BlinkActionID] = []
      ids.append(contentsOf:  [.snippets, .tabClose, .tabCreate])
      
      if DeviceInfo.shared().hasCorners {
        ids.append(contentsOf:  [.layoutMenu])
      }
      ids.append(contentsOf:  [.toggleLayoutLock, .toggleGeoTrack])
      menu.delegate = receiver;
      menu.build(withIDs: ids, andAppearance: [:])
      _blinkMenu = menu
      self.view.addSubview(menu)
      let size = self.view.frame.size;
      let menuSize = menu.layout(for: size)
      
      let finalMenuFrame = CGRect(x: size.width * 0.5 - menuSize.width * 0.5, y: _overlay.frame.maxY - menuSize.height - 20, width: menuSize.width, height: menuSize.height)
      
      menu.frame = CGRect(origin: CGPoint(x: finalMenuFrame.minX, y: _overlay.frame.maxY + 10), size: finalMenuFrame.size);
      
      UIView.animate(withDuration: 0.25) {
        menu.frame = finalMenuFrame
      }
    }
  }
  
  func _interactiveSpaceController() -> SpaceController {
    if let shadowWin = ShadowWindow.shared,
       self.view.window == shadowWin,
       let mainScreenSession = _activeSessions()
          .first(where: {$0.role == .windowApplication }),
       let delegate = mainScreenSession.scene?.delegate as? SceneDelegate
    {
      return delegate.spaceController
    }
    return self
  }
  
  @objc func toggleQuickActionsAction() {
    _interactiveSpaceController()
      ._toggleQuickActionActionWith(receiver: self)
  }
  
  @objc func toggleGeoTrack() {
    if GeoManager.shared().traking {
      GeoManager.shared().stop()
      return
    }

    let manager = CLLocationManager()
    let status = manager.authorizationStatus
    
    switch status  {
    case .authorizedAlways, .authorizedWhenInUse: break
    case .restricted:
      showAlert(msg: "Geo services are restricted on this device.")
      return
    case .denied:
      showAlert(msg: "Please allow Blink.app to use geo in Settings.app.")
      return
    case .notDetermined:
      GeoManager.shared().authorize()
      return
    @unknown default:
      return
    }
    
    GeoManager.shared().start()
  }
  
  @objc func _geoTrackStateChanged() {
    self.view.setNeedsLayout()
  }
  
  @objc func showWhatsNewAction() {
    if let shadowWindow = ShadowWindow.shared,
      view.window == shadowWindow {

      _ = currentDevice?.view?.webView.resignFirstResponder()

      let spCtrl = shadowWindow.windowScene?.windows.first?.rootViewController as? SpaceController
      spCtrl?.showWhatsNewAction()

      return
    }

    DispatchQueue.main.async {
      self.currentTerm()?.resignInput()
      WhatsNewInfo.setNewVersion()

      let urlString = XCConfig.infoPlistWhatsNewGithubURL()

      if let url = URL(string: urlString) {
        let redirectURL = url.customerTierURL()
        var request = URLRequest(url: redirectURL)
        request.httpMethod = "HEAD"

        URLSession.shared.dataTask(with: request) { _, response, error in
          if error == nil,
             let httpResponse = response as? HTTPURLResponse,
             httpResponse.statusCode == 302,
             let finalURL = response?.url {
            blink_openurl(finalURL)
          } else {
            // Fallback if we cannot get the current announcement
            blink_openurl(URL(string: "https://github.com/blinksh/blink/discussions/categories/announcements")!)
          }
        }.resume()
      }
    }
  }
  
  private func _addTerm(term: TermController, animated: Bool = true) {
    SessionRegistry.shared.track(session: term)
    term.delegate = self
    _viewportsKeys.append(term.meta.key)
    _moveToShell(key: term.meta.key, animated: animated)
  }
  
  private func _moveToShell(idx: Int, animated: Bool = true) {
    guard _viewportsKeys.indices.contains(idx) else {
      return
    }

    let key = _viewportsKeys[idx]
    
    _moveToShell(key: key, animated: animated)
  }
  
  private func _moveToLastShell(animated: Bool = true) {
    _moveToShell(idx: _viewportsKeys.count - 1)
  }
  
  @objc func moveToShell(key: String?) {
    guard
      let key = key,
      let uuidKey = UUID(uuidString: key)
    else {
      return
    }
    _moveToShell(key: uuidKey, animated: true)
  }
  
  private func _moveToShell(key: UUID, animated: Bool = true) {
    guard
      let currentKey = _currentKey,
      let currentIdx = _viewportsKeys.firstIndex(of: currentKey),
      let idx = _viewportsKeys.firstIndex(of: key)
    else {
      return
    }
    
    let term: TermController = SessionRegistry.shared[key]
    let direction: UIPageViewController.NavigationDirection = currentIdx < idx ? .forward : .reverse

    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([term], direction: direction, animated: animated) { (didComplete) in
      term.resumeIfNeeded()
      self._currentKey = term.meta.key
      self._displayHUD()
      self._attachInputToCurrentTerm()
      self._spaceControllerAnimating = false
    }
  }
  
  private func _filteredViewportsKeys() -> [UUID] {
    guard let filterId = _tabFilterMachineId else { return _viewportsKeys }
    return _viewportsKeys.filter { key in
      let term: TermController = SessionRegistry.shared[key]
      return term.mcpParams?.machineId == filterId
    }
  }

  private func _advanceShell(by: Int, animated: Bool = true) {
    let filtered = _filteredViewportsKeys()
    guard let currentKey = _currentKey else { return }
    if let pos = filtered.firstIndex(of: currentKey)?.advanced(by: by),
       filtered.indices.contains(pos),
       let idx = _viewportsKeys.firstIndex(of: filtered[pos]) {
      _moveToShell(idx: idx, animated: animated)
      return
    }
    // 当前 filter 内走到尽头：切到下一台机器（仅当 filter 非 nil 且有 >=2 台机器有 tab）
    guard let curFilter = _tabFilterMachineId else { return }
    let machineIds = _machineIdsWithTabs()
    guard machineIds.count > 1,
          let curMachinePos = machineIds.firstIndex(of: curFilter) else { return }
    let nextMachinePos = (curMachinePos + (by > 0 ? 1 : -1) + machineIds.count) % machineIds.count
    let newFilterId = machineIds[nextMachinePos]
    _tabFilterMachineId = newFilterId
    let newFiltered = _filteredViewportsKeys()
    guard let targetKey = (by > 0 ? newFiltered.first : newFiltered.last),
          let idx = _viewportsKeys.firstIndex(of: targetKey) else { return }
    _moveToShell(idx: idx, animated: animated)
    _reloadTabBar()
  }

  private func _sortTabsByMachineAndDir() {
    let machineOrder = Dictionary(uniqueKeysWithValues:
      BlinkMachineStore.shared.machines.enumerated().map { ($0.element.id, $0.offset) })
    let workDirOrder = Dictionary(uniqueKeysWithValues:
      BlinkWorkDirStore.shared.workDirs.enumerated().map { ($0.element.id, $0.offset) })

    let indexed = _viewportsKeys.enumerated().map { (offset: $0.offset, key: $0.element) }
    let sorted = indexed.sorted { a, b in
      let ta: TermController = SessionRegistry.shared[a.key]
      let tb: TermController = SessionRegistry.shared[b.key]
      let mka = ta.mcpParams?.machineId.flatMap { machineOrder[$0] } ?? Int.max
      let mkb = tb.mcpParams?.machineId.flatMap { machineOrder[$0] } ?? Int.max
      if mka != mkb { return mka < mkb }
      let dka = ta.mcpParams?.workDirId.flatMap { workDirOrder[$0] } ?? Int.max
      let dkb = tb.mcpParams?.workDirId.flatMap { workDirOrder[$0] } ?? Int.max
      if dka != dkb { return dka < dkb }
      return a.offset < b.offset  // 同组内保持原序
    }.map { $0.key }
    if sorted == _viewportsKeys { return }
    _viewportsKeys = sorted
  }

  private func _machineIdsWithTabs() -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for key in _viewportsKeys {
      let term: TermController = SessionRegistry.shared[key]
      guard let mid = term.mcpParams?.machineId else { continue }
      if seen.insert(mid).inserted {
        out.append(mid)
      }
    }
    return out
  }

  private func _advanceShellCycling(by: Int, animated: Bool = true) {
    let filtered = _filteredViewportsKeys()
    guard let currentKey = _currentKey, filtered.count > 1 else { return }
    let target: UUID
    if let pos = filtered.firstIndex(of: currentKey)?.advanced(by: by),
       pos >= 0 && pos < filtered.count {
      target = filtered[pos]
    } else {
      target = filtered[by > 0 ? 0 : filtered.count - 1]
    }
    guard let idx = _viewportsKeys.firstIndex(of: target) else { return }
    _moveToShell(idx: idx, animated: animated)
  }
  
}

// MARK: CommandsHUDDelegate
extension SpaceController: CommandsHUDDelegate {
  @objc func currentTerm() -> TermController? {
    if let currentKey = _currentKey {
      return SessionRegistry.shared[currentKey]
    }
    return nil
  }
  
  @objc func spaceController() -> SpaceController? { self }
}

// MARK: SnippetContext

extension SpaceController: SnippetContext {
  
  func _presentSnippetsController(receiver: SpaceController, openScratch: Bool = false) {
    do {
      self.view.window?.makeKeyAndVisible()
      let ctrl = try SnippetsViewController.create(context: receiver, transitionFrame: _blinkMenu?.bounds)
      ctrl.pendingOpenScratch = openScratch
      DispatchQueue.main.async {
        ctrl.view.frame = self.view.bounds
        ctrl.willMove(toParent: self)
        self.view.addSubview(ctrl.view)
        self.addChild(ctrl)
        ctrl.didMove(toParent: self)
        self._snippetsVC = ctrl
        self._isSnipsInputModeActive = true
      }
    } catch {
      self.showAlert(msg: "Could not display Snips: \(error)")
    }
  }

  func presentSnippetsController() {
    _interactiveSpaceController()._presentSnippetsController(receiver: self)
  }

  func presentSnippetsControllerWithScratch() {
    _interactiveSpaceController()._presentSnippetsController(receiver: self, openScratch: true)
  }
  
  func _dismissSnippetsController(ctrl: SpaceController) {
    ctrl.presentedViewController?.dismiss(animated: true)
    ctrl._snippetsVC?.willMove(toParent: nil)
    ctrl._snippetsVC?.view.removeFromSuperview()
    ctrl._snippetsVC?.removeFromParent()
    ctrl._snippetsVC?.didMove(toParent: nil)
    ctrl._snippetsVC = nil
    ctrl._isSnipsInputModeActive = false
  }
  
  func dismissSnippetsController() {
    _dismissSnippetsController(ctrl: _interactiveSpaceController())
    self.focusOnShellAction()
  }
  
  func providerSnippetReceiver() -> (any SnippetReceiver)? {
    self.focusOnShellAction()
    return self.currentDevice
  }

}

// MARK: SceneIntent handlers
extension SpaceController {
  @objc func runShellSessionIntent(command: String = "") {
    DispatchQueue.main.sync {
      self._newShellAction(command: command)
    }
  }

}

extension SpaceController: BlinkTabBarDelegate {
  public func tabBarDidSelect(index: Int) {
    guard _viewportsKeys.indices.contains(index) else { return }
    let key = _viewportsKeys[index]
    if key == _currentKey { return }
    let term: TermController = SessionRegistry.shared[key]
    term.delegate = self
    term.bgColor = view.backgroundColor ?? .black
    let curIdx = _currentKey.flatMap { _viewportsKeys.firstIndex(of: $0) } ?? 0
    let direction: UIPageViewController.NavigationDirection = (index >= curIdx) ? .forward : .reverse
    _viewportsController.setViewControllers([term], direction: direction, animated: true) { [weak self] _ in
      self?._currentKey = key
    }
  }

  public func tabBarDidRequestNew() {
    let vc = NewTabViewController()
    vc.onCreate = { [weak self] machineId, workDirId, tmuxSession in
      self?._newShellWithMachine(machineId, workDirId: workDirId, tmuxSession: tmuxSession)
    }
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  public func tabBarDidRequestSettings() {
    let vc = VoiceSettingsViewController(voiceView: nil)
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .fullScreen
    present(nav, animated: true)
  }

  public func tabBarDidRequestClose(index: Int) {
    guard _viewportsKeys.indices.contains(index) else { return }
    let key = _viewportsKeys[index]
    if key != _currentKey {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = self
      term.bgColor = view.backgroundColor ?? .black
      _viewportsController.setViewControllers([term], direction: .forward, animated: false)
      _currentKey = key
    }
    closeShellAction()
  }

  public func tabBarDidRequestMachineFilter() {
    let allMachines = BlinkMachineStore.shared.machines
    let alert = UIAlertController(title: "选择机器", message: nil, preferredStyle: .actionSheet)
    for m in allMachines {
      let mark = (_tabFilterMachineId == m.id) ? " ✓" : ""
      alert.addAction(UIAlertAction(title: m.displayName + mark, style: .default) { [weak self] _ in
        guard let self else { return }
        self._tabFilterMachineId = m.id
        let filtered = self._filteredViewportsKeys()
        if let cur = self._currentKey, filtered.contains(cur) {
          self._reloadTabBar()
        } else if let first = filtered.first, let idx = self._viewportsKeys.firstIndex(of: first) {
          self._moveToShell(idx: idx, animated: false)
        } else {
          self._reloadTabBar()
        }
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let pop = alert.popoverPresentationController {
      pop.sourceView = _tabBar
      pop.sourceRect = _tabBar.bounds
    }
    present(alert, animated: true)
  }
}

final class TranscriptViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
  private let webView: WKWebView
  private let bodyText: String
  private var didFinishInitialLoad = false

  init(text: String) {
    self.bodyText = text
    let config = WKWebViewConfiguration()
    config.userContentController = WKUserContentController()
    self.webView = WKWebView(frame: .zero, configuration: config)
    super.init(nibName: nil, bundle: nil)
    webView.configuration.userContentController.add(self, name: "copy")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  func userContentController(_ ctrl: WKUserContentController, didReceive msg: WKScriptMessage) {
    guard msg.name == "copy", let text = msg.body as? String else { return }
    UIPasteboard.general.string = text
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = "Transcript"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(closeTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .action, target: self, action: #selector(shareTapped))

    webView.isOpaque = false
    webView.backgroundColor = .systemBackground
    webView.scrollView.backgroundColor = .systemBackground
    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    webView.loadHTMLString(Self.htmlFor(transcript: bodyText), baseURL: nil)
  }

  static func htmlFor(transcript: String) -> String {
    let payloadB64 = Data(transcript.utf8).base64EncodedString()
    return #"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
           padding: 16px 16px 40px; line-height: 1.55; color: #1d1d1f; background: #fff;
           font-size: 15px; word-wrap: break-word; }
    h1, h2, h3 { font-weight: 600; margin: 1em 0 0.5em; }
    h1 { font-size: 1.4em; } h2 { font-size: 1.25em; } h3 { font-size: 1.1em; }
    .msg-head { display: flex; align-items: center; justify-content: space-between;
                margin: 1.8em 0 0.5em; padding-bottom: 4px; border-bottom: 1px solid #d2d2d7; }
    .role { font-weight: 600; font-size: 1.05em; }
    .role-user { color: #007aff; }
    .role-claude { color: #34c759; }
    .copy-btn { font: 12px -apple-system, sans-serif; color: #007aff; background: transparent;
                border: 1px solid #007aff; border-radius: 5px; padding: 3px 10px; cursor: pointer;
                -webkit-tap-highlight-color: transparent; }
    .copy-btn:active { background: rgba(0,122,255,0.15); }
    .copy-btn.copied { color: #34c759; border-color: #34c759; }
    .msg-body { margin-bottom: 0.5em; }
    .meta { color: #86868b; font-size: 11px; font-family: ui-monospace, Menlo, monospace; }
    pre { background: #f5f5f7; padding: 12px; border-radius: 8px; overflow-x: auto;
          font-family: ui-monospace, Menlo, monospace; font-size: 13px; line-height: 1.45;
          margin: 0.6em 0; }
    code { background: #f0f0f3; padding: 2px 5px; border-radius: 4px;
           font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; margin: 0.8em 0; display: block; overflow-x: auto;
            font-size: 0.92em; }
    th, td { border: 1px solid #d2d2d7; padding: 6px 10px; text-align: left; }
    th { background: #f5f5f7; font-weight: 600; }
    ul, ol { padding-left: 1.5em; margin: 0.5em 0; }
    li { margin: 0.2em 0; }
    a { color: #007aff; text-decoration: none; }
    blockquote { border-left: 3px solid #d2d2d7; padding-left: 12px; margin: 0.6em 0;
                 color: #515154; }
    hr { border: none; border-top: 1px solid #d2d2d7; margin: 1.5em 0; }
    p { margin: 0.5em 0; }
    img.md-img { max-width: 100%; border-radius: 8px; margin: 0.5em 0; cursor: zoom-in; display: block; }
    #lightbox { position: fixed; top: 0; left: 0; right: 0; bottom: 0;
                background: rgba(0,0,0,0.94); display: none; align-items: center;
                justify-content: center; z-index: 9999; touch-action: none; }
    #lightbox.show { display: flex; }
    #lightbox img { max-width: 96vw; max-height: 96vh; object-fit: contain;
                    touch-action: none; user-select: none; -webkit-user-select: none;
                    will-change: transform; transform-origin: center center; }
    #lightbox-close { position: absolute; top: max(16px, env(safe-area-inset-top));
                      right: 16px; width: 40px; height: 40px; border-radius: 20px;
                      background: rgba(255,255,255,0.18); color: #fff; border: none;
                      font-size: 20px; line-height: 40px; text-align: center; padding: 0; }
    @media (prefers-color-scheme: dark) {
      body { background: #000; color: #f2f2f7; }
      h1, h2, h3 { color: #f2f2f7; }
      .msg-head { border-bottom-color: #38383a; }
      .copy-btn { color: #0a84ff; border-color: #0a84ff; }
      .copy-btn.copied { color: #30d158; border-color: #30d158; }
      pre, code { background: #1c1c1e; }
      th, td { border-color: #38383a; }
      th { background: #1c1c1e; }
      blockquote { border-left-color: #38383a; color: #98989d; }
      hr { border-top-color: #38383a; }
      .meta { color: #98989d; }
      a { color: #0a84ff; }
      .role-user { color: #0a84ff; }
      .role-claude { color: #30d158; }
    }
    </style>
    </head>
    <body>
    <div id="content">…</div>
    <div id="lightbox"><img id="lightbox-img" src=""><button id="lightbox-close">✕</button></div>
    <script>
    (function() {
      var lb = document.getElementById('lightbox');
      var lbImg = document.getElementById('lightbox-img');
      var lbClose = document.getElementById('lightbox-close');
      var scale = 1, tx = 0, ty = 0;
      var startDist = 0, startScale = 1;
      var startX = 0, startY = 0, startTx = 0, startTy = 0;
      var mode = 'idle'; // idle | pan | pinch
      var movedSignificantly = false;
      var lastTap = 0;
      function apply() { lbImg.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')'; }
      function reset() { scale = 1; tx = 0; ty = 0; apply(); }
      function dist(a, b) { var dx = a.clientX - b.clientX, dy = a.clientY - b.clientY; return Math.sqrt(dx*dx + dy*dy); }
      function close() { lb.classList.remove('show'); lbImg.src = ''; reset(); }

      document.addEventListener('click', function(e) {
        if (e.target.tagName === 'IMG' && e.target.classList.contains('md-img')) {
          lbImg.src = e.target.src;
          reset();
          lb.classList.add('show');
          e.preventDefault();
        }
      });
      lbClose.addEventListener('click', function(e) { close(); e.stopPropagation(); });
      lb.addEventListener('touchstart', function(e) {
        if (e.touches.length === 2) {
          mode = 'pinch';
          startDist = dist(e.touches[0], e.touches[1]);
          startScale = scale;
          startTx = tx; startTy = ty;
          movedSignificantly = true;
          e.preventDefault();
        } else if (e.touches.length === 1) {
          startX = e.touches[0].clientX;
          startY = e.touches[0].clientY;
          startTx = tx; startTy = ty;
          mode = scale > 1 ? 'pan' : 'maybe-tap';
          movedSignificantly = false;
        }
      }, { passive: false });
      lb.addEventListener('touchmove', function(e) {
        if (mode === 'pinch' && e.touches.length === 2) {
          var d = dist(e.touches[0], e.touches[1]);
          scale = Math.max(1, Math.min(5, startScale * d / startDist));
          if (scale === 1) { tx = 0; ty = 0; } else { tx = startTx; ty = startTy; }
          apply();
          e.preventDefault();
        } else if ((mode === 'pan' || mode === 'maybe-tap') && e.touches.length === 1) {
          var dx = e.touches[0].clientX - startX;
          var dy = e.touches[0].clientY - startY;
          if (Math.abs(dx) > 6 || Math.abs(dy) > 6) movedSignificantly = true;
          if (scale > 1) {
            tx = startTx + dx; ty = startTy + dy; apply(); e.preventDefault();
          }
        }
      }, { passive: false });
      lb.addEventListener('touchend', function(e) {
        if (mode === 'maybe-tap' && !movedSignificantly && e.touches.length === 0) {
          var now = Date.now();
          if (now - lastTap < 300) {
            scale = scale > 1 ? 1 : 2.5;
            if (scale === 1) { tx = 0; ty = 0; }
            apply();
            lastTap = 0;
          } else {
            lastTap = now;
            setTimeout(function() {
              if (Date.now() - lastTap >= 290 && scale === 1) close();
            }, 300);
          }
        }
        if (e.touches.length === 0) mode = 'idle';
      });
    })();
    function escapeHTML(s) {
      return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }
    function decodeB64(b64) {
      const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
      return new TextDecoder('utf-8').decode(bytes);
    }
    function renderInline(s) {
      // 1. inline code 先做（避免 code 内 markdown 被解析）
      s = s.replace(/`([^`]+)`/g, (_, c) => '<code>' + escapeHTML(c) + '</code>');
      // 2. markdown image ![alt](url)
      s = s.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (_, alt, url) =>
        '<img class="md-img" src="' + url + '" alt="' + alt + '">');
      // 3. markdown link [text](url) — image-like url 也转成图片
      s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, text, url) => {
        if (/\.(?:jpe?g|png|gif|webp|bmp|heic|svg)(?:\?.*)?$/i.test(url)) {
          return '<img class="md-img" src="' + url + '" alt="' + text + '">';
        }
        return '<a href="' + url + '">' + text + '</a>';
      });
      // 4. bare image URL — 必须在 bold/italic 之前处理，否则会被 ** 包成 plain 粗体
      s = s.replace(/(https?:\/\/[^\s<"\)]+?\.(?:jpe?g|png|gif|webp|bmp|heic|svg)(?:\?[^\s<"\)]*)?)/gi,
        (m) => '<img class="md-img" src="' + m + '">');
      // 5. bare URL → <a> ，已有的 <a>/<img>/<code> 先 stash 起来避免重复包裹
      var placeholders = [];
      function stash(m) { placeholders.push(m); return '\x00P' + (placeholders.length - 1) + '\x00'; }
      s = s.replace(/<a\b[^>]*>[\s\S]*?<\/a>/gi, stash);
      s = s.replace(/<img\b[^>]*>/gi, stash);
      s = s.replace(/<code\b[^>]*>[\s\S]*?<\/code>/gi, stash);
      s = s.replace(/(https?:\/\/[^\s<>"'`]+)/gi, (m) => {
        var trail = '';
        var clean = m;
        var trailing = clean.match(/[.,;:!?\]\)]+$/);
        if (trailing) {
          trail = trailing[0];
          clean = clean.slice(0, -trail.length);
        }
        return '<a href="' + clean + '">' + clean + '</a>' + trail;
      });
      s = s.replace(/\x00P(\d+)\x00/g, (_, i) => placeholders[parseInt(i, 10)]);
      // 6. bold / italic（此时 image URL 已经是 <img>，不会被吞）
      s = s.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
      s = s.replace(/(?<![*\w])\*([^*\n]+)\*(?!\*)/g, '<em>$1</em>');
      return s;
    }
    function utf8B64(s) {
      return btoa(unescape(encodeURIComponent(s)));
    }
    function renderBlocks(text) {
      const lines = text.split('\n');
      let html = '';
      let i = 0;
      while (i < lines.length) {
        const line = lines[i];
        // role marker: 把 role 块（直到下一个 role/===）整体包成 msg-block
        if (/^[▶◆]/.test(line)) {
          const isUser = /^▶/.test(line);
          const roleLabel = isUser ? '你' : 'Claude';
          const roleClass = isUser ? 'role-user' : 'role-claude';
          i++;
          const bodyLines = [];
          while (i < lines.length && !/^[▶◆]/.test(lines[i]) && !/^=== /.test(lines[i])) {
            bodyLines.push(lines[i]); i++;
          }
          // trim trailing blanks
          while (bodyLines.length && bodyLines[bodyLines.length - 1].trim() === '') bodyLines.pop();
          const rawForCopy = bodyLines.join('\n');
          const bodyHtml = renderBlocks(rawForCopy);
          html += '<div class="msg-block">' +
            '<div class="msg-head">' +
              '<span class="role ' + roleClass + '">' + roleLabel + '</span>' +
              '<button class="copy-btn" data-content="' + utf8B64(rawForCopy) + '" onclick="copyMsg(this)">复制</button>' +
            '</div>' +
            '<div class="msg-body">' + bodyHtml + '</div>' +
          '</div>';
          continue;
        }
        // code block
        if (/^```/.test(line)) {
          const lang = line.slice(3).trim();
          const body = [];
          i++;
          while (i < lines.length && !/^```/.test(lines[i])) { body.push(lines[i]); i++; }
          i++;
          html += '<pre><code>' + escapeHTML(body.join('\n')) + '</code></pre>';
          continue;
        }
        // meta line
        if (/^=== /.test(line)) {
          html += '<div class="meta">' + escapeHTML(line) + '</div>';
          i++; continue;
        }
        // header
        const hMatch = line.match(/^(#{1,6})\s+(.+)$/);
        if (hMatch) {
          const lvl = hMatch[1].length;
          html += '<h' + lvl + '>' + renderInline(escapeHTML(hMatch[2])) + '</h' + lvl + '>';
          i++; continue;
        }
        // table
        if (/^\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\|[\s\-:|]+\|\s*$/.test(lines[i+1])) {
          const head = line.split('|').slice(1, -1).map(s => s.trim());
          i += 2;
          const rows = [];
          while (i < lines.length && /^\|.*\|\s*$/.test(lines[i])) {
            rows.push(lines[i].split('|').slice(1, -1).map(s => s.trim()));
            i++;
          }
          html += '<table><thead><tr>' +
            head.map(h => '<th>' + renderInline(escapeHTML(h)) + '</th>').join('') +
            '</tr></thead><tbody>' +
            rows.map(r => '<tr>' + r.map(c => '<td>' + renderInline(escapeHTML(c)) + '</td>').join('') + '</tr>').join('') +
            '</tbody></table>';
          continue;
        }
        // list (bullet or numbered)
        if (/^\s*[-*]\s+/.test(line) || /^\s*\d+\.\s+/.test(line)) {
          const ordered = /^\s*\d+\.\s+/.test(line);
          const items = [];
          while (i < lines.length && (/^\s*[-*]\s+/.test(lines[i]) || /^\s*\d+\.\s+/.test(lines[i]))) {
            const m = lines[i].match(/^\s*(?:[-*]|\d+\.)\s+(.*)$/);
            items.push(m ? m[1] : lines[i]);
            i++;
          }
          html += (ordered ? '<ol>' : '<ul>') +
            items.map(it => '<li>' + renderInline(escapeHTML(it)) + '</li>').join('') +
            (ordered ? '</ol>' : '</ul>');
          continue;
        }
        // blockquote
        if (/^>\s+/.test(line)) {
          const body = [];
          while (i < lines.length && /^>\s+/.test(lines[i])) {
            body.push(lines[i].replace(/^>\s+/, ''));
            i++;
          }
          html += '<blockquote>' + renderInline(escapeHTML(body.join(' '))) + '</blockquote>';
          continue;
        }
        // blank line
        if (line.trim() === '') {
          i++; continue;
        }
        // paragraph (merge with following non-blank, non-special lines)
        const para = [line];
        i++;
        while (i < lines.length && lines[i].trim() !== '' &&
               !/^(```|▶|◆|=== |#{1,6}\s|\s*[-*]\s|\s*\d+\.\s|>\s|\|.*\|\s*$)/.test(lines[i])) {
          para.push(lines[i]);
          i++;
        }
        html += '<p>' + renderInline(escapeHTML(para.join(' '))) + '</p>';
      }
      return html;
    }
    function copyMsg(btn) {
      const enc = btn.getAttribute('data-content') || '';
      let text = '';
      try { text = decodeURIComponent(escape(atob(enc))); } catch (e) { text = atob(enc); }
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copy) {
        window.webkit.messageHandlers.copy.postMessage(text);
      }
      const orig = btn.textContent;
      btn.classList.add('copied');
      btn.textContent = '✓ 已复制';
      setTimeout(() => { btn.classList.remove('copied'); btn.textContent = orig; }, 1500);
    }
    document.getElementById('content').innerHTML = renderBlocks(decodeB64("\#(payloadB64)"));
    function scrollToBottom() { window.scrollTo(0, document.documentElement.scrollHeight); }
    requestAnimationFrame(scrollToBottom);
    window.addEventListener('load', scrollToBottom);
    // 图片加载完会撑高文档，所有图加载完后再滚一次
    Array.from(document.images).forEach(img => {
      if (!img.complete) img.addEventListener('load', scrollToBottom, { once: true });
    });
    setTimeout(scrollToBottom, 300);
    setTimeout(scrollToBottom, 1000);
    </script>
    </body>
    </html>
    """#
  }

  private static func renderTranscript(_ raw: String) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let metaFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let headerFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
    let headerSpacing = NSMutableParagraphStyle()
    headerSpacing.paragraphSpacingBefore = 16
    headerSpacing.paragraphSpacing = 4
    let bodyPara = NSMutableParagraphStyle()
    bodyPara.lineSpacing = 3
    bodyPara.paragraphSpacing = 4

    var buffer: [String] = []
    var bufferIsBody = false

    func flush() {
      guard !buffer.isEmpty else { return }
      let text = buffer.joined(separator: "\n")
      buffer.removeAll()
      if bufferIsBody {
        out.append(Self.renderBody(text, paragraphStyle: bodyPara))
      } else {
        out.append(NSAttributedString(string: text + "\n", attributes: [
          .font: metaFont,
          .foregroundColor: UIColor.secondaryLabel,
        ]))
      }
    }

    for line in raw.components(separatedBy: "\n") {
      if line.hasPrefix("▶") {
        flush()
        out.append(NSAttributedString(string: "你\n", attributes: [
          .font: headerFont,
          .foregroundColor: UIColor.systemBlue,
          .paragraphStyle: headerSpacing,
        ]))
        bufferIsBody = true
      } else if line.hasPrefix("◆") {
        flush()
        out.append(NSAttributedString(string: "Claude\n", attributes: [
          .font: headerFont,
          .foregroundColor: UIColor.systemGreen,
          .paragraphStyle: headerSpacing,
        ]))
        bufferIsBody = true
      } else if line.hasPrefix("=== ") {
        flush()
        bufferIsBody = false
        buffer.append(line)
        flush()
      } else {
        buffer.append(line)
      }
    }
    flush()
    return out
  }

  private static func renderBody(_ text: String, paragraphStyle: NSParagraphStyle) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false,
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    let bodyFont = UIFont.systemFont(ofSize: 15)
    if let attr = try? NSMutableAttributedString(
      markdown: text + "\n",
      options: options,
      baseURL: nil
    ) {
      let full = NSRange(location: 0, length: attr.length)
      attr.addAttributes([
        .foregroundColor: UIColor.label,
        .paragraphStyle: paragraphStyle,
      ], range: full)
      // 把 markdown 的 inline intent 翻译成 font
      attr.enumerateAttribute(.inlinePresentationIntent,
                              in: full, options: []) { value, range, _ in
        let rawValue = (value as? UInt) ?? (value as? Int).map { UInt(bitPattern: $0) } ?? 0
        var font = bodyFont
        let intent = InlinePresentationIntent(rawValue: rawValue)
        if intent.contains(.code) {
          font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        } else if intent.contains(.stronglyEmphasized) && intent.contains(.emphasized) {
          let desc = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            .withSymbolicTraits([.traitBold, .traitItalic])
          font = UIFont(descriptor: desc ?? bodyFont.fontDescriptor, size: 15)
        } else if intent.contains(.stronglyEmphasized) {
          font = UIFont.boldSystemFont(ofSize: 15)
        } else if intent.contains(.emphasized) {
          font = UIFont.italicSystemFont(ofSize: 15)
        }
        attr.addAttribute(.font, value: font, range: range)
      }
      // 没设 font 的地方设默认
      attr.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
        if value == nil {
          attr.addAttribute(.font, value: bodyFont, range: range)
        }
      }
      return attr
    }
    return NSAttributedString(string: text + "\n", attributes: [
      .font: bodyFont,
      .foregroundColor: UIColor.label,
      .paragraphStyle: paragraphStyle,
    ])
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if !didFinishInitialLoad {
      didFinishInitialLoad = true
      decisionHandler(.allow)
      return
    }
    if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
      UIApplication.shared.open(url)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  @objc private func closeTapped() { dismiss(animated: true) }

  @objc private func shareTapped() {
    let av = UIActivityViewController(activityItems: [bodyText], applicationActivities: nil)
    av.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
    present(av, animated: true)
  }
}

