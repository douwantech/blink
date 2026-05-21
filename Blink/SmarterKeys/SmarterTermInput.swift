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

import UIKit
import Combine


@objc class SmarterTermInput: KBWebView {
  
  var kbView = KBView()
  var _proxyBarButtonItem: UIBarButtonItem!
  var _barButtonItemGroup: UIBarButtonItemGroup!
  
  lazy var _kbProxy: KBProxy = {
    KBProxy(kbView: self.kbView)
  }()
  
  private var _inputAccessoryView: UIView? = nil

  private var _voiceInputView: VoiceInputView?
  private(set) var useVoiceInput: Bool = true

  var isHardwareKB: Bool { kbView.traits.isHKBAttached }
  
  weak var device: TermDevice? = nil {
    didSet { reportStateReset() }
  }
  
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  
  override init(frame: CGRect, configuration: WKWebViewConfiguration) {
    
    
    super.init(frame: frame, configuration: configuration)


    _proxyBarButtonItem = UIBarButtonItem(customView: _kbProxy)
    _barButtonItemGroup = UIBarButtonItemGroup(barButtonItems: [_proxyBarButtonItem], representativeItem: nil)
    
    kbView.keyInput = self
    kbView.lang = textInputMode?.primaryLanguage ?? ""
    
    // Assume hardware kb by default, since sometimes we don't have kbframe change events
    // if shortcuts toggle in Settings.app is off.
    kbView.traits.isHKBAttached = true
    
    if traitCollection.userInterfaceIdiom == .pad {
//      _setupAssistantItem()
    } else {
      _setupAccessoryView()
    }
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
   
    if let value = self.window?.windowScene?.interfaceOrientation.isPortrait  {
      kbView.traits.isPortrait = value
    }
    kbView.setNeedsLayout()
  }
  
  func shouldUseWKCopyAndPaste() -> Bool {
    false
  }
  
  override func ready() {
    super.ready()
    reportLang()
    
//    device?.focus()
    kbView.isHidden = false
    kbView.invalidateIntrinsicContentSize()
  }
  
  func reset() {
    
  }
  
  func reportLang() {
    let lang = self.textInputMode?.primaryLanguage ?? ""
    kbView.lang = lang
    reportLang(lang, isHardwareKB: kbView.traits.isHKBAttached)
  }
  
  override var inputAssistantItem: UITextInputAssistantItem {
    let item = super.inputAssistantItem
    if KBTracker.shared.isHardwareKB {
      item.trailingBarButtonGroups = []
      item.leadingBarButtonGroups = []
    } else if _barButtonItemGroup != nil {
      item.leadingBarButtonGroups = []
      if item.trailingBarButtonGroups.first != _barButtonItemGroup || item.trailingBarButtonGroups.count != 1 {
        item.trailingBarButtonGroups = [_barButtonItemGroup]
        
        // Reload input views later. Fixes crash for detaching/attaching KB
        if let contentView = self.contentView() {
          DispatchQueue.main.async {
            contentView.reloadInputViews()
          }
        }
        
      }
      kbView.isHidden = false
      
    } else {
      item.trailingBarButtonGroups = []
      item.leadingBarButtonGroups = []
    }
    
    return item
  }
  
  override func becomeFirstResponder() -> Bool {
    // Don't become first responder if blocked (e.g., during Snips Input Mode)
    if device?.shouldBlockFirstResponder == true {
      return false
    }

    sync(traits: KBTracker.shared.kbTraits, device: KBTracker.shared.kbDevice, hideSmartKeysWithHKB: KBTracker.shared.hideSmartKeysWithHKB)

    let res = super.becomeFirstResponder()

    if !webViewReady {
      return res
    }

    device?.focus()
    kbView.isHidden = false
    setNeedsLayout()

    _inputAccessoryView?.isHidden = false

    return res
  }
  
  override func canBeFocused() -> Bool {
    let res = super.canBeFocused()
    if let delegate = self.window?.windowScene?.delegate as? SceneDelegate {
      if delegate.showingPaywall() {
        return false
      }
    }
    return res
    
  }
  
  var isRealFirstResponder: Bool {
    contentView()?.isFirstResponder == true
  }
  
