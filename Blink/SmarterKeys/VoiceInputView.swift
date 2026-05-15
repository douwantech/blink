import UIKit
import Speech
import AVFoundation
import AudioToolbox
import PhotosUI

enum VoiceInputArrow {
  case up, down, left, right
}

protocol VoiceInputViewDelegate: AnyObject {
  func voiceInput(_ view: VoiceInputView, didCommitText text: String)
  func voiceInputDidRequestKeyboard(_ view: VoiceInputView)
  func voiceInputDidRequestDismiss(_ view: VoiceInputView)
  func voiceInputDidRequestSendEsc(_ view: VoiceInputView)
  func voiceInputDidRequestClearLine(_ view: VoiceInputView)
  func voiceInputDidRequestCloseTab(_ view: VoiceInputView)
  func voiceInputDidRequestReloadTab(_ view: VoiceInputView)
  func voiceInput(_ view: VoiceInputView, didRequestSendArrow direction: VoiceInputArrow)
  func voiceInputDidRequestSendReturn(_ view: VoiceInputView)
  func voiceInputDidRequestCopyLastResponse(_ view: VoiceInputView)
  func voiceInputDidRequestPaste(_ view: VoiceInputView)
  func voiceInput(_ view: VoiceInputView, didRequestPasteText text: String)
}

final class VoiceInputView: UIInputView {

  weak var delegate: VoiceInputViewDelegate?

  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let placeholderText = "点击下方按钮开始说话"
  private let micButton = UIButton(type: .custom)
  private let pulseRing = UIView()
  private var hintDotsTimer: Timer?
  private var hintDotsStep = 0

