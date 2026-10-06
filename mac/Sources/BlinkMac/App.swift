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
            // 有 session 先拉一次服务器（DIAG 不走 RootView.task 的 startup，服务器
            // 同步层得在这里显式触发，否则诊断不到它）。fetchAndApply 不碰 MainActor，
            // 主线程 semaphore 等它不会死锁。
            if ServerSync.shared.hasSession {
                let sem = DispatchSemaphore(value: 0)
                var pulled: [SharedTab] = []
                Task.detached {
                    // fetchAndApply 不碰 @MainActor；公用标签走返回值（在 detached 里写 @Published 是数据竞争）
                    (_, pulled) = await ServerSync.shared.fetchAndApply()
                    sem.signal()
                }
                sem.wait()
                ServerSync.shared.publishSharedTabsForDiagnostics(pulled)
            }
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
                case .unconfigured:            lines.append("  MERGED \(m.name) → ⚠ blinkd 未配置（不降级 SSH）")
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

            // 公用标签（二期）：两个自测。
            //  1) BLINKMAC_DIAG_FIXTURE=<snapshot.json>：把一份快照走一遍「解码 + 剥离 + 落盘」，
            //     再回读断言没泄漏（LEAK 必须 0/0）。不需要凭据，配 BLINKMAC_SYNC_FILE=/tmp/...
            //     就不会碰真的同步文件。契约同 iOS BlinkTests/SharedTabSnapshotTests。
            //  2) 不带 fixture：走服务器真快照，只看计数（绝不回显 token）。
            let fixture = ProcessInfo.processInfo.environment["BLINKMAC_DIAG_FIXTURE"] ?? ""
            if !fixture.isEmpty {
                if let data = FileManager.default.contents(atPath: fixture) {
                    let shared = ServerSync.shared.applySnapshot(data)
                    let written = SyncConfig.read() ?? [:]
                    let outTabs = (written["tabs"] as? [[String: Any]]) ?? []
                    let outClosed = (written["closedIds"] as? [String]) ?? []
                    let leakedTabs = outTabs.filter { ($0["shared"] as? Bool) == true }.count
                    let sharedIDs = Set(shared.map { $0.id.lowercased() })
                    let leakedClosed = outClosed.filter { sharedIDs.contains($0.lowercased()) }.count
                    lines.append("SERVER shared=\(shared.count) own=\(outTabs.count)")
                    lines.append("LEAK shared_in_tabs=\(leakedTabs) shared_in_closed=\(leakedClosed)"
                                 + (leakedTabs == 0 && leakedClosed == 0 ? "  OK" : "  ❌ 公用标签泄漏进同步文件"))
                    let known = Set(s.machines.map(\.id))
                    lines.append("PUBLIC-MACHINES known=\(shared.filter { known.contains($0.machineId) }.count)/\(shared.count)")
                    ServerSync.shared.publishSharedTabsForDiagnostics(shared)   // 让下面能验侧栏合成
                } else {
                    lines.append("FIXTURE 读不到：\(fixture)")
                }
            }
            s.applySharedTabs()
            // 本地缓存这份是「重启只回 304」时的唯一来源：正常跑过一次后这里应等于服务端那份。
            lines.append("SHARED-TABS 服务端=\(ServerSync.shared.sharedTabs.count)"
                         + " 本地缓存=\(ServerSync.shared.cachedSharedTabs().count)"
                         + " 侧栏公用行=\(s.sharedSessions.count)"
                         + " 本机会话=\(s.sessions.filter { !$0.isShared }.count)")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(0)
        }
        // 截图自测：BLINKMAC_CHATSHOT=1 时，窗口渲染好后把 contentView 存成 PNG 再退出
        // （app 自绘成位图，不吃屏幕录制权限，命令行也能拿到真实布局图）。
        // BLINKMAC_SHOT_DELAY 可拉长等待（默认 2.5s；要看 SSH 枚举并入的多机标签得等 10s+）。
        // SwiftUI 的 .sheet 是独立 NSWindow，主窗抓不到 —— 第二张存成 *-sheet.png。
        if ProcessInfo.processInfo.environment["BLINKMAC_CHATSHOT"] == "1" {
            let env = ProcessInfo.processInfo.environment
            let out = env["BLINKMAC_CHATSHOT_OUT"] ?? "/tmp/blinkmac-chatshot.png"
            let delay = Double(env["BLINKMAC_SHOT_DELAY"] ?? "") ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var idx = 0
                for w in NSApp.windows where w.contentView != nil {
                    guard let v = w.contentView,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let path = idx == 0 ? out : ((out as NSString).deletingPathExtension) + "-sheet.png"
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                    idx += 1
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
