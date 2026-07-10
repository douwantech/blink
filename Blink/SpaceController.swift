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
        p.useTmux = true   // 强制全 tmux（忽略旧存值 / 已移除的 T 开关）
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
  private var _floatingDock = FloatingDockBar()
  private var _floatingDockPlaced = false
  private var _floatingMachineBar = FloatingMachineBar()
  private var _floatingMachineBarPlaced = false
  private var _lastKeyPerMachine: [String: UUID] = [:]   // 每台机器上次选中的 tab
  private var _voiceIsRecording = false
  private let _voiceHaptic = UIImpactFeedbackGenerator(style: .heavy)
  private var _pinnedBrowserVC: PinnedBrowserViewController?

  // Mac 大屏三栏（issue #5）：最左机器 rail + 中间会话列表 + 右侧终端。
  // 仅 Designed-for-iPad 主窗口启用；外接屏(Shadow)/iPhone/iPad 保持原浮动栏布局。
  // 模拟器调试可 `defaults write <bundleId> BlinkForceMacLayout -bool YES` 强开。
  private lazy var _macLayoutEnabled: Bool =
    (ProcessInfo.processInfo.isiOSAppOnMac
     || UserDefaults.standard.bool(forKey: "BlinkForceMacLayout"))
    && sceneRole == .windowApplication
  private var _macRail: MacMachineRailView? = nil
  private var _macSidebar: MacSessionSidebarView? = nil
  private var _macStatusBar: MacStatusBarView? = nil

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
    if _macLayoutEnabled {
      _layoutMacThreeColumn(safeTop: safeTop)
    } else {
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
      if !_floatingMachineBarPlaced {
        _floatingMachineBar.reload(currentId: _tabFilterMachineId)
        _floatingMachineBar.restorePosition(in: view)
        _floatingMachineBarPlaced = true
      }
      view.bringSubviewToFront(_floatingMachineBar)
    }
    if !_floatingDockPlaced {
      _floatingDock.restorePosition(in: view)
      _floatingDockPlaced = true
    }
    view.bringSubviewToFront(_floatingDock)
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
    // 玻璃 dock 常驻显示（语音 + 浏览器都在里面），只保证在最前
    _floatingDock.isHidden = false
    view.bringSubviewToFront(_floatingDock)
  }

  // 录音状态变化：浮动条 mic 钮切 停止/mic 图标
  @objc private func _voiceRecordingStateChanged(_ note: Notification) {
    let recording = (note.userInfo?["recording"] as? Bool) ?? false
    _voiceIsRecording = recording
    _floatingDock.setMicRecording(recording)
  }

  // 浮动条语音钮：录音中单点=停止；否则=弹面板（不开录）
  // touchDown 时预热触感生成器，降低长按震动的延迟
  @objc private func _prepareVoiceHaptic() {
    _voiceHaptic.prepare()
  }

  @objc private func _unhideVoiceInput() {
    if _voiceIsRecording {
      NotificationCenter.default.post(name: VoiceInputView.stopRecordingNotification, object: nil)
      return
    }
    SmarterTermInput.voiceInputAutoShow = true
    if SmarterTermInput.directHKBInput {
      // Mac 直输默认无面板，mic 钮是显式唤起语音面板的入口
      KBTracker.shared.input?.setUseVoiceInput(true)
    }
    _focusOnShell()
  }

  // 浮动条语音钮：长按才弹面板 + 直接开录
  @objc private func _voiceMicLongPressed(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()   // 震动反馈
    VoiceInputView.wantsAutoRecord = true
    SmarterTermInput.voiceInputAutoShow = true
    if SmarterTermInput.directHKBInput {
      KBTracker.shared.input?.setUseVoiceInput(true)
    }
    _focusOnShell()
    // 面板本来就开着的情况（didMoveToWindow 不会再触发）：发通知让当前实例立刻录
    NotificationCenter.default.post(name: VoiceInputView.startRecordingNotification, object: nil)
  }

  @objc func _openPinnedBrowser() {
    _presentSharedBrowser()
  }

  // dock 收藏钮：弹收藏短语选择器，选中的直接发到当前终端
  @objc func _openFavoritesPicker() {
    let picker = VoiceHistoryPickerViewController(mode: .favorites)
    picker.onPick = { [weak self] text in
      guard let self else { return }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      AITextPolisher.shared.recordHistory(trimmed)
      AITextPolisher.shared.incrementFavoriteUseCount(trimmed)
      self.currentDevice?.write(trimmed)
      self.currentDevice?.write("\r")
    }
    let nav = UINavigationController(rootViewController: picker)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
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
      TabStateStore.shared.adoptSyncedIfNewer()   // 先采纳 iCloud 上更新的 tab 列表（跨设备）
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
    _ensureAssistantTabFirst()
        
    self.view.addSubview(_bottomTapAreaView)

    // 玻璃 dock（方案 A）：语音 + 浏览器合并成靠右竖胶囊，可拖动
    _floatingDock.micButton.addTarget(self, action: #selector(_unhideVoiceInput), for: .touchUpInside)
    _floatingDock.micButton.addTarget(self, action: #selector(_prepareVoiceHaptic), for: .touchDown)
    _floatingDock.micButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(_voiceMicLongPressed(_:))))
    _floatingDock.browserButton.addTarget(self, action: #selector(_openPinnedBrowser), for: .touchUpInside)
    _floatingDock.favoritesButton.addTarget(self, action: #selector(_openFavoritesPicker), for: .touchUpInside)
    _floatingDock.historyButton.addTarget(self, action: #selector(dumpTranscriptForCurrentShell), for: .touchUpInside)
    _floatingDock.refreshButton.addTarget(self, action: #selector(reloadCurrentShell), for: .touchUpInside)
    NotificationCenter.default.addObserver(self, selector: #selector(_voiceRecordingStateChanged(_:)), name: VoiceInputView.recordingStateChangedNotification, object: nil)

    // E2E 自截屏后门：仅测试设备手动开 BlinkE2ESnapshotHook 才注册（生产 inert）。
    // 注意本工程没配 SWIFT_ACTIVE_COMPILATION_CONDITIONS，#if DEBUG 永远是 false，别用。
    if UserDefaults.standard.bool(forKey: "BlinkE2ESnapshotHook") {
      _ = Self._installDebugSnapshotHook
    }
    if _macLayoutEnabled {
      // Mac 三栏：悬浮机器条不上屏（rail 取代），tab 栏隐藏（会话列表取代）
      _setupMacThreeColumn()
    } else {
      // 独立的「切换机器」浮动条：点头像直接切机器，长按换头像，可拖
      _floatingMachineBar.onSelectMachine = { [weak self] id in self?._applyMachineFilter(id) }
      _floatingMachineBar.onEditAvatar = { [weak self] id in self?._editMachineAvatar(id) }
      _floatingMachineBar.reload(currentId: _tabFilterMachineId)
      view.addSubview(_floatingMachineBar)
    }
    view.addSubview(_floatingDock)
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

    nc.addObserver(self, selector: #selector(_cloudConfigDidRestore),
                   name: CloudConfigSync.didRestoreNotification, object: nil)
  }

  @objc private func _flushTabStateStore() {
    TabStateStore.shared.flushNow()
  }

  /// iCloud 送来新配置（可能含更新的 tab 列表）。
  /// - 本机没有「真实」tab（空 / 仅空白 shell）→ 整份采纳云端列表并重建（新设备拿到别人的 tab）。
  /// - 本机已有真实 tab（活跃设备）→ 增量追加：把别处新开、本机还没有的 tab 加进列表，
  ///   但不切走当前 tab、不动键盘焦点（跨设备实时可见又不打断正在用的会话）。
  @objc private func _cloudConfigDidRestore() {
    let hasReal = _viewportsKeys.contains { k -> Bool in
      let term: TermController = SessionRegistry.shared[k]
      let p = term.mcpParams
      return p?.machineId != nil || p?.workDirId != nil || p?.tmuxSession != nil
    }
    if !hasReal {
      guard TabStateStore.shared.adoptSyncedIfNewer() else { return }
      _restoreFromStore()
      if let key = _currentKey {
        let term: TermController = SessionRegistry.shared[key]
        term.delegate = self
        term.bgColor = view.backgroundColor ?? .black
        _viewportsController.setViewControllers([term], direction: .forward, animated: false)
      }
      _sortTabsByMachineAndDir()
      _ensureAssistantTabFirst()
      return
    }
    _appendNewSyncedTabs()
  }

  /// 活跃设备增量合并：iCloud 送来的列表里，本机（按 机器+目录+会话 签名）还没有的
  /// 「真实」tab 追加到末尾并 re-sort，当前 tab / 键盘焦点保持不变。
  /// 只增不减 —— 别处（手机）关掉的 tab 不在这里删：删除同步风险高、会误伤本机正用的会话。
  private func _appendNewSyncedTabs() {
    let synced = TabStateStore.shared.syncedTabs()
    guard !synced.isEmpty else { return }

    func sig(_ mid: String?, _ wid: String?, _ tmux: String?) -> String {
      "\(mid ?? "")|\(wid ?? "")|\(tmux ?? "")"
    }
    var seen = Set(_viewportsKeys.map { key -> String in
      let p = (SessionRegistry.shared[key] as TermController).mcpParams
      return sig(p?.machineId, p?.workDirId, p?.tmuxSession)
    })

    var appended: [UUID] = []
    for entry in synced {
      // 空白 shell（无机器/目录/会话）不追加
      guard entry.machineId != nil || entry.workDirId != nil || entry.tmuxSession != nil else { continue }
      let s = sig(entry.machineId, entry.workDirId, entry.tmuxSession)
      if seen.contains(s) { continue }
      seen.insert(s)

      let term: TermController = SessionRegistry.shared[entry.id]
      if term.mcpParams == nil {
        let p = MCPParams()
        p.machineId = entry.machineId
        p.workDirId = entry.workDirId
        p.tmuxSession = entry.tmuxSession
        p.useTmux = true
        term.bindRestoredMcpParams(p)
      }
      term.delegate = self
      term.bgColor = view.backgroundColor ?? .black
      appended.append(term.meta.key)
    }

    guard !appended.isEmpty else { return }
    _viewportsKeys.append(contentsOf: appended)   // didSet → 持久化 + 刷新 tab 栏/三栏
    _sortTabsByMachineAndDir()
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
    if _macLayoutEnabled,
       let mid = term.mcpParams?.machineId,
       let m = BlinkMachineStore.shared.machines.first(where: { $0.id == mid }) {
      // Mac 窗口标题带上机器名（窗口标题栏就是"顶栏"，不再另画）
      sceneTitle = "\(m.displayName) — " + sceneTitle
    }
    view.window?.windowScene?.title = sceneTitle
    if _macLayoutEnabled { _updateMacStatusBar() }
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
    
    return input.blinkKeyCommands + _macArrowNavKeyCommands
  }

  /// Mac（Designed-for-iPad）专属键盘导航：
  ///   Cmd+←/→ 或 Cmd+Shift+[ / ] 切标签；Cmd+↑/↓ 切机器。
  /// 仅在 Mac 上注入，避免干扰 iPhone/iPad 外接键盘上用户已有的按键习惯。
  private var _macArrowNavKeyCommands: [UIKeyCommand] {
    guard ProcessInfo.processInfo.isiOSAppOnMac else { return [] }
    let specs: [(String, UIKeyModifierFlags, Selector)] = [
      (UIKeyCommand.inputLeftArrow,  .command,           #selector(_macPrevTab)),
      (UIKeyCommand.inputRightArrow, .command,           #selector(_macNextTab)),
      (UIKeyCommand.inputUpArrow,    .command,           #selector(_macPrevMachine)),
      (UIKeyCommand.inputDownArrow,  .command,           #selector(_macNextMachine)),
      ("[",                          [.command, .shift], #selector(_macPrevTab)),   // Cmd+Shift+[ 上一个标签
      ("]",                          [.command, .shift], #selector(_macNextTab)),   // Cmd+Shift+] 下一个标签
    ]
    return specs.map { (input, mods, action) in
      let c = UIKeyCommand(input: input, modifierFlags: mods, action: action)
      c.wantsPriorityOverSystemBehavior = true   // 抢在系统默认行为之前
      return c
    }
  }

  @objc private func _macPrevTab()     { _advanceShellCycling(by: -1) }
  @objc private func _macNextTab()     { _advanceShellCycling(by: 1) }
  @objc private func _macPrevMachine() { _advanceMachine(by: -1) }
  @objc private func _macNextMachine() { _advanceMachine(by: 1) }

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
    params.useTmux = BlinkMachineStore.useTmuxMode   // 新标签默认走 tmux
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
    params.useTmux = BlinkMachineStore.useTmuxMode   // 新标签默认走 tmux
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
    // 先刷新页面（重 attach tmux），等 view 切换完再真正 dump，让 hterm 拿到最新一帧
    _reloadCurrentShell { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        self?._doDumpTranscript()
      }
    }
  }

  private func _doDumpTranscript() {
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
                                            deadline: Date(timeIntervalSinceNow: 15))
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
    _reloadCurrentShell(completion: nil)
  }

  private func _reloadCurrentShell(completion: (() -> Void)?) {
    guard let oldTerm = currentTerm(),
          let oldKey = _currentKey,
          let oldIdx = _viewportsKeys.firstIndex(of: oldKey),
          let p = oldTerm.mcpParams,
          let machineId = p.machineId, !machineId.isEmpty else { completion?(); return }

    let params = MCPParams()
    params.machineId = machineId
    params.workDirId = p.workDirId
    params.tmuxSession = p.tmuxSession
    params.useTmux = true   // 强制全 tmux
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
      completion?()
    }
  }

  fileprivate func _reloadTabBar() {
    var titles: [String] = []
    var icons: [UIImage?] = []
    var unread: [Bool] = []
    var tags: [Int] = []
    var sidebarSubs: [String] = []       // Mac 三栏：每行副标题（工作目录路径）
    var sidebarIcons: [UIImage?] = []    // Mac 三栏：32pt 头像（tab 的 22pt 太小）

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
        // 助手 tab：标题就显示「助手」，不拼 sessionPart
        if p.workDirId == BlinkWorkDirStore.assistantWorkDirId {
          term.meta.tabTitle = "助手"
          title = "助手"
          let mid = term.mcpParams?.machineId
          if let f = filterId, mid != f { continue }
          titles.append(title)
          var icon: UIImage? = nil
          if let img = BlinkWorkDirStore.shared.workDir(forId: BlinkWorkDirStore.assistantWorkDirId)?.iconImage {
            icon = AvatarRenderer.roundedThumbnail(from: img, size: CGSize(width: 22, height: 22))
          }
          icons.append(icon)
          unread.append(term.meta.hasUnread)
          tags.append(idx)
          if _macLayoutEnabled {
            let wd = BlinkWorkDirStore.shared.workDir(forId: BlinkWorkDirStore.assistantWorkDirId)
            sidebarSubs.append(wd?.path ?? "")
            sidebarIcons.append(wd?.iconImage.map {
              AvatarRenderer.roundedThumbnail(from: $0, size: CGSize(width: 32, height: 32))
            } ?? nil)
          }
          continue
        }
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
      // 找到对应 workDir 的头像；没配就给 nil（tab 显示纯文字）
      var icon: UIImage? = nil
      if let wid = term.mcpParams?.workDirId,
         let img = BlinkWorkDirStore.shared.workDir(forId: wid)?.iconImage {
        icon = AvatarRenderer.roundedThumbnail(from: img, size: CGSize(width: 22, height: 22))
      }
      icons.append(icon)
      unread.append(term.meta.hasUnread)
      tags.append(idx)
      if _macLayoutEnabled {
        let wd = BlinkWorkDirStore.shared.workDir(forId: term.mcpParams?.workDirId)
        sidebarSubs.append(wd?.path ?? BlinkMachineStore.effectiveTmuxSessionName(
          workDirId: term.mcpParams?.workDirId, tmuxSession: term.mcpParams?.tmuxSession))
        sidebarIcons.append(wd?.iconImage.map {
          AvatarRenderer.roundedThumbnail(from: $0, size: CGSize(width: 32, height: 32))
        } ?? nil)
      }
    }
    let chipTitle: String
    if let fid = filterId, let m = BlinkMachineStore.shared.machines.first(where: { $0.id == fid }) {
      chipTitle = m.displayName
    } else {
      chipTitle = "全部"
    }
    _tabBar.reload(titles: titles, icons: icons, unread: unread, tags: tags, filterTitle: chipTitle, currentTag: curIndex)

    if _macLayoutEnabled {
      // 三栏与 tab 栏同源刷新：rail 高亮当前机器，sidebar 铺当前机器的会话
      _macRail?.reload(currentId: filterId)
      let machine = filterId.flatMap { fid in
        BlinkMachineStore.shared.machines.first { $0.id == fid }
      }
      var items: [MacSessionSidebarView.Item] = []
      for (i, t) in titles.enumerated() {
        items.append(MacSessionSidebarView.Item(
          tag: tags[i],
          title: t,
          subtitle: i < sidebarSubs.count ? sidebarSubs[i] : "",
          icon: i < sidebarIcons.count ? sidebarIcons[i] : nil,
          unread: unread[i],
          isCurrent: tags[i] == curIndex))
      }
      _macSidebar?.reload(machineName: machine?.displayName ?? chipTitle,
                          transport: machine.map { $0.usesBlinkd ? "Socket" : "SSH" },
                          items: items)
      _updateMacHostLine(machine: machine)
      _updateMacStatusBar()
    }
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

    // 助手 workDir 永远排在每个机器组的最前面
    let assistantWdId = BlinkWorkDirStore.assistantWorkDirId
    func dkey(_ wd: String?) -> Int {
      if wd == assistantWdId { return -1 }
      return wd.flatMap { workDirOrder[$0] } ?? Int.max
    }

    let indexed = _viewportsKeys.enumerated().map { (offset: $0.offset, key: $0.element) }
    let sorted = indexed.sorted { a, b in
      let ta: TermController = SessionRegistry.shared[a.key]
      let tb: TermController = SessionRegistry.shared[b.key]
      let mka = ta.mcpParams?.machineId.flatMap { machineOrder[$0] } ?? Int.max
      let mkb = tb.mcpParams?.machineId.flatMap { machineOrder[$0] } ?? Int.max
      if mka != mkb { return mka < mkb }
      let dka = dkey(ta.mcpParams?.workDirId)
      let dkb = dkey(tb.mcpParams?.workDirId)
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

  /// 切到上/下一台「有 tab 的机器」并过滤显示它（复用 _applyMachineFilter，含掉线自动重连）。
  /// 无机器 filter 时以当前 tab 所属机器为起点；少于 2 台有 tab 的机器时无操作。
  private func _advanceMachine(by: Int) {
    let machineIds = _machineIdsWithTabs()
    guard machineIds.count > 1 else { return }
    let curMid: String? = _tabFilterMachineId ?? _currentKey.flatMap {
      (SessionRegistry.shared[$0] as TermController).mcpParams?.machineId
    }
    let curPos = curMid.flatMap { machineIds.firstIndex(of: $0) } ?? 0
    let nextPos = (curPos + by + machineIds.count) % machineIds.count
    _applyMachineFilter(machineIds[nextPos])
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

  public func tabBarDidRequestAssistantChat() {
    // 顶栏 sparkles 入口：打开气泡 chat UI（独立 modal，不是终端 tab）
    let chat = BlinkAssistantChatViewController()
    let nav = UINavigationController(rootViewController: chat)
    nav.modalPresentationStyle = .fullScreen
    present(nav, animated: true)
  }

  public func tabBarDidRequestAssistant() {
    // 旧入口保留兼容：跟 _ensureAssistantTabFirst 一样的逻辑
    _ensureAssistantTabFirst(switchTo: true)
  }

  /// 启动时调；保证助手终端 tab 一定存在且排在 _viewportsKeys[0]
  /// - 若已存在：移动到 index 0
  /// - 若不存在：创建并 insert 到 index 0
  /// - switchTo=true 时切到这个 tab
  fileprivate func _ensureAssistantTabFirst(switchTo: Bool = false) {
    guard let machineId = BlinkMachineStore.shared.currentMachine?.id else { return }
    _ = BlinkWorkDirStore.shared.ensureAssistantWorkDir()
    let session = BlinkWorkDirStore.assistantTmuxSession
    let workDirId = BlinkWorkDirStore.assistantWorkDirId

    if let curIdx = _viewportsKeys.firstIndex(where: { key in
      let term: TermController = SessionRegistry.shared[key]
      let p = term.mcpParams
      return p?.machineId == machineId && p?.tmuxSession == session
    }) {
      if curIdx != 0 {
        let key = _viewportsKeys.remove(at: curIdx)
        _viewportsKeys.insert(key, at: 0)
      }
      if switchTo { tabBarDidSelect(index: 0) }
      return
    }

    // 不存在 → 创建并放到 index 0
    let params = MCPParams()
    params.machineId = machineId
    params.workDirId = workDirId
    params.tmuxSession = session
    params.useTmux = BlinkMachineStore.useTmuxMode   // 新标签默认走 tmux
    let payload = MCPSessionPayload(params: params)
    let term = TermController(sceneRole: sceneRole, sessionPayload: payload)
    term.delegate = self
    term.bgColor = view.backgroundColor ?? .black
    SessionRegistry.shared.track(session: term)
    _viewportsKeys.insert(term.meta.key, at: 0)
    if switchTo {
      _currentKey = term.meta.key
      _viewportsController.setViewControllers([term], direction: .forward, animated: true) { [weak self] _ in
        self?._displayHUD()
        self?._attachInputToCurrentTerm()
      }
    }
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
        self?._applyMachineFilter(m.id)
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let pop = alert.popoverPresentationController {
      pop.sourceView = _tabBar
      pop.sourceRect = _tabBar.bounds
    }
    present(alert, animated: true)
  }

  // 切换 tab 过滤到某台机器（nil = 全部）；优先回到该机器上次选中的 tab
  func _applyMachineFilter(_ machineId: String?) {
    // 先记住「离开的这台机器」当前停在哪个 tab
    if let curKey = _currentKey,
       let curMid = (SessionRegistry.shared[curKey] as TermController).mcpParams?.machineId {
      _lastKeyPerMachine[curMid] = curKey
    }
    _tabFilterMachineId = machineId
    let filtered = _filteredViewportsKeys()

    // 选定目标 tab：上次选中的 > 当前若已在过滤集内 > 第一个
    var target: UUID? = nil
    if let mid = machineId, let remembered = _lastKeyPerMachine[mid], filtered.contains(remembered) {
      target = remembered
    } else if let cur = _currentKey, filtered.contains(cur) {
      target = cur
    } else {
      target = filtered.first
    }

    if let t = target, t != _currentKey, let idx = _viewportsKeys.firstIndex(of: t) {
      _moveToShell(idx: idx, animated: false)
    } else {
      _reloadTabBar()
      // Mac：点 rail 上已选中的机器（无切页）也要把键盘焦点还给终端
      if _macLayoutEnabled { _attachInputToCurrentTerm() }
    }
    _floatingMachineBar.reload(currentId: _tabFilterMachineId)

    // 切过去后，如果那个 tab 已经掉线（停在 blink> / 后台没连上）就重连
    if let t = target {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        (SessionRegistry.shared[t] as TermController).reconnectIfDisconnected()
      }
    }
  }

  // 机器条长按：给机器换头像（同「选择头像」的 Alohe Memoji 选择器）
  func _editMachineAvatar(_ machineId: String) {
    let picker = AvatarPickerViewController()
    picker.onPick = { [weak self] data in
      BlinkMachineStore.shared.setAvatar(data, forId: machineId)
      self?._floatingMachineBar.reload(currentId: self?._tabFilterMachineId)
      self?._macRail?.reload(currentId: self?._tabFilterMachineId)
    }
    let nav = UINavigationController(rootViewController: picker)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }
}

// MARK: Mac 大屏三栏布局（issue #5）
//
// 结构：机器 rail(68pt) | 会话列表(288pt) | 终端 + 底部状态栏(24pt)。
// 数据流全部复用现有机制 —— rail 点击 = _applyMachineFilter（含记忆各机器上次
// tab + 断线重连），行点击/关闭 = tabBarDidSelect/Close，刷新挂在 _reloadTabBar。
extension SpaceController {

  /// E2E 自动化后门（BlinkE2ESnapshotHook 默认值开启才注册）：Mac 上拿不到系统截屏
  /// （screencapture 要屏幕录制权限、lldb attach Designed-for-iPad 进程会卡死），让 app
  /// 自己监听 darwin 通知，把 key window 渲染成 PNG 写到 Documents/blink-window.png
  /// 并放进系统剪贴板（container 受 TCC 保护，剪贴板是唯一能带出去的通道）。
  /// 触发：`notifyutil -p sh.blink.snapshot`
  static let _installDebugSnapshotHook: Void = {
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), nil,
      { _, _, _, _, _ in
        DispatchQueue.main.async {
          let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                let w = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
          else { return }
          let png = UIGraphicsImageRenderer(bounds: w.bounds).pngData { _ in
            w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
          }
          let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("blink-window.png")
          try? png.write(to: url)
          if let img = UIImage(data: png) {
            // Mac E2E：app container 受 TCC 保护外面读不到，走系统剪贴板把图带出去
            UIPasteboard.general.image = img
          }
        }
      },
      "sh.blink.snapshot" as CFString, nil, .deliverImmediately)
  }()

  fileprivate func _setupMacThreeColumn() {
    _tabBar.isHidden = true
    _statusBarBg.isHidden = true

    let rail = MacMachineRailView()
    rail.onSelectMachine = { [weak self] id in self?._applyMachineFilter(id) }
    rail.onEditAvatar = { [weak self] id in self?._editMachineAvatar(id) }
    rail.onOpenAssistantChat = { [weak self] in self?.tabBarDidRequestAssistantChat() }
    rail.onOpenSettings = { [weak self] in self?.tabBarDidRequestSettings() }
    view.addSubview(rail)
    _macRail = rail

    let sidebar = MacSessionSidebarView()
    // 不走 tabBarDidSelect：它切页后不重挂输入（手机靠手指点终端恢复焦点，Mac 没这一步，
    // 键盘会直接失灵）。_moveToShell 完成后自带 _attachInputToCurrentTerm。
    sidebar.onSelect = { [weak self] tag in self?._moveToShell(idx: tag) }
    sidebar.onClose = { [weak self] tag in self?.tabBarDidRequestClose(index: tag) }
    sidebar.onNewSession = { [weak self] in self?.tabBarDidRequestNew() }
    view.addSubview(sidebar)
    _macSidebar = sidebar

    let status = MacStatusBarView()
    view.addSubview(status)
    _macStatusBar = status

    _reloadTabBar()

    // 直输模式启动兜底：首次 _focusOnShell 常跑在终端 webView ready 之前而落空
    //（旧版靠语音面板弹出掩盖了这点）。ready 后补挂，保证开屏即可打字。
    for delay in [2.0, 5.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?._focusOnShell()
      }
    }
  }

  fileprivate func _layoutMacThreeColumn(safeTop: CGFloat) {
    guard let rail = _macRail, let sidebar = _macSidebar, let status = _macStatusBar else { return }
    let railW = MacMachineRailView.railW
    let sideW = MacSessionSidebarView.sidebarW
    let statusH = MacStatusBarView.barH
    let w = view.bounds.width
    let h = view.bounds.height
    _statusBarBg.frame = CGRect(x: 0, y: 0, width: w, height: safeTop)
    rail.frame = CGRect(x: 0, y: safeTop, width: railW, height: max(0, h - safeTop))
    sidebar.frame = CGRect(x: railW, y: safeTop, width: sideW, height: max(0, h - safeTop))
    status.frame = CGRect(x: railW + sideW, y: h - statusH,
                          width: max(0, w - railW - sideW), height: statusH)
    if let v = _viewportsController.view {
      v.frame = CGRect(x: railW + sideW, y: safeTop,
                       width: max(0, w - railW - sideW),
                       height: max(0, h - safeTop - statusH))
    }
    view.bringSubviewToFront(rail)
    view.bringSubviewToFront(sidebar)
    view.bringSubviewToFront(status)
  }

  /// 选用地址是同步探测（LAN→外网1→外网2，各 0.3s 超时），放后台算完回主线程喂 header
  fileprivate func _updateMacHostLine(machine: BlinkMachine?) {
    guard _macLayoutEnabled else { return }
    guard let m = machine else {
      _macSidebar?.updateHostLine(nil)
      return
    }
    let mid = m.id
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let r = BlinkMachineStore.resolveHost(for: m)
      DispatchQueue.main.async {
        guard let self, self._tabFilterMachineId == mid else { return }
        self._macSidebar?.updateHostLine("\(m.user)@\(r.host) · \(r.source)")
      }
    }
  }

  fileprivate func _updateMacStatusBar() {
    guard _macLayoutEnabled, let term = currentTerm() else { return }
    let p = term.mcpParams
    let session = BlinkMachineStore.effectiveTmuxSessionName(
      workDirId: p?.workDirId, tmuxSession: p?.tmuxSession)
    var left = "tmux \(session) · UTF-8"
    if let mid = p?.machineId,
       let m = BlinkMachineStore.shared.machines.first(where: { $0.id == mid }) {
      left = "\(m.displayName)(\(m.usesBlinkd ? "Socket" : "SSH")) · " + left
    }
    let hasSize = !(term.termView.rows == 0 && term.termView.cols == 0)
    let sizePart = hasSize ? "\(term.termView.cols)×\(term.termView.rows)  " : ""
    _macStatusBar?.update(left: left, right: sizePart + "⌘↑↓ 机器 · ⌘←→ 会话")
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
    // 允许 <video> 内联播放（否则 mp4 在 iPhone 上不显示）
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
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
    .head-btns { display: flex; gap: 6px; flex: 0 0 auto; }
    .sel-btn { font: 12px -apple-system, sans-serif; color: #8e8e93; background: transparent;
               border: 1px solid #c7c7cc; border-radius: 5px; padding: 3px 10px; cursor: pointer;
               -webkit-tap-highlight-color: transparent; }
    .sel-btn:active { background: rgba(142,142,147,0.15); }
    /* 选择复制整页 */
    #selpage { position: fixed; inset: 0; background: #f7f7f8; z-index: 10000;
               display: none; flex-direction: column; }
    #selpage.show { display: flex; }
    .sel-top { display: flex; align-items: center; gap: 8px; background: #fff; flex: 0 0 auto;
               padding: max(12px, env(safe-area-inset-top)) 14px 10px; border-bottom: 1px solid #d2d2d7; }
    .sel-title { font-weight: 600; font-size: 16px; flex: 1 1 auto; }
    .sel-top button { font: 14px -apple-system, sans-serif; color: #007aff; background: transparent;
                      border: none; padding: 6px 4px; cursor: pointer; -webkit-tap-highlight-color: transparent; }
    .sel-list { flex: 1 1 auto; overflow-y: auto; -webkit-overflow-scrolling: touch; padding: 10px 12px 12px; }
    .sel-card { position: relative; border: 1.5px solid #d2d2d7; border-radius: 10px; background: #fff;
                margin: 8px 0; padding: 12px 12px 12px 42px; cursor: pointer; overflow-x: auto; }
    .sel-card.on { border-color: #007aff; background: rgba(0,122,255,0.06); }
    .sel-card .chk { position: absolute; left: 12px; top: 12px; width: 20px; height: 20px;
                     border-radius: 11px; border: 1.5px solid #c7c7cc; box-sizing: border-box; }
    .sel-card.on .chk { background: #007aff; border-color: #007aff; }
    .sel-card.on .chk::after { content: '✓'; color: #fff; font-size: 13px; line-height: 20px;
                               display: block; text-align: center; }
    .sel-card > .msg-body, .sel-card > p:first-of-type, .sel-card > pre:first-child { margin-top: 0; }
    .sel-bottom { flex: 0 0 auto; background: #fff; border-top: 1px solid #d2d2d7;
                  padding: 10px 14px max(12px, env(safe-area-inset-bottom)); }
    .sel-copy { width: 100%; font: 600 16px -apple-system, sans-serif; color: #fff; background: #007aff;
                border: none; border-radius: 10px; padding: 12px; cursor: pointer;
                -webkit-tap-highlight-color: transparent; }
    .sel-copy:disabled { background: #c7c7cc; }
    .sel-toast { position: fixed; left: 50%; bottom: 92px; transform: translateX(-50%);
                 background: rgba(0,0,0,0.82); color: #fff; padding: 8px 16px; border-radius: 18px;
                 font-size: 14px; opacity: 0; transition: opacity 0.2s; z-index: 10001; pointer-events: none; }
    .sel-toast.show { opacity: 1; }
    .msg-body { margin-bottom: 0.5em; }
    .meta { color: #86868b; font-size: 11px; font-family: ui-monospace, Menlo, monospace; }
    pre { background: #f5f5f7; padding: 12px; border-radius: 8px; overflow-x: auto;
          font-family: ui-monospace, Menlo, monospace; font-size: 13px; line-height: 1.45;
          margin: 0.6em 0; }
    code { background: #f0f0f3; padding: 2px 5px; border-radius: 4px;
           font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
    pre code { background: none; padding: 0; }
    .code-wrap { position: relative; }
    .code-wrap pre { cursor: pointer; padding-top: 30px; }
    .code-copy { position: absolute; top: 6px; right: 8px; font-size: 11px; color: #6e6e73;
                 background: rgba(120,120,128,0.14); padding: 2px 8px; border-radius: 6px;
                 pointer-events: none; z-index: 2; }
    .code-wrap.copied .code-copy { color: #34c759; background: rgba(52,199,89,0.16); }
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
    video.md-video { width: 100%; max-width: 100%; min-height: 180px; border-radius: 8px; margin: 0.5em 0 0; display: block; background: #000; }
    a.md-video-link { display: inline-block; font-size: 13px; color: #007aff; margin: 0.2em 0 0.7em; text-decoration: none; }
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
      .sel-btn { color: #98989d; border-color: #48484a; }
      #selpage { background: #000; }
      .sel-top, .sel-bottom { background: #1c1c1e; border-color: #38383a; }
      .sel-card { background: #1c1c1e; border-color: #38383a; }
      .sel-card.on { border-color: #0a84ff; background: rgba(10,132,255,0.12); }
      .sel-card .chk { border-color: #48484a; }
      .sel-card.on .chk { background: #0a84ff; border-color: #0a84ff; }
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
    <div id="selpage">
      <div class="sel-top">
        <button onclick="closeSelect()">关闭</button>
        <span class="sel-title">选择要复制的块</span>
        <button onclick="selAll(true)">全选</button>
        <button onclick="selAll(false)">清空</button>
      </div>
      <div class="sel-list" id="sel-list"></div>
      <div class="sel-bottom">
        <button class="sel-copy" id="sel-copy" onclick="copySelected()">复制所选</button>
      </div>
    </div>
    <div class="sel-toast" id="sel-toast"></div>
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
    // 把已转义文本里的裸 http(s) URL 包成可点链接（用于代码块——里面的链接原本点不动）。
    // 输入已 escapeHTML 过，URL 里的 & 已是 &amp;，href 要还原回 &。
    function linkifyEscaped(s) {
      return s.replace(/(https?:\/\/[^\s<>"'`]+)/g, function(m) {
        var trail = '';
        var clean = m;
        var t = clean.match(/(?:[.,;:!?)\]]|&gt;|&lt;)+$/);
        if (t) { trail = t[0]; clean = clean.slice(0, -trail.length); }
        var href = clean.replace(/&amp;/g, '&');
        return '<a href="' + href + '">' + clean + '</a>' + trail;
      });
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
      // 3. markdown link [text](url) — image/video url 也转成内联媒体
      s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, text, url) => {
        if (/\.(?:jpe?g|png|gif|webp|bmp|heic|svg)(?:\?.*)?$/i.test(url)) {
          return '<img class="md-img" src="' + url + '" alt="' + text + '">';
        }
        if (/\.(?:mp4|mov|m4v|webm|ogv)(?:\?.*)?$/i.test(url)) {
          return '<video class="md-video" src="' + url + '" controls playsinline webkit-playsinline preload="metadata"></video>' +
                 '<a class="md-video-link" href="' + url + '">▶ ' + text + '</a>';
        }
        return '<a href="' + url + '">' + text + '</a>';
      });
      // 3.5. markdown autolink <url> — escapeHTML 后变成 &lt;url&gt;，
      //     先把尖括号包裹剥掉，避免 bare URL 把 &gt; 吞进 href（点完会变 %3E）
      s = s.replace(/&lt;(https?:\/\/[^\s]+?)&gt;/gi, '$1');
      // 4. bare image URL — 必须在 bold/italic 之前处理，否则会被 ** 包成 plain 粗体
      //    URL char 类排除 * ，防止 **url** 把闭合 ** 吞进 URL
      s = s.replace(/(https?:\/\/[^\s<"\)*]+?\.(?:jpe?g|png|gif|webp|bmp|heic|svg)(?:\?[^\s<"\)*]*)?)/gi,
        (m) => '<img class="md-img" src="' + m + '">');
      // 4.5. bare video URL → 内联 <video controls>
      s = s.replace(/(https?:\/\/[^\s<"\)*]+?\.(?:mp4|mov|m4v|webm|ogv)(?:\?[^\s<"\)*]*)?)/gi,
        (m) => '<video class="md-video" src="' + m + '" controls playsinline webkit-playsinline preload="metadata"></video>' +
               '<a class="md-video-link" href="' + m + '">▶ 打开视频</a>');
      // 5. bare URL → <a> ，已有的 <a>/<img>/<video>/<code> 先 stash 起来避免重复包裹
      var placeholders = [];
      function stash(m) { placeholders.push(m); return '\x00P' + (placeholders.length - 1) + '\x00'; }
      s = s.replace(/<a\b[^>]*>[\s\S]*?<\/a>/gi, stash);
      s = s.replace(/<img\b[^>]*>/gi, stash);
      s = s.replace(/<video\b[^>]*>[\s\S]*?<\/video>/gi, stash);
      s = s.replace(/<code\b[^>]*>[\s\S]*?<\/code>/gi, stash);
      s = s.replace(/(https?:\/\/[^\s<>"'`*]+)/gi, (m) => {
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
              '<span class="head-btns">' +
                '<button class="sel-btn" data-content="' + utf8B64(rawForCopy) + '" onclick="openSelect(this)">选择复制</button>' +
                '<button class="copy-btn" data-content="' + utf8B64(rawForCopy) + '" onclick="copyMsg(this)">复制</button>' +
              '</span>' +
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
          const codeRaw = body.join('\n');
          const codeInner = '<pre><code>' + linkifyEscaped(escapeHTML(codeRaw)) + '</code></pre>';
          if (codeClickable) {
            html += '<div class="code-wrap" data-code="' + utf8B64(codeRaw) + '" onclick="copyCode(event, this)">' +
                    '<span class="code-copy">⧉ 点击复制</span>' + codeInner + '</div>';
          } else {
            html += codeInner;
          }
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
        let para = line;
        i++;
        while (i < lines.length && lines[i].trim() !== '' &&
               !/^(```|▶|◆|=== |#{1,6}\s|\s*[-*]\s|\s*\d+\.\s|>\s|\|.*\|\s*$)/.test(lines[i])) {
          // 终端折行会把长 URL 从中间断开（上一行以未结束 URL 收尾，下一行紧接 URL 字符），
          // 这种情况无空格拼回，避免点链接时丢掉后半段；下一行是中文/普通正文则照常加空格
          const wrappedURL = /https?:\/\/[^\s<>"'`]+$/.test(para) &&
                             /^[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]/.test(lines[i]);
          para += wrappedURL ? lines[i] : (' ' + lines[i]);
          i++;
        }
        html += '<p>' + renderInline(escapeHTML(para)) + '</p>';
      }
      return html;
    }
    // 多重 fallback：1) native bridge（专属 webView），2) navigator.clipboard，3) textarea+execCommand
    function doCopy(text) {
      let copied = false;
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copy) {
        try { window.webkit.messageHandlers.copy.postMessage(text); copied = true; } catch (e) {}
      }
      if (!copied && navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(() => {});
        copied = true;
      }
      if (!copied) {
        try {
          const ta = document.createElement('textarea');
          ta.value = text;
          ta.style.position = 'fixed'; ta.style.opacity = '0';
          document.body.appendChild(ta);
          ta.focus(); ta.select();
          document.execCommand('copy');
          document.body.removeChild(ta);
        } catch (e) {}
      }
    }
    function decodeContent(btn) {
      const enc = btn.getAttribute('data-content') || '';
      try { return decodeURIComponent(escape(atob(enc))); } catch (e) { return atob(enc); }
    }
    function copyMsg(btn) {
      doCopy(decodeContent(btn));
      const orig = btn.textContent;
      btn.classList.add('copied');
      btn.textContent = '✓ 已复制';
      setTimeout(() => { btn.classList.remove('copied'); btn.textContent = orig; }, 1500);
    }
    // 代码块点击整块复制
    var codeClickable = true;
    function copyCode(e, el) {
      if (e) e.stopPropagation();
      const enc = el.getAttribute('data-code') || '';
      let text; try { text = decodeURIComponent(escape(atob(enc))); } catch (err) { text = atob(enc); }
      doCopy(text);
      const badge = el.querySelector('.code-copy');
      el.classList.add('copied');
      if (badge) badge.textContent = '✓ 已复制';
      setTimeout(() => { el.classList.remove('copied'); if (badge) badge.textContent = '⧉ 点击复制'; }, 1400);
    }
    // 把一条消息正文切成可勾选的块：代码块/表格/列表/引用/标题各算一块，连续非空行算一段
    function splitBlocks(text) {
      const lines = text.split('\n');
      const blocks = [];
      let i = 0;
      while (i < lines.length) {
        const line = lines[i];
        if (line.trim() === '') { i++; continue; }
        if (/^```/.test(line)) {
          const start = i; i++;
          while (i < lines.length && !/^```/.test(lines[i])) i++;
          if (i < lines.length) i++;
          blocks.push(lines.slice(start, i).join('\n')); continue;
        }
        if (/^#{1,6}\s+/.test(line)) { blocks.push(line); i++; continue; }
        if (/^\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\|[\s\-:|]+\|\s*$/.test(lines[i+1])) {
          const start = i; i += 2;
          while (i < lines.length && /^\|.*\|\s*$/.test(lines[i])) i++;
          blocks.push(lines.slice(start, i).join('\n')); continue;
        }
        if (/^\s*[-*]\s+/.test(line) || /^\s*\d+\.\s+/.test(line)) {
          const start = i;
          while (i < lines.length && (/^\s*[-*]\s+/.test(lines[i]) || /^\s*\d+\.\s+/.test(lines[i]))) i++;
          blocks.push(lines.slice(start, i).join('\n')); continue;
        }
        if (/^>\s+/.test(line)) {
          const start = i;
          while (i < lines.length && /^>\s+/.test(lines[i])) i++;
          blocks.push(lines.slice(start, i).join('\n')); continue;
        }
        const start = i; i++;
        while (i < lines.length && lines[i].trim() !== '' &&
               !/^(```|=== |#{1,6}\s|\s*[-*]\s|\s*\d+\.\s|>\s|\|.*\|\s*$)/.test(lines[i])) i++;
        blocks.push(lines.slice(start, i).join('\n'));
      }
      return blocks;
    }
    var selBlocks = [], selChosen = [];
    function updateSelCount() {
      const n = selChosen.filter(Boolean).length;
      const btn = document.getElementById('sel-copy');
      btn.textContent = n ? ('复制所选 (' + n + ')') : '复制所选';
      btn.disabled = n === 0;
    }
    function renderSelList() {
      const list = document.getElementById('sel-list');
      list.innerHTML = '';
      codeClickable = false;   // 选择复制页里代码块不单独可点，避免和整卡勾选冲突
      selBlocks.forEach((raw, idx) => {
        const card = document.createElement('div');
        card.className = 'sel-card' + (selChosen[idx] ? ' on' : '');
        card.innerHTML = '<span class="chk"></span>' + renderBlocks(raw);
        card.addEventListener('click', function(e) {
          if (e.target.tagName === 'A' || (e.target.tagName === 'IMG' && e.target.classList.contains('md-img'))) return;
          selChosen[idx] = !selChosen[idx];
          card.classList.toggle('on', selChosen[idx]);
          updateSelCount();
        });
        list.appendChild(card);
      });
      codeClickable = true;
      updateSelCount();
    }
    function openSelect(btn) {
      selBlocks = splitBlocks(decodeContent(btn));
      selChosen = selBlocks.map(() => true);
      renderSelList();
      document.getElementById('sel-list').scrollTop = 0;
      document.getElementById('selpage').classList.add('show');
    }
    function closeSelect() { document.getElementById('selpage').classList.remove('show'); }
    function selAll(v) {
      selChosen = selBlocks.map(() => v);
      Array.from(document.querySelectorAll('#sel-list .sel-card')).forEach(c => c.classList.toggle('on', v));
      updateSelCount();
    }
    function showSelToast(msg) {
      const t = document.getElementById('sel-toast');
      t.textContent = msg; t.classList.add('show');
      setTimeout(() => t.classList.remove('show'), 1400);
    }
    function copySelected() {
      const parts = [];
      selBlocks.forEach((raw, i) => { if (selChosen[i]) parts.push(raw); });
      if (!parts.length) return;
      doCopy(parts.join('\n\n'));
      showSelToast('已复制 ' + parts.length + ' 块');
      setTimeout(closeSelect, 450);
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

