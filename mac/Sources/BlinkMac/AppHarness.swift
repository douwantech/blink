import AppKit
import SwiftUI

/// #74 验收用的隐藏测试钩子（与既有 BLINKMAC_CHATSHOT / BLINKMAC_DIAG / BLINKMAC_SYNC_FILE 同类）。
///
/// 存在的理由：这台机器上 `screencapture` 被 TCC 拦掉（没有屏幕录制权限），
/// 只能让 app 自绘窗口成 PNG —— 和 CHATSHOT 同一条路径，不吃系统权限。
/// 另外要能选机器 / 选会话，才能证明「点开某台机器的标签真的连上了 blinkd」。
///
/// 环境变量（一个都不设时本文件完全不生效）：
///   BLINKMAC_E2E_SHOT=<path.png>   跑完 startup 后：可选登录 → 选机器 → 选会话 → 等 SHOT_DELAY 秒 → 抓图退出
///   BLINKMAC_E2E_LOGIN=<file>      凭据文件（第 1 行用户名、第 2 行密码），走真实 ServerSync.login
///   BLINKMAC_E2E_MACHINE=<显示名>  切到这台机器（大小写不敏感）
///   BLINKMAC_E2E_SESSION=<会话名>  点开同名会话（走真实终端 → blinkd 连接）
///   BLINKMAC_SHOT_DELAY=<秒>       抓图前等待，默认 14（等 refresh 落地 + tmux attach + 首屏输出）
enum AppHarness {
    @MainActor
    static func runAfterStartup(_ state: AppState) async {
        let env = ProcessInfo.processInfo.environment
        guard let shot = env["BLINKMAC_E2E_SHOT"], !shot.isEmpty else { return }

        // 1) 没 session 就真登录一次（密码从文件读，不进 argv / 不进聊天）。
        if !ServerSync.shared.hasSession,
           let cred = env["BLINKMAC_E2E_LOGIN"], !cred.isEmpty,
           let raw = try? String(contentsOfFile: cred, encoding: .utf8) {
            let lines = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.count >= 2 {
                do {
                    try await ServerSync.shared.login(username: lines[0], password: lines[1])
                    FileHandle.standardError.write(Data("harness: login ok (\(lines[0]))\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("harness: login failed: \(error.localizedDescription)\n".utf8))
                }
            }
        }

        // 2) 选机器 / 选会话。refresh 落地会把清单重建回第一台，所以重试到选中为止。
        if env["BLINKMAC_E2E_TEAM"] == "1" { state.showTeam = true }   // 团队面板：跨机器列全部标签
        let wantMachine = env["BLINKMAC_E2E_MACHINE"] ?? ""
        let wantSession = env["BLINKMAC_E2E_SESSION"] ?? ""
        for _ in 0..<20 {
            if !wantSession.isEmpty,
               let s = state.sessions.first(where: { $0.name.caseInsensitiveCompare(wantSession) == .orderedSame }) {
                state.selectSession(s.id)
                if state.activeSessionID == s.id { break }
            } else if !wantMachine.isEmpty,
                      let m = state.machines.first(where: { $0.name.caseInsensitiveCompare(wantMachine) == .orderedSame }) {
                state.selectMachine(m.id)
                if state.activeMachineID == m.id { break }
            } else {
                break   // 没指定目标：就拿默认状态抓图
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let delay = Double(env["BLINKMAC_SHOT_DELAY"] ?? "") ?? 14
        try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
        capture(to: shot)
        exit(0)
    }

    /// 把每个窗口的 contentView 自绘成 PNG（第一张用给定路径，其余加 -N 后缀）。
    private static func capture(to path: String) {
        var idx = 0
        for w in NSApp.windows where w.contentView != nil {
            guard let v = w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let p = idx == 0 ? path : ((path as NSString).deletingPathExtension) + "-\(idx).png"
                try? data.write(to: URL(fileURLWithPath: p))
            }
            idx += 1
        }
    }
}