  private let thinkingOverlay = UIView()
  private let thinkingImageView = UIImageView()
  private let thinkingLabel = UILabel()
  private var thinkingDotsTimer: Timer?
  private var thinkingDotsStep = 0
  private let confirmButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  private let keyboardButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private let minimizeButton = UIButton(type: .system)
  private let escButton = UIButton(type: .system)
  private let clearTextButton = UIButton(type: .system)
  private let claudeButton = UIButton(type: .system)
  private let reloadButton = UIButton(type: .system)
  private let closeTabButton = UIButton(type: .system)
  private let hintLabel = UILabel()
  private let arrowPadContainer = UIView()
  private let arrowUpButton = UIButton(type: .system)
  private let arrowDownButton = UIButton(type: .system)
  private let arrowLeftButton = UIButton(type: .system)
  private let arrowRightButton = UIButton(type: .system)
  private let returnButton = UIButton(type: .system)
  private let copyLastButton = UIButton(type: .system)
  private let pasteButton = UIButton(type: .system)
  private let imagePickButton = UIButton(type: .system)

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
    NotificationCenter.default.addObserver(
      self, selector: #selector(activeSessionDidChange),
      name: .blinkActiveSessionDidChange, object: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func activeSessionDidChange() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshSettingsButtonTitle()
      if self.isRecording {
        self.setMicButtonRecording(false)
        self.stopRecording()
      }
      self.delegate?.voiceInputDidRequestDismiss(self)
    }
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 260)
  }

  private func setupUI() {
    textView.font = .systemFont(ofSize: 18, weight: .regular)
    textView.textColor = .label
    textView.backgroundColor = .clear
    textView.textAlignment = .center
    textView.isScrollEnabled = false
    textView.isEditable = false
    textView.isSelectable = false
    textView.panGestureRecognizer.isEnabled = false
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

    let brainConfig = UIImage.SymbolConfiguration(pointSize: 38, weight: .regular)
    if #available(iOS 18.1, *),
       let intel = UIImage(systemName: "apple.intelligence",
                           withConfiguration: brainConfig.applying(UIImage.SymbolConfiguration.preferringMulticolor())) {
      thinkingImageView.image = intel
    } else {
      thinkingImageView.image = UIImage(systemName: "sparkles", withConfiguration: brainConfig)
      thinkingImageView.tintColor = .systemBlue
    }
    thinkingImageView.contentMode = .scaleAspectFit
    thinkingImageView.translatesAutoresizingMaskIntoConstraints = false

    thinkingLabel.text = "AI 整理中…"
    thinkingLabel.font = .systemFont(ofSize: 13, weight: .medium)
    thinkingLabel.textColor = .systemBlue
    thinkingLabel.textAlignment = .center
    thinkingLabel.translatesAutoresizingMaskIntoConstraints = false

    thinkingOverlay.translatesAutoresizingMaskIntoConstraints = false
    thinkingOverlay.isUserInteractionEnabled = false
    thinkingOverlay.isHidden = true
    thinkingOverlay.addSubview(thinkingImageView)
    thinkingOverlay.addSubview(thinkingLabel)

    pulseRing.backgroundColor = UIColor.systemRed
    pulseRing.layer.cornerRadius = 22
    pulseRing.alpha = 0
    pulseRing.isUserInteractionEnabled = false
    pulseRing.translatesAutoresizingMaskIntoConstraints = false

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

    settingsButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
    settingsButton.titleLabel?.lineBreakMode = .byTruncatingTail
    settingsButton.setTitleColor(.secondaryLabel, for: .normal)
    settingsButton.contentHorizontalAlignment = .center
    settingsButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
    settingsButton.layer.cornerRadius = 6
    settingsButton.layer.borderWidth = 1
    settingsButton.layer.borderColor = UIColor.secondaryLabel.withAlphaComponent(0.5).cgColor
    settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
    refreshSettingsButtonTitle()

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

    closeTabButton.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
    closeTabButton.tintColor = .systemRed
    closeTabButton.addTarget(self, action: #selector(closeTabTapped), for: .touchUpInside)

    clearTextButton.setTitle("Clear", for: .normal)
    clearTextButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    clearTextButton.setTitleColor(.secondaryLabel, for: .normal)
    clearTextButton.layer.borderColor = UIColor.secondaryLabel.cgColor
    clearTextButton.layer.borderWidth = 1
    clearTextButton.layer.cornerRadius = 6
    clearTextButton.addTarget(self, action: #selector(clearTextTapped), for: .touchUpInside)

    claudeButton.setTitle("Claude", for: .normal)
    claudeButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    claudeButton.setTitleColor(.systemOrange, for: .normal)
    claudeButton.layer.borderColor = UIColor.systemOrange.cgColor
    claudeButton.layer.borderWidth = 1
    claudeButton.layer.cornerRadius = 6
    claudeButton.addTarget(self, action: #selector(claudeTapped), for: .touchUpInside)

    reloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
    reloadButton.tintColor = .systemTeal
    reloadButton.layer.borderColor = UIColor.systemTeal.cgColor
    reloadButton.layer.borderWidth = 1
    reloadButton.layer.cornerRadius = 6
    reloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)

    configureArrowButton(arrowUpButton, systemName: "arrow.up", action: #selector(arrowUpTapped))
    configureArrowButton(arrowDownButton, systemName: "arrow.down", action: #selector(arrowDownTapped))
    configureArrowButton(arrowLeftButton, systemName: "arrow.left", action: #selector(arrowLeftTapped))
    configureArrowButton(arrowRightButton, systemName: "arrow.right", action: #selector(arrowRightTapped))
    configureArrowButton(returnButton, systemName: "return", action: #selector(returnTapped))
    returnButton.tintColor = .systemBlue
    returnButton.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
    returnButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold), forImageIn: .normal)

    configureArrowButton(copyLastButton, systemName: "doc.on.clipboard", action: #selector(copyLastTapped))
    copyLastButton.tintColor = .systemGreen
    copyLastButton.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.6).cgColor

    configureArrowButton(pasteButton, systemName: "arrow.down.doc", action: #selector(pasteTapped))
    pasteButton.tintColor = .systemPurple
    pasteButton.layer.borderColor = UIColor.systemPurple.withAlphaComponent(0.6).cgColor

    configureArrowButton(imagePickButton, systemName: "photo.on.rectangle", action: #selector(imagePickTapped))
    imagePickButton.tintColor = .systemOrange
    imagePickButton.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.6).cgColor

    hintLabel.font = .systemFont(ofSize: 13)
    hintLabel.textColor = .tertiaryLabel
    hintLabel.textAlignment = .center
    hintLabel.text = currentLocaleTitle()
    hintLabel.isHidden = true

    [textView, placeholderLabel, micButton, confirmButton, cancelButton, keyboardButton, settingsButton, minimizeButton, escButton, clearTextButton, claudeButton, reloadButton, closeTabButton, hintLabel, arrowPadContainer].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }
    insertSubview(pulseRing, belowSubview: micButton)
    addSubview(thinkingOverlay)
    [arrowUpButton, arrowDownButton, arrowLeftButton, arrowRightButton, returnButton, copyLastButton, pasteButton, imagePickButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      arrowPadContainer.addSubview($0)
    }

    NSLayoutConstraint.activate([
      settingsButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      settingsButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      settingsButton.heightAnchor.constraint(equalToConstant: 32),

      closeTabButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 4),
      closeTabButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
      closeTabButton.widthAnchor.constraint(equalToConstant: 28),
      closeTabButton.heightAnchor.constraint(equalToConstant: 28),
      closeTabButton.trailingAnchor.constraint(lessThanOrEqualTo: keyboardButton.leadingAnchor, constant: -8),

      minimizeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      minimizeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      minimizeButton.widthAnchor.constraint(equalToConstant: 40),
      minimizeButton.heightAnchor.constraint(equalToConstant: 32),

      keyboardButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      keyboardButton.trailingAnchor.constraint(equalTo: minimizeButton.leadingAnchor, constant: -4),
      keyboardButton.widthAnchor.constraint(equalToConstant: 40),
      keyboardButton.heightAnchor.constraint(equalToConstant: 32),

      clearTextButton.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 6),
      clearTextButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      clearTextButton.widthAnchor.constraint(equalToConstant: 56),
      clearTextButton.heightAnchor.constraint(equalToConstant: 30),

      escButton.centerYAnchor.constraint(equalTo: clearTextButton.centerYAnchor),
      escButton.leadingAnchor.constraint(equalTo: clearTextButton.trailingAnchor, constant: 6),
      escButton.widthAnchor.constraint(equalToConstant: 44),
      escButton.heightAnchor.constraint(equalToConstant: 30),

      claudeButton.centerYAnchor.constraint(equalTo: clearTextButton.centerYAnchor),
      claudeButton.leadingAnchor.constraint(equalTo: escButton.trailingAnchor, constant: 6),
      claudeButton.widthAnchor.constraint(equalToConstant: 64),
      claudeButton.heightAnchor.constraint(equalToConstant: 30),

      reloadButton.centerYAnchor.constraint(equalTo: clearTextButton.centerYAnchor),
      reloadButton.leadingAnchor.constraint(equalTo: claudeButton.trailingAnchor, constant: 6),
      reloadButton.widthAnchor.constraint(equalToConstant: 38),
      reloadButton.heightAnchor.constraint(equalToConstant: 30),

      textView.topAnchor.constraint(equalTo: clearTextButton.bottomAnchor, constant: 4),
      textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      textView.trailingAnchor.constraint(equalTo: arrowPadContainer.leadingAnchor, constant: -8),
      textView.bottomAnchor.constraint(equalTo: micButton.topAnchor, constant: -8),

      arrowPadContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      arrowPadContainer.centerYAnchor.constraint(equalTo: textView.centerYAnchor, constant: -10),
      arrowPadContainer.widthAnchor.constraint(equalToConstant: 110),
      arrowPadContainer.heightAnchor.constraint(equalToConstant: 144),

      arrowUpButton.topAnchor.constraint(equalTo: arrowPadContainer.topAnchor),
      arrowUpButton.centerXAnchor.constraint(equalTo: arrowPadContainer.centerXAnchor),
      arrowUpButton.widthAnchor.constraint(equalToConstant: 34),
      arrowUpButton.heightAnchor.constraint(equalToConstant: 30),

      arrowLeftButton.topAnchor.constraint(equalTo: arrowUpButton.bottomAnchor, constant: 4),
      arrowLeftButton.leadingAnchor.constraint(equalTo: arrowPadContainer.leadingAnchor),
      arrowLeftButton.widthAnchor.constraint(equalToConstant: 34),
      arrowLeftButton.heightAnchor.constraint(equalToConstant: 30),

      arrowDownButton.topAnchor.constraint(equalTo: arrowUpButton.bottomAnchor, constant: 4),
      arrowDownButton.centerXAnchor.constraint(equalTo: arrowPadContainer.centerXAnchor),
      arrowDownButton.widthAnchor.constraint(equalToConstant: 34),
      arrowDownButton.heightAnchor.constraint(equalToConstant: 30),

      arrowRightButton.topAnchor.constraint(equalTo: arrowUpButton.bottomAnchor, constant: 4),
      arrowRightButton.trailingAnchor.constraint(equalTo: arrowPadContainer.trailingAnchor),
      arrowRightButton.widthAnchor.constraint(equalToConstant: 34),
      arrowRightButton.heightAnchor.constraint(equalToConstant: 30),

      returnButton.topAnchor.constraint(equalTo: arrowLeftButton.bottomAnchor, constant: 4),
      returnButton.leadingAnchor.constraint(equalTo: arrowPadContainer.leadingAnchor),
      returnButton.trailingAnchor.constraint(equalTo: arrowPadContainer.trailingAnchor),
      returnButton.heightAnchor.constraint(equalToConstant: 36),

      copyLastButton.topAnchor.constraint(equalTo: returnButton.bottomAnchor, constant: 4),
      copyLastButton.leadingAnchor.constraint(equalTo: arrowPadContainer.leadingAnchor),
      copyLastButton.widthAnchor.constraint(equalToConstant: 30),
      copyLastButton.heightAnchor.constraint(equalToConstant: 30),

      imagePickButton.topAnchor.constraint(equalTo: returnButton.bottomAnchor, constant: 4),
      imagePickButton.centerXAnchor.constraint(equalTo: arrowPadContainer.centerXAnchor),
      imagePickButton.widthAnchor.constraint(equalToConstant: 30),
      imagePickButton.heightAnchor.constraint(equalToConstant: 30),

      pasteButton.topAnchor.constraint(equalTo: returnButton.bottomAnchor, constant: 4),
      pasteButton.trailingAnchor.constraint(equalTo: arrowPadContainer.trailingAnchor),
      pasteButton.widthAnchor.constraint(equalToConstant: 30),
      pasteButton.heightAnchor.constraint(equalToConstant: 30),

      placeholderLabel.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
      placeholderLabel.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
      placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textView.leadingAnchor, constant: 8),
      placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -8),

      micButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      micButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
      micButton.widthAnchor.constraint(equalToConstant: 44),
      micButton.heightAnchor.constraint(equalToConstant: 44),

      pulseRing.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
      pulseRing.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
      pulseRing.widthAnchor.constraint(equalTo: micButton.widthAnchor),
      pulseRing.heightAnchor.constraint(equalTo: micButton.heightAnchor),

      thinkingOverlay.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
      thinkingOverlay.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
      thinkingImageView.topAnchor.constraint(equalTo: thinkingOverlay.topAnchor),
      thinkingImageView.centerXAnchor.constraint(equalTo: thinkingOverlay.centerXAnchor),
      thinkingImageView.widthAnchor.constraint(equalToConstant: 44),
      thinkingImageView.heightAnchor.constraint(equalToConstant: 44),
      thinkingLabel.topAnchor.constraint(equalTo: thinkingImageView.bottomAnchor, constant: 6),
      thinkingLabel.centerXAnchor.constraint(equalTo: thinkingOverlay.centerXAnchor),
      thinkingLabel.leadingAnchor.constraint(equalTo: thinkingOverlay.leadingAnchor),
      thinkingLabel.trailingAnchor.constraint(equalTo: thinkingOverlay.trailingAnchor),
      thinkingLabel.bottomAnchor.constraint(equalTo: thinkingOverlay.bottomAnchor),

      cancelButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
      cancelButton.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 8),
      cancelButton.widthAnchor.constraint(equalToConstant: 72),
      cancelButton.heightAnchor.constraint(equalToConstant: 36),

      confirmButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
      confirmButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 8),
      confirmButton.widthAnchor.constraint(equalToConstant: 78),
      confirmButton.heightAnchor.constraint(equalToConstant: 36),

      hintLabel.leadingAnchor.constraint(equalTo: confirmButton.trailingAnchor, constant: 8),
      hintLabel.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
      hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: arrowPadContainer.leadingAnchor, constant: -8),
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

  private func polishText(rawText: String? = nil) {
    let source: String
    if let raw = rawText {
      source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      source = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !source.isEmpty else { return }
    guard AITextPolisher.shared.enabled, !AITextPolisher.shared.apiKey.isEmpty else {
      // polish 不可用：fallback 直接显示 raw
      if rawText != nil { setText(source) }
      return
    }
    guard !isPolishing else { return }
    isPolishing = true
    startThinkingAnimation()
    AITextPolisher.shared.polish(source) { [weak self] result in
      guard let self else { return }
      self.isPolishing = false
      self.stopThinkingAnimation()
      switch result {
      case .success(let polished):
        self.setText(polished)
        self.hintLabel.text = "已整理 · \(self.currentLocaleTitle())"
        self.hintLabel.textColor = .tertiaryLabel
      case .failure(let err):
        self.setText(source)  // polish 失败 fallback 到 ASR 原文
        self.hintLabel.text = self.currentLocaleTitle()
        self.hintLabel.textColor = .tertiaryLabel
        self.showToast("AI 整理失败: \(err.localizedDescription)", isError: true)
      }
    }
  }

  private func startThinkingAnimation() {
    thinkingOverlay.isHidden = false
    placeholderLabel.isHidden = true
    bringSubviewToFront(thinkingOverlay)

    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1.0
    scale.toValue = 1.18
    scale.duration = 0.8
    scale.autoreverses = true
    scale.repeatCount = .infinity
    scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    thinkingImageView.layer.add(scale, forKey: "brain.pulse")

    thinkingDotsTimer?.invalidate()
    thinkingDotsStep = 0
    thinkingDotsTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.thinkingDotsStep = (self.thinkingDotsStep + 1) % 4
      let dots = String(repeating: "·", count: max(self.thinkingDotsStep, 1))
      self.thinkingLabel.text = "AI 整理中 \(dots)"
    }
  }

  private func stopThinkingAnimation() {
    thinkingOverlay.isHidden = true
    thinkingImageView.layer.removeAllAnimations()
    thinkingDotsTimer?.invalidate()
    thinkingDotsTimer = nil
    updatePlaceholderVisibility()
  }

  func showToast(_ message: String, isError: Bool = false) {
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
      container.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 60),
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
    if recording {
      startPulseAnimation()
      startHintDotsAnimation()
    } else {
      stopPulseAnimation()
      stopHintDotsAnimation()
      hintLabel.text = currentLocaleTitle()
    }
  }

  private func startPulseAnimation() {
    pulseRing.layer.removeAllAnimations()
    pulseRing.alpha = 1.0

    let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
    scaleAnim.fromValue = 1.0
    scaleAnim.toValue = 1.8
    scaleAnim.duration = 1.2
    scaleAnim.repeatCount = .infinity
    scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
    pulseRing.layer.add(scaleAnim, forKey: "pulse.scale")

    let opacityAnim = CABasicAnimation(keyPath: "opacity")
    opacityAnim.fromValue = 0.55
    opacityAnim.toValue = 0.0
    opacityAnim.duration = 1.2
    opacityAnim.repeatCount = .infinity
    opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
    pulseRing.layer.add(opacityAnim, forKey: "pulse.opacity")
  }

  private func stopPulseAnimation() {
    pulseRing.layer.removeAllAnimations()
    pulseRing.alpha = 0
  }

  private func startHintDotsAnimation() {
    hintDotsTimer?.invalidate()
    hintDotsStep = 0
    hintLabel.text = "正在听 · 点击结束"
    hintLabel.textColor = .systemRed
    hintDotsTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.hintDotsStep = (self.hintDotsStep + 1) % 4
      let dots = String(repeating: "·", count: max(self.hintDotsStep, 1))
      self.hintLabel.text = "正在听 \(dots) 点击结束"
    }
  }

  private func stopHintDotsAnimation() {
    hintDotsTimer?.invalidate()
    hintDotsTimer = nil
  }

  @objc private func commitTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    AITextPolisher.shared.recordHistory(text)
    if let raw = lastAsrRaw {
      AITextPolisher.shared.recordCorrection(asrRaw: raw, final: text)
    }
    lastAsrRaw = nil
    delegate?.voiceInput(self, didCommitText: text)
    setText("")
    delegate?.voiceInputDidRequestDismiss(self)
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

  @objc private func claudeTapped() {
    let entries: [(label: String, command: String)] = [
      ("cc · 自定义快捷", "cc"),
      ("/resume · 恢复会话", "/resume"),
      ("/exit · 退出 Claude Code", "/exit"),
      ("claude · 新会话", "claude"),
      ("claude -c · 继续上次会话", "claude -c"),
      ("claude -r · 选择会话恢复", "claude -r"),
      ("claude --print · 非交互一次性问答", "claude --print "),
      ("claude --version", "claude --version"),
      ("claude --help", "claude --help"),
      ("/clear · 清空当前对话", "/clear"),
      ("/compact · 压缩上下文", "/compact"),
      ("/init · 生成 CLAUDE.md", "/init"),
      ("/rewind · 回退代码/对话（或连按两下 Esc）", "/rewind"),
      ("/agents · 子代理", "/agents"),
      ("/mcp · MCP 服务器", "/mcp"),
      ("/model · 切换模型", "/model"),
      ("/review · 代码评审", "/review"),
      ("/security-review · 安全评审", "/security-review"),
      ("/help · 帮助", "/help"),
    ]
    let alert = UIAlertController(title: "Claude 命令", message: "选中后直接发送到当前会话", preferredStyle: .actionSheet)
    for entry in entries {
      alert.addAction(UIAlertAction(title: entry.label, style: .default) { [weak self] _ in
        guard let self else { return }
        self.delegate?.voiceInput(self, didCommitText: entry.command)
        self.delegate?.voiceInputDidRequestDismiss(self)
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let pop = alert.popoverPresentationController {
      pop.sourceView = claudeButton
      pop.sourceRect = claudeButton.bounds
    }
    findViewController()?.present(alert, animated: true)
  }

  @objc private func reloadTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    delegate?.voiceInputDidRequestReloadTab(self)
    showToast("关闭并重开 tab…")
  }

  @objc private func escTapped() {
    if isRecording {
      setMicButtonRecording(false)
      stopRecording()
    }
    delegate?.voiceInputDidRequestSendEsc(self)
  }

  private func configureArrowButton(_ button: UIButton, systemName: String, action: Selector) {
    let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    button.setImage(UIImage(systemName: systemName, withConfiguration: cfg), for: .normal)
    button.tintColor = .label
    button.layer.borderColor = UIColor.secondaryLabel.withAlphaComponent(0.4).cgColor
    button.layer.borderWidth = 1
    button.layer.cornerRadius = 6
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  @objc private func arrowUpTapped() {
    delegate?.voiceInput(self, didRequestSendArrow: .up)
  }

  @objc private func arrowDownTapped() {
    delegate?.voiceInput(self, didRequestSendArrow: .down)
  }

  @objc private func arrowLeftTapped() {
    delegate?.voiceInput(self, didRequestSendArrow: .left)
  }

  @objc private func arrowRightTapped() {
    delegate?.voiceInput(self, didRequestSendArrow: .right)
  }

  @objc private func returnTapped() {
    delegate?.voiceInputDidRequestSendReturn(self)
  }

  @objc private func copyLastTapped() {
    delegate?.voiceInputDidRequestCopyLastResponse(self)
  }

  @objc private func pasteTapped() {
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      showToast("剪贴板是空的", isError: true)
      return
    }
    let vc = PasteSelectionViewController(text: text) { [weak self] selected in
      guard let self else { return }
      self.delegate?.voiceInput(self, didRequestPasteText: selected)
    }
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .fullScreen
    findViewController()?.present(nav, animated: true)
  }

  @objc private func imagePickTapped() {
    var cfg = PHPickerConfiguration()
    cfg.filter = .images
    cfg.selectionLimit = 1
    let picker = PHPickerViewController(configuration: cfg)
    picker.delegate = self
    findViewController()?.present(picker, animated: true)
  }

  @objc private func minimizeTapped() {
    if isRecording {
      stopRecording()
    }
    delegate?.voiceInputDidRequestDismiss(self)
  }

  @objc private func closeTabTapped() {
    let alert = UIAlertController(title: "关闭当前标签？", message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "关闭", style: .destructive) { [weak self] _ in
      guard let self else { return }
      self.delegate?.voiceInputDidRequestCloseTab(self)
    })
    findViewController()?.present(alert, animated: true)
  }

  @objc private func settingsTapped() {
    let mcp = MCPSession.currentActive()
    let vc = NewTabViewController(
      machineId: mcp?.sessionParams.machineId,
      workDirId: mcp?.sessionParams.workDirId,
      tmuxName: mcp?.sessionParams.tmuxSession
    )
    vc.customTitle = "切换机器 / 目录"
    vc.actionTitle = "应用"
    vc.onCreate = { [weak self] machineId, workDirId, tmuxSession in
      MCPSession.currentActive()?.switchToMachine(id: machineId, workDirId: workDirId, tmuxSession: tmuxSession)
      self?.refreshSettingsButtonTitle()
      NotificationCenter.default.post(name: .blinkActiveSessionDidChange, object: nil)
    }
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    findViewController()?.present(nav, animated: true)
  }

  func refreshSettingsButtonTitle() {
    let mcp = MCPSession.currentActive()
    let name = BlinkMachineStore.effectiveTmuxSessionName(
      workDirId: mcp?.sessionParams.workDirId,
      tmuxSession: mcp?.sessionParams.tmuxSession)
    settingsButton.setTitle(name, for: .normal)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      refreshSettingsButtonTitle()
    }
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

  private func showPermissionDenied(_ what: String) {
    hintLabel.text = "\(what)权限被拒绝，点 ⌨ 切到键盘"
    hintLabel.textColor = .systemRed
  }

  // MARK: - Recording

  private var glmRecorder: AVAudioRecorder?
  private var glmRecordedFileURL: URL?
  private var lastAsrRaw: String?

  private func startRecording() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
    } catch {
      hintLabel.text = "音频会话失败: \(error.localizedDescription)"
      hintLabel.textColor = .systemRed
      return
    }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    do {
      let r = try AVAudioRecorder(url: url, settings: settings)
      r.prepareToRecord()
      r.record()
      glmRecorder = r
      glmRecordedFileURL = url
      isRecording = true
    } catch {
      hintLabel.text = "录音启动失败: \(error.localizedDescription)"
      hintLabel.textColor = .systemRed
    }
  }

  private func stopRecording() {
    guard isRecording, let r = glmRecorder, let url = glmRecordedFileURL else {
      isRecording = false
      return
    }
    isRecording = false
    r.stop()
    glmRecorder = nil
    glmRecordedFileURL = nil

    let apiKey = AITextPolisher.shared.apiKey
    guard !apiKey.isEmpty else {
      hintLabel.text = "未配置 GLM API key（设置→AI 配置）"
      hintLabel.textColor = .systemRed
      try? FileManager.default.removeItem(at: url)
      return
    }

    hintLabel.text = "识别中…"
    hintLabel.textColor = .secondaryLabel

    GLMASRClient.transcribe(fileURL: url, apiKey: apiKey) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        try? FileManager.default.removeItem(at: url)
        switch result {
        case .success(let text):
          self.lastAsrRaw = text
          self.hintLabel.text = self.currentLocaleTitle()
          self.hintLabel.textColor = .tertiaryLabel
          self.polishText(rawText: text)
        case .failure(let err):
          self.hintLabel.text = "识别失败: \(err.localizedDescription)"
          self.hintLabel.textColor = .systemRed
        }
      }
    }
  }
}

