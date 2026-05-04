import UIKit
import Speech
import AVFoundation
import AudioToolbox

protocol VoiceInputViewDelegate: AnyObject {
  func voiceInput(_ view: VoiceInputView, didCommitText text: String)
  func voiceInputDidRequestKeyboard(_ view: VoiceInputView)
  func voiceInputDidRequestDismiss(_ view: VoiceInputView)
  func voiceInputDidRequestSendEsc(_ view: VoiceInputView)
  func voiceInputDidRequestClearLine(_ view: VoiceInputView)
}

final class VoiceInputView: UIInputView {

  weak var delegate: VoiceInputViewDelegate?

  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let placeholderText = "点击下方按钮开始说话"
  private let micButton = UIButton(type: .custom)
  private let confirmButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  private let keyboardButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private let minimizeButton = UIButton(type: .system)
  private let escButton = UIButton(type: .system)
  private let clearTextButton = UIButton(type: .system)
  private let hintLabel = UILabel()

  private static let kLocaleKey = "VoiceInputView.localeIdentifier"
  private static let supportedLocales: [(title: String, id: String)] = [
    ("中文（普通话）", "zh-CN"),
    ("English (US)", "en-US"),
    ("English (UK)", "en-GB"),
    ("日本語", "ja-JP"),
  ]

  private var localeIdentifier: String {
    didSet {
      UserDefaults.standard.set(localeIdentifier, forKey: Self.kLocaleKey)
      recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }
  }

  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
  private var isRecording = false

  private var debounceTimer: Timer?
  private var isPolishing = false


