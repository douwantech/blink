import SwiftUI

// MARK: - Machine rail (leftmost, 64pt)

struct MachineRail: View {
    @EnvironmentObject var state: AppState
    let onOpenSettings: () -> Void

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
                        // #25 降级可见性：blinkd=在线绿点；按 SSH 连的=teal「ssh」小标；
                        // 声明 blinkd 但配置没同步=amber ⚠（不降级 SSH，去手机重新保存机器）。
                        .overlay(alignment: .bottomTrailing) {
                            if m.transport.isUnconfigured {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.wait)
                                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2).frame(width: 14, height: 14))
                                    .offset(x: 1, y: 1)
                            } else if m.online {
                                Circle().fill(Theme.work)
                                    .frame(width: 11, height: 11)
                                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                                    .offset(x: 1, y: 1)
                            } else if case .ssh = m.transport {
                                Text("ssh")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Theme.teal)
                                    .padding(.horizontal, 2)
                                    .background(Capsule().fill(Theme.bg).frame(width: 16, height: 11))
                                    .overlay(Capsule().stroke(Theme.teal.opacity(0.7), lineWidth: 0.8).frame(width: 16, height: 11))
                                    .offset(x: 1, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            IconButton(system: "sparkles", color: Theme.purple, size: 36, iconSize: 19) { state.mode = .chat }
            IconButton(system: "gearshape", size: 36, iconSize: 19, action: onOpenSettings)
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
                Text("\(state.activeMachine.host) · \(state.sidebarSessions.count) 在岗"
                     + (state.restingCount > 0 ? " · \(state.restingCount) 休息" : ""))
                    .font(Theme.mono(11)).foregroundColor(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            // list
            if state.machines.isEmpty {
                // #74：没配本机 blinkd、还没登录（或刚登录还没拉到快照）时的空态。
                // 以前这里显示的是写死的示例机器和示例会话。
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有机器").font(Theme.ui(12, .semibold))
                    Text(ServerSync.shared.hasSession
                         ? "正在读取服务器清单…"
                         : "登录 Blink 团队后自动拉取机器和公用标签")
                        .font(Theme.ui(11)).foregroundColor(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(state.sidebarSessions) { s in
                            SessionRow(session: s)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

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
        Button {
            state.selectSession(session.id)
        } label: {
            HStack(spacing: 10) {
                Avatar(text: session.initials, grad: session.grad, size: 30, corner: 9,
                       image: state.avatar(session.owner),
                       agent: state.agent(for: session), ring: Theme.panel2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name).font(Theme.ui(14, .semibold)).foregroundColor(Theme.fg)
                    Text(session.dir).font(Theme.mono(11)).foregroundColor(Theme.sub)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                // 状态胶囊（等你/干活中/空闲）去掉：探测不准，看了误导
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
            .contentShape(Rectangle())   // 整行(含空白/Spacer)都可点
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
