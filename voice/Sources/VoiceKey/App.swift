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
    private var settingsTestWindow: NSWindow?   // TERMTEST 的替身设置窗，持有防释放

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 菜单栏后台 app，不占 Dock

        HUDPanelController.shared.begin()
        _ = LearningStore.shared   // 提前建好持久化学习库（~/Library/Application Support/VoiceKey）

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

        // 自测：VOICEKEY_TERMTEST=1 验证「我的词表」链路——预置 seed / contextualStrings /
        // 本地替换 / 手工增删改往返 / 设置窗能打开。不用真说话，跑完退出。
        if ProcessInfo.processInfo.environment["VOICEKEY_TERMTEST"] == "1" {
            Diag.log("TERMTEST 开始")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let store = LearningStore.shared
                let pairs = store.allTermPairs()
                Diag.log("TERMTEST 词表 \(pairs.count) 对；contextualStrings \(store.contextualStrings().count) 条")
                let sample = "这个糖床在蒸鸡上测过了"
                let out = store.applyTerms(to: sample)
                Diag.log("TERMTEST 替换：\"\(sample)\" → \"\(out)\"")
                store.setTerm("测试错词", right: "测试对词")
                store.renameTerm(oldWrong: "测试错词", newWrong: "测试错词2", right: "测试对词")
                store.retargetTerm(wrong: "测试错词2", oldRight: "测试对词", newRight: "测试对词2")
                let after = store.allTermPairs().first { $0.wrong == "测试错词2" }
                Diag.log("TERMTEST 增改往返：\(after.map { "\($0.wrong)→\($0.right)" } ?? "缺失")")
                store.removeTerm(wrong: "测试错词2", right: "测试对词2")
                let still = store.allTermPairs().contains { $0.wrong == "测试错词2" }
                Diag.log("TERMTEST 删除后还在？\(still)")
                // 渲染设置页验证「我的词表」节不崩。程序化开 SwiftUI Settings scene 的
                // selector 在 accessory app 里全不接（试过 3 个变体），改用替身 NSWindow +
                // NSHostingView 直接渲染 SettingsView；真入口 SettingsLink 是系统控件，
                // 用户点击路径不需要验。onAppear 的日志是「视图真求值过」的直接证据。
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "语音键设置（TERMTEST 替身窗）"
                w.contentView = NSHostingView(rootView: SettingsView())
                w.center()
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.settingsTestWindow = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                    let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) }
                    let hasSettings = mine.contains { w in
                        let layer = w[kCGWindowLayer as String] as? Int ?? -1
                        let width = (w[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Int ?? 0
                        return layer == 0 && width > 300
                    }
                    Diag.log("TERMTEST 设置窗已打开？\(hasSettings)")
                    Diag.log("TERMTEST 结束")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }  // 等 Diag 异步落盘
                }
            }
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
