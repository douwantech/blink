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
        .commands {
            // Ctrl-R 刷新：走主菜单 key equivalent，NSApp 先于终端响应链拦截，
            // 不管焦点在不在 SwiftTerm 都能刷新会话列表 + 探测状态。
            CommandGroup(after: .toolbar) {
                Button("刷新会话") { Task { await state.refresh() } }
                    .keyboardShortcut("r", modifiers: .control)
            }
        }
    }
}

/// 构建版本：debug(`make run`) = 开发版；release(`make app`/`install`) = 正式版。
enum AppBuild {
    static var isDev: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    static var label: String { isDev ? "DEV" : "正式" }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 裸 SPM 二进制默认不是常规 app，必须尽早置 .regular 才出窗口。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // 开发版在 Dock 图标挂红色 DEV 角标 + 窗口标题带后缀，和正式版一眼分清。
        if AppBuild.isDev {
            NSApp.dockTile.badgeLabel = "DEV"
        }
        for w in NSApp.windows { w.title = AppBuild.isDev ? "BlinkMac · DEV" : "BlinkMac" }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
