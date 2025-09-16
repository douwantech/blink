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


import Combine
import UserNotifications
import AVFoundation

@objc protocol TermControlDelegate: NSObjectProtocol {
  // May be do it optional
  func terminalHangup(control: TermController)
  @objc optional func terminalDidResize(control: TermController)
}

@objc protocol ControlPanelDelegate: NSObjectProtocol {
  func controlPanelOnClose()
  func controlPanelOnPaste()
  func currentTerm() -> TermController!
}

private class ProxyView: UIView {
  var controlledView: UIView? = nil
  private var _cancelable: AnyCancellable? = nil
  private var _hasBeenPlaced: Bool = false  // TEST: Track if view has been placed
  private var _isTerminated: Bool = false   // TEST: Prevent re-placement after termination

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if superview == nil {
      _cancelable = nil
    }
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()

    _cancelable = nil

    guard
      let parent = superview
    else {
      return
    }

    _cancelable = parent.publisher(for: \.frame).sink { [weak self] frame in
      guard let controlledView = self?.controlledView,
            controlledView.superview != nil
      else {
        return
      }
      controlledView.frame = frame
    }

    placeControlledView()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard
      let parent = superview,
      let controlledView = controlledView
    else {
      return
    }
    controlledView.frame = parent.frame
  }

  func removeControlledView() {
    // TEST: Hide instead of remove (for temporary switching)
    guard let controlledView = controlledView else { return }
    controlledView.isHidden = true
  }

  func destroyControlledView() {
    // TEST: Full removal for terminal termination
    guard let controlledView = controlledView else { return }
    controlledView.removeFromSuperview()
    _hasBeenPlaced = false
    _isTerminated = true  // Prevent any future re-placement
  }

  func prepareForWindowMove() {
    // TEST: Remove for window move but allow re-placement in new window
    guard let controlledView = controlledView else { return }
    controlledView.removeFromSuperview()
    _hasBeenPlaced = false
    // Note: Don't set _isTerminated - this is a move, not termination
  }

  func placeControlledView() {
    // TEST: Never place if terminal was terminated
    if _isTerminated { return }

    guard
      let parent = superview,
      let container = parent.superview,
      let controlledView = controlledView
    else {
      return
    }

    controlledView.frame = parent.frame

    // TEST: Place once per container, then just show/hide
    // If view is in a different container (window changed), we need to re-place
    if !_hasBeenPlaced || controlledView.superview !== container {
      if
        let sharedWindow = ShadowWindow.shared,
        container.window == sharedWindow {

        sharedWindow.layer.removeFromSuperlayer()
        container.addSubview(controlledView)
        sharedWindow.refWindow.layer.addSublayer(sharedWindow.layer)

      } else {
        container.addSubview(controlledView)
      }
      _hasBeenPlaced = true
    }

    // Show the view when placing
    controlledView.isHidden = false
  }
}

class TermController: UIViewController {
  private let _meta: SessionMeta

  private var _termDevice = TermDevice()
  private var _bag = Array<AnyCancellable>()
  private var _termView = TermView(frame: .zero)
  private var _proxyView = ProxyView(frame: .zero)
  private var _termUIState: TermUIState = TermUIState.withDefaults()
  private var _bgColor: UIColor? = nil
  private var _fontSizeBeforeScaling: Int? = nil

  @objc public var viewIsLoaded: Bool = false

  @objc public var activityKey: String? = nil
  @objc public var termDevice: TermDevice { _termDevice }
  @objc weak var delegate: TermControlDelegate? = nil

  // Control whether terminal can become first responder (e.g., during Snips Input Mode)
  var shouldBlockFirstResponder: Bool = false {
    didSet {
      _termDevice.shouldBlockFirstResponder = shouldBlockFirstResponder
    }
  }
  @objc var bgColor: UIColor? {
    get { _bgColor }
    set { _bgColor = newValue }
  }
  
  // State Properties for Input Management
  var isReady: Bool {
    _termDevice.view?.isReady ?? false
  }
  
  var isAttached: Bool {
    KBTracker.shared.input == _termDevice.view?.webView
  }
  
  override var isFirstResponder: Bool {
    _termDevice.view?.webView.isFirstResponder ?? false
  }


  @objc var termUIState: TermUIState { _termUIState }

  private var _sessionPayload: TermSessionPayload? = nil
  private var _session: Session? { _sessionPayload?.session }

