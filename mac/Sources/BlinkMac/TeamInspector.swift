import SwiftUI

/// 与 iOS 团队页一致：员工卡内列项目，行尾分别管理模型和休息。
/// 点员工或项目直接切到对应标签，休息中的标签会先唤醒。
struct TeamInspector: View {
    @EnvironmentObject var state: AppState
    @State private var hoveredSessionID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("团队").font(Theme.ui(15, .bold))
                Spacer()
                IconButton(system: "arrow.clockwise", size: 28, iconSize: 15) { state.probe() }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 11)

            HStack(spacing: 0) {
                segItem("按员工", .employee)
                segItem("按项目", .project)
                segItem("按机器", .machine)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .padding(.horizontal, 14).padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(state.teamSections) { section in
                        VStack(alignment: .leading, spacing: 9) {
                            if let title = section.title {
                                HStack {
                                    Text(title).font(Theme.mono(12, .bold)).foregroundColor(Theme.fg)
                                    Spacer()
                                    Text("\(section.groups.count) 人")
                                        .font(Theme.mono(10)).foregroundColor(Theme.dim)
                                }
                                .padding(.horizontal, 3)
                            }
                            ForEach(section.groups) { group in
                                employeeCard(group)
                            }
                        }
                    }
                    if state.sessionCount == 0 {
                        Text("无会话").font(Theme.ui(12)).foregroundColor(Theme.dim)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
        }
        .frame(width: 320)
        .background(Color.white.opacity(0.03))
    }

    private func employeeCard(_ group: TeamGroup) -> some View {
        let allResting = group.sessions.allSatisfy { state.resting($0) }
        let selected = group.sessions.contains { $0.id == state.activeSessionID }
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { open(group.sessions.first(where: { !state.resting($0) }) ?? group.sessions[0]) } label: {
                    HStack(spacing: 10) {
                        Avatar(text: initials(group.sessions[0].owner), grad: group.sessions[0].grad,
                               size: 34, corner: 17, fontSize: 13,
                               image: state.avatar(group.sessions[0].owner), agent: commonAgent(group), ring: Theme.panel)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title).font(Theme.mono(13, .bold)).foregroundColor(Theme.fg)
                                .lineLimit(1).truncationMode(.middle)
                            Text(group.sub).font(Theme.mono(10)).foregroundColor(Theme.sub)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开 \(group.title) 的标签")

                // 按项目时一张卡只有一条会话，iOS 把操作放到卡片头。
                if state.inspector == .project, let session = group.sessions.first {
                    agentGear(session)
                    restButton(session)
                }
            }

            if state.inspector != .project {
                VStack(spacing: 5) {
                    ForEach(group.sessions) { session in
                        projectRow(session)
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(allResting ? Theme.rest.opacity(0.45) : selected ? Theme.teal.opacity(0.45) : Theme.hair,
                    lineWidth: 1))
        .opacity(allResting ? 0.72 : 1)
    }

    private func projectRow(_ session: Session) -> some View {
        let resting = state.resting(session)
        let selected = state.activeSessionID == session.id
        return HStack(spacing: 6) {
            Button { open(session) } label: {
                HStack(spacing: 7) {
                    Text(session.project)
                        .font(Theme.mono(12, .bold))
                        .foregroundColor(resting ? Theme.rest : Theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if resting {
                        Text("休息中").font(Theme.mono(10)).foregroundColor(Theme.rest)
                    }
                    AgentBadge(kind: state.agent(for: session), size: 14, ring: Theme.panel2)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.leading, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(resting ? "唤醒并打开 \(session.name)" : "打开 \(session.name)")

            agentGear(session)
            restButton(session)
        }
        .padding(.trailing, 5)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Theme.teal.opacity(0.13) : hoveredSessionID == session.id
                  ? Color.white.opacity(0.09) : Color.white.opacity(resting ? 0.025 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(selected ? Theme.teal.opacity(0.35) : .clear, lineWidth: 1))
        .onHover { hovering in hoveredSessionID = hovering ? session.id : nil }
        .contextMenu {
            Button("打开标签") { open(session) }
            Button(resting ? "唤醒" : "休息") { state.toggleRest(sessionID: session.id) }
        }
    }

    private func open(_ session: Session) {
        state.openTeamSession(session.id)
    }

    private func restButton(_ session: Session) -> some View {
        let resting = state.resting(session)
        return Button { state.toggleRest(sessionID: session.id) } label: {
            Image(systemName: resting ? "moon.zzz.fill" : "moon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(resting ? Theme.rest : Theme.sub)
                .frame(width: 25, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(resting ? "唤醒（在岗）" : "让 TA 休息")
    }

    private func agentGear(_ session: Session) -> some View {
        let current = state.agent(for: session)
        return Menu {
            ForEach(AgentKind.allCases) { kind in
                Button { state.setAgent(kind, for: session) } label: {
                    Label(kind == current ? "\(kind.label)（当前）" : kind.label, systemImage: kind.symbol)
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(current == .claude ? Theme.sub : current.brand)
                .frame(width: 25, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("打开时进哪个 CLI：\(current.label)")
    }

    private func commonAgent(_ group: TeamGroup) -> AgentKind? {
        guard let first = group.sessions.first.map({ state.agent(for: $0) }),
              group.sessions.allSatisfy({ state.agent(for: $0) == first }) else { return nil }
        return first
    }

    private func segItem(_ label: String, _ mode: InspectorMode) -> some View {
        let selected = state.inspector == mode
        return Button { state.inspector = mode } label: {
            Text(label).font(Theme.ui(12, selected ? .semibold : .regular))
                .foregroundColor(selected ? Theme.fg : Theme.sub)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.panel3 : .clear))
        }
        .buttonStyle(.plain)
    }

    private func initials(_ value: String) -> String {
        String(value.replacingOccurrences(of: "-", with: "").prefix(2))
    }
}
