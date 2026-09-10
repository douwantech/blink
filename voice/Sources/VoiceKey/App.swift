import SwiftUI
import AppKit

@main
struct VoiceKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var d = DictationController.shared

    var body: some Scene {
        MenuBarExtra("语音键", systemImage: menuIcon) {
            Button(d.phase == .idle ? "开始听写" : "结束 / 取消") {
                DictationController.shared.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            SettingsLink { Text("设置…") }
                .keyboardShortcut(",", modifiers: .command)

            Button("辅助功能授权…") {
                AccessibilityPermission.prompt()
                AccessibilityPermission.openSettings()
            }

            Divider()
            Button("退出语音键") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            SettingsView()
        }
    }

    private var menuIcon: String {
        switch d.phase {
        case .listening: return "mic.fill"
        case .transcribing: return "waveform"
        default: return "mic"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var retryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 菜单栏后台 app，不占 Dock

        HUDPanelController.shared.begin()

        // 辅助功能：第一次装会弹系统引导；授权前 event tap 起不来，起不来就轮询重试。
        AccessibilityPermission.prompt()
        if !HotkeyMonitor.shared.start() {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
                if HotkeyMonitor.shared.start() {
                    t.invalidate(); self?.retryTimer = nil
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyMonitor.shared.stop()
    }
}