  func reportStateReset() {
    reportStateReset(false)
    device?.view?.cleanSelection()
  }
  
  func reportStateWithSelection() {
    reportStateReset(device?.view?.hasSelection ?? false)
  }
  
  
  override func resignFirstResponder() -> Bool {
    let res = super.resignFirstResponder()
    if res {
      device?.blur()
      kbView.isHidden = true
      _inputAccessoryView?.isHidden = true
    }
    return res
  }

  func _setupAccessoryView() {
    if isHardwareKB {
      return
    }
    inputAssistantItem.leadingBarButtonGroups = []
    inputAssistantItem.trailingBarButtonGroups = []

    if let _ = _inputAccessoryView as? KBAccessoryView {
    } else {
      let av = KBAccessoryView(kbView: kbView)
      av.onVoiceButtonTap = { [weak self] in
        self?.setUseVoiceInput(true)
      }
      _inputAccessoryView = av
    }
  }

  override var inputAccessoryView: UIView? {
    if isHardwareKB {
      return nil
    }
    if useVoiceInput {
      return nil
    }
    return _inputAccessoryView
  }

  override var inputView: UIView? {
    guard useVoiceInput else { return nil }
    if _voiceInputView == nil {
      let v = VoiceInputView()
      v.delegate = self
      _voiceInputView = v
    }
    return _voiceInputView
  }

  func setUseVoiceInput(_ enabled: Bool) {
    guard useVoiceInput != enabled else { return }
    useVoiceInput = enabled
    if let cv = contentView() {
      cv.reloadInputViews()
    } else {
      reloadInputViews()
    }
  }

  @objc private func _toggleVoiceInputAction() {
    setUseVoiceInput(!useVoiceInput)
  }

  override var keyCommands: [UIKeyCommand]? {
    var cmds = super.keyCommands ?? []
    let toggle = UIKeyCommand(
      title: "切换语音/键盘输入",
      action: #selector(_toggleVoiceInputAction),
      input: "M",
      modifierFlags: [.command, .shift]
    )
    cmds.append(toggle)
    return cmds
  }

  func sync(traits: KBTraits, device: KBDevice, hideSmartKeysWithHKB: Bool) {
    kbView.kbDevice = device
    
    defer {
      
      kbView.traits = traits
      
      if let scene = window?.windowScene {
        if traitCollection.userInterfaceIdiom == .phone {
          kbView.traits.isPortrait = scene.interfaceOrientation.isPortrait
        } else if kbView.traits.isFloatingKB {
          kbView.traits.isPortrait = true
        } else {
          kbView.traits.isPortrait = scene.interfaceOrientation.isPortrait
        }
      }
      
    }
    
    if traitCollection.userInterfaceIdiom == .phone {
      if hideSmartKeysWithHKB && traits.isHKBAttached {
        _removeSmartKeys()
        return
      }
    }
    
    if traits.isFloatingKB {
      _setupAccessoryView()
      return
    }
    
    if traitCollection.userInterfaceIdiom != .pad {
//      needToReload = (_inputAccessoryView as? KBAccessoryView) == nil
      _setupAccessoryView()
    }
    
  }
  
//  func _setupAssistantItem() {
//    let item = inputAssistantItem
//
////    let proxyItem = UIBarButtonItem(customView: _kbProxy)
////    let group = UIBarButtonItemGroup(barButtonItems: [proxyItem], presentativeItem: nil)
//
////    item.leadingBarButtonGroups = []
////    item.trailingBarButtonGroups = [group]
//
//    item.leadingBarButtonGroups = []
//    item.trailingBarButtonGroups = []
//  }
  
  func _removeSmartKeys() {
    if let _ = _inputAccessoryView as? KBAccessoryView {
      _inputAccessoryView = UIView(frame: .zero)
      self.contentView()?.reloadInputViews()      
    }
    
    guard let item = contentView()?.inputAssistantItem
      else {
        return
    }
    item.leadingBarButtonGroups = []
    item.trailingBarButtonGroups = []
    setNeedsLayout()
  }
  
  // MARK: - Legacy Keyboard Methods Removed
  // These empty override methods have been removed as keyboard tracking
  // is now handled by UIKeyboardLayoutGuide in SpaceController
  
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    super.pressesBegan(presses, with: event)
    
