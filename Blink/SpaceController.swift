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
                      tmuxSession: p?.tmuxSession)
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
  public override var prefersStatusBarHidden: Bool { true }
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