  init() {
    self.localeIdentifier = UserDefaults.standard.string(forKey: Self.kLocaleKey) ?? "zh-CN"
    super.init(frame: .zero, inputViewStyle: .keyboard)
    self.allowsSelfSizing = true
    self.translatesAutoresizingMaskIntoConstraints = false
    self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    setupUI()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 220)
  }

  private func setupUI() {
    textView.font = .systemFont(ofSize: 18, weight: .regular)
    textView.textColor = .label
    textView.backgroundColor = .clear
    textView.textAlignment = .center
    textView.isScrollEnabled = true
    textView.isEditable = false
    textView.isSelectable = false
    textView.textContainerInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    let tap = UITapGestureRecognizer(target: self, action: #selector(textViewTapped))
    textView.addGestureRecognizer(tap)

    placeholderLabel.text = placeholderText
    placeholderLabel.font = textView.font
    placeholderLabel.textColor = .secondaryLabel
    placeholderLabel.textAlignment = .center
    placeholderLabel.numberOfLines = 0
    placeholderLabel.isUserInteractionEnabled = false

    let micConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: micConfig), for: .normal)
    micButton.tintColor = .white
    micButton.backgroundColor = UIColor.systemBlue
    micButton.layer.cornerRadius = 22
    micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

    var confirmCfg = UIButton.Configuration.filled()
    confirmCfg.title = "确定 ↵"
    confirmCfg.baseBackgroundColor = .systemBlue
    confirmCfg.baseForegroundColor = .white
    confirmCfg.cornerStyle = .medium
    confirmButton.configuration = confirmCfg
    confirmButton.addTarget(self, action: #selector(commitTapped), for: .touchUpInside)

    var cancelCfg = UIButton.Configuration.tinted()
    cancelCfg.title = "清空"
    cancelCfg.baseForegroundColor = .systemRed
    cancelCfg.cornerStyle = .medium
    cancelButton.configuration = cancelCfg
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

    keyboardButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
    keyboardButton.tintColor = .secondaryLabel
    keyboardButton.addTarget(self, action: #selector(keyboardTapped), for: .touchUpInside)

    settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
    settingsButton.tintColor = .secondaryLabel
    settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

    minimizeButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
    minimizeButton.tintColor = .secondaryLabel
    minimizeButton.addTarget(self, action: #selector(minimizeTapped), for: .touchUpInside)

    escButton.setTitle("ESC", for: .normal)
    escButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    escButton.setTitleColor(.systemRed, for: .normal)
    escButton.layer.borderColor = UIColor.systemRed.cgColor
    escButton.layer.borderWidth = 1
    escButton.layer.cornerRadius = 6
    escButton.addTarget(self, action: #selector(escTapped), for: .touchUpInside)

    clearTextButton.setTitle("Clear", for: .normal)
    clearTextButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    clearTextButton.setTitleColor(.secondaryLabel, for: .normal)
    clearTextButton.layer.borderColor = UIColor.secondaryLabel.cgColor
    clearTextButton.layer.borderWidth = 1
    clearTextButton.layer.cornerRadius = 6
    clearTextButton.addTarget(self, action: #selector(clearTextTapped), for: .touchUpInside)

    hintLabel.font = .systemFont(ofSize: 13)
    hintLabel.textColor = .tertiaryLabel
    hintLabel.textAlignment = .center
    hintLabel.text = currentLocaleTitle()

    [textView, placeholderLabel, micButton, confirmButton, cancelButton, keyboardButton, settingsButton, minimizeButton, escButton, clearTextButton, hintLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }

    NSLayoutConstraint.activate([
      settingsButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      settingsButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      settingsButton.widthAnchor.constraint(equalToConstant: 40),
      settingsButton.heightAnchor.constraint(equalToConstant: 32),

      minimizeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      minimizeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      minimizeButton.widthAnchor.constraint(equalToConstant: 40),
      minimizeButton.heightAnchor.constraint(equalToConstant: 32),

      keyboardButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      keyboardButton.trailingAnchor.constraint(equalTo: minimizeButton.leadingAnchor, constant: -4),
      keyboardButton.widthAnchor.constraint(equalToConstant: 40),
      keyboardButton.heightAnchor.constraint(equalToConstant: 32),

      textView.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 4),
      textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      textView.bottomAnchor.constraint(equalTo: micButton.topAnchor, constant: -8),

      placeholderLabel.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
      placeholderLabel.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
      placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textView.leadingAnchor, constant: 8),
      placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -8),

      micButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      micButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
      micButton.widthAnchor.constraint(equalToConstant: 44),
      micButton.heightAnchor.constraint(equalToConstant: 44),

      escButton.trailingAnchor.constraint(equalTo: keyboardButton.leadingAnchor, constant: -4),
      escButton.centerYAnchor.constraint(equalTo: keyboardButton.centerYAnchor),
      escButton.widthAnchor.constraint(equalToConstant: 44),
      escButton.heightAnchor.constraint(equalToConstant: 30),

      clearTextButton.trailingAnchor.constraint(equalTo: escButton.leadingAnchor, constant: -4),
      clearTextButton.centerYAnchor.constraint(equalTo: escButton.centerYAnchor),
      clearTextButton.widthAnchor.constraint(equalToConstant: 56),
      clearTextButton.heightAnchor.constraint(equalToConstant: 30),

      hintLabel.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 8),
      hintLabel.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
      hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

      confirmButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
      confirmButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      confirmButton.widthAnchor.constraint(equalToConstant: 78),

      cancelButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
      cancelButton.trailingAnchor.constraint(equalTo: confirmButton.leadingAnchor, constant: -8),
      cancelButton.widthAnchor.constraint(equalToConstant: 72),
      cancelButton.heightAnchor.constraint(equalToConstant: 36),
      confirmButton.heightAnchor.constraint(equalToConstant: 36),
    ])
  }

  private func currentLocaleTitle() -> String {
    Self.supportedLocales.first { $0.id == localeIdentifier }?.title ?? localeIdentifier
  }

  private func setText(_ text: String) {
    textView.text = text
    updatePlaceholderVisibility()
    if isRecording {
      resetDebounceTimer()
    }
  }

  private func resetDebounceTimer() {
    debounceTimer?.invalidate()
    guard AITextPolisher.shared.enabled, !AITextPolisher.shared.apiKey.isEmpty else { return }
    let delay = AITextPolisher.shared.debounceSeconds
    debounceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      self?.handleDebounceFired()
    }
  }

  private func handleDebounceFired() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    polishText()
  }

  private func polishText() {
    guard AITextPolisher.shared.enabled, !AITextPolisher.shared.apiKey.isEmpty else { return }
    let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isPolishing else { return }
    isPolishing = true
    hintLabel.text = "AI 整理中…"
    hintLabel.textColor = .systemBlue
    AITextPolisher.shared.polish(text) { [weak self] result in
      guard let self else { return }
      self.isPolishing = false
      switch result {
      case .success(let polished):
        self.textView.text = polished
        self.updatePlaceholderVisibility()
        self.hintLabel.text = "已整理 · \(self.currentLocaleTitle())"
        self.hintLabel.textColor = .tertiaryLabel
      case .failure(let err):
        self.hintLabel.text = self.currentLocaleTitle()
        self.hintLabel.textColor = .tertiaryLabel
        self.showToast("AI 整理失败: \(err.localizedDescription)", isError: true)
      }
    }
  }

  private func showToast(_ message: String, isError: Bool = false) {
    let scenes = UIApplication.shared.connectedScenes
    guard let window = scenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }

    let label = UILabel()
    label.text = message
    label.textColor = .white
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.numberOfLines = 0
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = isError
      ? UIColor.systemRed.withAlphaComponent(0.92)
      : UIColor.black.withAlphaComponent(0.85)
    container.layer.cornerRadius = 10
    container.layer.masksToBounds = true
    container.alpha = 0
    container.isUserInteractionEnabled = false
    container.addSubview(label)
    window.addSubview(container)

    NSLayoutConstraint.activate([
      container.centerXAnchor.constraint(equalTo: window.centerXAnchor),
      container.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -80),
      container.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 24),
      container.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -24),

      label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
    ])

    UIView.animate(withDuration: 0.25, animations: {
      container.alpha = 1
    }) { _ in
      UIView.animate(withDuration: 0.3, delay: 2.0, options: [], animations: {
        container.alpha = 0
      }) { _ in
        container.removeFromSuperview()
      }
    }
  }

  private func updatePlaceholderVisibility() {
    placeholderLabel.isHidden = !textView.text.isEmpty
  }

  // MARK: - Actions

  @objc private func micTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
      debounceTimer?.invalidate()
      polishText()
      return
    }
    setMicButtonRecording(true)
    requestPermissionsThen { [weak self] granted in
      guard let self else { return }
      if granted {
        self.startRecording()
      } else {
        self.setMicButtonRecording(false)
      }
    }
  }

  private func setMicButtonRecording(_ recording: Bool) {
    UIView.animate(withDuration: 0.15) {
      self.micButton.backgroundColor = recording ? UIColor.systemRed : UIColor.systemBlue
      self.micButton.transform = recording ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
    }
    hintLabel.text = recording ? "正在听… 点击结束" : currentLocaleTitle()
  }

  @objc private func commitTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    AITextPolisher.shared.recordHistory(text)
    delegate?.voiceInput(self, didCommitText: text)
    setText("")
  }

  @objc private func cancelTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    setText("")
  }

  @objc private func keyboardTapped() {
    if isRecording {
      stopRecording()
    }
    delegate?.voiceInputDidRequestKeyboard(self)
  }

  @objc private func textViewTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    let editor = VoiceEditTextViewController()
    editor.initialText = textView.text ?? ""
    editor.onDone = { [weak self] text in
      self?.setText(text)
    }
    let nav = UINavigationController(rootViewController: editor)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    findViewController()?.present(nav, animated: true)
  }

  @objc private func clearTextTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    setText("")
    delegate?.voiceInputDidRequestClearLine(self)
  }

  @objc private func escTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    delegate?.voiceInputDidRequestSendEsc(self)
  }

  @objc private func minimizeTapped() {
    if isRecording {
      stopRecording()
    }
    delegate?.voiceInputDidRequestDismiss(self)
  }

  @objc private func settingsTapped() {
    let vc = VoiceSettingsViewController(voiceView: self)
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    findViewController()?.present(nav, animated: true)
  }

  static var supportedLocalesPublic: [(title: String, id: String)] { supportedLocales }
  var localeIdentifierForSettings: String { localeIdentifier }
  func setLocaleIdentifierFromSettings(_ id: String) {
    localeIdentifier = id
    hintLabel.text = Self.supportedLocales.first { $0.id == id }?.title ?? id
    hintLabel.textColor = .tertiaryLabel
  }

  func currentLocaleTitleForSettings() -> String { currentLocaleTitle() }
  func openLanguagePickerFromSettings() { presentLanguageSheet() }
  func openAIConfigFromSettings() { presentAISettings() }
  func setHintForSettingsChange(_ text: String) {
    hintLabel.text = text
    hintLabel.textColor = .tertiaryLabel
  }

  private func presentLanguageSheet() {
    let alert = UIAlertController(title: "识别语言", message: nil, preferredStyle: .actionSheet)
    for entry in Self.supportedLocales {
      let isCurrent = entry.id == localeIdentifier
      let title = isCurrent ? "✓ \(entry.title)" : entry.title
      alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
        self?.localeIdentifier = entry.id
        self?.hintLabel.text = entry.title
        self?.hintLabel.textColor = .tertiaryLabel
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let pop = alert.popoverPresentationController {
      pop.sourceView = settingsButton
      pop.sourceRect = settingsButton.bounds
    }
    findViewController()?.present(alert, animated: true)
  }

  private func presentAISettings() {
    let alert = UIAlertController(title: "AI 配置", message: "兼容 OpenAI 协议（智谱 GLM 等）", preferredStyle: .alert)
    alert.addTextField { tf in
      tf.placeholder = "API Key"
      tf.text = AITextPolisher.shared.apiKey
      tf.isSecureTextEntry = true
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
    }
    alert.addTextField { tf in
      tf.placeholder = "模型 (如 glm-4.5)"
      tf.text = AITextPolisher.shared.model
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
    }
    alert.addTextField { tf in
      tf.placeholder = "Base URL"
      tf.text = AITextPolisher.shared.baseURL
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
      tf.keyboardType = .URL
    }
    alert.addTextField { tf in
      tf.placeholder = "停顿延迟（秒，默认 3.5）"
      tf.text = String(format: "%.1f", AITextPolisher.shared.debounceSeconds)
      tf.keyboardType = .decimalPad
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
      let fields = alert.textFields ?? []
      if let k = fields[safe: 0]?.text { AITextPolisher.shared.apiKey = k }
      if let m = fields[safe: 1]?.text, !m.isEmpty { AITextPolisher.shared.model = m }
      if let u = fields[safe: 2]?.text, !u.isEmpty { AITextPolisher.shared.baseURL = u }
      if let s = fields[safe: 3]?.text, let d = Double(s), d > 0 {
        AITextPolisher.shared.debounceSeconds = d
      }
    })
    findViewController()?.present(alert, animated: true)
  }

  private func findViewController() -> UIViewController? {
    var n: UIResponder? = self
    while let r = n {
      if let vc = r as? UIViewController { return vc }
      n = r.next
    }
    let scenes = UIApplication.shared.connectedScenes
    let window = scenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  // MARK: - Permissions

  private func requestPermissionsThen(_ completion: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { speechStatus in
      DispatchQueue.main.async {
        guard speechStatus == .authorized else {
          self.showPermissionDenied("语音识别")
          completion(false)
          return
        }
        let micHandler: (Bool) -> Void = { granted in
          DispatchQueue.main.async {
            if !granted {
              self.showPermissionDenied("麦克风")
              completion(false)
            } else {
              completion(true)
            }
          }
        }
        if #available(iOS 17.0, *) {
          AVAudioApplication.requestRecordPermission(completionHandler: micHandler)
        } else {
          AVAudioSession.sharedInstance().requestRecordPermission(micHandler)
        }
      }
    }
  }

  private func showPermissionDenied(_ what: String) {
    hintLabel.text = "\(what)权限被拒绝，点 ⌨ 切到键盘"
    hintLabel.textColor = .systemRed
  }

  // MARK: - Recording

  private func startRecording() {
    guard let recognizer, recognizer.isAvailable else {
      hintLabel.text = "识别服务不可用"
      hintLabel.textColor = .systemRed
      return
    }

    task?.cancel()
    task = nil

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      hintLabel.text = "音频会话失败: \(error.localizedDescription)"
      hintLabel.textColor = .systemRed
      return
    }

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    request = req

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.request?.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      hintLabel.text = "录音启动失败: \(error.localizedDescription)"
      hintLabel.textColor = .systemRed
      return
    }

    isRecording = true

    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      guard let self else { return }
      if let result {
        let text = result.bestTranscription.formattedString
        DispatchQueue.main.async {
          guard self.isRecording else { return }
          self.setText(text)
        }
      }
      if error != nil {
        DispatchQueue.main.async {
          if let err = error {
            self.hintLabel.text = "识别失败: \(err.localizedDescription)"
          }
        }
      }
    }
  }

  private func stopRecording() {
    guard isRecording else { return }
    isRecording = false
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    request?.endAudio()
    request = nil
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}