  required init(meta: SessionMeta? = nil) {
    _meta = meta ?? SessionMeta()
    super.init(nibName: nil, bundle: nil)
  }

  convenience init(sceneRole: UISceneSession.Role? = nil, sessionPayload: TermSessionPayload? = nil) {
    self.init(meta: nil)
    self._sessionPayload = sessionPayload

    if sceneRole == .windowExternalDisplayNonInteractive {
      _termUIState.fontSize = BLKDefaults.selectedExternalDisplayFontSize()?.intValue ?? 24
    }
  }

  required public init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func placeToContainer() {
    _proxyView.placeControlledView()
  }

  func removeFromContainer() -> Bool {
    if KBTracker.shared.input == _termView.webView {
      return false
    }
    _proxyView.removeControlledView()
    return true
  }

  func prepareForWindowMove() {
    // TEST: Prepare terminal for move to different window
    _proxyView.prepareForWindowMove()
  }

  public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    if !coordinator.isAnimated {
      return
    }

    super.viewWillTransition(to: size, with: coordinator)
  }

  public override func loadView() {
    super.loadView()
    _termDevice.delegate = self
    _termDevice.attachView(_termView)
    _termView.backgroundColor = _bgColor
    _termView.termController = self
    _proxyView.controlledView = _termView;
    _proxyView.isUserInteractionEnabled = false
    view = _proxyView
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    viewIsLoaded = true

    // resumeIfNeeded()

    _termView.load(with: _termUIState)
  }

  public override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()

    guard let window = view.window,
      let windowScene = window.windowScene,
      windowScene.activationState == .foregroundActive
    else {
      return
    }
  }

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    _termUIState.viewSize = view.bounds.size
  }

  @objc public func terminate() {
    NotificationCenter.default.post(name: .deviceTerminated, object: nil, userInfo: ["device": _termDevice])
    _proxyView.destroyControlledView()
    _termDevice.delegate = nil
    _termView.terminate()
    _session?.kill()
  }

  @objc public func isRunningCmd() -> Bool {
    return true
    //return _session?.isRunningCmd() ?? false
  }

  @objc public func scaleWithPich(_ pinch: UIPinchGestureRecognizer) {
    // Block font resize when layout is locked
    guard !_termUIState.layoutLocked else {
      return
    }

    switch pinch.state {
    case .began: fallthrough
    case .ended:
      _fontSizeBeforeScaling = _termUIState.fontSize
    case .changed:
      guard let initialSize = _fontSizeBeforeScaling else {
        return
      }
      let newSize = Int(round(CGFloat(initialSize) * pinch.scale))
      guard newSize != _termUIState.fontSize else {
        return
      }
      _termView.setFontSize(newSize as NSNumber)
    default:  break
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    // Break ref-loop
    _session?.delegate = nil
  }
}

extension TermController: SessionDelegate {
  public func sessionFinished() {
// TODO Not sure how accurate this flow is.
//    if _session.sessionParams.hasEncodedState() {
//      _session.delegate = nil
//      return
//    }
    self.delegate?.terminalHangup(control: self)
  }
}

let _apiRoutes:[String: (MCPSession, String) -> AnyPublisher<String, Never>] = [
  "history.search": History.searchAPI,
  "completion.for": Complete.forAPI
]


/// Types of supported notifications
@objc enum BKNotificationType: NSInteger {
  case bell = 0
  case osc = 1
}

// MARK: - TermDeviceDelegate methods
extension TermController: TermDeviceDelegate {