    guard presses.count == 1, let press = presses.first, let key = press.key,
    // left or right cmd
    key.keyCode.rawValue == 227 || key.keyCode.rawValue == 231
    else {
      commandPressTimestamp = 0
      return
    }
    
    if press.timestamp - commandPressTimestamp > 0.5 {
      commandPressTimestamp = press.timestamp
      return
    }
    
    UIApplication.shared.sendAction(#selector(SpaceController.toggleQuickActionsAction), to: nil, from: nil, for: nil)
    commandPressTimestamp = 0
  }
  
  var commandPressTimestamp: TimeInterval = 0
}

// - MARK: Web communication
extension SmarterTermInput {
  
  override func onOut(_ data: String) {
    defer {
      kbView.turnOffUntracked()
    }
    
    guard
      let device = device,
      let deviceView = device.view,
      let scene = deviceView.window?.windowScene,
      scene.activationState == .foregroundActive
    else {
        return
    }
    
    deviceView.displayInput(data)
    
    device.write(data)
  }
  
  override func onCommand(_ command: String) {
    kbView.turnOffUntracked()
    guard
      let device = device,
      let scene = device.view.window?.windowScene,
      scene.activationState == .foregroundActive,
      let cmd = Command(rawValue: command),
      let spCtrl = spaceController
    else {
      return
    }
    
    spCtrl._onCommand(cmd)
  }
  
  var spaceController: SpaceController? {
    var n = next
    while let responder = n {
      if let spCtrl = responder as? SpaceController {
        return spCtrl
      }
      n = responder.next
    }
    return nil
  }
  
  override func onSelection(_ args: [AnyHashable : Any]) {
    if let dir = args["dir"] as? String, let gran = args["gran"] as? String {
      device?.view?.modifySelection(inDirection: dir, granularity: gran)
    } else if let op = args["command"] as? String {
      switch op {
      case "change": device?.view?.modifySideOfSelection()
      case "copy": copy(self)
      case "paste": device?.view?.pasteSelection(self)
      case "cancel": fallthrough
      default:  device?.view?.cleanSelection()
      }
    }
  }
  
  override func onMods() {
    kbView.stopRepeats()
  }
  
  override func onIME(_ event: String, data: String) {
    if event == "compositionstart" && data.isEmpty {
    } else if event == "compositionend" {
      kbView.traits.isIME = false
    } else { // "compositionupdate"
      kbView.traits.isIME = true
    }
  }
  
  func stuckKey() -> KeyCode? {
    let mods: UIKeyModifierFlags = [.shift, .control, .alternate, .command]
    let stuck = mods.intersection(trackingModifierFlags)
    
    // Return command key first
    if stuck.contains(.command) {
      return KeyCode.commandLeft
    }

    if stuck.contains(.shift) {
      return KeyCode.shiftLeft
    }
    if stuck.contains(.control) {
      return KeyCode.controlLeft
    }
    
    if stuck.contains(.alternate) {
      return KeyCode.optionLeft
    }
    
    return nil
  }
}
// - MARK: Config

extension SmarterTermInput {
  
  @objc private func _updateSettings() {
//    let hideSmartKeysWithHKB = !BKUserConfigurationManager.userSettingsValue(forKey: BKUserConfigShowSmartKeysWithXKeyBoard)
//    
//    if hideSmartKeysWithHKB != hideSmartKeysWithHKB {
//      _hideSmartKeysWithHKB = hideSmartKeysWithHKB
//      if traitCollection.userInterfaceIdiom == .pad {
//        _setupAssistantItem()
//      } else {
//        _setupAccessoryView()
//      }
//      _refreshInputViews()
//    }
  }
}


// - MARK: Commands

