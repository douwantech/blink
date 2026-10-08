import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// 浏览器占满顶栏以下整块（和鸿蒙平板一样全屏），关掉回终端；⌘B / 顶栏地球按钮切换
    @AppStorage("BrowserPanel.open") private var showBrowser = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showBrowser: $showBrowser, onOpenSettings: { showSettings = true })
            Divider().overlay(Theme.hair)
            if showBrowser {
                BrowserPanel(onClose: { showBrowser = false })
            } else {
                HStack(spacing: 0) {
                    MachineRail(onOpenSettings: { showSettings = true })
                    Divider().overlay(Theme.hair)
                    SessionSidebar()
                    Divider().overlay(Theme.hair)
                    TerminalColumn()
                    if state.showTeam {
                        Divider().overlay(Theme.hair)
                        TeamInspector()
                    }
                }
            }
        }
        .background(Theme.bg)
        .foregroundColor(Theme.fg)
        .task { await state.startup() }
        .sheet(isPresented: $showSettings) {
            MacSettingsView {
                ServerSync.shared.logout()
                state.allowOfflineSession = false
                showSettings = false
                openWindow(id: "login")
                dismissWindow(id: "main")
            }
        }
        .onAppear {
            if !ServerSync.shared.hasSession && !state.allowOfflineSession {
                openWindow(id: "login")
                dismissWindow(id: "main")
            }
        }
    }
}

private struct MacSettingsView: View {
    @ObservedObject private var sync = ServerSync.shared
    @State private var confirmLogout = false
    let onLogout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("设置").font(Theme.ui(18, .bold))
            VStack(alignment: .leading, spacing: 12) {
                Text("账号").font(Theme.ui(13, .semibold))
                HStack {
                    Text(sync.username ?? "未登录")
                        .font(Theme.ui(13))
                    Spacer()
                    Button("退出登录") { confirmLogout = true }
                        .disabled(!sync.hasSession)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel3))
        }
        .padding(24)
        .frame(width: 380)
        .background(Theme.bg)
        .alert("退出登录", isPresented: $confirmLogout) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive, action: onLogout)
        } message: {
            Text("退出后本机不再同步机器与标签，需要重新输入团队账号密码。")
        }
    }
}

// MARK: - Top bar (breadcrumb + right toolbar)

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showBrowser: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // reserve space for the window traffic lights
            Spacer().frame(width: 72)

            Text(state.activeMachine.name).font(Theme.ui(13)).foregroundColor(Theme.sub)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: 0x3a4048))
            Text("cc-\(state.activeSession.name)").font(Theme.mono(13, .semibold)).foregroundColor(Theme.fg)

            HStack(spacing: 5) {
                Circle().fill(Theme.teal).frame(width: 6, height: 6)
                // 直接显示实际连接 IP（本机 127.0.0.1 / 远程对应 IP），比「本地」更明确
                Text(state.activeMachine.transport.badge).font(Theme.ui(11, .semibold))
            }
            .foregroundColor(Theme.teal)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.teal.opacity(0.12)))

            // 版本徽章：开发版琥珀 DEV / 正式版青色 正式，一眼区分两个窗口
            HStack(spacing: 4) {
                Image(systemName: AppBuild.isDev ? "hammer.fill" : "checkmark.seal.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(AppBuild.label).font(Theme.ui(11, .bold))
            }
            .foregroundColor(AppBuild.isDev ? Theme.wait : Theme.work)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill((AppBuild.isDev ? Theme.wait : Theme.work).opacity(0.14)))

            Spacer()

            // 浏览器：后台清单 + 原型目录（BrowserPanel），⌘B
            Button { showBrowser.toggle() } label: {
                Image(systemName: "globe")
                    .font(.system(size: 17))
                    .foregroundColor(showBrowser ? Theme.teal : Theme.sub)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("b", modifiers: .command)
            .help("浏览器（后台 / 原型）")

            IconButton(system: "person.2", iconSize: 17) { state.showTeam.toggle() }
            IconButton(system: "arrow.up.left.and.arrow.down.right", iconSize: 15) {
                // 切换最大化（zoom：铺满屏幕可视区 ↔ 还原）
                (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first)?.zoom(nil)
            }
            IconButton(system: "arrow.clockwise", color: Theme.work, iconSize: 17) { state.reconnect() }
            IconButton(system: "gearshape", iconSize: 17, action: onOpenSettings)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(WindowChromeDragZoom())   // 双击放大/还原、拖拽移动窗口（空白处生效）
        .background(Color.white.opacity(0.02))
    }
}