final class AITextPolisher {
  static let shared = AITextPolisher()

  private let kAPIKey = "VoiceInputView.aiAPIKey"
  private let kModel = "VoiceInputView.aiModel"
  private let kBaseURL = "VoiceInputView.aiBaseURL"
  private let kEnabled = "VoiceInputView.aiEnabled"
  private let kDebounce = "VoiceInputView.aiDebounce"
  private let kHistory = "VoiceInputView.aiHistory"
  private let maxHistory = 30

  private init() {
    UserDefaults.standard.register(defaults: [
      kAPIKey: "",
      kModel: "glm-4.5",
      kBaseURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
      kEnabled: true,
      kDebounce: 3.5,
    ])
  }

  var apiKey: String {
    get { UserDefaults.standard.string(forKey: kAPIKey) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: kAPIKey) }
  }
  var model: String {
    get { UserDefaults.standard.string(forKey: kModel) ?? "glm-4.5" }
    set { UserDefaults.standard.set(newValue, forKey: kModel) }
  }
  var baseURL: String {
    get { UserDefaults.standard.string(forKey: kBaseURL) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: kBaseURL) }
  }
  var enabled: Bool {
    get { UserDefaults.standard.bool(forKey: kEnabled) }
    set { UserDefaults.standard.set(newValue, forKey: kEnabled) }
  }
  var debounceSeconds: Double {
    get {
      let v = UserDefaults.standard.double(forKey: kDebounce)
      return v <= 0 ? 3.5 : v
    }
    set { UserDefaults.standard.set(newValue, forKey: kDebounce) }
  }

  private let systemPrompt = """
    你是一个语音转文字的清理助手。我会给你：
    1. 用户近期已提交的输入（作为上下文，里面包含用户常用的术语、命令、专有名词、代码标识符）
    2. 这一次的语音识别结果

    任务：
    1. 根据上下文修正语音识别明显错听的词或词组（例如把"给客密"还原为"git commit"，把"倒克尔"还原为"docker"，把"卡了带"还原为"Claude"等）
    2. 清理口语化卡顿（嗯、啊、那个、就是、就是说）、重复字词、自我修正

    严格遵守：
    - 不要润色、不要换说法、不要美化用词
    - 不要补充原文没有的内容
    - 不要修改原文的语义；若上下文里没出现过的词不要强行替换
    - 如果原文已经通顺无错听，原样输出
    - 只输出清理后的文本，不要解释、不要加引号、不要 markdown、不要前后空白
    """

  func recordHistory(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var arr = UserDefaults.standard.stringArray(forKey: kHistory) ?? []
    arr.append(trimmed)
    if arr.count > maxHistory {
      arr.removeFirst(arr.count - maxHistory)
    }
    UserDefaults.standard.set(arr, forKey: kHistory)
  }

  private func historyBlock() -> String {
    let arr = UserDefaults.standard.stringArray(forKey: kHistory) ?? []
    guard !arr.isEmpty else { return "" }
    let recent = arr.suffix(maxHistory).reversed()
    let body = recent.map { "- \($0)" }.joined(separator: "\n")
    return "\n\n用户近期已提交的输入（按从新到旧）：\n\(body)"
  }

  func polish(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
    guard !apiKey.isEmpty, let url = URL(string: baseURL) else {
      DispatchQueue.main.async {
        completion(.failure(NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "未配置"])))
      }
      return
    }
    let fullSystem = systemPrompt + historyBlock()
    let payload: [String: Any] = [
      "model": model,
      "messages": [
        ["role": "system", "content": fullSystem],
        ["role": "user", "content": "本次识别结果：\n\(text)"],
      ],
      "temperature": 0.3,
      "stream": false,
    ]
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 15
    req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    URLSession.shared.dataTask(with: req) { data, _, error in
      if let error {
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }
      guard let data,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        DispatchQueue.main.async {
          completion(.failure(NSError(domain: "AI", code: -2, userInfo: [NSLocalizedDescriptionKey: "解析失败"])))
        }
        return
      }
      if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
        DispatchQueue.main.async {
          completion(.failure(NSError(domain: "AI", code: -3, userInfo: [NSLocalizedDescriptionKey: msg])))
        }
        return
      }
      guard let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String else {
        DispatchQueue.main.async {
          completion(.failure(NSError(domain: "AI", code: -4, userInfo: [NSLocalizedDescriptionKey: "返回格式异常"])))
        }
        return
      }
      let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
      DispatchQueue.main.async { completion(.success(cleaned)) }
    }.resume()
  }
}