enum GLMASRClient {
  private static let endpoint = "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions"
  private static let model = "glm-asr-2512"

  static func transcribe(fileURL: URL, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
    guard let url = URL(string: endpoint) else {
      completion(.failure(NSError(domain: "GLMASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad endpoint"])))
      return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let boundary = "Boundary-\(UUID().uuidString)"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    func append(_ s: String) { body.append(s.data(using: .utf8)!) }
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"stream\"\r\n\r\nfalse\r\n")
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
    if let data = try? Data(contentsOf: fileURL) { body.append(data) }
    append("\r\n--\(boundary)--\r\n")
    req.httpBody = body

    URLSession.shared.dataTask(with: req) { data, resp, err in
      if let err {
        completion(.failure(err))
        return
      }
      let http = resp as? HTTPURLResponse
      let status = http?.statusCode ?? -1
      guard status == 200,
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String else {
        let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let snippet = bodyText.prefix(200)
        completion(.failure(NSError(domain: "GLMASR", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(snippet)"])))
        return
      }
      completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }.resume()
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

extension VoiceInputView: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider,
          provider.canLoadObject(ofClass: UIImage.self) else {
      return
    }
    showToast("上传中…")
    provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
      guard let self else { return }
      guard let image = obj as? UIImage,
            let data = image.jpegData(compressionQuality: 0.75) else {
        DispatchQueue.main.async { self.showToast("图片加载失败", isError: true) }
        return
      }
      ImageHostUploader.upload(jpegData: data) { [weak self] url in
        DispatchQueue.main.async {
          guard let self else { return }
          if let url {
            UIPasteboard.general.string = url
            self.showToast("URL 已复制：\(url)")
          } else {
            self.showToast("上传失败", isError: true)
          }
        }
      }
    }
  }
}

enum ImageHostUploader {
  static func upload(jpegData: Data, completion: @escaping (String?) -> Void) {
    uploadTmpfiles(jpegData: jpegData) { url in
      if let url { completion(url); return }
      uploadUguu(jpegData: jpegData, completion: completion)
    }
  }

