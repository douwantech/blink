import AppKit
import ApplicationServices

/// 「辅助功能」权限：地球键全局监听 + 合成 ⌘V 都要它。
enum AccessibilityPermission {
    /// 当前是否已授权。
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 弹系统授权引导（第一次会把 app 加进「辅助功能」列表并提示去打开）。
    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 直接打开「系统设置 → 隐私与安全性 → 辅助功能」。
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
