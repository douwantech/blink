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
                // Cmd-D = 终端 ↔ 对话记录 来回切（同底部「历史」按钮）
                Button("终端 / 对话记录") { state.openHistory() }
                    .keyboardShortcut("d", modifiers: .command)
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
                case .ssh(_, let h):           lines.append("  MERGED \(m.name) → ssh \(h)  [系统ssh]")
                case .local:                   lines.append("  MERGED \(m.name) → local")
                }
            }
            // 真连测试：对每台 SSH 机器跑一次系统 ssh 枚举，看这台 Mac 到底能不能免密登进去。
            for m in s.machines {
                guard case .ssh(let u, let h) = m.transport else { continue }
                let sem = DispatchSemaphore(value: 0)
                var out = ""
                Task.detached { out = await SSHExec.run(user: u, host: h, command: BlinkdScript.listSessions(), timeout: 8); sem.signal() }
                sem.wait()
                let cnt = out.split(whereSeparator: { $0.isNewline }).filter { $0.contains("cc-") }.count
                lines.append("  SSH \(m.name) (\(u.isEmpty ? "?" : u)@\(h)): 枚举到 \(cnt) 个 cc-* 会话  \(out.isEmpty ? "[连不上/无免密]" : "✅")")
            }
            s.loadCloudTabs()
            for m in s.machines {
                let n = s.sessions.filter { $0.machineID == m.id }.count
                lines.append("MERGE-TABS \(m.name): 并入后会话=\(n)")
            }
            let map = CloudTabStore.mapping()
            let sample = map.ccToUUIDs.prefix(4).map { "\($0.key)→\($0.value.count)uuid" }.joined(separator: ", ")
            lines.append("REST-MAP cc→uuid 条目=\(map.ccToUUIDs.count)  [\(sample)]")
            // 关闭标签 dry-run（只算不写）：拿第一个 tab 的 uuid 走一遍 mutateSyncState
            if let anyUUID = map.ccToUUIDs.values.first?.first,
               let td = NSUbiquitousKeyValueStore.default.data(forKey: "TabStateStore.syncState"),
               let obj = try? JSONSerialization.jsonObject(with: td) as? [String: Any] {
                let beforeTabs = (obj["tabs"] as? [[String: Any]])?.count ?? 0
                let beforeClosed = (obj["closedIds"] as? [String])?.count ?? 0
                if let after = CloudTabStore.mutateSyncState(closingId: anyUUID) {
                    let at = (after["tabs"] as? [[String: Any]])?.count ?? 0
                    let ac = (after["closedIds"] as? [String])?.count ?? 0
                    lines.append("CLOSE dry-run uuid=\(anyUUID.prefix(8)): tabs \(beforeTabs)→\(at), closedIds \(beforeClosed)→\(ac)  (未写KV)")
                } else { lines.append("CLOSE dry-run: mutate 返回 nil") }
            }
            // 已关闭标签：本地记录 + 过滤 自测（用不存在的合成 cc，不动真数据；测完清理）
            let testCC = "cc-blinkmac-selftest"
            MacClosedStore.add(testCC)
            s.loadClosed()
            let hidden = s.closedCC.contains(testCC)
            MacClosedStore.remove([testCC])
            s.loadClosed()
            let cleared = !s.closedCC.contains(testCC)
            lines.append("CLOSED-PERSIST 合成cc加入后隐藏=\(hidden) 清理后=\(cleared ? "已移除" : "残留")  当前closedCC=\(s.closedCC.count)")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(0)
        }
        // 截图自测：BLINKMAC_CHATSHOT=1 时，窗口渲染好后把 contentView 存成 PNG 再退出
        // （app 自绘成位图，不吃屏幕录制权限，命令行也能拿到真实布局图）。
        if ProcessInfo.processInfo.environment["BLINKMAC_CHATSHOT"] == "1" {
            let out = ProcessInfo.processInfo.environment["BLINKMAC_CHATSHOT_OUT"] ?? "/tmp/blinkmac-chatshot.png"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if let w = NSApp.windows.first(where: { $0.contentView != nil }),
                   let v = w.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: out))
                    }
                }
                exit(0)
            }
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