  private static func uploadTmpfiles(jpegData: Data, completion: @escaping (String?) -> Void) {
    guard let url = URL(string: "https://tmpfiles.org/api/v1/upload") else {
      completion(nil); return
    }
    let boundary = "Boundary-\(UUID().uuidString)"
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = multipartBody(fieldName: "file", filename: "image.jpg", mime: "image/jpeg", data: jpegData, boundary: boundary)
    URLSession.shared.dataTask(with: req) { data, _, _ in
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let inner = json["data"] as? [String: Any],
            var link = inner["url"] as? String else {
        completion(nil); return
      }
      link = link.replacingOccurrences(of: "http://", with: "https://")
      if !link.contains("/dl/") {
        link = link.replacingOccurrences(of: "tmpfiles.org/", with: "tmpfiles.org/dl/")
      }
      completion(link)
    }.resume()
  }

  private static func uploadUguu(jpegData: Data, completion: @escaping (String?) -> Void) {
    guard let url = URL(string: "https://uguu.se/upload") else {
      completion(nil); return
    }
    let boundary = "Boundary-\(UUID().uuidString)"
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = multipartBody(fieldName: "files[]", filename: "image.jpg", mime: "image/jpeg", data: jpegData, boundary: boundary)
    URLSession.shared.dataTask(with: req) { data, _, _ in
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [[String: Any]],
            let link = files.first?["url"] as? String else {
        completion(nil); return
      }
      completion(link)
    }.resume()
  }

