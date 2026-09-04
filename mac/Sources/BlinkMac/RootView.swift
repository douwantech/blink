import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.hair)
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
        .background(Theme.bg)
        .foregroundColor(Theme.fg)
    }
}

// MARK: - Top bar (breadcrumb + right toolbar)

struct TopBar: View {
    @EnvironmentObject var state: AppState

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

            Spacer()

            IconButton(system: "person.2", iconSize: 17) { state.showTeam.toggle() }
            IconButton(system: "arrow.clockwise", color: Theme.work, iconSize: 17) { state.reconnect() }
            IconButton(system: "gearshape", iconSize: 17) { state.showToast("打开设置") }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color.white.opacity(0.02))
    }
}
