import UIKit

/// 内嵌 RustDesk 远程桌面页(阶段 1:连接 + 看屏)。
/// 事件流:rd_session_start 后,Rust 线程回调 → 解析 JSON 事件/取 RGBA 帧 → 主线程上屏。
final class RemoteDesktopViewController: UIViewController, UITextFieldDelegate {
  private let peerId: String
  private let password: String
  // SSH 通道(用于"点击缩放到窗口":到目标机跑 windowat)。nil 则双击回退固定放大。
  private let sshHost: String?
  private let sshUser: String?
  private let sessionUUID = UUID().uuidString.lowercased()
  private var port: Int64 = 0
  private var closed = false

  // 当前显示器尺寸(peer_info / switch_display 事件更新;取帧算 bytesPerRow 用)
  private var displayWidth = 0
  private var displayHeight = 0
  private var currentDisplay = 0

  private let imageView = UIImageView()
  private let statusLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .large)

  // 软件光标反馈点(远端桌面画面通常不含指针,自己画一个跟手的点)
  private let cursorDot = UIView()
  // 触控映射到的远端坐标(左键 down/up 复用最近一次 move 的落点)
  private var lastRemote = CGPoint.zero

  // 浮动文字输入框:输入完回车,整串发到远端并补一个回车键
  private let inputField = UITextField()

  // 底部按钮栏(关闭/旋转/键盘都放这)
  private let bottomBar = UIView()
  private let barButtons = UIStackView()

  // 双击缩放:默认 aspectFit 居中;双击某点 → 以该点为中心放大铺满可用区,再双击复原
  private var zoomed = false
  private var zoomCenterRemote = CGPoint.zero
  // 非 nil 时缩放到这个远端窗口 rect(windowat 命中结果);nil 则用 zoomCenterRemote 固定放大
  private var zoomRemoteRect: CGRect?
  private var querying = false

  init(peerId: String, password: String, sshHost: String? = nil, sshUser: String? = nil) {
    self.peerId = peerId
    self.password = password
    self.sshHost = sshHost
    self.sshUser = sshUser
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError() }

  // 远程页独立于 app 的竖屏锁(根控制器 lockPortrait)。方向完全由本页的 🔄 按钮掌控,
  // 不跟设备摇晃自动转——远程桌面下更稳。默认竖屏进入,点按钮才转横屏。
  private var forcedOrientation: UIInterfaceOrientationMask = .portrait
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { forcedOrientation }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
  override var shouldAutorotate: Bool { true }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    _applyOrientation()
  }

  private func _applyOrientation() {
    setNeedsUpdateOfSupportedInterfaceOrientations()
    guard let scene = view.window?.windowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: forcedOrientation)) { _ in }
  }

  @objc private func toggleOrientation() {
    forcedOrientation = (forcedOrientation == .landscapeRight) ? .portrait : .landscapeRight
    _applyOrientation()
  }

  // MARK: 浮动输入框

  @objc private func toggleKeyboard() {
    if inputField.isFirstResponder {
      inputField.resignFirstResponder()
    } else {
      inputField.isHidden = false
      view.bringSubviewToFront(inputField)
      inputField.becomeFirstResponder()
    }
  }

  /// 输入框吸附在软键盘正上方;键盘收起时滑出屏幕并隐藏。
  @objc private func keyboardFrameChanged(_ n: Notification) {
    guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    let kbTop = view.convert(f, from: nil).minY
    let h = inputField.frame.height
    inputField.frame = CGRect(x: 0, y: min(kbTop, view.bounds.height) - h,
                              width: view.bounds.width, height: h)
    if kbTop >= view.bounds.height { inputField.isHidden = true }   // 键盘已收起
  }

  func textFieldShouldReturn(_ tf: UITextField) -> Bool {
    sendTextToRemote(tf.text ?? "")
    tf.text = ""
    tf.resignFirstResponder()   // 回车后收起键盘
    return false
  }

  /// 键盘开着时,任意触控先收键盘、不落到远端鼠标。返回 true 表示这次触控已被吃掉。
  @discardableResult
  private func dismissKeyboardIfActive() -> Bool {
    guard inputField.isFirstResponder else { return false }
    inputField.resignFirstResponder()
    return true
  }

  /// 整串走 input_string 一次性输入,再补一个回车键(VK_RETURN)。
  private func sendTextToRemote(_ text: String) {
    if !text.isEmpty { rd_session_input_string(sessionUUID, text) }
    rd_session_input_key(sessionUUID, "VK_RETURN", true, true, false, false, false, false)
  }

  private func _barButton(_ icon: String, _ action: Selector) -> UIButton {
    let b = UIButton(type: .system)
    b.setImage(UIImage(systemName: icon,
                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
    b.tintColor = UIColor.white.withAlphaComponent(0.85)
    b.addTarget(self, action: action, for: .touchUpInside)
    return b
  }

  /// 底部栏高度(含底部安全区),画面可用区 = 屏幕去掉底部栏。
  private var barHeight: CGFloat { 56 + view.safeAreaInsets.bottom }
  private var availRect: CGRect {
    CGRect(x: 0, y: 0, width: view.bounds.width, height: max(0, view.bounds.height - barHeight))
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let bh = barHeight
    bottomBar.frame = CGRect(x: 0, y: view.bounds.height - bh, width: view.bounds.width, height: bh)
    barButtons.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 56)
    _layoutImageView()
  }

  /// 画面在可用区居中(aspectFit);缩放态则以双击点为中心放大铺满可用区。
  private func _layoutImageView() {
    let dw = CGFloat(displayWidth), dh = CGFloat(displayHeight)
    guard dw > 0, dh > 0 else { imageView.frame = view.bounds; return }
    let a = availRect
    if !zoomed {
      let scale = min(a.width / dw, a.height / dh)
      let w = dw * scale, h = dh * scale
      imageView.frame = CGRect(x: a.midX - w / 2, y: a.midY - h / 2, width: w, height: h)
      return
    }
    // 缩放锚点与倍数:有窗口 rect → 让该窗口 aspectFit 铺满可用区、居中;
    // 否则以双击点为中心 aspectFill 放大。
    let scale: CGFloat
    let anchor: CGPoint   // 要对齐到可用区中心的那个远端点
    if let r = zoomRemoteRect {
      scale = min(a.width / r.width, a.height / r.height)
      anchor = CGPoint(x: r.midX, y: r.midY)
    } else {
      scale = max(a.width / dw, a.height / dh)
      anchor = zoomCenterRemote
    }
    let w = dw * scale, h = dh * scale
    var x = a.midX - anchor.x * scale
    var y = a.midY - anchor.y * scale
    x = w >= a.width ? min(a.minX, max(a.maxX - w, x)) : a.midX - w / 2
    y = h >= a.height ? min(a.minY, max(a.maxY - h, y)) : a.midY - h / 2
    imageView.frame = CGRect(x: x, y: y, width: w, height: h)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    imageView.contentMode = .scaleAspectFit
    imageView.frame = view.bounds
    view.addSubview(imageView)

    statusLabel.textColor = .white
    statusLabel.font = .systemFont(ofSize: 15)
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    statusLabel.frame = CGRect(x: 20, y: view.bounds.midY + 40, width: view.bounds.width - 40, height: 80)
    statusLabel.autoresizingMask = [.flexibleWidth, .flexibleTopMargin, .flexibleBottomMargin]
    statusLabel.text = "正在连接 \(peerId)…"
    view.addSubview(statusLabel)

    spinner.color = .white
    spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
    spinner.startAnimating()
    view.addSubview(spinner)

    // 底部按钮栏:关闭 / 旋转 / 键盘,横排均分。frame 在 viewDidLayoutSubviews 里定。
    bottomBar.backgroundColor = UIColor(white: 0.08, alpha: 0.92)
    view.addSubview(bottomBar)

    barButtons.axis = .horizontal
    barButtons.distribution = .fillEqually
    barButtons.alignment = .center
    bottomBar.addSubview(barButtons)

    barButtons.addArrangedSubview(_barButton("keyboard", #selector(toggleKeyboard)))
    barButtons.addArrangedSubview(_barButton("rotate.right", #selector(toggleOrientation)))
    barButtons.addArrangedSubview(_barButton("xmark.circle.fill", #selector(closeTapped)))

    inputField.backgroundColor = UIColor(white: 0.12, alpha: 0.96)
    inputField.textColor = .white
    inputField.tintColor = .systemTeal
    inputField.autocapitalizationType = .none
    inputField.autocorrectionType = .no
    inputField.spellCheckingType = .no
    inputField.returnKeyType = .send
    inputField.placeholder = "输入文字，回车发送到远端"
    inputField.attributedPlaceholder = NSAttributedString(
      string: "输入文字，回车发送到远端",
      attributes: [.foregroundColor: UIColor(white: 0.6, alpha: 1)])
    inputField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
    inputField.leftViewMode = .always
    inputField.delegate = self
    inputField.isHidden = true
    inputField.frame = CGRect(x: 0, y: view.bounds.height, width: view.bounds.width, height: 46)
    inputField.autoresizingMask = [.flexibleWidth]
    view.addSubview(inputField)

    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardFrameChanged(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

    cursorDot.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
    cursorDot.layer.cornerRadius = 8
    cursorDot.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.9)
    cursorDot.layer.borderWidth = 1.5
    cursorDot.layer.borderColor = UIColor.black.withAlphaComponent(0.5).cgColor
    cursorDot.isUserInteractionEnabled = false
    cursorDot.isHidden = true
    view.addSubview(cursorDot)

    setupInput()
    connect()
  }

  // MARK: 触控 → 鼠标

  private func setupInput() {
    // 单指拖:移动光标(跟手,不按键)
    let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
    pan.maximumNumberOfTouches = 1
    view.addGestureRecognizer(pan)

    // 单击:左键点击
    let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
    view.addGestureRecognizer(tap)

    // 长按:右键点击
    let long = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
    long.minimumPressDuration = 0.5
    view.addGestureRecognizer(long)

    // 双指拖:滚轮
    let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
    scroll.minimumNumberOfTouches = 2
    scroll.maximumNumberOfTouches = 2
    view.addGestureRecognizer(scroll)

    // 双击:以该点为中心放大/复原
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    view.addGestureRecognizer(doubleTap)

    tap.require(toFail: long)
    tap.require(toFail: doubleTap)
  }

  /// 视图坐标 → 远端桌面绝对像素坐标(纯计算,基于画面实际所在的 imageView.frame)。
  private func remoteCoord(_ p: CGPoint) -> CGPoint? {
    let dw = CGFloat(displayWidth), dh = CGFloat(displayHeight)
    let f = imageView.frame
    guard dw > 0, dh > 0, f.width > 0, f.height > 0 else { return nil }
    let rx = min(max((p.x - f.minX) / f.width * dw, 0), dw)
    let ry = min(max((p.y - f.minY) / f.height * dh, 0), dh)
    return CGPoint(x: rx, y: ry)
  }

  /// 同 remoteCoord,但排除底部栏区域,并更新光标点(用于鼠标操作)。
  private func mapToRemote(_ p: CGPoint) -> CGPoint? {
    if bottomBar.frame.contains(p) { return nil }
    guard let r = remoteCoord(p) else { return nil }
    lastRemote = r
    showCursor(at: p)
    return r
  }

  @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
    if dismissKeyboardIfActive() { return }
    let p = g.location(in: view)
    if bottomBar.frame.contains(p) { return }
    if querying { return }
    // 已放大 → 复原
    if zoomed {
      zoomed = false
      zoomRemoteRect = nil
      UIView.animate(withDuration: 0.25) { self._layoutImageView() }
      return
    }
    guard let r = remoteCoord(p) else { return }
    // 有 SSH 通道 → 查该点所在窗口,缩放到窗口;否则/查不到 → 以该点为中心固定放大
    guard let host = sshHost, !host.isEmpty, let user = sshUser, !user.isEmpty else {
      zoomCenterRemote = r
      zoomRemoteRect = nil
      zoomed = true
      UIView.animate(withDuration: 0.25) { self._layoutImageView() }
      return
    }
    querying = true
    showStatus("识别窗口…")
    Task { [weak self] in
      guard let self else { return }
      let rect = await WindowAtQuery.query(host: host, user: user, px: Int(r.x), py: Int(r.y))
      await MainActor.run {
        guard !self.closed else { return }
        self.querying = false
        self.showStatus(nil)
        if let rect = rect {
          self.zoomRemoteRect = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        } else {
          self.zoomCenterRemote = r   // 回退:固定放大到点
          self.zoomRemoteRect = nil
        }
        self.zoomed = true
        UIView.animate(withDuration: 0.25) { self._layoutImageView() }
      }
    }
  }

  private func showCursor(at p: CGPoint) {
    cursorDot.center = p
    if cursorDot.isHidden { cursorDot.isHidden = false }
    view.bringSubviewToFront(cursorDot)
  }

  @objc private func onPan(_ g: UIPanGestureRecognizer) {
    if g.state == .began, dismissKeyboardIfActive() { return }
    if inputField.isFirstResponder { return }
    let p = g.location(in: view)
    guard let r = mapToRemote(p) else { return }
    sendMouseMove(r)
  }

  @objc private func onTap(_ g: UITapGestureRecognizer) {
    if dismissKeyboardIfActive() { return }
    let p = g.location(in: view)
    guard let r = mapToRemote(p) else { return }
    sendClick(button: "left", at: r)
  }

  @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
    guard g.state == .began else { return }
    if dismissKeyboardIfActive() { return }
    let p = g.location(in: view)
    guard let r = mapToRemote(p) else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    sendClick(button: "right", at: r)
  }

  private var scrollAccum: CGFloat = 0
  @objc private func onScroll(_ g: UIPanGestureRecognizer) {
    if g.state == .began, dismissKeyboardIfActive() { return }
    switch g.state {
    case .began:
      scrollAccum = 0
    case .changed:
      let dy = g.translation(in: view).y
      g.setTranslation(.zero, in: view)
      scrollAccum += dy
      // 每累计 ~24pt 发一个滚轮档;RustDesk 向上滚为正
      let step: CGFloat = 24
      while abs(scrollAccum) >= step {
        let dir = scrollAccum > 0 ? 1 : -1
        scrollAccum -= CGFloat(dir) * step
        sendScroll(y: dir)
      }
    default:
      break
    }
  }

  // MARK: 发鼠标事件(JSON 契约见 flutter_ffi::session_send_mouse)

  private func sendMouse(_ dict: [String: String]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let json = String(data: data, encoding: .utf8) else { return }
    rd_session_send_mouse(sessionUUID, json)
  }

  private func sendMouseMove(_ r: CGPoint) {
    sendMouse(["x": "\(Int(r.x))", "y": "\(Int(r.y))"])
  }

  private func sendClick(button: String, at r: CGPoint) {
    let x = "\(Int(r.x))", y = "\(Int(r.y))"
    sendMouse(["x": x, "y": y])                                  // 先定位
    sendMouse(["type": "down", "buttons": button, "x": x, "y": y])
    sendMouse(["type": "up", "buttons": button, "x": x, "y": y])
  }

  private func sendScroll(y: Int) {
    sendMouse(["type": "wheel", "x": "0", "y": "\(y)"])
  }

  private func relayoutOnMain() {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed else { return }
      self._layoutImageView()
    }
  }

  private func connect() {
    RustDeskCore.shared.ensureInit()
    port = RustDeskCore.shared.allocPort { [weak self] kind, s, n1, _ in
      self?.onEvent(kind: kind, s: s, n1: n1)
    }
    let err = rd_session_add(sessionUUID, peerId, false, password)
    if let err, strlen(err) > 0 {
      let msg = String(cString: err)
      rd_free_cstring(err)
      showStatus("连接失败：\(msg)")
      return
    }
    if let err { rd_free_cstring(err) }
    if !rd_session_start(port, sessionUUID, peerId) {
      showStatus("会话启动失败")
    }
  }

  // MARK: 事件(Rust 线程)

  private func onEvent(kind: Int32, s: String?, n1: Int64) {
    switch kind {
    case 0:
      guard let s, let data = s.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = obj["name"] as? String else { return }
      handleNamedEvent(name, obj)
    case 1:
      fetchFrame(display: Int(n1))
    case 4:
      showStatus("流错误：\(s ?? "")")
    default:
      break
    }
  }

  private func handleNamedEvent(_ name: String, _ obj: [String: Any]) {
    switch name {
    case "peer_info":
      // displays 是 JSON 字符串数组 [{x,y,width,height,...}]
      currentDisplay = Int(obj["current_display"] as? String ?? "0") ?? 0
      if let ds = obj["displays"] as? String, let dd = ds.data(using: .utf8),
         let arr = try? JSONSerialization.jsonObject(with: dd) as? [[String: Any]],
         currentDisplay < arr.count {
        displayWidth = (arr[currentDisplay]["width"] as? Int) ?? 0
        displayHeight = (arr[currentDisplay]["height"] as? Int) ?? 0
      }
      showStatus(nil)
      relayoutOnMain()
    case "switch_display":
      currentDisplay = Int(obj["display"] as? String ?? "0") ?? 0
      displayWidth = Int(obj["width"] as? String ?? "0") ?? 0
      displayHeight = Int(obj["height"] as? String ?? "0") ?? 0
      relayoutOnMain()
    case "msgbox":
      let type = obj["type"] as? String ?? ""
      let text = obj["text"] as? String ?? ""
      let title = obj["title"] as? String ?? ""
      if type.contains("input-password") {
        promptPassword(wrong: type.contains("re-input"))
      } else if type == "error" || type.hasPrefix("error") {
        showStatus("❌ \(title) \(text)")
      } else if type == "success" {
        showStatus(nil)
      } else if !text.isEmpty {
        showStatus(text)
      }
    case "cancel_msgbox":
      showStatus(nil)
    default:
      break
    }
  }

  // MARK: 视频帧(Rust 线程取,主线程上屏)

  private func fetchFrame(display: Int) {
    let size = rd_session_get_rgba_size(sessionUUID, display)
    guard size > 0, let ptr = session_get_rgba(sessionUUID, display) else { return }
    let data = Data(bytes: ptr, count: size)
    rd_session_next_rgba(sessionUUID, display)

    let h = displayHeight
    let w = displayWidth
    guard h > 0, w > 0, size >= w * 4 else { return }
    let bytesPerRow = size / h   // 兼容有行对齐 padding 的情况
    guard bytesPerRow >= w * 4 else { return }

    // RustDesk 在 iOS 上的帧是 BGRA8888。CGImage 要用 little-endian + alpha-first
    // 才能把内存里的 B,G,R,A 正确解读成 RGB(否则红蓝互换,色调偏冷)。
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: data as CFData),
          let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed else { return }
      if self.spinner.isAnimating {
        self.spinner.stopAnimating()
        self.statusLabel.isHidden = true
      }
      self.imageView.image = UIImage(cgImage: cg)
    }
  }

  // MARK: UI 辅助

  private func showStatus(_ text: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed else { return }
      if let text {
        self.statusLabel.text = text
        self.statusLabel.isHidden = false
      } else {
        self.statusLabel.isHidden = true
      }
    }
  }

  private func promptPassword(wrong: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed else { return }
      let alert = UIAlertController(
        title: wrong ? "密码错误" : "输入密码",
        message: "远端 \(self.peerId) 需要密码",
        preferredStyle: .alert)
      alert.addTextField { $0.isSecureTextEntry = true; $0.placeholder = "RustDesk 密码" }
      alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in self.closeTapped() })
      alert.addAction(UIAlertAction(title: "连接", style: .default) { _ in
        let pwd = alert.textFields?.first?.text ?? ""
        rd_session_login(self.sessionUUID, "", "", pwd, true)
      })
      self.present(alert, animated: true)
    }
  }

  @objc private func closeTapped() {
    guard !closed else { return }
    closed = true
    rd_session_close(sessionUUID)
    RustDeskCore.shared.releasePort(port)
    // 主 window 的根是 SpaceController,它允许所有方向——横屏不主动转回就会留在主界面。
    // 必须等 dismiss 完成、栈顶回到根控制器后再请求竖屏,否则会被返回动画覆盖掉。
    let scene = view.window?.windowScene
    let root = view.window?.rootViewController
    dismiss(animated: true) {
      root?.setNeedsUpdateOfSupportedInterfaceOrientations()
      scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
    }
  }
}