  private static func multipartBody(fieldName: String, filename: String, mime: String, data: Data, boundary: String) -> Data {
    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
    body.append(data)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    return body
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
  private let kCorrections = "VoiceInputView.aiCorrections"
  private let maxHistory = 30
  private let maxCorrections = 30

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
    你是一个语音转文字的清理助手。**最重要的原则：尽可能保留用户原话，只做最少必要的修改。**

    我会给你：
    1. 用户近期已提交的输入（作为上下文，里面包含常用术语、命令、专有名词）
    2. 用户的修正记录（左=ASR 原文 右=用户改后版本）
    3. 这一次的语音识别结果

    任务（只做这两件，其他一律不动）：

    1. 修正 ASR 错听词。
       触发条件：候选词必须在「用户近期已提交的输入」或「用户的修正记录」里实际出现过，才允许替换。
       修正记录优先：如果当前 ASR 出现修正记录左边的词且上下文类似，按右边版本改。
       常见模式（仅当修正记录未覆盖时用）：
       - 中文同音/近音：历史里有 git commit → "给客密"改"git commit"；docker ← "倒克尔"；Claude ← "卡了带 / 卡老的 / cloud"
       - 英文同音 / 长短词：历史里有 tab → "table"改"tab"；shell ← share；grep ← grab；cd ← see d / seedy；push ← poosh
       - 中英混合句里的错词同样处理

    2. 清理明显的口语化卡顿（仅限：嗯、啊、呃、那个、就是、就是说）+ 紧邻的字词重复（说错后立刻改口的那一遍）。
       只删卡顿词本身和重复，不要重组剩下的句子。

    严格遵守：
    - **保守原则**：原文无 ASR 错听、无明显卡顿，就**原样输出**，一个字都不改
    - 不要润色、不要换说法、不要改句式、不要美化用词
    - 不要做指代消解（"那个 tab"、"刚才那个 bug" 原样保留，不要主动嵌 history 内容）
    - 不要把口语化请求"指令化"（"修一下"不要改成"修复"、"看一下"不要改成"检查"）
    - 不要补充原文没有的内容、不要扩展请求范围
    - 不要加礼貌语、不要加结尾问候
    - 保持原文的语言：英文输出英文，中文输出中文，中英混合保持混合；不要翻译
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

  var historyEntries: [String] {
    UserDefaults.standard.stringArray(forKey: kHistory) ?? []
  }

  func deleteHistory(at index: Int) {
    var arr = historyEntries
    guard arr.indices.contains(index) else { return }
    arr.remove(at: index)
    UserDefaults.standard.set(arr, forKey: kHistory)
  }

  func clearHistory() {
    UserDefaults.standard.removeObject(forKey: kHistory)
  }

  func recordCorrection(asrRaw: String, final: String) {
    let asrTrim = asrRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    let finTrim = final.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !asrTrim.isEmpty, !finTrim.isEmpty, asrTrim != finTrim else { return }
    var arr = UserDefaults.standard.array(forKey: kCorrections) as? [[String]] ?? []
    arr.append([asrTrim, finTrim])
    if arr.count > maxCorrections {
      arr.removeFirst(arr.count - maxCorrections)
    }
    UserDefaults.standard.set(arr, forKey: kCorrections)
  }

  var correctionEntries: [(asrRaw: String, final: String)] {
    let arr = UserDefaults.standard.array(forKey: kCorrections) as? [[String]] ?? []
    return arr.compactMap { pair in
      guard pair.count == 2 else { return nil }
      return (pair[0], pair[1])
    }
  }

  func deleteCorrection(at index: Int) {
    var arr = UserDefaults.standard.array(forKey: kCorrections) as? [[String]] ?? []
    guard arr.indices.contains(index) else { return }
    arr.remove(at: index)
    UserDefaults.standard.set(arr, forKey: kCorrections)
  }

  func clearCorrections() {
    UserDefaults.standard.removeObject(forKey: kCorrections)
  }

  private func historyBlock() -> String {
    var parts: [String] = []
    let history = UserDefaults.standard.stringArray(forKey: kHistory) ?? []
    if !history.isEmpty {
      let recent = history.suffix(maxHistory).reversed()
      let body = recent.map { "- \($0)" }.joined(separator: "\n")
      parts.append("用户近期已提交的输入（按从新到旧）：\n\(body)")
    }
    let corrections = correctionEntries
    if !corrections.isEmpty {
      let recent = corrections.suffix(maxCorrections).reversed()
      let body = recent.map { "- 「\($0.asrRaw)」 → 「\($0.final)」" }.joined(separator: "\n")
      parts.append("用户的修正记录（左=ASR 原文，右=用户改后的版本，按从新到旧）：\n\(body)")
    }
    guard !parts.isEmpty else { return "" }
    return "\n\n" + parts.joined(separator: "\n\n")
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

  override func numberOfSections(in tableView: UITableView) -> Int { 5 }

  override func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
    ["机器", "工作目录", "识别", "AI 整理", "实验"][section]
  }

  override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    [1, 1, 1, 3, 2][section]
  }

