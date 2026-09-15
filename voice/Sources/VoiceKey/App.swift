import SwiftUI
import AppKit
import Speech
import AVFoundation

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

        // 尽早申请麦克风/语音权限：让 HAL 在进程早期就拿到授权，避免首次录音拿到零缓冲。
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // 自测：VOICEKEY_SELFTEST=1 时自动跑一遍完整听写周期（开始录→tap 落盘→停→afconvert→
        // GLM-ASR），用来在没人按地球键的情况下验证录音/转换路径不崩。跑完退出。
        if ProcessInfo.processInfo.environment["VOICEKEY_SELFTEST"] == "1" {
            Diag.log("SELFTEST 开始")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { DictationController.shared.toggle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { DictationController.shared.toggle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { Diag.log("SELFTEST 结束"); exit(0) }
        }

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
