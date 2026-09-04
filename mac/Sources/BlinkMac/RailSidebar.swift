import SwiftUI

// MARK: - Machine rail (leftmost, 64pt)

struct MachineRail: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            ForEach(state.machines) { m in
                Button { state.selectMachine(m.id) } label: {
                    Avatar(text: m.initials, grad: m.grad, size: 40, corner: 12, fontSize: 15)
                        .opacity(m.id == state.activeMachineID ? 1 : 0.72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.9), lineWidth: m.id == state.activeMachineID ? 2.5 : 0)
                        )
                        .overlay(alignment: .bottomTrailing) {
                            if m.online {
                                Circle().fill(Theme.work)
                                    .frame(width: 11, height: 11)
                                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                                    .offset(x: 1, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }

            Button { state.showToast("添加机器…") } label: {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .foregroundColor(Color.white.opacity(0.16))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "plus").font(.system(size: 16)).foregroundColor(Theme.dim))
            }
            .buttonStyle(.plain)

            Spacer()

            IconButton(system: "sparkles", color: Theme.purple, size: 36, iconSize: 19) { state.mode = .chat }
            IconButton(system: "gearshape", size: 36, iconSize: 19) { state.showToast("打开设置") }
        }
        .padding(.vertical, 14)
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - Session sidebar (280pt)

struct SessionSidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // header
            VStack(alignment: .leading, spacing: 3) {
                Text(state.activeMachine.name).font(Theme.ui(17, .bold))
                Text("\(state.activeMachine.host) · \(state.sidebarSessions.count) 会话")
                    .font(Theme.mono(11)).foregroundColor(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            // list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(state.sidebarSessions) { s in
                        SessionRow(session: s)
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().overlay(Theme.hair)

            // footer
            HStack(spacing: 8) {
                Button { state.newSession() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("新会话").font(Theme.ui(13, .semibold))
                    }
                    .foregroundColor(Theme.teal)
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.teal.opacity(0.4)))
                }
                .buttonStyle(.plain)

                Button { state.toggleRestActive() } label: {
                    Image(systemName: "moon")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.rest)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.rest.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .frame(width: 280)
        .background(Color.white.opacity(0.045))
    }
}

struct SessionRow: View {
    @EnvironmentObject var state: AppState
    var session: Session
    @State private var hovering = false

    var isActive: Bool { session.id == state.activeSessionID }

    var body: some View {
        Button { state.selectSession(session.id) } label: {
            HStack(spacing: 10) {
                Avatar(text: session.initials, grad: session.grad, size: 30, corner: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name).font(Theme.ui(14, .semibold)).foregroundColor(Theme.fg)
                    Text(session.dir).font(Theme.mono(11)).foregroundColor(Theme.sub)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                StatusPill(status: session.status)
            }
            .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Theme.teal.opacity(0.10) : (hovering ? Color.white.opacity(0.04) : .clear))
            )
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.teal)
                        .frame(width: 3).padding(.vertical, 12)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