  override func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
    cell.selectionStyle = .default
    switch (indexPath.section, indexPath.row) {
    case (0, 0):
      cell.textLabel?.text = "机器"
      let m = BlinkMachineStore.shared.currentMachine
      cell.detailTextLabel?.text = m.map { "\($0.user)@\($0.host)" } ?? "未配置"
      cell.accessoryType = .disclosureIndicator
    case (1, 0):
      cell.textLabel?.text = "工作目录"
      cell.detailTextLabel?.text = "\(BlinkWorkDirStore.shared.workDirs.count) 个"
      cell.accessoryType = .disclosureIndicator
    case (2, 0):
      cell.textLabel?.text = "识别语言"
      cell.detailTextLabel?.text = voiceView?.currentLocaleTitleForSettings() ?? "—"
      cell.accessoryType = .disclosureIndicator
    case (3, 0):
      cell.textLabel?.text = "AI 整理"
      let sw = UISwitch()
      sw.isOn = AITextPolisher.shared.enabled
      sw.addTarget(self, action: #selector(toggleAI(_:)), for: .valueChanged)
      cell.accessoryView = sw
      cell.selectionStyle = .none
    case (3, 1):
      cell.textLabel?.text = "AI 配置"
      cell.detailTextLabel?.text = AITextPolisher.shared.model
      cell.accessoryType = .disclosureIndicator
    case (3, 2):
      cell.textLabel?.text = "提交历史"
      cell.detailTextLabel?.text = "\(AITextPolisher.shared.historyEntries.count) 条"
      cell.accessoryType = .disclosureIndicator
    case (4, 0):
      cell.textLabel?.text = "测试 GLM-ASR"
      cell.detailTextLabel?.text = "bigmodel.cn"
      cell.accessoryType = .disclosureIndicator
    case (4, 1):
      cell.textLabel?.text = "测试 Whisper"
      cell.detailTextLabel?.text = "api.openai.com"
      cell.accessoryType = .disclosureIndicator
    default: break
    }
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: true)
    switch (indexPath.section, indexPath.row) {
    case (0, 0):
      let list = MachineListViewController()
      navigationController?.pushViewController(list, animated: true)
    case (1, 0):
      let list = WorkDirListViewController()
      navigationController?.pushViewController(list, animated: true)
    case (2, 0):
      let picker = LanguagePickerViewController()
      picker.voiceView = voiceView
      navigationController?.pushViewController(picker, animated: true)
    case (3, 1):
      presentAISettings()
    case (3, 2):
      navigationController?.pushViewController(AIHistoryViewController(), animated: true)
    case (4, 0):
      navigationController?.pushViewController(ASRTestViewController(config: .glm), animated: true)
    case (4, 1):
      navigationController?.pushViewController(ASRTestViewController(config: .whisper), animated: true)
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

final class AIHistoryViewController: UITableViewController {
  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "提交历史"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "清空", style: .plain, target: self, action: #selector(clearTapped))
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 2 }

  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    if s == 0 { return max(AITextPolisher.shared.historyEntries.count, 1) }
    return max(AITextPolisher.shared.correctionEntries.count, 1)
  }

  override func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
    if s == 0 {
      let n = AITextPolisher.shared.historyEntries.count
      return n > 0 ? "提交记录（共 \(n) 条，新→旧）" : "提交记录"
    }
    let n = AITextPolisher.shared.correctionEntries.count
    return n > 0 ? "修正对（共 \(n) 对，左=ASR 原文，右=你改后版本）" : "修正对"
  }

