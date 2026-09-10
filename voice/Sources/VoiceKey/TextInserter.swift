import AppKit

/// 把转写文字送进「当前光标所在的那个 app」。
/// 做法：写进剪贴板 → 合成一次 ⌘V。合成按键需要「辅助功能」权限（和地球键监听同一个）。
/// 粘完把用户原来的剪贴板内容还回去，不污染。
enum TextInserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general

        // 备份用户原剪贴板（只备份纯文本，够用；粘贴后还原）
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // 给系统一点时间落定剪贴板，再发 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pasteCmdV()
            // 粘完再等一下还原原剪贴板（太快还原会把没粘上的这次也冲掉）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let saved {
                    pb.clearContents()
                    pb.setString(saved, forType: .string)
                }
            }
        }
    }

    /// 合成 Command+V 键盘事件（keyCode 9 = V）。
    private static func pasteCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
