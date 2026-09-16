import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var state: AppState
    /// 浏览器占满顶栏以下整块（和鸿蒙平板一样全屏），关掉回终端；⌘B / 顶栏地球按钮切换
    @AppStorage("BrowserPanel.open") private var showBrowser = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showBrowser: $showBrowser)
            Divider().overlay(Theme.hair)
            if showBrowser {
                BrowserPanel(onClose: { showBrowser = false })
            } else {
                HStack(spacing: 0) {
                    MachineRail()
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
    }
}

// MARK: - Top bar (breadcrumb + right toolbar)

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showBrowser: Bool

    var body: some View {
        HStack(spacing: 10) {
            // reserve space for the window traffic lights
            Spacer().frame(width: 72)

            Text(state.activeMachine.name).font(Theme.ui(13)).foregroundColor(Theme.sub)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: 0x3a4048))
            Text("cc-\(state.activeSession.name)").font(Theme.mono(13, .semibold)).foregroundColor(Theme.fg)

            HStack(spacing: 5) {
                Circle().fill(Theme.teal).frame(width: 6, height: 6)
                Text("blinkd").font(Theme.ui(11, .semibold))
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
            IconButton(system: "gearshape", iconSize: 17) { state.showToast("打开设置") }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(WindowChromeDragZoom())   // 双击放大/还原、拖拽移动窗口（空白处生效）
        .background(Color.white.opacity(0.02))
    }
}