  override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
    if s == 0 {
      return "每次在语音面板按提交时记一条；最多 30 条；作为上下文喂给 AI 整理。"
    }
    return "若 ASR 出文本后你做了修改，提交时把这对存下来。AI 整理会优先按这里的修正习惯改。最多 30 对。"
  }

  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    if ip.section == 0 {
      let entries = AITextPolisher.shared.historyEntries
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      if entries.isEmpty {
        cell.textLabel?.text = "暂无（提交后这里就会出现）"
        cell.textLabel?.textColor = .secondaryLabel
        cell.textLabel?.font = .systemFont(ofSize: 14)
        cell.selectionStyle = .none
      } else {
        let reversed = Array(entries.reversed())
        cell.textLabel?.text = reversed[ip.row]
        cell.textLabel?.numberOfLines = 0
        cell.selectionStyle = .none
      }
      return cell
    }
    let corrections = AITextPolisher.shared.correctionEntries
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    if corrections.isEmpty {
      cell.textLabel?.text = "暂无（语音转出文本后改一下再提交就会出现）"
      cell.textLabel?.textColor = .secondaryLabel
      cell.textLabel?.font = .systemFont(ofSize: 14)
      cell.selectionStyle = .none
      return cell
    }
    let reversed = Array(corrections.reversed())
    let pair = reversed[ip.row]
    cell.textLabel?.text = pair.final
    cell.textLabel?.numberOfLines = 0
    cell.detailTextLabel?.text = "原: \(pair.asrRaw)"
    cell.detailTextLabel?.numberOfLines = 0
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.selectionStyle = .none
    return cell
  }

  override func tableView(_ tv: UITableView, canEditRowAt ip: IndexPath) -> Bool {
    if ip.section == 0 { return !AITextPolisher.shared.historyEntries.isEmpty }
    return !AITextPolisher.shared.correctionEntries.isEmpty
  }

  override func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
    guard editingStyle == .delete else { return }
    if ip.section == 0 {
      let entries = AITextPolisher.shared.historyEntries
      let realIndex = entries.count - 1 - ip.row
      AITextPolisher.shared.deleteHistory(at: realIndex)
    } else {
      let corrections = AITextPolisher.shared.correctionEntries
      let realIndex = corrections.count - 1 - ip.row
      AITextPolisher.shared.deleteCorrection(at: realIndex)
    }
    tv.reloadData()
  }

  @objc private func clearTapped() {
    let historyN = AITextPolisher.shared.historyEntries.count
    let correctionN = AITextPolisher.shared.correctionEntries.count
    let alert = UIAlertController(title: "清空哪一项？", message: nil, preferredStyle: .actionSheet)
    if historyN > 0 {
      alert.addAction(UIAlertAction(title: "清空提交记录 (\(historyN))", style: .destructive) { [weak self] _ in
        AITextPolisher.shared.clearHistory()
        self?.tableView.reloadData()
      })
    }
    if correctionN > 0 {
      alert.addAction(UIAlertAction(title: "清空修正对 (\(correctionN))", style: .destructive) { [weak self] _ in
        AITextPolisher.shared.clearCorrections()
        self?.tableView.reloadData()
      })
    }
    if historyN > 0 && correctionN > 0 {
      alert.addAction(UIAlertAction(title: "全部清空", style: .destructive) { [weak self] _ in
        AITextPolisher.shared.clearHistory()
        AITextPolisher.shared.clearCorrections()
        self?.tableView.reloadData()
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let pop = alert.popoverPresentationController {
      pop.barButtonItem = navigationItem.rightBarButtonItem
    }
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


// MARK: - ASR Test Page (multipart /audio/transcriptions, OpenAI 兼容协议)

final class ASRTestViewController: UIViewController, AVAudioRecorderDelegate, UITextFieldDelegate {
  struct Config {
    let title: String
    let endpoint: String
    let defaultModel: String
    let apiKeyDefaultsKey: String
    let extraFormFields: [String: String]
  }

  private let config: Config
  private let modelField = UITextField()
  private let apiKeyField = UITextField()
  private let recordButton = UIButton(type: .system)
  private let statusLabel = UILabel()
  private let resultView = UITextView()
  private var recorder: AVAudioRecorder?
  private var fileURL: URL?
  private var recordStartedAt: Date?
  private var uploadStartedAt: Date?

  init(config: Config) {
    self.config = config
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = config.title
    view.backgroundColor = .systemBackground

    let modelLabel = UILabel()
    modelLabel.text = "model"
    modelLabel.font = .systemFont(ofSize: 14)
    modelLabel.translatesAutoresizingMaskIntoConstraints = false

    modelField.text = config.defaultModel
    modelField.borderStyle = .roundedRect
    modelField.autocapitalizationType = .none
    modelField.autocorrectionType = .no
    modelField.translatesAutoresizingMaskIntoConstraints = false

    let keyLabel = UILabel()
    keyLabel.text = "key"
    keyLabel.font = .systemFont(ofSize: 14)
    keyLabel.translatesAutoresizingMaskIntoConstraints = false

    apiKeyField.text = UserDefaults.standard.string(forKey: config.apiKeyDefaultsKey) ?? ""
    apiKeyField.placeholder = "API Key (Bearer …)"
    apiKeyField.borderStyle = .roundedRect
    apiKeyField.autocapitalizationType = .none
    apiKeyField.autocorrectionType = .no
    apiKeyField.isSecureTextEntry = true
    apiKeyField.clearButtonMode = .whileEditing
    apiKeyField.delegate = self
    apiKeyField.addTarget(self, action: #selector(saveKey), for: .editingDidEnd)
    apiKeyField.translatesAutoresizingMaskIntoConstraints = false

    recordButton.setTitle("● 开始录音", for: .normal)
    recordButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
    recordButton.setTitleColor(.systemRed, for: .normal)
    recordButton.layer.cornerRadius = 12
    recordButton.layer.borderWidth = 1
    recordButton.layer.borderColor = UIColor.separator.cgColor
    recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
    recordButton.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.text = "endpoint: \(config.endpoint)"
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabel
    statusLabel.numberOfLines = 0
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    resultView.font = .systemFont(ofSize: 16)
    resultView.layer.borderColor = UIColor.separator.cgColor
    resultView.layer.borderWidth = 1
    resultView.layer.cornerRadius = 8
    resultView.isEditable = false
    resultView.translatesAutoresizingMaskIntoConstraints = false

    [modelLabel, modelField, keyLabel, apiKeyField, recordButton, statusLabel, resultView].forEach { view.addSubview($0) }

    let g = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      modelLabel.topAnchor.constraint(equalTo: g.topAnchor, constant: 16),
      modelLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
      modelLabel.widthAnchor.constraint(equalToConstant: 50),
      modelField.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
      modelField.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 8),
      modelField.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),

      keyLabel.topAnchor.constraint(equalTo: modelField.bottomAnchor, constant: 12),
      keyLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
      keyLabel.widthAnchor.constraint(equalToConstant: 50),
      apiKeyField.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor),
      apiKeyField.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 8),
      apiKeyField.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),

      recordButton.topAnchor.constraint(equalTo: apiKeyField.bottomAnchor, constant: 16),
      recordButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
      recordButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
      recordButton.heightAnchor.constraint(equalToConstant: 60),

      statusLabel.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 12),
      statusLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),

      resultView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
      resultView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
      resultView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
      resultView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
    ])
  }

  func textFieldShouldReturn(_ tf: UITextField) -> Bool { tf.resignFirstResponder(); return true }

  @objc private func saveKey() {
    UserDefaults.standard.set(apiKeyField.text ?? "", forKey: config.apiKeyDefaultsKey)
  }

  @objc private func recordTapped() {
    apiKeyField.resignFirstResponder()
    modelField.resignFirstResponder()
    if recorder?.isRecording == true {
      stopAndUpload()
    } else {
      requestMicAndStart()
    }
  }

  private func requestMicAndStart() {
    AVAudioApplication.requestRecordPermission { [weak self] ok in
      DispatchQueue.main.async {
        guard let self else { return }
        if ok { self.startRecording() }
        else { self.statusLabel.text = "麦克风权限被拒绝" }
      }
    }
  }

  private func startRecording() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
    } catch {
      statusLabel.text = "AVSession 错误：\(error.localizedDescription)"
      return
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("asr-\(UUID().uuidString).wav")
    fileURL = url
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    do {
      let r = try AVAudioRecorder(url: url, settings: settings)
      r.delegate = self
      r.prepareToRecord()
      r.record()
      recorder = r
      recordStartedAt = Date()
      recordButton.setTitle("■ 停止 (录音中…)", for: .normal)
      statusLabel.text = "录音中…"
      resultView.text = ""
    } catch {
      statusLabel.text = "录音错误：\(error.localizedDescription)"
    }
  }

  private func stopAndUpload() {
    guard let r = recorder, let url = fileURL else { return }
    r.stop()
    recorder = nil
    let recDur = recordStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    recordButton.setTitle("● 开始录音", for: .normal)
    upload(fileURL: url, recordedSeconds: recDur)
  }

  private func upload(fileURL: URL, recordedSeconds: Double) {
    saveKey()
    let key = (apiKeyField.text ?? "").trimmingCharacters(in: .whitespaces)
    if key.isEmpty {
      statusLabel.text = "未配置 API key — 在上面 key 框里填一下"
      return
    }
    statusLabel.text = String(format: "上传中…（录音 %.1fs）", recordedSeconds)
    uploadStartedAt = Date()
    let model = (modelField.text?.isEmpty == false) ? modelField.text! : config.defaultModel
    let endpoint = URL(string: config.endpoint)!
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let boundary = "Boundary-\(UUID().uuidString)"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    func append(_ s: String) { body.append(s.data(using: .utf8)!) }
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
    for (k, v) in config.extraFormFields {
      append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
    }
    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
    if let data = try? Data(contentsOf: fileURL) { body.append(data) }
    append("\r\n--\(boundary)--\r\n")
    req.httpBody = body
    let bodySize = body.count

    URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
      DispatchQueue.main.async {
        guard let self else { return }
        let elapsed = self.uploadStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        try? FileManager.default.removeItem(at: fileURL)
        if let err {
          self.statusLabel.text = String(format: "失败：%@（%.2fs）", err.localizedDescription, elapsed)
          return
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if status == 200,
           let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
          self.resultView.text = text
          self.statusLabel.text = String(format: "成功（录音 %.1fs / 上传+识别 %.2fs / payload %d KB）",
                                         recordedSeconds, elapsed, bodySize / 1024)
        } else if status == 200 {
          self.resultView.text = bodyText
          self.statusLabel.text = String(format: "200 但解析失败（%.2fs）", elapsed)
        } else {
          self.resultView.text = bodyText
          self.statusLabel.text = String(format: "HTTP %d（%.2fs）", status, elapsed)
        }
      }
    }.resume()
  }
}

