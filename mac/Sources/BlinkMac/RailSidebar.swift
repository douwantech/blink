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
                Text("\(state.activeMachine.host) · \(state.sidebarSessions.count) 在岗"
                     + (state.restingCount > 0 ? " · \(state.restingCount) 休息" : ""))
                    .font(Theme.mono(11)).foregroundColor(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            // list：公用标签是服务端注入的全局只读集合，放在最上面（服务端顺序）
            ScrollView {
                VStack(spacing: 4) {
                    if !state.sharedSessions.isEmpty {
                        SidebarSectionLabel(title: "公用标签", count: state.sharedSessions.count)
                        ForEach(state.sharedSessions) { s in
                            SessionRow(session: s)
                        }
                    }
                    if !state.sidebarSessions.isEmpty {
                        // 只有两节都在时才加标题，单节时不给噪音
                        if !state.sharedSessions.isEmpty {
                            SidebarSectionLabel(title: "我的标签", count: state.sidebarSessions.count)
                        }
                        ForEach(state.sidebarSessions) { s in
                            SessionRow(session: s)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().overlay(Theme.hair)

            // footer（休息统一在右侧员工列表管理，这里不再放休息按钮）
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
            .padding(12)
        }
        .frame(width: 280)
        .background(Color.white.opacity(0.045))
    }
}

struct SidebarSectionLabel: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased()).font(Theme.ui(10, .bold)).foregroundColor(Theme.dim)
            Text("\(count)").font(Theme.mono(10)).foregroundColor(Theme.dim.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 1)
    }
}

struct SessionRow: View {
    @EnvironmentObject var state: AppState
    var session: Session
    @State private var hovering = false

    var isActive: Bool { session.id == state.activeSessionID }

    /// 公用标签可能挂在别的员工的机器上 —— 那台不在本机清单里就没有 transport，
    /// 行照样列出来（老板要「全部」），但置灰，点它只给一句提示。
    var machineKnown: Bool { state.machines.contains { $0.id == session.machineID } }
    var machineName: String { state.machines.first { $0.id == session.machineID }?.name ?? session.machineID }

    var subtitle: String {
        guard session.isShared else { return session.dir }
        return machineKnown ? machineName : "\(machineName) · 未在本机配置"
    }

    var body: some View {
        Button {
            state.selectSession(session.id)
        } label: {
            HStack(spacing: 10) {
                Avatar(text: session.initials, grad: session.grad, size: 30, corner: 9,
                       image: state.avatar(session.owner),
                       agent: state.agent(for: session), ring: Theme.panel2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(session.name).font(Theme.ui(14, .semibold)).foregroundColor(Theme.fg)
                        if session.isShared {
                            Text("公用")
                                .font(Theme.ui(9, .bold))
                                .foregroundColor(Theme.teal)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Capsule().fill(Theme.teal.opacity(0.14)))
                        }
                    }
                    Text(subtitle).font(Theme.mono(11)).foregroundColor(Theme.sub)
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
            .opacity(session.isShared && !machineKnown ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 关闭统一走底部「关闭」按钮；列表里只保留右键「关闭标签」，不再显示悬停 ×。
        // 公用标签的条目是只读的（不可休息 / 切 CLI / 关闭）—— 只给一句说明，
        // 菜单里不放任何能点的项（能点但报错不如根本不给）。
        .contextMenu {
            if session.isShared {
                Text("公用标签 · 由管理员维护")
            } else {
                Button { state.toggleRest(sessionID: session.id) } label: {
                    Label(state.resting(session) ? "唤醒（在岗）" : "让 TA 休息",
                          systemImage: state.resting(session) ? "moon.zzz.fill" : "moon")
                }
                // 打开时进哪个 CLI（跟团队面板行尾齿轮同一份配置）
                Menu("打开时进…") {
                    ForEach(AgentKind.allCases) { k in
                        Button { state.setAgent(k, for: session) } label: {
                            Label(k == state.agent(for: session) ? "\(k.label)（当前）" : k.label,
                                  systemImage: k.symbol)
                        }
                    }
                }
                Divider()
                Button(role: .destructive) { state.closeTab(sessionID: session.id) } label: {
                    Label("关闭标签", systemImage: "xmark")
                }
            }
        }
    }
}