final class VoiceSettingsViewController: UITableViewController {
  private weak var voiceView: VoiceInputView?

  init(voiceView: VoiceInputView?) {
    self.voiceView = voiceView
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "语音输入设置"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(closeTapped)
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    tableView.reloadData()
  }

  @objc private func closeTapped() { dismiss(animated: true) }

  override func numberOfSections(in tableView: UITableView) -> Int { 2 }

  override func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
    ["识别", "AI 整理"][section]
  }

  override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    [1, 2][section]
  }

  override func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
    cell.selectionStyle = .default
    switch (indexPath.section, indexPath.row) {
    case (0, 0):
      cell.textLabel?.text = "识别语言"
      cell.detailTextLabel?.text = voiceView?.currentLocaleTitleForSettings() ?? "—"
      cell.accessoryType = .disclosureIndicator
    case (1, 0):
      cell.textLabel?.text = "AI 整理"
      let sw = UISwitch()
      sw.isOn = AITextPolisher.shared.enabled
      sw.addTarget(self, action: #selector(toggleAI(_:)), for: .valueChanged)
      cell.accessoryView = sw
      cell.selectionStyle = .none
    case (1, 1):
      cell.textLabel?.text = "AI 配置"
      cell.detailTextLabel?.text = AITextPolisher.shared.model
      cell.accessoryType = .disclosureIndicator
    default: break
    }
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: true)
    switch (indexPath.section, indexPath.row) {
    case (0, 0):
      let picker = LanguagePickerViewController()
      picker.voiceView = voiceView
      navigationController?.pushViewController(picker, animated: true)
    case (1, 1):
      presentAISettings()
    default: break
    }
  }

  @objc private func toggleAI(_ sw: UISwitch) {
    AITextPolisher.shared.enabled = sw.isOn
    voiceView?.setHintForSettingsChange(sw.isOn ? "AI 整理已开启" : "AI 整理已关闭")
  }

  private func presentAISettings() {
    let alert = UIAlertController(title: "AI 配置", message: "兼容 OpenAI 协议（智谱 GLM 等）", preferredStyle: .alert)
    alert.addTextField { tf in
      tf.placeholder = "API Key"
      tf.text = AITextPolisher.shared.apiKey
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
      tf.clearButtonMode = .whileEditing
    }
    alert.addTextField { tf in
      tf.placeholder = "模型 (如 glm-4.5)"
      tf.text = AITextPolisher.shared.model
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
    }
    alert.addTextField { tf in
      tf.placeholder = "Base URL"
      tf.text = AITextPolisher.shared.baseURL
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
      tf.keyboardType = .URL
    }
    alert.addTextField { tf in
      tf.placeholder = "停顿延迟（秒，默认 3.5）"
      tf.text = String(format: "%.1f", AITextPolisher.shared.debounceSeconds)
      tf.keyboardType = .decimalPad
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
      let fields = alert.textFields ?? []
      if fields.indices.contains(0), let k = fields[0].text { AITextPolisher.shared.apiKey = k }
      if fields.indices.contains(1), let m = fields[1].text, !m.isEmpty { AITextPolisher.shared.model = m }
      if fields.indices.contains(2), let u = fields[2].text, !u.isEmpty { AITextPolisher.shared.baseURL = u }
      if fields.indices.contains(3), let s = fields[3].text, let d = Double(s), d > 0 {
        AITextPolisher.shared.debounceSeconds = d
      }
      self?.tableView.reloadData()
    })
    present(alert, animated: true)
  }
}