extension SmarterTermInput {
  
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    switch action {
    case #selector(UIResponder.paste(_:)):
      // do not touch UIPasteboard before actual paste to skip exta notification.
      return true// UIPasteboard.general.string != nil
    case
      #selector(UIResponder.copy(_:)),
      #selector(Self.copyRaw(_:)),
      #selector(UIResponder.cut(_:)):
      // When the action is requested from the keyboard, the sender will be nil.
      // In that case we let it go through to the WKWebView.
      // Otherwise, we check if there is a selection.
      return (sender == nil) || (sender != nil && device?.view?.hasSelection == true)
    case
         #selector(TermView.pasteSelection(_:)),
         #selector(Self.soSelection(_:)),
         #selector(Self.googleSelection(_:)),
         #selector(Self.shareSelection(_:)):
      return sender != nil && device?.view?.hasSelection == true
    case #selector(Self.copyLink(_:)),
         #selector(Self.openLink(_:)),
         #selector(Self.viewImageInApp(_:)):
      return sender != nil && device?.view?.detectedLink != nil
    default:
//      if #available(iOS 15.0, *) {
//        switch action {
//          case #selector(UIResponder.pasteAndMatchStyle(_:)),
//               #selector(UIResponder.pasteAndSearch(_:)),
//               #selector(UIResponder.pasteAndGo(_:)): return false
//          case _: break
//        }
//      }
      return super.canPerformAction(action, withSender: sender)
    }
  }
  
  override func copy(_ sender: Any?) {
    if shouldUseWKCopyAndPaste() {
      super.copy(sender)
    } else {
      device?.view?.copy(sender)
    }
  }

  @objc func copyRaw(_ sender: Any?) {
    device?.view?.copyRaw(sender)
  }

  override func paste(_ sender: Any?) {
    if shouldUseWKCopyAndPaste() {
      super.paste(sender)
    } else {
      device?.view?.paste(sender)
    }
  }

  @objc func copyLink(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let url = deviceView.detectedLink
      else {
        return
    }
    UIPasteboard.general.url = url
    deviceView.cleanSelection()
  }
  
  @objc func viewImageInApp(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let url = deviceView.detectedLink,
      let presenter = window?.rootViewController?.topPresented
    else {
      return
    }
    deviceView.cleanSelection()
    BlinkImageViewerController.present(url: url, from: presenter)
  }

  @objc func openLink(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let url = deviceView.detectedLink
      else {
        return
    }
    deviceView.cleanSelection()
    
    blink_openurl(url)
  }
  
  @objc func pasteSelection(_ sender: Any) {
    device?.view?.pasteSelection(sender)
  }
  
  @objc func googleSelection(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let query = deviceView.selectedText?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
      let url = URL(string: "https://google.com/search?q=\(query)")
    else {
        return
    }
    
    blink_openurl(url)
  }
  
  @objc func soSelection(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let query = deviceView.selectedText?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
      let url = URL(string: "https://stackoverflow.com/search?q=\(query)")
    else {
        return
    }
    
    blink_openurl(url)
  }
  
  @objc func shareSelection(_ sender: Any) {
    guard
      let vc = device?.delegate?.viewController(),
      let deviceView = device?.view,
      let text = deviceView.selectedText
    else {
        return
    }
    
    let ctrl = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    ctrl.popoverPresentationController?.sourceView = deviceView
    ctrl.popoverPresentationController?.sourceRect = deviceView.selectionRect
    vc.present(ctrl, animated: true, completion: nil)
  }
}


extension SmarterTermInput: VoiceInputViewDelegate {
  func voiceInput(_ view: VoiceInputView, didCommitText text: String) {
    guard let device = device else { return }
    device.write(text)
    device.write("\r")
  }

  func voiceInputDidRequestKeyboard(_ view: VoiceInputView) {
    setUseVoiceInput(false)
  }

  func voiceInputDidRequestDismiss(_ view: VoiceInputView) {
    _ = resignFirstResponder()
  }

  func voiceInputDidRequestSendEsc(_ view: VoiceInputView) {
    device?.write("\u{1B}")
  }

  func voiceInputDidRequestClearLine(_ view: VoiceInputView) {
    device?.write("\u{15}")
  }

  func voiceInputDidRequestCloseTab(_ view: VoiceInputView) {
    spaceController?.closeShellAction()
  }

  func voiceInputDidRequestReloadTab(_ view: VoiceInputView) {
    spaceController?.reloadCurrentShell()
  }

  func voiceInputCurrentTabUseTmux(_ view: VoiceInputView) -> Bool {
    spaceController?.currentTerm()?.mcpParams?.useTmux ?? false
  }

