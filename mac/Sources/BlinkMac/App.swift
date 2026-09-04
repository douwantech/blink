import SwiftUI
import AppKit

@main
struct BlinkMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1120, minHeight: 720)
                .preferredColorScheme(.dark)
                .background(Theme.bg)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 裸 SPM 二进制默认不是常规 app，必须尽早置 .regular 才出窗口。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