final class LanguagePickerViewController: UITableViewController {
  weak var voiceView: VoiceInputView?
  private let locales = VoiceInputView.supportedLocalesPublic

  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "识别语言"
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    locales.count
  }
  override func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    let entry = locales[indexPath.row]
    cell.textLabel?.text = entry.title
    cell.accessoryType = (entry.id == voiceView?.localeIdentifierForSettings) ? .checkmark : .none
    return cell
  }
  override func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: true)
    let entry = locales[indexPath.row]
    voiceView?.setLocaleIdentifierFromSettings(entry.id)
    tv.reloadData()
  }
}

final class VoiceEditTextViewController: UIViewController {
  private let textView = UITextView()
  var initialText: String = ""
  var onDone: ((String) -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = "编辑识别结果"

    textView.font = .systemFont(ofSize: 18)
    textView.text = initialText
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.autocorrectionType = .no
    textView.spellCheckingType = .no
    textView.smartDashesType = .no
    textView.smartQuotesType = .no
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel,
      target: self,
      action: #selector(cancelTapped)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(doneTapped)
    )
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    textView.becomeFirstResponder()
    let end = textView.text.count
    textView.selectedRange = NSRange(location: end, length: 0)
  }

  @objc private func cancelTapped() {
    dismiss(animated: true)
  }

  @objc private func doneTapped() {
    onDone?(textView.text ?? "")
    dismiss(animated: true)
  }
}

