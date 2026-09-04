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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只读自测：枚举真实会话并打印后退出（不开窗、不 attach，用于 E2E）。
        if ProcessInfo.processInfo.environment["BLINKD_ENUM_TEST"] != nil {
            NSApp.setActivationPolicy(.prohibited)
            let env = ProcessInfo.processInfo.environment
            Task { @MainActor in
                let out = await BlinkdExec.run(host: env["BLINKD_HOST"] ?? "127.0.0.1",
                                               port: UInt16(env["BLINKD_PORT"] ?? "7777") ?? 7777,
                                               token: env["BLINKD_TOKEN"] ?? "",
                                               command: BlinkdScript.listSessions())
                let real = AppState.parseSessions(out)
                print("=== avatars configured for: \(BlinkAvatars.byOwner.keys.sorted()) ===")
                print("=== parsed \(real.count) sessions ===")
                for s in real {
                    let has = BlinkAvatars.image(forOwner: s.owner) != nil
                    print("name=\(s.name)  owner=\(s.owner)  avatar=\(has ? "✓真图" : "×色块")  dir=\(s.dir)")
                }
                exit(0)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 自测：验证 zoom 真的把窗口最大化
        if ProcessInfo.processInfo.environment["BLINKD_ZOOM_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
                let before = w?.frame.size ?? .zero
                let visible = w?.screen?.visibleFrame.size ?? .zero
                w?.zoom(nil)
                let after = w?.frame.size ?? .zero
                FileHandle.standardError.write(Data("[zoom] before=\(before) after=\(after) screenVisible=\(visible)\n".utf8))
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