extension ASRTestViewController.Config {
  static let glm = ASRTestViewController.Config(
    title: "GLM-ASR 测试",
    endpoint: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions",
    defaultModel: "glm-asr-2512",
    apiKeyDefaultsKey: "VoiceInputView.aiAPIKey",
    extraFormFields: ["stream": "false"]
  )
  static let whisper = ASRTestViewController.Config(
    title: "Whisper 测试",
    endpoint: "https://api.openai.com/v1/audio/transcriptions",
    defaultModel: "whisper-1",
    apiKeyDefaultsKey: "VoiceInputView.whisperAPIKey",
    extraFormFields: [:]
  )
}

// MARK: - Paste Selection

final class PasteSelectionViewController: UITableViewController {
  private let segments: [String]
  private let fullText: String
  private let onSelect: (String) -> Void

  init(text: String, onSelect: @escaping (String) -> Void) {
    self.fullText = text
    self.onSelect = onSelect
    let parts = text.components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    self.segments = parts.isEmpty ? [text] : parts
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private lazy var pasteButton = UIBarButtonItem(
    title: "粘贴", style: .done, target: self, action: #selector(pasteSelected))
  private lazy var selectAllButton = UIBarButtonItem(
    title: "全选", style: .plain, target: self, action: #selector(toggleSelectAll))

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "选择粘贴内容"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
    navigationItem.rightBarButtonItems = [pasteButton, selectAllButton]
    tableView.allowsSelection = true
    tableView.allowsMultipleSelection = true
    updateButtons()
  }

  @objc private func cancelTapped() {
    dismiss(animated: true)
  }

  @objc private func pasteSelected() {
    let indices = (tableView.indexPathsForSelectedRows ?? []).map { $0.row }.sorted()
    let combined: String
    if indices.isEmpty {
      combined = fullText
    } else {
      combined = indices.map { segments[$0] }.joined(separator: "\n\n")
    }
    let cb = self.onSelect
    dismiss(animated: true) {
      cb(combined)
    }
  }

  @objc private func toggleSelectAll() {
    let allSelected = (tableView.indexPathsForSelectedRows?.count ?? 0) == segments.count
    if allSelected {
      for ip in tableView.indexPathsForSelectedRows ?? [] {
        tableView.deselectRow(at: ip, animated: false)
      }
    } else {
      for row in 0..<segments.count {
        tableView.selectRow(at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .none)
      }
    }
    updateButtons()
  }

  private func updateButtons() {
    let count = tableView.indexPathsForSelectedRows?.count ?? 0
    if count == 0 {
      pasteButton.title = "全部粘贴"
    } else {
      pasteButton.title = "粘贴 (\(count))"
    }
    selectAllButton.title = count == segments.count ? "取消全选" : "全选"
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 1 }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    "共 \(segments.count) 段 · 点击多选，未选时点'全部粘贴'"
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    segments.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let id = "seg"
    let cell = tableView.dequeueReusableCell(withIdentifier: id) ?? UITableViewCell(style: .default, reuseIdentifier: id)
    cell.textLabel?.numberOfLines = 0
    cell.textLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    cell.textLabel?.text = segments[indexPath.row]
    cell.selectionStyle = .default
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    updateButtons()
  }

  override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    updateButtons()
  }
}