  /**
   When a `ring-bell` notification has been received on `TermView` react to it by sounding a bell if the terminal that sent it
   is in focus and if it's not send a notification. Tapping the notification opens the session that sent it.

   Only reproduce haptic feedback on iPhones and if it's enabled.

   Enable/Disable standard OSC sequences & iTerm2 notifications
   */
  func viewDidReceiveBellRing() {

    if BLKDefaults.isPlaySoundOnBellOn() && _termView.isFocused() {
      AudioServicesPlaySystemSound(1103);
    }

    viewNotify(["title": "🔔 \(_termView.title ?? "")", "type": BKNotificationType.bell.rawValue])

    // Haptic feedback is only visible from iPhones
    if UIDevice.current.userInterfaceIdiom == .phone && !BLKDefaults.hapticFeedbackOnBellOff() {
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
  }

  /**
   Presents a UserNotification with the `title` & `body` values passed on `data`. Tapping on the notification opens the terminal that originated the notification. Also triggered when the terminal receives a standard `OSC` sequence & iTerm2-like notification.

   - Parameters:
    - data: Set the `title` and `body` String values to display those values in the notification banner. Set the `type`'s rawValue of `BKNotificationType` to identify the type of notification used.
   */
  func viewNotify(_ data: [AnyHashable : Any]!) {

    guard let notificationTypeRaw = data["type"] as? Int, let notificationType = BKNotificationType(rawValue: notificationTypeRaw) else {
      return
    }

    if notificationType  == .bell && (_termView.isFocused() || !BLKDefaults.isNotificationOnBellUnfocusedOn())
        || notificationType == .osc && !BLKDefaults.isOscNotificationsOn() {
       return
    }

    let content = UNMutableNotificationContent()
    content.title = (data["title"] as? String) ?? title ?? "Blink"
    content.body = (data["body"] as? String) ?? ""
    content.sound = .default
    content.threadIdentifier = meta.key.uuidString
    content.targetContentIdentifier = "blink://open-scene/\(view?.window?.windowScene?.session.persistentIdentifier ?? "")"

    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .announcement]) { (granted, error) in
      if granted {
        center.add(req, withCompletionHandler: nil)
      }
    }
  }

  func apiCall(_ api: String!, andRequest request: String!) {
    guard
      let api = api,
      let call = _apiRoutes[api]
    else {
      return
    }

    weak var termView = _termView

//    _ = call(session, request)
//      .receive(on: RunLoop.main)
//      .sink { termView?.apiResponse(api, response: $0) }
  }

  public func deviceIsReady() {
    if _sessionPayload != nil {
      _startSession()
    } else {
      resumeIfNeeded()
    }

    // Input progression. When device becomes ready, check if we need to become first responder
    if isAttached {
      _becomeFirstResponder()
    }
  }

  
  func activateInput() {
    // Don't activate input if blocked (e.g., during Snips Input Mode)
    guard !shouldBlockFirstResponder else {
      return
    }

    if !isAttached {
      _attachInput()
    }

    if isReady {
      _becomeFirstResponder()
    }
    // If not ready, wait for isReady call to trigger _becomeFirstResponder()
  }

  func resignInput() {
    guard isAttached && isReady else {
      return
    }

    guard let deviceView = _termDevice.view else { return }

    deviceView.webView.reportFocus(false)

    // It is key to reset here so when attached again, settings are synced and the keyboard state is properly reset.
    KBTracker.shared.attach(input: nil)

    _ = _termDevice.view?.webView.resignFirstResponder()
  }
  
  private func _attachInput() {
    guard let deviceView = _termDevice.view else { return }
    
    let input = KBTracker.shared.input
    
    if deviceView.browserView != nil {
      KBTracker.shared.attach(input: deviceView.browserView)
      _termDevice.attachInput(deviceView.browserView)
      _ = deviceView.browserView.becomeFirstResponder()
      if input != KBTracker.shared.input {
        input?.reportFocus(false)
      }
      return
    }

    KBTracker.shared.attach(input: deviceView.webView)
    _termDevice.attachInput(deviceView.webView)
  }
  
  private func _becomeFirstResponder() {
    guard let deviceView = _termDevice.view else { return }

    // Don't become first responder if blocked (e.g., during Snips Input Mode)
    guard !shouldBlockFirstResponder else { return }

    if !isAttached && !isReady{ return }

    deviceView.webView.reportFocus(true)
    _termDevice.focus()

    let input = KBTracker.shared.input

    if input != KBTracker.shared.input {
      input?.reportFocus(false)
    }

    _ = _termDevice.view?.webView.becomeFirstResponder()
  }
    
  public func deviceSizeChanged() {
    _termUIState.rows = _termDevice.rows
    _termUIState.cols = _termDevice.cols

    delegate?.terminalDidResize?(control: self)
    print("Terminal size changed - rows: \(_termDevice.rows) x cols: \(_termDevice.cols)")
    _session?.sigwinch()
  }

  public func viewFontSizeChanged(_ size: Int) {
    _termUIState.fontSize = size
    _termDevice.input?.reset()
  }

  public func deviceFocused() {
    view.setNeedsLayout()
  }

  public func viewController() -> UIViewController! {
    return self
  }

  public func xCallbackLineSubmitted(_ line: String, _ successUrl: URL? = nil) {
    //_session?.enqueueXCallbackCommand(line, xCallbackSuccessUrl: successUrl)
  }
}