  func voiceInputDidToggleTmuxMode(_ view: VoiceInputView) {
    guard let sp = spaceController,
          let term = sp.currentTerm(),
          let p = term.mcpParams else { return }
    p.useTmux = !p.useTmux
    sp.reloadCurrentShell()
  }

  func voiceInputDidRequestDumpTranscript(_ view: VoiceInputView) {
    spaceController?.dumpTranscriptForCurrentShell()
  }

  func voiceInput(_ view: VoiceInputView, didRequestSendArrow direction: VoiceInputArrow) {
    let seq: String
    switch direction {
    case .up: seq = "\u{1B}[A"
    case .down: seq = "\u{1B}[B"
    case .right: seq = "\u{1B}[C"
    case .left: seq = "\u{1B}[D"
    }
    device?.write(seq)
  }

  func voiceInputDidRequestSendReturn(_ view: VoiceInputView) {
    device?.write("\r")
  }

  func voiceInputDidRequestCopyLastResponse(_ view: VoiceInputView) {
    let js = """
    (function(){
      try {
        var term = window.t;
        var inAlt = !!(term && term.alternateScreen_ && term.screen_ === term.alternateScreen_);

        // alt screen（Claude Code 这类 TUI）：DOM x-row 才是真实可见行
        // primary screen：用 scrollback + 当前可见 rowsArray
        var rows = [];
        if (inAlt) {
          rows = Array.from(document.querySelectorAll('x-row'))
            .map(function(r){ return (r.textContent || '').replace(/\\u00A0/g,' ').replace(/\\s+$/,''); });
        } else if (term && term.scrollbackRows_ && term.screen_ && term.screen_.rowsArray) {
          var sb = term.scrollbackRows_, vis = term.screen_.rowsArray;
          for (var i = 0; i < sb.length; i++) {
            var n = sb[i];
            rows.push((n && n.textContent ? n.textContent : '').replace(/\\u00A0/g,' ').replace(/\\s+$/,''));
          }
          for (var i = 0; i < vis.length; i++) {
            var n = vis[i];
            rows.push((n && n.textContent ? n.textContent : '').replace(/\\u00A0/g,' ').replace(/\\s+$/,''));
          }
        } else {
          rows = Array.from(document.querySelectorAll('x-row'))
            .map(function(r){ return (r.textContent || '').replace(/\\u00A0/g,' ').replace(/\\s+$/,''); });
        }
        while (rows.length && rows[rows.length-1] === '') rows.pop();

        var start = 0, end = rows.length;

        if (inAlt) {
          // alt screen TUI：底部一定是 [输入框 ╭─╮ / │ > │ / ╰─╯] + status banner
          // 从尾部往前丢这些；保留中间表格/分隔符
          for (var i = rows.length - 1; i >= 0; i--) {
            var line = rows[i];
            if (line === '') { end = i; continue; }
            // 输入框上下边（整行都是 ─ 和角字符）
            if (/^\\s*[╭╰][─\\s]*[╮╯]\\s*$/.test(line)) { end = i; continue; }
            // 输入框内行（│ ... │）
            if (/^\\s*│.*│\\s*$/.test(line)) { end = i; continue; }
            // status banner
            if (/^\\s*\\?\\s+for/i.test(line)) { end = i; continue; }
            if (/Bypass Permissions|accept edits on|plan mode on|bypass permissions on/i.test(line)) { end = i; continue; }
            if (/^\\s*[✶✻⏵⏴◯●∙·❯]/.test(line)) { end = i; continue; }
            if (/[⏵⏴]/.test(line)) { end = i; continue; }
            if (/^\\s*(Cooked|Cooking|Forging|Pondering|Thinking|Working|Crafting|Mulling|Brewing|Stewing|Simmering|Hatching|Brewing|Wandering|Whisking|Spinning|Conjuring|Imagining|Plotting|Synthesizing)\\b/i.test(line)) { end = i; continue; }
            break;
          }
          while (start < end && rows[start] === '') start++;
        } else {
          // 普通 shell / primary screen：找最近一行用户提交的 prompt
          for (var i = rows.length - 1; i >= 0; i--) {
            var line = rows[i];
            if (line === '') { end = i; continue; }
            if (/[╭╮╰╯│─]/.test(line)) { end = i; continue; }
            if (/^\\s*\\?\\s+for/i.test(line)) { end = i; continue; }
            if (/Bypass Permissions|accept edits on|plan mode on|bypass permissions on/i.test(line)) { end = i; continue; }
            if (/^\\s*[✶✻⏵⏴◯●∙·❯]/.test(line)) { end = i; continue; }
            if (/[⏵⏴]/.test(line)) { end = i; continue; }
            if (/^\\s*~?\\/[\\w./\\-~]*(\\s*\\([^)]+\\))?\\s*$/.test(line)) { end = i; continue; }
            if (/^\\s*~[\\w./\\-]*(\\s*\\([^)]+\\))?\\s*$/.test(line)) { end = i; continue; }
            if (line.length < 120 && /^[~/].*[$#%>❯]\\s*$/.test(line)) { end = i; continue; }
            if (/^\\s*\\[[\\w@.\\-]+:[^\\]]*\\*?/.test(line)) { end = i; continue; }
            if (/^\\s*\\[[~/]/.test(line) || /^\\s*\\[\\S+\\]\\[\\S+\\]/.test(line)) { end = i; continue; }
            if (/^\\s*(Cooked|Cooking|Forging|Pondering|Thinking|Working|Crafting|Mulling|Brewing|Stewing|Simmering|Hatching|Brewing|Wandering|Whisking|Spinning|Conjuring|Imagining|Plotting|Synthesizing)\\b/i.test(line)) { end = i; continue; }
            if (/^\\s*❯\\s*$/.test(line)) { end = i; continue; }
            break;
          }
          var s = -1;
          for (var i = end - 1; i >= 0; i--) {
            if (/^>\\s+\\S/.test(rows[i])) { s = i + 1; break; }
          }
          if (s < 0) for (var i = end - 1; i >= 0; i--) {
            if (/^>\\s/.test(rows[i])) { s = i + 1; break; }
          }
          if (s < 0) for (var j = end - 1; j >= 0; j--) {
            if (rows[j].indexOf('⏺') !== -1) {
              s = j;
              for (var k = j - 1; k >= 0; k--) {
                if (rows[k].indexOf('⏺') !== -1) s = k;
                else if (rows[k] === '') break;
              }
              break;
            }
          }
          start = s < 0 ? 0 : s;
          while (start < end && rows[start] === '') start++;
        }

        return rows.slice(start, end).join('\\n').replace(/^[\\s\\u23FA⏺]+/, '').trim();
      } catch(e) { return ''; }
    })()
    """
    evaluateJavaScript(js) { [weak view] result, _ in
      guard let view else { return }
      let text = (result as? String) ?? ""
      if !text.isEmpty {
        UIPasteboard.general.string = text
        let preview = text.count > 24 ? String(text.prefix(24)) + "…" : text
        view.showToast("已复制 · \(preview)")
      } else {
        view.showToast("没抓到内容", isError: true)
      }
    }
  }

  func voiceInputDidRequestPaste(_ view: VoiceInputView) {
    guard let device = device else { return }
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      view.showToast("剪贴板是空的", isError: true)
      return
    }
    device.write(text)
    let preview = text.count > 24 ? String(text.prefix(24)) + "…" : text
    view.showToast("已粘贴 · \(preview)")
  }

  func voiceInput(_ view: VoiceInputView, didRequestPasteText text: String) {
    guard let device = device, !text.isEmpty else { return }
    device.write(text)
    let preview = text.count > 24 ? String(text.prefix(24)) + "…" : text
    view.showToast("已粘贴 · \(preview)")
  }
}

extension SmarterTermInput: TermInput {
  var secureTextEntry: Bool {
    get {
      false
    }
    set(secureTextEntry) {
      
    }
  }
  
}

private extension UIViewController {
  var topPresented: UIViewController {
    var top: UIViewController = self
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }
}

class VSCodeInput: SmarterTermInput {
  override func shouldUseWKCopyAndPaste() -> Bool {
    true
  }
  
  override func canBeFocused() -> Bool {
    let res = super.canBeFocused()
   
    if res == false {
      return KBTracker.shared.input == self
    }
    
    return res
  }
}
