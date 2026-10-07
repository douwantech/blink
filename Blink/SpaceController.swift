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
      // 这里**不再** _persistTabsToStore()：自有标签已按老板口径彻底丢弃（不显示、不落盘、
      // 不回传），而坞里全是服务端公用标签。Documents/blink_tabs.json、iCloud KV 镜像、
      // PUT /v1/config/tabs 三者都从 TabStateStore 出发，不喂它就都不会被写。
      // 顺带避免了渲染期写状态（每次刷坞都会触发一次 personal 上传，还会跟服务端 ping-pong）。
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
      // 公用标签不是账号的数据：停在它上面也不写 currentId（否则会把公用标签的 ID
      // 当成自己的选中项回传）。当前选中项保持在上一个自有标签。
      if let key = _currentKey, !_sharedKeys.contains(key) {
        TabStateStore.shared.update { $0.currentId = self._currentKey }
      }
      _reloadTabBar()
      NotificationCenter.default.post(name: .blinkActiveSessionDidChange, object: nil)
    }
  }

  /// 服务端读时注入的全局公用标签（见 server/README.md「Public tabs」）。它们会进
  /// `_viewportsKeys` 供查看/翻页，但**不落盘、不回传、不可关闭**；栖身坞里的也只有
  /// employee 前缀是 tom 的那几条（见 `_dockKeySet`）。
  private var _sharedKeys = Set<UUID>()
  /// 当前公用标签被休息/撤下时，保留它所在的机器供补位选择。
  private var _removedSharedMachineId: String?

  /// 自有标签的第一位（公用恒在最前，见 `_syncSharedTabs`）。给「把某个标签提到最前」
  /// 那几处用，别让自有的新标签插到公用标签前面去。
  private var _firstOwnIndex: Int {
    _viewportsKeys.firstIndex { !_sharedKeys.contains($0) } ?? _viewportsKeys.count
  }

  /// 把服务端的公用标签同步进 tab 集合：新来的建终端并排到最前，服务器不再给的移除。
  /// 这是公用标签进入 `_viewportsKeys` 的唯一入口，也是它们唯一的生命周期管理点 ——
  /// 不走墓碑（它们不是用户关掉的）。**休息的标签不进坞**（SharedRestStore 过滤，
  /// 团队页月亮开关管的就是它；默认只有 tom 的在岗）。
  private func _syncSharedTabs() {
    let shared = ServerConfigSync.shared.sharedTabs.filter { SharedRestStore.shared.isActive($0.tmuxSession) }
    // TODO(teamfix): 临时诊断日志（非 tom 在岗不显示的排查），定位完删
    Self.teamDebugLog("sync: serverTabs=\(ServerConfigSync.shared.sharedTabs.count) activeAfter=\(shared.map(\.tmuxSession).sorted().joined(separator: ","))")
    let newKeys = shared.map { $0.id }
    let newSet = Set(newKeys)
    let previous = _sharedKeys

    for tab in shared {
      let term: TermController = SessionRegistry.shared[tab.id]
      if term.mcpParams == nil {
        let p = MCPParams()
        p.machineId = tab.machineId
        p.workDirId = nil
        p.tmuxSession = tab.tmuxSession
        p.useTmux = true
        term.bindRestoredMcpParams(p)
      }
      term.delegate = self
      term.bgColor = view.backgroundColor ?? .black
    }

    let dropped = previous.subtracting(newSet)
    if let current = _currentKey, dropped.contains(current) {
      _removedSharedMachineId = (SessionRegistry.shared[current] as TermController).mcpParams?.machineId
    }
    // TODO(teamfix): 临时诊断日志（终端反复重建排查），定位完删
    if !dropped.isEmpty {
      var names: [String] = []
      for k in dropped {
        let t: TermController? = SessionRegistry.shared[k]
        names.append(t?.mcpParams?.tmuxSession ?? "?")
      }
      Self.teamDebugLog("dropTabs: count=\(dropped.count) sessions=\(names.sorted().joined(separator: ","))")
    }
    for key in dropped {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = nil
      term.terminate()
      SessionRegistry.shared.remove(forKey: key)
    }

    _sharedKeys = newSet
    let own = _viewportsKeys.filter { !previous.contains($0) && !newSet.contains($0) }
    let merged = SharedTabLayout.ordered(shared: newKeys, own: own)
    if merged != _viewportsKeys {
      _viewportsKeys = merged   // didSet → 持久化 + 刷新 tab 栏/三栏
    }
    _sortTabsByMachineAndDir()
  }

  /// 坞空（未登录 / 离线 / 服务端没给 tom 的标签）时什么都不选 —— 空坞空屏，不兜底
  ///（老板口径「不保留退路」：宁可不显示，也不要拿一条本地标签顶上）。
  private func _selectDockFirstIfNeeded() {
    let dock = _dockKeySet()
    if let cur = _currentKey, dock.contains(cur) {
      _removedSharedMachineId = nil
      return
    }
    let machineId = _removedSharedMachineId
    _removedSharedMachineId = nil
    let sameMachine = machineId.flatMap { mid in
      _viewportsKeys.first { key in
        guard dock.contains(key) else { return false }
        return (SessionRegistry.shared[key] as TermController).mcpParams?.machineId == mid
      }
    }
    _currentKey = sameMachine ?? _viewportsKeys.first { dock.contains($0) }
  }

  /// 同步可能在首屏建好后才送来标签，也可能撤掉当前标签。选中项和 page controller
  /// 必须一起更新；只改 _currentKey 会留下没有终端内容的黑屏。
  private func _showSelectedDockTabAfterSync() {
    _selectDockFirstIfNeeded()
    guard let key = _currentKey else {
      _viewportsController.view.isHidden = true
      return
    }
    let term: TermController = SessionRegistry.shared[key]
    _viewportsController.view.isHidden = false
    if _viewportsController.viewControllers?.first !== term {
      term.delegate = self
      term.bgColor = view.backgroundColor ?? .black
      _viewportsController.setViewControllers([term], direction: .forward, animated: false)
    }
    term.resumeIfNeeded()
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
    // 公用标签仍钉在最前（服务端顺序），恢复出来的自有标签接在后面 —— 以前这里是
    // `_viewportsKeys = keys` 整份替换，会把公用标签从坞里冲掉。自有标签这轮不显示，
    // 留着它们只为了不打断 `_viewportsKeys` 的既有不变量（别让它们伪造出「有这个 tab」）。
    _viewportsKeys = SharedTabLayout.ordered(
      shared: _viewportsKeys.filter { _sharedKeys.contains($0) }, own: keys)
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
  /// 供外部（如 SmarterTermInput 的 ⌘V 贴图）借 dock 弹 toast
  var voiceDock: VoiceInputView { _voiceDock }
  // 常驻底部语音 dock（第三块布局）：钉在 keyboardLayoutGuide 顶部，跟键盘生命周期解绑，
  // 上下滚终端/失焦都不会被收走。仅手机布局用；Mac 直输不加。
  private let _voiceDock = VoiceInputView()
  private let _dockBottomFill = UIView()
  private var _voiceDockInstalled = false
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
      let tabH: CGFloat = 50   // 单行 tab 栏（原型：38pt 胶囊 + 上下留白）
      _installVoiceDockIfNeeded()
      // 底部给常驻 dock 让出高度（dock 高 + 底部安全区）
      let dockReserved = VoiceInputView.dockHeight + view.safeAreaInsets.bottom
      _statusBarBg.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: safeTop)
      _tabBar.frame = CGRect(x: 0, y: safeTop, width: view.bounds.width, height: tabH)
      view.bringSubviewToFront(_statusBarBg)
      if let v = _viewportsController.view {
        v.frame = CGRect(
          x: 0,
          y: safeTop + tabH,
          width: view.bounds.width,
          height: max(0, view.bounds.height - safeTop - tabH - dockReserved)
        )
      }
      view.bringSubviewToFront(_tabBar)
      _voiceDock.delegate = KBTracker.shared.input
      view.bringSubviewToFront(_dockBottomFill)
      view.bringSubviewToFront(_voiceDock)
    }
  }

  /// 安装常驻底部 dock：钉在 keyboardLayoutGuide 顶部（没键盘→钉底部安全区；键盘起→浮到键盘上方）。
  private func _installVoiceDockIfNeeded() {
    guard !_voiceDockInstalled, !_macLayoutEnabled else { return }
    _voiceDockInstalled = true
    _voiceDock.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(_voiceDock)
    // dock 下面的 home 指示条安全区补同色底，别露 view 的纯黑
    _dockBottomFill.backgroundColor = _voiceDock.backgroundColor
    _dockBottomFill.isUserInteractionEnabled = false
    _dockBottomFill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(_dockBottomFill)
    NSLayoutConstraint.activate([
      _voiceDock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      _voiceDock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      _voiceDock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      _voiceDock.heightAnchor.constraint(equalToConstant: VoiceInputView.dockHeight),

      _dockBottomFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      _dockBottomFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      _dockBottomFill.topAnchor.constraint(equalTo: _voiceDock.bottomAnchor),
      _dockBottomFill.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    _voiceDock.delegate = KBTracker.shared.input
  }

  @objc private func _agentConfigChanged() {
    DispatchQueue.main.async { [weak self] in self?._reloadTabBar() }
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
    // 浮动竖条已移除：语音/浏览器/远程桌面入口都在底部常驻 dock 里
  }

  //（浮动机器条已移除：`_showMachineBarChanged` / `_toggleFloatingBars` 两个观察者
  // 与其 watch 的 BlinkMachineStore.showMachineBarChanged 一起退休；设置页里那个
  // 「切换机器条」开关也一并撤掉了 —— 按了没反应的开关比没有更糟。
  // `BlinkMachineStore.showMachineBar` 留着（FloatingMachineBar 那个已无人实例化的类还读它）。）

  // 录音状态变化：浮动条 mic 钮切 停止/mic 图标
  @objc private func _voiceRecordingStateChanged(_ note: Notification) {
    let recording = (note.userInfo?["recording"] as? Bool) ?? false
    _voiceIsRecording = recording
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

  /// 当前 tab 机器的 RustDesk 配置;没配则弹提示返回 nil
  private func _rustdeskMachine() -> BlinkMachine? {
    let store = BlinkMachineStore.shared
    let mid = currentTerm()?.mcpParams?.machineId
    let machine = mid.flatMap { id in store.machines.first { $0.id == id } } ?? store.currentMachine
    guard let m = machine, let rid = m.rustdeskId, !rid.isEmpty else {
      let name = machine?.displayName ?? "当前机器"
      let alert = UIAlertController(
        title: "未配置远程桌面",
        message: "在「机器 → \(name) → 远程桌面」里填上这台机器的 RustDesk ID（和固定密码）。",
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "确定", style: .default))
      present(alert, animated: true)
      return nil
    }
    return m
  }

  // dock 🖥️ 钮：打开内嵌 RustDesk 远程桌面页（核心库直连，不切 App）
  @objc func _openRemoteDesktop() {
    guard RustDeskCore.isAvailable else {
      let alert = UIAlertController(
        title: "远程桌面不可用",
        message: "本次构建没有链接 RustDesk 核心库（liblibrustdesk.a）。长按此按钮可改走独立 RustDesk App。",
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "确定", style: .default))
      present(alert, animated: true)
      return
    }
    guard let m = _rustdeskMachine(), let rid = m.rustdeskId else { return }
    // 传 SSH 通道(同一台机器的 host/user),供"双击识别窗口并缩放"用
    let host = BlinkMachineStore.bestHost(for: m)
    let vc = RemoteDesktopViewController(peerId: rid, password: m.rustdeskPassword ?? "",
                                        sshHost: host, sshUser: m.user)
    present(vc, animated: true)
  }

  // dock 🖥️ 长按：保底走深链拉起独立 RustDesk App
  @objc func _openRemoteDesktopViaApp(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began else { return }
    guard let m = _rustdeskMachine(), let rid = m.rustdeskId else { return }
    var link = "rustdesk://connection/new/\(rid)"
    if let pwd = m.rustdeskPassword, !pwd.isEmpty,
       let enc = pwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
      link += "?password=\(enc)"
    }
    guard let url = URL(string: link) else { return }
    UIApplication.shared.open(url, options: [:]) { [weak self] ok in
      guard !ok, let self else { return }
      let alert = UIAlertController(
        title: "打不开 RustDesk",
        message: "手机上似乎没装 RustDesk App（com.aitools.rustdesk）。",
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "确定", style: .default))
      self.present(alert, animated: true)
    }
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
    vc.onToggleMaximize = { [weak self] in self?._toggleBrowserMaximize() }
    if vc.presentingViewController != nil {
      return vc
    }
    _applyBrowserPresentation(vc, maximized: _browserMaximized)
    var top: UIViewController = self
    while let presented = top.presentedViewController { top = presented }
    top.present(vc, animated: true)
    return vc
  }

  private var _browserMaximized = false

  /// Mac 浏览器窗口最大化：pageSheet(.large 浮层) ↔ fullScreen(占满整个 Blink 窗口)。
  private func _applyBrowserPresentation(_ vc: PinnedBrowserViewController, maximized: Bool) {
    if maximized {
      vc.modalPresentationStyle = .fullScreen
    } else {
      vc.modalPresentationStyle = .pageSheet
      if let sheet = vc.sheetPresentationController {
        sheet.detents = [.large()]
        sheet.selectedDetentIdentifier = .large
        sheet.prefersGrabberVisible = false
        sheet.preferredCornerRadius = 16
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
      }
    }
    vc.setMaximized(maximized)
  }

  /// modal 呈现方式不能就地改，切换靠 dismiss + 无动画 re-present；_pinnedBrowserVC 实例
  /// 强引用复用，tabs / 当前页 / 缩放全部保留。
  private func _toggleBrowserMaximize() {
    guard let vc = _pinnedBrowserVC, vc.presentingViewController != nil else { return }
    _browserMaximized.toggle()
    let presenting = vc.presentingViewController ?? self
    vc.dismiss(animated: false) { [weak self] in
      guard let self else { return }
      self._applyBrowserPresentation(vc, maximized: self._browserMaximized)
      presenting.present(vc, animated: false)
    }
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
    v.backgroundColor = UIColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1)   // #0b0c0e，与 tab 栏/dock 同色
    v.isUserInteractionEnabled = false
    return v
  }()
  private static let kTabFilterMachineId = "BlinkTabFilterMachineId"

  // 被标记「休息」(😴) 的员工始终从标签栏隐藏；改回在岗用顶栏 🌙 面板。
  // 保留此计算属性（恒为 true）以复用原有的过滤判断。
  private var _workModeOn: Bool { true }

  /// Mac rail 选定的机器（手机上没人写它，恒为 nil = 全部）。**只是导航维度**，
  /// 不再是「员工×机器筛选器」的一半 —— 那个功能已按老板口径删掉。
  private var _tabFilterMachineId: String? {
    get { UserDefaults.standard.string(forKey: SpaceController.kTabFilterMachineId) }
    set {
      if let v = newValue {
        UserDefaults.standard.set(v, forKey: SpaceController.kTabFilterMachineId)
      } else {
        UserDefaults.standard.removeObject(forKey: SpaceController.kTabFilterMachineId)
      }
      ServerConfigSync.shared.schedulePersonalUpload()
    }
  }

  /// 坞里铺的键。老板口径：**服务端公用标签里 employee 前缀为 tom 的那几条**，写死常量、
  /// 不做筛选器、不分节不加徽标。自有标签不在坞里（`_sharedKeys` 一刀切掉），其余公用标签
  /// 也不在（它们是别位员工的，仍会注册会话供「员工状态」计数，只是 UI 不可达）。
  /// Mac rail 选定的那台机器再从里面收窄；手机上恒为 nil，所以就是 tom 的那 6 条。
  /// **只读派生**：渲染路径绝不写回 —— 写回会让每次刷坞都触发一次 personal 上传。
  private func _dockKeySet() -> Set<UUID> {
    // 机器收窄只属于 Mac rail（选定机器高亮用）。手机坞 = **全部**在岗标签跨机器平铺；
    // 别让 selection 回读来的 machineId 把手机坞锁死在一台机器上（2026-10-06 踩过：
    // Mac 端 rail 选过 brain 后 iPhone 坞永远只剩 brain 的 tom 三条，其他员工开在岗
    // 也不显示 —— _tabFilterMachineId 底层是 UserDefaults，会被 ServerConfigSync 回写）。
    let machineId = _macRail != nil ? _tabFilterMachineId : nil
    return Set(_viewportsKeys.filter { key in
      guard _sharedKeys.contains(key) else { return false }
      let p = (SessionRegistry.shared[key] as TermController).mcpParams
      guard SharedTabLayout.isDockTab(tmuxSession: p?.tmuxSession) else { return false }
      return machineId == nil || p?.machineId == machineId
    })
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
    
    // 自有标签一律不恢复、不兜底：坞里只有服务端 tom 的那几条（见 `_dockKeySet`）。
    // 公用标签：登录/冷启动时先补进 tab 集合。这个场景走不到 didApply（见
    // _serverConfigDidApply），通知只在 App 已经活着时到。
    _syncSharedTabs()
    _sortTabsByMachineAndDir()
    _hideAssistantTabs()
    // 当前页必须落在坞里。**这是「不保留退路」的总闸**：本机 blink_tabs.json、iCloud KV
    // 镜像、服务端 user_configs 三处可能还留着旧的自有标签，无论哪条恢复路径把它们拉起来，
    // 都不会成为当前页（坞与滑动集合另外两道闸也不列它们）。
    _selectDockFirstIfNeeded()
    if let key = _currentKey {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = self
      // term.layoutProvider = self
      term.bgColor = view.backgroundColor ?? .black
      _viewportsController.setViewControllers([term], direction: .forward, animated: false)
    }

    self.view.addSubview(_bottomTapAreaView)

    // 浮动竖条已移除：语音/浏览器/远程桌面等入口全在底部常驻 dock 工具行
    NotificationCenter.default.addObserver(self, selector: #selector(_voiceRecordingStateChanged(_:)), name: VoiceInputView.recordingStateChangedNotification, object: nil)

    // E2E 自截屏后门：仅测试设备手动开 BlinkE2ESnapshotHook 才注册（生产 inert）。
    // 注意本工程没配 SWIFT_ACTIVE_COMPILATION_CONDITIONS，#if DEBUG 永远是 false，别用。
    if UserDefaults.standard.bool(forKey: "BlinkE2ESnapshotHook") {
      _ = Self._installDebugSnapshotHook
    }
    if _macLayoutEnabled {
      // Mac 三栏：tab 栏隐藏（会话列表取代）
      _setupMacThreeColumn()
    }
    // iPhone 的「切换机器」浮动机器条已按老板口径移除（掉头：坞只剩服务端 tom 的标签，
    // 手机上没有可切的机器维度）。设置里那一项与 Mac rail 的机器导航暂时还在。
    NotificationCenter.default.addObserver(self, selector: #selector(_voiceInputAutoShowChanged), name: .voiceInputAutoShowChanged, object: nil)
    // 团队页/长按菜单改了某个 tab 的 CLI，tab 条上的角标得跟着换
    NotificationCenter.default.addObserver(self, selector: #selector(_agentConfigChanged),
                                           name: TabAgentStore.didChangeNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(_keyboardDidShowForMic), name: UIResponder.keyboardDidShowNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(_keyboardDidHideForMic), name: UIResponder.keyboardDidHideNotification, object: nil)
    _updateFloatingMicVisibility()

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleQuickActionsAction))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.numberOfTouchesRequired = 1
    _bottomTapAreaView.addGestureRecognizer(doubleTap)

    // 长按终端切换浮动条显隐那条通知的观察者已随浮动机器条一起移除
    //（BLToggleFloatingBars 现在没有订阅者，长按无副作用）
    
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
    nc.addObserver(self, selector: #selector(_serverConfigDidApply),
                   name: ServerConfigSync.didApply, object: nil)
  }

  @objc private func _serverConfigDidApply() {
    _cloudConfigDidRestore()
    // 服务端每次采纳完（登录/回前台刷新）都重放一遍公用标签：新增的进来、撤下的移走。
    _syncSharedTabs()
    _showSelectedDockTabAfterSync()
    _macRail?.reload(currentId: _tabFilterMachineId)
    _reloadTabBar()
  }

  @objc private func _flushTabStateStore() {
    TabStateStore.shared.flushNow()
  }

  /// iCloud 送来新配置（可能含更新的 tab 列表）。
  /// - 本机没有「真实」tab（空 / 仅空白 shell）→ 整份采纳云端列表并重建（新设备拿到别人的 tab）。
  /// - 本机已有真实 tab（活跃设备）→ 增量追加：把别处新开、本机还没有的 tab 加进列表，
  ///   但不切走当前 tab、不动键盘焦点（跨设备实时可见又不打断正在用的会话）。
  @objc private func _cloudConfigDidRestore() {
    // iCloud KV 变更通知（didChangeExternally）在后台线程投递。下面要建 TermController /
    // 碰 UIKit / 改 _viewportsKeys，必须切主线程，否则在后台线程创建 TermView 直接崩
    //（"Unsupported layout off the main thread"）。原来活跃设备一律 return、空白设备极少走到，
    // 都没建视图所以没暴露；增量追加真的建了视图，才把这个后台线程 bug 触发出来。
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?._cloudConfigDidRestore() }
      return
    }
    // 休息标记跨设备同步：云端可能改了 TabRestStore.resting（内存缓存要重读），变了就刷新列表过滤 + 🌙 计数。
    if TabRestStore.shared.reload() {
      _reloadTabBar()
    }
    let hasReal = _viewportsKeys.contains { k -> Bool in
      let term: TermController = SessionRegistry.shared[k]
      let p = term.mcpParams
      return p?.machineId != nil || p?.workDirId != nil || p?.tmuxSession != nil
    }
    if !hasReal {
      guard TabStateStore.shared.adoptSyncedIfNewer() else { return }
      _restoreFromStore()
      _sortTabsByMachineAndDir()
      _hideAssistantTabs()
      // 恢复出来的自有标签一律不作数：当前页必须落回坞里（坞空就是空屏）—— 跟 viewDidLoad
      // 同一条闸，否则 iCloud 一同步就会把一个用户不该看到的终端顶到屏幕上。
      _selectDockFirstIfNeeded()
      if let key = _currentKey {
        let term: TermController = SessionRegistry.shared[key]
        term.delegate = self
        term.bgColor = view.backgroundColor ?? .black
        _viewportsController.setViewControllers([term], direction: .forward, animated: false)
      }
      return
    }
    _appendNewSyncedTabs()
  }

  /// 活跃设备增量合并：iCloud 送来的列表里，本机（按 机器+目录+会话 签名）还没有的
  /// 「真实」tab 追加到末尾并 re-sort，当前 tab / 键盘焦点保持不变。
  /// 增量追加之外，还要采纳云端的关闭墓碑（closedIds）：别处显式关掉的 tab 在这里也删掉，
  /// 这样删除才能跨设备传播、且不会被本机没删又推回去复活。墓碑只删「显式关过」的，
  /// 不会误伤本机正用但别处从没见过的会话。
  private func _appendNewSyncedTabs() {
    guard let syncedState = TabStateStore.shared.syncedState() else { return }
    let synced = syncedState.tabs
    // 墓碑里可能留着公用 ID（跨设备的旧记录），先剔掉：公用标签不是用户关掉的。
    let closed = Set(syncedState.closedIds ?? []).subtracting(_sharedKeys)

    // 采纳别处的关闭：墓碑并进本地（本机后续 push 不再带这些），并把本机还留着的删掉。
    // 仅当有新墓碑、或本机还留着被墓碑标记的 tab 时才动，避免每次云端变更都无谓回写（防 ping-pong）。
    if !closed.isEmpty {
      let localClosed = Set(TabStateStore.shared.snapshot().closedIds ?? [])
      let hasNewTombstone = !closed.isSubset(of: localClosed)
      let hasLocalToRemove = _viewportsKeys.contains { closed.contains($0) }
      if hasNewTombstone || hasLocalToRemove {
        TabStateStore.shared.closeTabs(Array(closed))
        _removeKeys(closed)
      }
    }

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
      // 公用标签由 _syncSharedTabs 管，绝不从这里（iCloud 镜像 / 别的设备推来的列表）追加：
      // 否则它们会以自有标签的身份进 _viewportsKeys，被持久化、被回传。
      guard !_sharedKeys.contains(entry.id) else { continue }
      // 空白 shell（无机器/目录/会话）不追加
      guard entry.machineId != nil || entry.workDirId != nil || entry.tmuxSession != nil else { continue }
      if closed.contains(entry.id) { continue }   // 已被墓碑标记的别再加回来
      // 助手 tab 暂时下线：别的设备（老版本）推来的也不收
      if entry.tmuxSession == BlinkWorkDirStore.assistantTmuxSession
          || entry.workDirId == BlinkWorkDirStore.assistantWorkDirId { continue }
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

    // 回前台主动向配置服务器对齐一次：设备间切换是「切前台」不是冷启动，只靠启动
    // 时那一次拉，切过来常常看不到另一台的最新 tab。iCloud 拉回已停用（老板
    // 2026-10-05 拍板），没登录服务器时这里不做任何 iCloud 动作，等登录页出现。
    if view.window?.windowScene === scene {
      if ServerConfigSync.shared.hasSession {
        Task { try? await ServerConfigSync.shared.refresh() }
      } else {
        #if targetEnvironment(macCatalyst)
        // 顺手把配置推到各台机器的 ~/.blink/sync/（60s 节流），鸿蒙端从那里拉
        ConfigSyncPush.shared.pushSoon()
        #endif
      }
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
    // 公用标签不可关（服务端也会把它们从 closedIds 里剔除，但本机就不该走到这里）：
    // 不记墓碑、不终止会话。Tab 栏/侧栏本来也不给关闭入口，这里是最后一道闸。
    if let k = _currentKey, _sharedKeys.contains(k) {
      _reloadTabBar()
      return
    }
    // 墓碑：记下这次关闭，跨设备传播删除（否则别的设备没删、又会把它推回来复活）。
    // 只在真·关闭时记；窗口移动走的是 _removeCurrentSpace，不记墓碑。
    if let k = _currentKey { TabStateStore.shared.closeTabs([k]) }
    currentTerm()?.terminate()
    _removeCurrentSpace()
  }

  /// 采纳别处的关闭：把这些 key 从本机 UI 移除（终止会话、修当前 tab）。
  /// 与 _removeCurrentSpace 不同，这里可一次删多个、且要处理「删到当前 tab」的补位。
  private func _removeKeys(_ toRemove: Set<UUID>) {
    let toRemove = toRemove.subtracting(_sharedKeys)   // 公用标签不受别处墓碑影响
    guard !toRemove.isEmpty,
          _viewportsKeys.contains(where: { toRemove.contains($0) }) else { return }
    let oldCurrentIdx = _currentKey.flatMap { _viewportsKeys.firstIndex(of: $0) }
    let currentRemoved = _currentKey.map { toRemove.contains($0) } ?? false

    for key in _viewportsKeys where toRemove.contains(key) {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = nil
      term.terminate()
      SessionRegistry.shared.remove(forKey: key)
    }
    let survivors = _viewportsKeys.filter { !toRemove.contains($0) }
    _viewportsKeys = survivors   // didSet → 持久化 + 刷新 tab 栏/三栏

    guard currentRemoved else { return }
    if survivors.isEmpty {
      _newShellAction(animated: false)
      return
    }
    // 删到当前 tab：切到原位置附近的存活 tab
    let newIdx = min(oldCurrentIdx ?? 0, survivors.count - 1)
    let term: TermController = SessionRegistry.shared[survivors[newIdx]]
    term.delegate = self
    term.bgColor = view.backgroundColor ?? .black
    _viewportsController.setViewControllers([term], direction: .forward, animated: false)
    _currentKey = survivors[newIdx]
    term.resumeIfNeeded()   // 补位的也可能是没启动过的，同上要踢一脚
    if _macLayoutEnabled { _attachInputToCurrentTerm() }
  }
  
  private func _removeCurrentSpace(attachInput: Bool = true) {
    // 公用标签不参与「移走当前 tab」（移到别的窗口/外接屏）：它们由服务端列表决定去留。
    if let currentKey = _currentKey, _sharedKeys.contains(currentKey) { return }
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

    // 落位 = 与手动滑动**同一条**路径与顺序（老板口径 2026-10-07：别自成一派）：
    // completion 里 先 resumeIfNeeded（旁边 tab 可能是没启动过的新建）→ 再设
    // _currentKey → HUD/输入焦点。旧实现把 _currentKey 提前到切页之前写，
    // didSet 的整套副作用（持久化/刷坞）会跟切页动画赛跑，是黑屏来源之一。
    let neighborIdx = min(idx, _viewportsKeys.count - 1)
    let term: TermController = SessionRegistry.shared[_viewportsKeys[neighborIdx]]
    term.delegate = self
    term.bgColor = view.backgroundColor ?? .black
    _spaceControllerAnimating = true
    _viewportsController.setViewControllers([term], direction: .forward, animated: true) { _ in
      term.resumeIfNeeded()
      self._currentKey = term.meta.key
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
    // swipe 跨到了另一台机器：同步 rail 高亮到新机器
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
    // 与 tab 栏一致：左右滑动也跳过被「只显示工作中」隐藏（休息）的 tab
    let filtered = _visibleFilteredKeys()
    if let pos = filtered.firstIndex(of: key)?.advanced(by: advancedBy),
       filtered.indices.contains(pos) {
      let newCtrl: TermController = SessionRegistry.shared[filtered[pos]]
      newCtrl.delegate = self
      newCtrl.bgColor = view.backgroundColor ?? .black
      return newCtrl
    }
    // 越界：rail 选了机器 + ≥2 台机器有坞内标签 → 跨到下一台机器的端点 tab
    guard let curFilter = _tabFilterMachineId else { return nil }
    let machineIds = _machineIdsWithTabs()
    guard machineIds.count > 1,
          let curMid = machineIds.firstIndex(of: curFilter) else { return nil }
    let nextMid = (curMid + (advancedBy > 0 ? 1 : -1) + machineIds.count) % machineIds.count
    let nextFilterId = machineIds[nextMid]
    let nextFiltered = _dockKeys(onMachine: nextFilterId)
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
    var specs: [(String, UIKeyModifierFlags, Selector)] = [
      (UIKeyCommand.inputLeftArrow,  .command,           #selector(_macPrevTab)),
      (UIKeyCommand.inputRightArrow, .command,           #selector(_macNextTab)),
      (UIKeyCommand.inputUpArrow,    .command,           #selector(_macPrevMachine)),
      (UIKeyCommand.inputDownArrow,  .command,           #selector(_macNextMachine)),
      ("[",                          [.command, .shift], #selector(_macPrevTab)),   // Cmd+Shift+[ 上一个标签
      ("]",                          [.command, .shift], #selector(_macNextTab)),   // Cmd+Shift+] 下一个标签
      ("r",                          .command,           #selector(reloadCurrentShell)),  // ⌘R 重连当前终端（重 attach tmux）
    ]
    // Cmd+1…9 直接切到机器栏里第 N 台机器（等同点 rail 第 N 个头像）。
    // Blink 默认键位表未绑 Cmd+数字，无冲突；仅 Mac 注入。
    for n in 1...9 {
      specs.append((String(n), .command, #selector(_macSelectMachineByNumber(_:))))
    }
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

  /// Cmd+N：切到机器栏（BlinkMachineStore.machines 顺序）里第 N 台机器，
  /// 等同点 rail 第 N 个头像。sender.input 是按下的数字；机器数不足则静默忽略。
  @objc private func _macSelectMachineByNumber(_ cmd: UIKeyCommand) {
    guard let input = cmd.input, let n = Int(input), n >= 1 else { return }
    let machines = BlinkMachineStore.shared.machines
    guard n <= machines.count else { return }
    _applyTabFilterMachine(machines[n - 1].id)
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
    // .tabNew 已按老板口径停用：坞里全是服务端拉下来的公用标签，客户端不再造标签。
    // 动作枚举与 c/目标态保留（删枚举要动 KB 模块），只是这里什么都不做。
    case .tabNew: break
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
    // 原生对话记录页:秒显本地缓存 → 后台只拉 jsonl 新增行(不开浏览器、不开 scratch 终端)
    guard let term = currentTerm(),
          let p = term.mcpParams,
          let machineId = p.machineId, !machineId.isEmpty,
          let baseName = p.tmuxSession, !baseName.isEmpty else {
      _doDumpTranscript()   // 老式非 tmux tab 兜底走旧链路
      return
    }
    let key = TranscriptStore.key(machineId: machineId, baseName: baseName)
    // 缓存里连一条真对话都没有（早期 jq 失败只存下 WARN+文件头）→ 当没缓存，
    // 强制 FULL 整拉一次自愈；不然增量路径永远"没新行"，坏缓存一直霸屏。
    let cached: TranscriptCache? = {
      guard let c = TranscriptStore.load(key: key) else { return nil }
      let hasDialogue = c.body.contains("▶ You") || c.body.contains("◆ Claude")
      return hasDialogue ? c : nil
    }()
    let label = _transcriptTabLabel(forCurrentTerm: term)
    // Claude 侧头像/名字和 tab 同一逻辑:workDir 配的头像 + 目录名(没配就用会话名)
    let wd = p.workDirId.flatMap { BlinkWorkDirStore.shared.workDir(forId: $0) }
    let wdName = (wd?.name.isEmpty == false ? wd!.name : baseName)
    let vc = TranscriptViewController(text: cached?.body ?? "", pageTitle: label, refreshing: true,
                                      claudeAvatar: wd?.iconImage, claudeName: wdName)
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .fullScreen
    present(nav, animated: true)

    TranscriptFetcher.shared.fetch(machineId: machineId, workDirId: p.workDirId, baseName: baseName,
                                   cachedFile: cached?.file, cachedLines: cached?.lines ?? 0) { [weak vc] result in
      DispatchQueue.main.async {
        guard let vc else { return }
        switch result {
        case .success(let d):
          if d.file == "NOTFOUND" {
            // 没找到 session:提示怎么修,不写缓存
            vc.update(text: cached?.body.isEmpty == false ? (cached!.body + "\n\n" + d.body) : d.body)
            return
          }
          var body: String
          if d.isFull || cached == nil {
            body = d.body
          } else if d.body.isEmpty {
            body = cached!.body
          } else {
            body = cached!.body + "\n\n" + d.body
          }
          body = TranscriptStore.trim(body)
          TranscriptStore.save(key: key, TranscriptCache(file: d.file, lines: d.lines, body: body))
          if d.isFull || !d.body.isEmpty || cached?.body.isEmpty != false {
            vc.update(text: body)
          } else {
            vc.finishRefresh()   // 没新消息:缓存已在屏上,只收掉转圈
          }
        case .failure(let e):
          if cached?.body.isEmpty != false {
            vc.update(text: "[拉取失败] \(e.localizedDescription)")
          } else {
            vc.finishRefresh()
          }
        }
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

  /// 语音条「功能」组的 🌙 pill：切当前 tab 在岗⇄休息（复用 dock 😴 逻辑）
  public func toggleRestCurrentTab() { _toggleRestForCurrentTab() }

  /// 语音条睡眠按钮右侧：为当前标签选择 CLI，并立即在原目录重开远端 pane。
  func presentModelPickerForCurrentTab(anchor: UIView) {
    guard let term = currentTerm(), let params = term.mcpParams,
          let machineId = params.machineId,
          let machine = BlinkMachineStore.shared.machines.first(where: { $0.id == machineId }) else {
      _voiceDock.showToast("当前标签没有可切换的机器", isError: true)
      return
    }
    let title = BlinkMachineStore.ccTitle(
      machine: machine, workDirId: params.workDirId, tmuxSession: params.tmuxSession)
    let current = TabAgentStore.shared.agent(machineId: machineId, title: title)
    let picker = UIAlertController(title: title, message: "切换后在原目录重新启动会话",
                                   preferredStyle: .actionSheet)
    for kind in AgentKind.allCases {
      let action = UIAlertAction(title: kind == current ? "\(kind.label)（当前）" : kind.label,
                                 style: .default) { [weak self] _ in
        guard let self, kind != current else { return }
        TabAgentStore.shared.setAgent(kind, machineId: machineId, title: title)
        Task { [weak self] in
          let result = await TeamStatusViewController.resetPane(
            outerSession: "cc-\(title)", machine: machine)
          await MainActor.run {
            guard let self else { return }
            switch result {
            case "OK":
              term.restartConnection()
              self._voiceDock.showToast("已切到 \(kind.label)，正在原目录重开")
            case "NO_SESSION":
              self._voiceDock.showToast("已切到 \(kind.label)，下次打开生效")
            default:
              self._voiceDock.showToast("模型已保存，重启会话失败；请刷新标签", isError: true)
            }
          }
        }
      }
      if kind == current { action.setValue(true, forKey: "checked") }
      picker.addAction(action)
    }
    picker.addAction(UIAlertAction(title: "取消", style: .cancel))
    picker.popoverPresentationController?.sourceView = anchor
    picker.popoverPresentationController?.sourceRect = anchor.bounds
    present(picker, animated: true)
  }

  /// dock 😴 钮：把当前 tab 标记 / 取消标记「休息」。
  /// 公用标签走 SharedRestStore（服务端权威）：休息的标签从坞里消失，重新在岗再回来
  ///（与团队页月亮开关同一条链）。其它 tab 才走旧的本地标记路径。
  @objc private func _toggleRestForCurrentTab() {
    guard let key = _currentKey else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()

    if _sharedKeys.contains(key),
       let sess = (SessionRegistry.shared[key] as TermController).mcpParams?.tmuxSession {
      let store = SharedRestStore.shared
      store.materializeDefault(from: ServerConfigSync.shared.sharedTabs.map(\.tmuxSession))
      store.setActive(!store.isActive(sess), session: sess)
      _syncSharedTabs()
      _showSelectedDockTabAfterSync()
      _reloadTabBar()
      return
    }

    let nowResting = TabRestStore.shared.toggle(key.uuidString)
    let target = nowResting && _workModeOn ? _nextWorkingKey(excluding: key) : nil
    if let target = target {
      // 切走后 _currentKey.didSet 会自动 _reloadTabBar，原 tab 即被隐藏
      _moveToShell(key: target)
    } else {
      _reloadTabBar()
    }
  }

  /// 标当前 tab 休息后要跳去的下一个「工作中」tab。
  /// 在**坞集合**里找（`_visibleFilteredKeys` 已排除休息的，且只含 tom 的公用标签）：
  /// 优先同机器、当前之后、非休息的；同机器没有再退到其它机器的工作 tab。
  /// 只在坞集合里选，是为了保证跳过去之后当前 tab 仍在坞里高亮得到。
  private func _nextWorkingKey(excluding key: UUID) -> UUID? {
    let dock = _visibleFilteredKeys()
    guard let pos = dock.firstIndex(of: key), dock.count > 1 else { return nil }
    let n = dock.count
    let curMachine = (SessionRegistry.shared[key] as TermController).mcpParams?.machineId
    var sameMachine: UUID? = nil
    var otherMachine: UUID? = nil
    for step in 1..<n {
      let cand = dock[(pos + step) % n]
      if cand == key { continue }
      let m = (SessionRegistry.shared[cand] as TermController).mcpParams?.machineId
      if m == curMachine {
        sameMachine = cand
        break                        // 同机器优先，找到最近的即停
      } else if otherMachine == nil {
        otherMachine = cand
      }
    }
    return sameMachine ?? otherMachine
  }

  /// 让 dock 的 😴 钮反映当前 tab 的休息状态；顶栏（Mac 上是侧栏）🌙 按钮刷新休息人数。
  private func _syncSleepButton() {
    let restingCount = _viewportsKeys.filter { TabRestStore.shared.isResting($0.uuidString) }.count
    _tabBar.setRestingCount(restingCount)
    _macSidebar?.setRestingCount(restingCount)
  }

  fileprivate func _reloadTabBar() {
    var titles: [String] = []
    var icons: [UIImage?] = []
    var agents: [AgentKind?] = []        // 头像右下角的 CLI 角标
    var unread: [Bool] = []
    var tags: [Int] = []
    var sidebarSubs: [String] = []       // Mac 三栏：每行副标题（工作目录路径）
    var sidebarIcons: [UIImage?] = []    // Mac 三栏：32pt 头像（tab 的 22pt 太小）

    // 坞是**一个平铺列表**：只铺服务端 tom 的那几条，不分节、不加徽标、不列自有标签。
    // 集合是只读派生的（`_dockKeySet`），渲染路径不写任何状态。
    let dockSet = _dockKeySet()
    let curIndex = _currentKey.flatMap { _viewportsKeys.firstIndex(of: $0) } ?? -1
    for (idx, key) in _viewportsKeys.enumerated() {
      let term: TermController = SessionRegistry.shared[key]
      // 助手 tab 的标题照旧算出来（HUD 用），但它不占坞里的位置。
      if term.mcpParams?.workDirId == BlinkWorkDirStore.assistantWorkDirId {
        term.meta.tabTitle = "助手"
      }
      // 坞里只铺 tom 的公用标签：自有标签与别位员工的标签都不列。
      guard dockSet.contains(key) else { continue }
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
      titles.append(title)
      // 头像：员工目录（内置像素图）优先 —— 从 tmuxSession「员工-项目」拆员工，
      // 公用标签没有 workDir 图标可退（_syncSharedTabs 建的 terminal workDirId 为
      // nil，chip 会只剩文字）；自有标签再退 workDir 自带图标；都没有给 nil。
      var icon: UIImage? = nil
      if let sess = term.mcpParams?.tmuxSession,
         let emp = SharedTabLayout.employee(ofTmuxSession: sess),
         let img = BlinkPeopleStore.shared.directoryIcon(for: emp) {
        icon = AvatarRenderer.roundedThumbnail(from: img, size: CGSize(width: 26, height: 26))
      }
      if icon == nil, let wid = term.mcpParams?.workDirId,
         let img = BlinkWorkDirStore.shared.workDir(forId: wid)?.iconImage {
        icon = AvatarRenderer.roundedThumbnail(from: img, size: CGSize(width: 26, height: 26))
      }
      icons.append(icon)
      // 这个 tab 配的是哪个 CLI：跟团队页、长按菜单查的是同一份 agents 配置
      if let mid = term.mcpParams?.machineId,
         let m = BlinkMachineStore.shared.machines.first(where: { $0.id == mid }) {
        let t = BlinkMachineStore.ccTitle(machine: m, workDirId: term.mcpParams?.workDirId,
                                          tmuxSession: term.mcpParams?.tmuxSession)
        agents.append(TabAgentStore.shared.agent(machineId: mid, title: t))
      } else {
        agents.append(nil)
      }
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
    _tabBar.reload(titles: titles, icons: icons, unread: unread, tags: tags,
                   currentTag: curIndex, agents: agents)
    _syncSleepButton()

    if _macLayoutEnabled {
      // 三栏与 tab 栏同源刷新：rail 高亮选定的那台机器（只读，不写回）
      _macRail?.reload(currentId: _tabFilterMachineId)
      let machine = _tabFilterMachineId.flatMap { fid in
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
      // 平铺一列：不再有「公用标签 (N) / 我的标签」两个节标题。
      let sectionList = items.isEmpty ? [] : [MacSessionSidebarView.Section(title: nil, items: items)]
      _macSidebar?.reload(machineName: machine?.displayName ?? "（无机器）",
                          transport: machine.map { $0.usesBlinkd ? "Socket" : "SSH" },
                          sections: sectionList)
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
#if targetEnvironment(macCatalyst)
      // Mac 侧仍是经典设置页：Style / Display / Keys & Certificates / Hosts / iCloud Sync
      // 这些只有 Mac 端在用的入口都还在那里（见 2026-10-06 的设置页收窄口径）。
      let navCtrl = UINavigationController()
      navCtrl.navigationBar.prefersLargeTitles = true
      let s = SettingsHostingController.createSettings(nav: navCtrl, onDismiss: {
        [weak self] in self?.focusOnShellAction()
      })
      navCtrl.setViewControllers([s], animated: false)
      self.present(navCtrl, animated: true, completion: nil)
#else
      self.presentSettings()
#endif
    }
  }

  /// 全 App 唯一的设置页（iPhone/iPad）。⌘, / ⋯ 菜单「Show Config」/ shell 的 `config`
  /// 命令 / 语音坞齿轮都走这里。
  public func presentSettings() {
    let vc = BlinkSettingsViewController(voiceView: voiceDock)
    vc.onClose = { [weak self] in self?.focusOnShellAction() }
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    present(nav, animated: true)
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
  
  /// 左/右翻页走到某台机器坞集合的尽头时，跨到**指定机器**的端点 tab。判据与坞完全一致
  /// （`_dockKeySet` 的机器维度换成入参），免得切过去落到一台在 tom 名下没有标签的机器上。
  private func _dockKeys(onMachine machineId: String) -> [UUID] {
    _viewportsKeys.filter { key in
      guard _sharedKeys.contains(key) else { return false }
      let p = (SessionRegistry.shared[key] as TermController).mcpParams
      guard p?.machineId == machineId,
            SharedTabLayout.isDockTab(tmuxSession: p?.tmuxSession) else { return false }
      return !(_workModeOn && TabRestStore.shared.isResting(key.uuidString))
    }
  }

  /// 左右滑动的集合 = 坞里看得见的那几条（`_dockKeySet()`：服务端 tom 的公用标签，
  /// Mac rail 选定的机器再从里面收窄）。自有标签**不在滑动集合里** —— 老板口径
  /// 「不显示、不保留退路」的第二道闸：即便有恢复路径把它们拉回 `_viewportsKeys`，
  /// 也滑不到、看不到。
  private func _filteredViewportsKeys() -> [UUID] {
    let dockSet = _dockKeySet()
    return _viewportsKeys.filter { key in
      // 当前这条永远留着 —— 兜底，别让翻页时脚下的地突然没了
      if key == _currentKey { return true }
      return dockSet.contains(key)
    }
  }

  /// 机器过滤后再排除「只显示工作中」隐藏（休息）的 tab；`current` 永远保留（哪怕它被标了休息），
  /// 这样左右滑动翻页遍历的集合与 tab 栏显示的一致。
  private func _visibleFilteredKeys() -> [UUID] {
    // 休息已由 SharedRestStore 统一管（_syncSharedTabs/_dockKeySet 层面过滤，服务端
    // 权威）。这里不再叠旧的 TabRestStore（本地 UUID 休息标记）过滤 —— 旧面板时代的
    // 残留标记会污染翻页集合，造成「chip 看得见、滑动却跳过」（2026-10-06 老板实测
    // tom-ben 被跳过：坞渲染不读旧 store，翻页集合读，两边不一致）。
    _filteredViewportsKeys()
  }

  private func _advanceShell(by: Int, animated: Bool = true) {
    let filtered = _visibleFilteredKeys()   // 键盘上/下切 tab 也跳过休息的
    guard let currentKey = _currentKey else { return }
    if let pos = filtered.firstIndex(of: currentKey)?.advanced(by: by),
       filtered.indices.contains(pos),
       let idx = _viewportsKeys.firstIndex(of: filtered[pos]) {
      _moveToShell(idx: idx, animated: animated)
      return
    }
    // 当前 filter 内走到尽头：切到下一台机器（仅当 rail 选了机器、且有 >=2 台机器有坞内标签）
    guard let curFilter = _tabFilterMachineId else { return }
    let machineIds = _machineIdsWithTabs()
    guard machineIds.count > 1,
          let curMachinePos = machineIds.firstIndex(of: curFilter) else { return }
    let nextMachinePos = (curMachinePos + (by > 0 ? 1 : -1) + machineIds.count) % machineIds.count
    let newFilterId = machineIds[nextMachinePos]
    _tabFilterMachineId = newFilterId
    // 目标键必须排除「刚离开的那条」，否则会原地不动（它作为当前 tab 永远在集合里）
    let newFiltered = _dockKeys(onMachine: newFilterId)
    guard let targetKey = (by > 0 ? newFiltered.first : newFiltered.last),
          let idx = _viewportsKeys.firstIndex(of: targetKey) else { return }
    _moveToShell(idx: idx, animated: animated)
    _reloadTabBar()
  }

  private func _sortTabsByMachineAndDir() {
    let machineOrder = Dictionary(uniqueKeysWithValues:
      BlinkMachineStore.shared.machines.enumerated().map { ($0.element.id, $0.offset) })
    // 助手 workDir 永远排在每个机器组的最前面
    let assistantWdId = BlinkWorkDirStore.assistantWorkDirId

    // 同一台机器内跟 macOS 版侧栏一致：按 cc 标题（员工-项目）的 (项目, 员工) 排序。
    // owner = 第一个 "-" 之前，project = 之后（jack-talkai → jack / talkai），同 mac Session.owner/project。
    let machinesById = Dictionary(uniqueKeysWithValues: BlinkMachineStore.shared.machines.map { ($0.id, $0) })
    func projectOwner(_ p: MCPParams?) -> (String, String) {
      guard let p, let mid = p.machineId, let m = machinesById[mid] else { return ("", "") }
      let name = BlinkMachineStore.ccTitle(machine: m, workDirId: p.workDirId, tmuxSession: p.tmuxSession)
      let parts = name.split(separator: "-", maxSplits: 1)
      let owner = parts.first.map(String.init) ?? name
      let project = parts.count > 1 ? String(parts[1]) : name
      return (project, owner)
    }

    let indexed = _viewportsKeys.enumerated().map { (offset: $0.offset, key: $0.element) }
    let sorted = indexed.sorted { a, b in
      // 公用标签永远排在自有标签前面，内部按名字排（tmuxSession 字母序：
      // adam-blink < candy-blink < jack-ben < tom-ben…，老板口径 2026-10-06），
      // 大小写不敏感；同名再按原顺序保持稳定。
      let sharedA = _sharedKeys.contains(a.key)
      let sharedB = _sharedKeys.contains(b.key)
      if sharedA != sharedB { return sharedA }
      if sharedA && sharedB {
        let sa = (SessionRegistry.shared[a.key] as TermController).mcpParams?.tmuxSession ?? ""
        let sb = (SessionRegistry.shared[b.key] as TermController).mcpParams?.tmuxSession ?? ""
        if sa != sb { return sa.localizedCaseInsensitiveCompare(sb) == .orderedAscending }
        return a.offset < b.offset
      }
      let ta: TermController = SessionRegistry.shared[a.key]
      let tb: TermController = SessionRegistry.shared[b.key]
      let mka = ta.mcpParams?.machineId.flatMap { machineOrder[$0] } ?? Int.max
      let mkb = tb.mcpParams?.machineId.flatMap { machineOrder[$0] } ?? Int.max
      if mka != mkb { return mka < mkb }
      let assistA = ta.mcpParams?.workDirId == assistantWdId
      let assistB = tb.mcpParams?.workDirId == assistantWdId
      if assistA != assistB { return assistA }   // 助手 tab 仍钉在每台机器最前
      let poa = projectOwner(ta.mcpParams)
      let pob = projectOwner(tb.mcpParams)
      if poa != pob { return poa < pob }
      return a.offset < b.offset  // 完全同名时保持原序
    }.map { $0.key }
    if sorted == _viewportsKeys { return }
    _viewportsKeys = sorted
  }

  /// 「坞里有标签的机器」按**坞集合**算：跨机器跳转只落在真有 tom 标签的机器上，
  /// 否则会跳到一台坞里空着的机器（用户以为坏了）。
  private func _machineIdsWithTabs() -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for key in _filteredViewportsKeys() {
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

  /// 切到上/下一台「有 tab 的机器」并过滤显示它（复用 _applyTabFilterMachine，含掉线自动重连）。
  /// 无机器 filter 时以当前 tab 所属机器为起点；少于 2 台有 tab 的机器时无操作。
  private func _advanceMachine(by: Int) {
    let machineIds = _machineIdsWithTabs()
    guard machineIds.count > 1 else { return }
    let curMid: String? = _tabFilterMachineId ?? _currentKey.flatMap {
      (SessionRegistry.shared[$0] as TermController).mcpParams?.machineId
    }
    let curPos = curMid.flatMap { machineIds.firstIndex(of: $0) } ?? 0
    let nextPos = (curPos + by + machineIds.count) % machineIds.count
    _applyTabFilterMachine(machineIds[nextPos])
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
    // TODO(teamfix): 临时诊断日志（黑屏 tab 排查），定位完删
    Self.teamDebugLog("select: sess=\(term.mcpParams?.tmuxSession ?? "-") suspended=\(term.meta.isSuspended) payload=\(term.mcpParams != nil) viewLoaded=\(term.isViewLoaded)")
    term.delegate = self
    term.bgColor = view.backgroundColor ?? .black
    let curIdx = _currentKey.flatMap { _viewportsKeys.firstIndex(of: $0) } ?? 0
    let direction: UIPageViewController.NavigationDirection = (index >= curIdx) ? .forward : .reverse
    _viewportsController.setViewControllers([term], direction: direction, animated: true) { [weak self] _ in
      // 与滑动翻页（didFinishAnimating）完全同序：先踢启动，再设 currentKey。
      term.resumeIfNeeded()
      self?._currentKey = key
      self?._attachInputToCurrentTerm()
    }
  }

  // 「新建标签」入口（原来弹 NewTabViewController 让你挑机器/目录/会话）已按老板口径删除：
  // ⋯ 菜单那一项、Mac 侧栏「＋ 新会话」、⌘T 都没有了。`_newShellAction` 本身还留着 ——
  // Siri intent、`terminalHangup` 这些内部路径仍用它（不走用户入口）。

  public func tabBarDidRequestSettings() {
    // 齿轮和 ⌘, / ⋯ 菜单 / `config` 命令进的是同一个设置页：传真实 voiceDock，
    // 「识别语言」才不会永远显示「—」（此前这里传的是 nil）。
    presentSettings()
  }

  /// TODO(teamfix): 临时诊断日志（写 Documents/teamdebug.log，真机可拉容器），定位完删
  static func teamDebugLog(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"
    let line = "[\(f.string(from: Date()))] \(s)\n"
    guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = dir.appendingPathComponent("teamdebug.log")
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
    NSLog("[teamfix] \(s)")
  }

  public func tabBarDidRequestTeamStatus() {
    // 团队页全量吃远程数据：服务端注入的公用标签（ServerConfigSync.sharedTabs，登录即有，
    // 员工×项目 全覆盖），不再看本地开了哪些 tab —— 本地 viewport 只代表「我开着谁」，
    // 不是团队。员工/项目从 tmuxSession「员工-项目」拆：员工取首个 `-` 前、项目取末个
    // `-` 后（与 #49 筛选器同口径；员工 ID 带 `-` 时归到前段，够用）。
    var items: [TeamStatusTab] = []
    for tab in ServerConfigSync.shared.sharedTabs {
      guard let m = BlinkMachineStore.shared.machines.first(where: { $0.id == tab.machineId }) else { continue }
      let s = tab.tmuxSession
      let employee = s.firstIndex(of: "-").map { String(s[s.startIndex..<$0]) } ?? s
      let project = s.lastIndex(of: "-").map { String(s[s.index(after: $0)...]) } ?? s
      items.append(TeamStatusTab(
        tabKey: tab.id, machineId: tab.machineId, machineName: m.displayName,
        employee: employee, project: project,
        outerSession: "cc-\(s)", avatar: nil,
        resting: !SharedRestStore.shared.isActive(s)))
    }
    let vc = TeamStatusViewController(tabs: items)
    // 休息开关 = 服务端真数据：写 SharedRestStore（随个人配置队列 PUT recentSelection 的
    // restSessions 键），在岗的标签才进坞 —— 关掉的人即刻从坞里消失，开的人即刻出现。
    // 首次切换前先把「默认只有 tom 在岗」物化成显式集合，默认规则到此让位。
    vc.onToggleRest = { [weak self] key, resting in
      let store = SharedRestStore.shared
      store.materializeDefault(from: ServerConfigSync.shared.sharedTabs.map(\.tmuxSession))
      if let s = ServerConfigSync.shared.sharedTabs.first(where: { $0.id == key })?.tmuxSession {
        store.setActive(!resting, session: s)
        // TODO(teamfix): 临时诊断日志，定位完删
        Self.teamDebugLog("toggle: sess=\(s) toResting=\(resting) loaded=\(store.loaded) joined=\(store.joinedActive) dockSet=\(self?._dockKeySet().count ?? -1)")
        // 必须重跑 sync（重画不够：_viewportsKeys/_sharedKeys 只有它更新），当前页若
        // 落在刚被休息掉的标签上，还要挪回第一个在岗的。
        self?._syncSharedTabs()
        self?._showSelectedDockTabAfterSync()
        self?._reloadTabBar()
      }
    }
    // 切 CLI 的收尾：团队页已重建远端 pane（保会话保目录），这里让对应
    // tab 强制断开重连 —— 重连命令重新生成（新 CLI 启动脚本），attach 回活会话后
    // heal 自愈起新 CLI。用非创建式查询：休息中不在坞里的标签没有 term，跳过
    //（远端进程已杀，下次打开时 heal 自然用新配置起）。
    vc.onRestartSession = { key in
      let term: TermController? = SessionRegistry.shared.sessionFromIndexWith(key: key)
      term?.restartConnection()
    }
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

  /// （助手暂时下线）把启动恢复/云同步带回来的助手终端 tab 从 UI 移除。
  /// 只动本机 UI 和持久化列表，远端 blink-assistant tmux session 不杀，恢复入口时还能接上。
  /// 要恢复助手：把 viewDidLoad / _cloudConfigDidRestore 里的本调用换回 _ensureAssistantTabFirst()。
  fileprivate func _hideAssistantTabs() {
    let session = BlinkWorkDirStore.assistantTmuxSession
    let wdId = BlinkWorkDirStore.assistantWorkDirId
    let victims = Set(_viewportsKeys.filter { key in
      let p = (SessionRegistry.shared[key] as TermController).mcpParams
      return p?.tmuxSession == session || p?.workDirId == wdId
    })
    guard !victims.isEmpty else { return }
    _removeKeys(victims)
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
      // 「最前」= 自有标签的最前（公用标签恒在最前，不能被顶到后面去）
      let head = _firstOwnIndex
      if curIdx != head {
        let key = _viewportsKeys.remove(at: curIdx)
        _viewportsKeys.insert(key, at: min(head, _viewportsKeys.count))
      }
      if switchTo { tabBarDidSelect(index: head) }
      return
    }

    // 不存在 → 创建并放到自有标签的最前
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
    _viewportsKeys.insert(term.meta.key, at: min(_firstOwnIndex, _viewportsKeys.count))
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
    // 公用标签不给关闭入口（tab 栏/侧栏本来也不显示 ✕，这里是兜底）
    guard !_sharedKeys.contains(key) else { return }
    if key != _currentKey {
      let term: TermController = SessionRegistry.shared[key]
      term.delegate = self
      term.bgColor = view.backgroundColor ?? .black
      _viewportsController.setViewControllers([term], direction: .forward, animated: false)
      _currentKey = key
    }
    closeShellAction()
  }

  /// 长按标签弹的菜单：休息/唤醒 · 打开时进哪个 CLI · 关闭标签。
  /// 换 CLI 会把远端那个 tmux 会话 kill 掉，重连时按新配置重跑启动脚本，不用手动退出。
  public func tabBarDidRequestTabMenu(index: Int, anchor: UIView) {
    guard _viewportsKeys.indices.contains(index) else { return }
    let key = _viewportsKeys[index]
    // 公用标签不弹菜单：菜单里的休息/换 CLI/关闭都按「这个标签是我的」记账
    //（写 TabRestStore / TabAgentStore 并按 uuid 回传），公用标签一条都不适用。
    guard !_sharedKeys.contains(key) else { return }
    let term: TermController = SessionRegistry.shared[key]
    let p = term.mcpParams
    let machine = p?.machineId.flatMap { id in BlinkMachineStore.shared.machines.first { $0.id == id } }
    let title = machine.map {
      BlinkMachineStore.ccTitle(machine: $0, workDirId: p?.workDirId, tmuxSession: p?.tmuxSession)
    }
    let name = title ?? "这个标签"

    let ac = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)
    let resting = TabRestStore.shared.isResting(key.uuidString)
    ac.addAction(UIAlertAction(title: resting ? "唤醒（在岗）" : "让 TA 休息", style: .default) { _ in
      TabRestStore.shared.setResting(!resting, key: key.uuidString)
      NotificationCenter.default.post(name: NSNotification.Name("BlinkTabRestChanged"), object: nil)
    })
    if let m = machine, let t = title {
      let cur = TabAgentStore.shared.agent(machineId: m.id, title: t)
      for k in AgentKind.allCases where k != cur {
        ac.addAction(UIAlertAction(title: "打开时进 \(k.label)", style: .default) { [weak self] _ in
          TabAgentStore.shared.setAgent(k, machineId: m.id, title: t)
          self?._restartTabWithNewAgent(outerSession: "cc-\(t)", machine: m, label: k.label)
        })
      }
    }
    ac.addAction(UIAlertAction(title: "关闭标签", style: .destructive) { [weak self] _ in
      self?.tabBarDidRequestClose(index: index)
    })
    ac.addAction(UIAlertAction(title: "取消", style: .cancel))
    ac.popoverPresentationController?.sourceView = anchor
    ac.popoverPresentationController?.sourceRect = anchor.bounds
    present(ac, animated: true)
  }

  /// 把远端 tmux 会话杀掉 —— `tmux new-session -A` 碰到已存在的会话只会 attach，
  /// 里面跑的还是旧 CLI；杀掉后自动重连会重跑启动脚本，新 CLI 就起来了。
  private func _restartTabWithNewAgent(outerSession: String, machine: BlinkMachine, label: String) {
    let script = """
    export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
    tmux kill-session -t \(outerSession) 2>/dev/null
    echo done
    """
    if let cfg = machine.blinkdConfig {
      BlinkdExecOnce.run(host: cfg.host, port: cfg.port, token: cfg.token, script: script) { _ in }
    } else {
      Task { _ = try? await BlinkAssistantBackend.shared.execRemote(script: script, machine: machine) }
    }
    let hud = UIAlertController(title: nil, message: "已切到 \(label)，会话正在用它重开", preferredStyle: .alert)
    present(hud, animated: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { hud.dismiss(animated: true) }
  }

  public func tabBarDidRequestRestPanel() {
    // 旧的「员工在岗/休息」列表已并入团队状态页（每行行尾就是月亮开关），入口统一开新页。
    tabBarDidRequestTeamStatus()
  }

  // 「筛选 · tom @ brain」两级 sheet、「我的标签 (N)」尾入口已按老板口径**整段删除**：
  // 坞就是服务端 tom 那几条，没有筛选器、没有自有标签入口、不分节不加徽标。
  // 协议方法 tabBarDidRequestTabFilter / tabBarDidRequestOwnTabs 与 ⋯ 菜单里对应两项一并去掉。

  /// 只换机器维度（Mac rail / 跨机器翻页 / ⌘数字 用）。
  /// 手机上没人调用它，`_tabFilterMachineId` 恒为 nil → 坞就是 tom 的全部标签。
  func _applyTabFilterMachine(_ machineId: String?) {
    // 先记住「离开的这台机器」当前停在哪个 tab
    if let curKey = _currentKey,
       let curMid = (SessionRegistry.shared[curKey] as TermController).mcpParams?.machineId {
      _lastKeyPerMachine[curMid] = curKey
    }
    _tabFilterMachineId = machineId
    let filtered = _filteredViewportsKeys()

    // 注意：这里**没有**「筛出来是空的就顺手开一个终端」的退路 —— 老板口径
    // 「不保留退路」，坞里没有 tom 的标签时就是空坞空屏（`_reloadTabBar` 会照实渲染）。

    // 选定目标 tab：上次选中的 > 当前若已在坞集合内 > 第一条
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

    // 切过去后，如果那个 tab 已经掉线（停在 blink> / 后台没连上）就重连
    if let t = target {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        (SessionRegistry.shared[t] as TermController).reconnectIfDisconnected()
      }
    }
  }

  // 机器长按换头像（同「选择头像」的 Alohe Memoji 选择器）。手机上原来从浮动机器条进，
  // 那条已移除 → 现在只有 Mac rail 能到这个入口。
  func _editMachineAvatar(_ machineId: String) {
    let picker = AvatarPickerViewController()
    picker.onPick = { [weak self] data in
      BlinkMachineStore.shared.setAvatar(data, forId: machineId)
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
// 数据流全部复用现有机制 —— rail 点击 = _applyTabFilterMachine（含记忆各机器上次
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

    // 幂等：viewDidLoad 若二次执行（Mac 场景重连 / 视图重建等）会重复 new 三份视图并
    // addSubview，而 _macRail/_macSidebar/_macStatusBar 只指向最新的，旧的三份留在 view
    // 上没人排版 → 两套侧栏重叠、出现两个「＋ 新会话」。建新之前先移除旧的，保证只有一套。
    _macRail?.removeFromSuperview()
    _macSidebar?.removeFromSuperview()
    _macStatusBar?.removeFromSuperview()

    let rail = MacMachineRailView()
    rail.onSelectMachine = { [weak self] id in self?._applyTabFilterMachine(id) }
    rail.onEditAvatar = { [weak self] id in self?._editMachineAvatar(id) }
    rail.onOpenAssistantChat = { [weak self] in self?.tabBarDidRequestAssistantChat() }
    rail.onOpenSettings = { [weak self] in self?.tabBarDidRequestSettings() }
    view.addSubview(rail)
    _macRail = rail

    let sidebar = MacSessionSidebarView()
    // 不走 tabBarDidSelect：它切页后不重挂输入（手机靠手指点终端恢复焦点，Mac 没这一步，
    // 键盘会直接失灵）。_moveToShell 完成后自带 _attachInputToCurrentTerm。
    sidebar.onSelect = { [weak self] tag in self?._moveToShell(idx: tag) }
    // 侧栏的「＋ 新会话」与「我的标签」入口已按老板口径移除（坞/侧栏是纯只读的服务端列表）
    // Mac 顶栏是隐藏的，🌙 面板只能从侧栏进；没它的话 dock 😴 标的休息 tab 改不回在岗。
    sidebar.onRestPanel = { [weak self] in self?.tabBarDidRequestRestPanel() }
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
  private var bodyText: String
  private let pageTitle: String
  private var refreshing: Bool
  private var claudeAvatarURI = ""
  private var userAvatarURI = ""
  private var claudeName = ""
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var didFinishInitialLoad = false

  init(text: String, pageTitle: String = "对话记录", refreshing: Bool = false,
       claudeAvatar: UIImage? = nil, claudeName: String = "") {
    self.bodyText = text
    self.pageTitle = pageTitle
    self.refreshing = refreshing
    self.claudeAvatarURI = Self.avatarDataURI(claudeAvatar)
    self.claudeName = claudeName
    let config = WKWebViewConfiguration()
    config.userContentController = WKUserContentController()
    // 允许 <video> 内联播放（否则 mp4 在 iPhone 上不显示）
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    self.webView = WKWebView(frame: .zero, configuration: config)
    super.init(nibName: nil, bundle: nil)
    webView.configuration.userContentController.add(self, name: "copy")
    webView.configuration.userContentController.add(self, name: "fetchImage")
  }

  convenience init(text: String) {
    self.init(text: text, pageTitle: "对话记录", refreshing: false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  func userContentController(_ ctrl: WKUserContentController, didReceive msg: WKScriptMessage) {
    if msg.name == "copy", let text = msg.body as? String {
      UIPasteboard.general.string = text
      return
    }
    if msg.name == "fetchImage", let d = msg.body as? [String: Any],
       let url = d["url"] as? String, let id = d["id"] as? String {
      fetchImage(url: url, id: id)
    }
  }

  /// 页内 <img> 加载失败(多半是门禁 401——WebView 的挑战回调对子资源不生效)时,
  /// 原生带 Basic 账密把图抓回来,以 data URI 塞回去,让门禁内的截图也能直接显示。
  private func fetchImage(url: String, id: String) {
    guard let u = URL(string: url) else { return }
    var req = URLRequest(url: u, timeoutInterval: 20)
    if let cred = Self.basicAuth(forHost: u.host ?? "") {
      let token = Data("\(cred.0):\(cred.1)".utf8).base64EncodedString()
      req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
    URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      let mime = (resp as? HTTPURLResponse)?.mimeType ?? "image/png"
      // 6MB 上限：整页长图也够用，再大塞 data URI 会把 WebView 拖垮
      guard let data, code == 200, data.count < 6_000_000 else {
        DispatchQueue.main.async { self?.evalImage(id: id, dataURI: "") }
        return
      }
      let uri = "data:\(mime);base64,\(data.base64EncodedString())"
      DispatchQueue.main.async { self?.evalImage(id: id, dataURI: uri) }
    }.resume()
  }

  private func evalImage(id: String, dataURI: String) {
    let js = dataURI.isEmpty ? "imgGiveUp('\(id)')" : "imgReady('\(id)','\(dataURI)')"
    webView.evaluateJavaScript(js, completionHandler: nil)
  }

  /// 该 host 的 Basic 账密：钉住的浏览器 tab 里存的优先，prototype 原型站有内置兜底。
  static func basicAuth(forHost host: String) -> (String, String)? {
    for t in PinnedTabsStore.shared.tabs {
      guard let user = t.authUser, !user.isEmpty,
            let pwd = t.authPassword, !pwd.isEmpty,
            let u = URL(string: t.url), u.host == host else { continue }
      return (user, pwd)
    }
    if host == "prototype.douwantech.com" { return ("binku87", "binku87works") }
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // 卡片流(方案 D):浅灰底,和页面 HTML 同底色
    let termBg = UIColor(red: 0xf4/255.0, green: 0xf5/255.0, blue: 0xf7/255.0, alpha: 1)
    overrideUserInterfaceStyle = .light
    view.backgroundColor = termBg
    // navbar 只显示名字;右侧无按钮(转圈除外);左侧系统返回箭头
    title = claudeName.isEmpty ? pageTitle : claudeName
    let navAp = UINavigationBarAppearance()
    navAp.configureWithOpaqueBackground()
    navAp.backgroundColor = termBg
    navAp.shadowColor = UIColor(red: 0xe2/255.0, green: 0xe4/255.0, blue: 0xe8/255.0, alpha: 1)
    navigationItem.standardAppearance = navAp
    navigationItem.scrollEdgeAppearance = navAp
    let back = UIBarButtonItem(
      image: UIImage(systemName: "chevron.backward",
                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
      style: .plain, target: self, action: #selector(closeTapped))
    navigationItem.leftBarButtonItem = back
    // 右侧不放任何 barButtonItem(iOS 26 会给 item 画胶囊底);转圈浮在内容右上角
    spinner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
      spinner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    ])
    if refreshing { spinner.startAnimating() }

    webView.isOpaque = false
    webView.backgroundColor = termBg
    webView.scrollView.backgroundColor = termBg
    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    view.bringSubviewToFront(spinner)

    // 底部悬浮返回按钮:长记录翻到底不用回顶部关页
    var backCfg = UIButton.Configuration.filled()
    backCfg.image = UIImage(systemName: "chevron.backward",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    backCfg.title = "返回"
    backCfg.imagePadding = 5
    backCfg.baseBackgroundColor = .white
    backCfg.baseForegroundColor = UIColor(red: 0x1a/255.0, green: 0x73/255.0, blue: 0xe8/255.0, alpha: 1)
    backCfg.cornerStyle = .capsule
    backCfg.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)
    let bottomBack = UIButton(configuration: backCfg)
    bottomBack.layer.shadowColor = UIColor.black.cgColor
    bottomBack.layer.shadowOpacity = 0.14
    bottomBack.layer.shadowRadius = 10
    bottomBack.layer.shadowOffset = CGSize(width: 0, height: 3)
    bottomBack.layer.borderWidth = 1
    bottomBack.layer.borderColor = UIColor(red: 0xe2/255.0, green: 0xe4/255.0, blue: 0xe8/255.0, alpha: 1).cgColor
    bottomBack.layer.cornerRadius = 19
    bottomBack.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    bottomBack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(bottomBack)
    NSLayoutConstraint.activate([
      bottomBack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      bottomBack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])

    renderCurrent()
  }

  private static func avatarDataURI(_ img: UIImage?) -> String {
    guard let img else { return "" }
    let side: CGFloat = 60
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
    let scaled = renderer.image { _ in
      img.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    guard let data = scaled.pngData() else { return "" }
    return "data:image/png;base64,\(data.base64EncodedString())"
  }

  private func renderCurrent() {
    let initial = bodyText.isEmpty && refreshing ? "⏳ 正在拉取最新对话…" : bodyText
    webView.loadHTMLString(Self.htmlFor(transcript: initial,
                                        claudeAvatar: claudeAvatarURI,
                                        userAvatar: userAvatarURI,
                                        claudeName: claudeName), baseURL: nil)
  }

  /// 增量拉回来后整页换内容(HTML 自带滚到底逻辑)
  func update(text: String) {
    bodyText = text
    finishRefresh()
    renderCurrent()
  }

  /// 没新内容/失败但缓存已在屏上:只收掉转圈
  func finishRefresh() {
    refreshing = false
    spinner.stopAnimating()
  }

  /// avatar 参数是 data:image/png;base64,… URI;空串走 emoji 兜底。claudeName 空串显示 CLAUDE
  static func htmlFor(transcript: String, claudeAvatar: String = "", userAvatar: String = "",
                      claudeName: String = "") -> String {
    let payloadB64 = Data(transcript.utf8).base64EncodedString()
    let claudeAvatarJS = claudeAvatar
    let userAvatarJS = userAvatar
    let claudeNameJS = claudeName.filter { $0 != "\"" && $0 != "\\" && $0 != "<" && $0 != ">" }
    return #"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>
    /* Claude 卡片流(方案 D):浅灰底,Claude 回复通栏白卡片,user 右侧蓝胶囊 */
    body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
           padding: 14px 14px 40px; line-height: 1.6; color: #1a1d21; background: #f4f5f7;
           font-size: 14px; word-wrap: break-word; }
    h1, h2, h3 { font-weight: 600; margin: 1em 0 0.5em; color: #1a1d21; }
    h1 { font-size: 1.3em; } h2 { font-size: 1.18em; } h3 { font-size: 1.08em; }
    .msg-block { margin: 14px 0; display: flex; gap: 8px; align-items: flex-start; }
    .ava { width: 30px; height: 30px; border-radius: 50%; flex: 0 0 auto;
           display: flex; align-items: center; justify-content: center; margin-top: 2px;
           -webkit-user-select: none; user-select: none; }
    .ava-claude { background: linear-gradient(135deg, #3fdc97, #2ea9e8); color: #fff;
                  font-size: 14px; font-weight: 700; }
    .ava-user { background: #4a5568; color: #fff; font-size: 12px; font-weight: 600; }
    .ava.has-img { background: #e2e4e8; overflow: hidden; }
    .ava-img { width: 100%; height: 100%; border-radius: 50%; object-fit: cover; display: block; }
    .mb-claude .card { flex: 1 1 auto; min-width: 0; background: #fff; border: 1px solid #e2e4e8;
                       border-radius: 5px 14px 14px 14px; overflow: hidden;
                       box-shadow: 0 1px 3px rgba(20,30,40,0.05); }
    .mb-claude .msg-head { padding: 7px 14px; background: #fafbfc; border-bottom: 1px solid #eef0f3;
                           margin: 0; }
    .mb-claude .msg-body { padding: 10px 14px 12px; }
    .msg-block.mb-user { flex-direction: row-reverse; }
    .mb-user .card { max-width: 84%; background: #dce8ff; color: #1a3a6b;
                     border-radius: 16px 5px 16px 16px; padding: 8px 13px; }
    .mb-user .card .msg-body { margin: 0; }
    .mb-user .msg-body p:first-child { margin-top: 0; }
    .mb-user .msg-body p:last-child { margin-bottom: 0; }
    .mb-claude .msg-body > p:first-child { margin-top: 0; }
    .msg-head { display: flex; align-items: center; justify-content: space-between; }
    .role { font-weight: 600; font-size: 11px; letter-spacing: 0.1em; }
    .role-user { color: #1a73e8; }
    .role-claude { color: #7a828c; }
    .copy-btn { font: 12px -apple-system, sans-serif; color: #1a73e8; background: transparent;
                border: 1px solid #c8d7f5; border-radius: 6px; padding: 3px 10px; cursor: pointer;
                -webkit-tap-highlight-color: transparent; }
    .copy-btn:active { background: rgba(26,115,232,0.1); }
    .copy-btn.copied { color: #1e9e63; border-color: #b4e3cd; }
    .head-btns { display: flex; gap: 6px; flex: 0 0 auto; }
    .sel-btn { font: 12px -apple-system, sans-serif; color: #7a828c; background: transparent;
               border: 1px solid #d9dde3; border-radius: 6px; padding: 3px 10px; cursor: pointer;
               -webkit-tap-highlight-color: transparent; }
    .sel-btn:active { background: rgba(122,130,140,0.12); }
    /* 选择复制整页 */
    #selpage { position: fixed; inset: 0; background: #f4f5f7; z-index: 10000;
               display: none; flex-direction: column; }
    #selpage.show { display: flex; }
    .sel-top { display: flex; align-items: center; gap: 8px; background: #fff; flex: 0 0 auto;
               padding: max(12px, env(safe-area-inset-top)) 14px 10px; border-bottom: 1px solid #e2e4e8; }
    .sel-title { font-weight: 600; font-size: 16px; flex: 1 1 auto; color: #1a1d21; }
    .sel-top button { font: 14px -apple-system, sans-serif; color: #1a73e8; background: transparent;
                      border: none; padding: 6px 4px; cursor: pointer; -webkit-tap-highlight-color: transparent; }
    .sel-list { flex: 1 1 auto; overflow-y: auto; -webkit-overflow-scrolling: touch; padding: 10px 12px 12px; }
    .sel-card { position: relative; border: 1.5px solid #e2e4e8; border-radius: 12px; background: #fff;
                margin: 8px 0; padding: 12px 12px 12px 42px; cursor: pointer; overflow-x: auto; }
    .sel-card.on { border-color: #1a73e8; background: rgba(26,115,232,0.05); }
    .sel-card .chk { position: absolute; left: 12px; top: 12px; width: 20px; height: 20px;
                     border-radius: 11px; border: 1.5px solid #c8ccd2; box-sizing: border-box; }
    .sel-card.on .chk { background: #1a73e8; border-color: #1a73e8; }
    .sel-card.on .chk::after { content: '✓'; color: #fff; font-size: 13px; line-height: 20px;
                               display: block; text-align: center; }
    .sel-card > .msg-body, .sel-card > p:first-of-type, .sel-card > pre:first-child { margin-top: 0; }
    .sel-bottom { flex: 0 0 auto; background: #fff; border-top: 1px solid #e2e4e8;
                  padding: 10px 14px max(12px, env(safe-area-inset-bottom)); }
    .sel-copy { width: 100%; font: 600 16px -apple-system, sans-serif; color: #fff; background: #1a73e8;
                border: none; border-radius: 12px; padding: 12px; cursor: pointer;
                -webkit-tap-highlight-color: transparent; }
    .sel-copy:disabled { background: #c8ccd2; }
    .sel-toast { position: fixed; left: 50%; bottom: 92px; transform: translateX(-50%);
                 background: rgba(0,0,0,0.82); color: #fff; padding: 8px 16px; border-radius: 18px;
                 font-size: 14px; opacity: 0; transition: opacity 0.2s; z-index: 10001; pointer-events: none; }
    .sel-toast.show { opacity: 1; }
    .msg-body { margin-bottom: 0; }
    .meta { color: #9aa1aa; font-size: 11px; font-family: ui-monospace, Menlo, monospace;
            margin: 10px 2px; }
    pre { background: #14181d; color: #c9d4de; padding: 12px; border-radius: 10px; overflow-x: auto;
          font-family: ui-monospace, Menlo, monospace; font-size: 12px; line-height: 1.45;
          margin: 0.6em 0; }
    code { background: #eef0f3; padding: 2px 5px; border-radius: 4px;
           font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; color: #1a1d21; }
    pre code { background: none; padding: 0; color: #7ee2ad; }
    .code-wrap { position: relative; }
    .code-wrap pre { cursor: pointer; padding-top: 30px; }
    .code-copy { position: absolute; top: 6px; right: 8px; font-size: 11px; color: #8b98a5;
                 background: rgba(139,152,165,0.18); padding: 2px 8px; border-radius: 6px;
                 pointer-events: none; z-index: 2; }
    .code-wrap.copied .code-copy { color: #3fdc97; background: rgba(63,220,151,0.2); }
    table { border-collapse: collapse; margin: 0.8em 0; display: block; overflow-x: auto;
            font-size: 0.92em; }
    th, td { border: 1px solid #e2e4e8; padding: 6px 10px; text-align: left; }
    th { background: #fafbfc; font-weight: 600; }
    ul, ol { padding-left: 1.5em; margin: 0.5em 0; }
    li { margin: 0.2em 0; }
    a { color: #1a73e8; text-decoration: none; }
    blockquote { border-left: 3px solid #e2e4e8; padding-left: 12px; margin: 0.6em 0;
                 color: #5f6670; }
    hr { border: none; border-top: 1px solid #e2e4e8; margin: 1.5em 0; }
    p { margin: 0.5em 0; }
    img.md-img { max-width: 100%; border-radius: 8px; margin: 0.5em 0; cursor: zoom-in; display: block; }
    a.md-img-fallback { word-break: break-all; }
    video.md-video { width: 100%; max-width: 100%; min-height: 180px; border-radius: 8px; margin: 0.5em 0 0; display: block; background: #000; }
    a.md-video-link { display: inline-block; font-size: 13px; color: #1a73e8; margin: 0.2em 0 0.7em; text-decoration: none; }
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
    // 图加载不出来：多半是门禁 401（WebView 的 auth 挑战对 <img> 子资源不生效），
    // 先请原生带 Basic 账密抓回来塞 data URI；原生也拿不到才退成可点链接。
    var imgSeq = 0;
    var imgWaiting = {};
    function imgFail(el) {
      var u = el.getAttribute('src') || '';
      if (el.dataset.retried || u.indexOf('data:') === 0) { imgLink(el, u); return; }
      el.dataset.retried = '1';
      var id = 'gi' + (++imgSeq);
      imgWaiting[id] = el;
      el.dataset.origsrc = u;
      el.removeAttribute('src');
      el.alt = '载入中…';
      try {
        window.webkit.messageHandlers.fetchImage.postMessage({url: u, id: id});
      } catch (e) { imgLink(el, u); }
    }
    function imgLink(el, u) {
      var a = document.createElement('a');
      a.href = u; a.textContent = u; a.className = 'md-img-fallback';
      el.replaceWith(a);
    }
    function imgReady(id, uri) {
      var el = imgWaiting[id];
      if (!el) { return; }
      delete imgWaiting[id];
      el.alt = '';
      el.src = uri;
    }
    function imgGiveUp(id) {
      var el = imgWaiting[id];
      if (!el) { return; }
      delete imgWaiting[id];
      imgLink(el, el.dataset.origsrc || '');
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
        '<img class="md-img" src="' + url + '" alt="' + alt + '" onerror="imgFail(this)">');
      // 3. markdown link [text](url) — image/video url 也转成内联媒体
      s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, text, url) => {
        if (/\.(?:jpe?g|png|gif|webp|bmp|heic|svg)(?:\?.*)?$/i.test(url)) {
          return '<img class="md-img" src="' + url + '" alt="' + text + '" onerror="imgFail(this)">';
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
        (m) => '<img class="md-img" src="' + m + '" onerror="imgFail(this)">');
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
          const roleLabel = isUser ? 'YOU' : (CLAUDE_NAME || 'CLAUDE');
          const roleClass = isUser ? 'role-user' : 'role-claude';
          const blockClass = isUser ? 'mb-user' : 'mb-claude';
          i++;
          const bodyLines = [];
          while (i < lines.length && !/^[▶◆]/.test(lines[i]) && !/^=== /.test(lines[i])) {
            bodyLines.push(lines[i]); i++;
          }
          // trim trailing blanks
          while (bodyLines.length && bodyLines[bodyLines.length - 1].trim() === '') bodyLines.pop();
          const rawForCopy = bodyLines.join('\n');
          const bodyHtml = renderBlocks(rawForCopy);
          // user 胶囊不带任何按钮;Claude 卡片头只留一个「复制」;两边都带圆头像
          const headHtml = isUser ? '' :
            '<div class="msg-head">' +
              '<span class="role ' + roleClass + '">' + roleLabel + '</span>' +
              '<span class="head-btns">' +
                '<button class="copy-btn" data-content="' + utf8B64(rawForCopy) + '" onclick="copyMsg(this)">复制</button>' +
              '</span>' +
            '</div>';
          const avaHtml = isUser
            ? (AVA_USER ? '<div class="ava has-img"><img class="ava-img" src="' + AVA_USER + '"></div>'
                        : '<div class="ava ava-user">我</div>')
            : (AVA_CLAUDE ? '<div class="ava has-img"><img class="ava-img" src="' + AVA_CLAUDE + '"></div>'
                          : '<div class="ava ava-claude">' +
                            (CLAUDE_NAME ? CLAUDE_NAME.charAt(0).toUpperCase() : 'C') + '</div>');
          html += '<div class="msg-block ' + blockClass + '">' + avaHtml +
            '<div class="card">' + headHtml +
              '<div class="msg-body">' + bodyHtml + '</div>' +
            '</div>' +
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
    var AVA_CLAUDE = "\#(claudeAvatarJS)";
    var AVA_USER = "\#(userAvatarJS)";
    var CLAUDE_NAME = "\#(claudeNameJS)";
    // 尾部优先渲染:先只渲染最后 N 条消息立即显示(隐藏→定位到底→显示,不跳动),
    // 更早的历史随后后台补渲染插到上面,滚动位置补偿保持不动
    document.documentElement.style.opacity = '0';
    function scrollToBottom() { window.scrollTo(0, document.documentElement.scrollHeight); }
    var RAW = decodeB64("\#(payloadB64)");
    function splitTail(raw, n) {
      var lines = raw.split('\n');
      var idxs = [];
      for (var i = 0; i < lines.length; i++) { if (/^[▶◆]/.test(lines[i])) idxs.push(i); }
      if (idxs.length <= n) return { head: '', tail: raw };
      var cut = idxs[idxs.length - n];
      return { head: lines.slice(0, cut).join('\n'), tail: lines.slice(cut).join('\n') };
    }
    var parts = splitTail(RAW, 12);
    document.getElementById('content').innerHTML = renderBlocks(parts.tail);
    scrollToBottom();
    requestAnimationFrame(function() {
      scrollToBottom();
      document.documentElement.style.opacity = '1';
    });
    // 兜底:JS 异常/极端情况也要显示出来
    setTimeout(function() { document.documentElement.style.opacity = '1'; }, 400);
    if (parts.head) {
      setTimeout(function() {
        var div = document.createElement('div');
        div.innerHTML = renderBlocks(parts.head);
        var c = document.getElementById('content');
        var before = document.documentElement.scrollHeight;
        var y = window.scrollY;
        while (div.lastChild) { c.insertBefore(div.lastChild, c.firstChild); }
        var delta = document.documentElement.scrollHeight - before;
        window.scrollTo(0, y + delta);
      }, 80);
    }
    window.addEventListener('load', scrollToBottom);
    // 图片加载完会撑高文档，加载完补滚保持贴底
    Array.from(document.images).forEach(img => {
      if (!img.complete) img.addEventListener('load', scrollToBottom, { once: true });
    });
    setTimeout(scrollToBottom, 300);
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

  /// 消息里内联的 <img> 撞上门禁（Basic Auth）时，用钉住浏览器 tab 里存的账密应答——
  /// prototype 站等图床的凭证跟浏览器共用一份，门禁内截图就能直接显示出来。
  func webView(_ webView: WKWebView,
               didReceive challenge: URLAuthenticationChallenge,
               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    let method = challenge.protectionSpace.authenticationMethod
    let basicLike = method == NSURLAuthenticationMethodHTTPBasic
      || method == NSURLAuthenticationMethodHTTPDigest
    if basicLike, challenge.previousFailureCount == 0 {
      let host = challenge.protectionSpace.host
      if let cred = Self.basicAuth(forHost: challenge.protectionSpace.host) {
        completionHandler(.useCredential, URLCredential(user: cred.0, password: cred.1, persistence: .forSession))
        return
      }
    }
    completionHandler(.performDefaultHandling, nil)
  }

  @objc private func closeTapped() { dismiss(animated: true) }

  @objc private func shareTapped() {
    let av = UIActivityViewController(activityItems: [bodyText], applicationActivities: nil)
    av.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
    present(av, animated: true)
  }
}