extension TermController: SuspendableSession {

  var meta: SessionMeta { _meta }

  var _decodableKey: String { "params" }
  
  private func _createPayloadFromTermParams(_ termParams: TermParams) -> TermSessionPayload? {
    switch termParams.sessionType {
    case MCPSessionPayload.sessionType.rawValue:
      if let mcpParams = termParams.sessionParams as? MCPParams {
        return MCPSessionPayload(params: mcpParams)
      }
    default:
      break
    }
    return nil
  }

  func _startSession() {
    guard let payload = _sessionPayload,
          _session == nil else { return }

    payload.start(in: _termDevice, sessionKey: meta.key.uuidString)
    _session?.delegate = self

    // TODO Move to the MCPSession instead.
    // if let initialPrompt = WhatsNewInfo.mustDisplayInitialPrompt() {
    //   _termDevice.writeOutLn(initialPrompt)
    // }

    if view.bounds.size != _termUIState.viewSize {
      _session?.sigwinch()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      self._termView.setClipboardWrite(true)
    }
  }

  func resume(with unarchiver: NSKeyedUnarchiver) -> NSKeyedArchiver? {    
    guard
      unarchiver.containsValue(forKey: _decodableKey),
      let termParams = unarchiver.decodeObject(of: TermParams.self, forKey: _decodableKey)
    else {
      return nil
    }

    guard let termUIState = termParams.termUIState,
          let sessionParams = termParams.sessionParams else {
            return nil
          }

    _termUIState = termUIState

    // Two paths. If there is no "live" payload, we create and start again,
    // otherwise we resume the suspended payload.
    if _sessionPayload == nil {
      // Create a deepCopy of the params to be fully owned by the Session, while the TermParams can be "cleaned".
      // We need this separation because start / resume are fully asynchronous.
      guard let payloadTermParams = termParams.deepCopy(),
            let payload = _createPayloadFromTermParams(payloadTermParams) else { return nil }
      
      _sessionPayload = payload
      payload.start(in: _termDevice, sessionKey: _meta.key.uuidString)
      _session!.delegate = self
    } else {
      _sessionPayload!.resumeFromSuspended()
    }

    if view.bounds.size != _termUIState.viewSize {
      _session!.sigwinch()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      self._termView.setClipboardWrite(true)
    }

    // After resuming the payload, we write a "clean" copy back to disk.
    // Meaning the Session will have taken any encodedState, so we store it "clean" to avoid reuse.
    let _ = termParams.sessionParams?.takeEncodedState()
    let updatedArchiver = NSKeyedArchiver(requiringSecureCoding: true)
    updatedArchiver.encode(termParams, forKey: _decodableKey)
    return updatedArchiver
  }

  func suspendSession(with archiver: NSKeyedArchiver) {
    // TODO session as a getter instead of _session. Do not keep a ref.
    guard let session = _session, let sessionPayload = _sessionPayload else { return }
    _termView.setClipboardWrite(false)

    _sessionPayload?.suspend()

    let termParams = TermParams(sessionParams: session.sessionParams,
                                // TODO A bit ugly
                                sessionType: type(of: sessionPayload).sessionType.rawValue,
                                termUIState: _termUIState)

    archiver.encode(termParams, forKey: _decodableKey)
  }

  func resumeIfNeeded() {
    guard _termDevice.isReady else { return }
    (self as SuspendableSession).resumeIfNeeded()
  }
}

extension Notification.Name {
  static let deviceTerminated = Notification.Name("deviceTerminated")
}

fileprivate extension TermUIState {
    static func withDefaults() -> TermUIState {
        var uiState = TermUIState()
        uiState.fontSize = BLKDefaults.selectedFontSize()?.intValue ?? 16
        uiState.fontName = BLKDefaults.selectedFontName()
        uiState.themeName = BLKDefaults.selectedThemeName()
        uiState.enableBold = UInt(BLKDefaults.enableBold())
        uiState.boldAsBright = BLKDefaults.isBoldAsBright()
        uiState.layoutMode = BLKDefaults.layoutMode().rawValue
        return uiState
    }
}
