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
            // Cmd-R = 刷新重连（同 quickBar「刷新重连」按钮）：走主菜单 key equivalent，
            // NSApp 先于终端响应链拦截，不管焦点在不在 SwiftTerm 都能触发。
            CommandGroup(after: .toolbar) {
                Button("刷新重连") { state.reconnect() }
                    .keyboardShortcut("r", modifiers: .command)
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
        // 隐藏诊断：BLINKMAC_DIAG=1 时打印从 iCloud KV 读到的机器清单（不含 token），随后退出。
        // 用来验证「从手机同步机器清单」这条路真的读到数据——正式签名跑才有 KV。
        if ProcessInfo.processInfo.environment["BLINKMAC_DIAG"] == "1" {
            let raw = MacMachineStore.machines()
            let s = AppState()
            s.loadCloudMachines()
            var lines = ["DIAG kv_machines=\(raw.count) merged=\(s.machines.count)"]
            for m in raw {
                let b = m.blinkd
                lines.append("  KV \(m.name) host=\(m.host) blinkd=\(b != nil ? "\(b!.host):\(b!.port)" : "-（无/走SSH）")")
            }
            for m in s.machines {
                switch m.transport {
                case .blinkd(let h, let p, _): lines.append("  MERGED \(m.name) → blinkd \(h):\(p)  [\(m.host)]")
                case .ssh(_, let h):           lines.append("  MERGED \(m.name) → ssh \(h)  [不可连]")
                case .local:                   lines.append("  MERGED \(m.name) → local")
                }
            }
            let tabs = CloudTabStore.tabs()
            lines.append("KV tabs=\(tabs.count)")
            s.loadCloudTabs()   // 没有活会话的机器（诊断里全都没枚举）→ 从 KV 标签补
            for m in s.machines {
                let ss = s.sessions.filter { $0.machineID == m.id }
                lines.append("  SESSIONS \(m.name): \(ss.count) 个  [\(ss.prefix(6).map { $0.name }.joined(separator: ", "))]")
            }
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(0)
        }
        NSApp.activate(ignoringOtherApps: true)
        // 开发版在 Dock 图标挂红色 DEV 角标 + 窗口标题带后缀，和正式版一眼分清。
        if AppBuild.isDev {
            NSApp.dockTile.badgeLabel = "DEV"
        }
        for w in NSApp.windows { w.title = AppBuild.isDev ? "BlinkMac · DEV" : "BlinkMac" }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
