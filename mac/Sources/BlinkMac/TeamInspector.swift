import SwiftUI

struct TeamInspector: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Text("团队").font(Theme.ui(14, .bold))
                Spacer()
                IconButton(system: "arrow.clockwise", size: 26, iconSize: 15) { state.probe() }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider().overlay(Theme.hair)

            // stat tiles
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                statTile(state.count(.wait), "等你", Theme.wait)
                statTile(state.count(.work), "干活中", Theme.work)
                statTile(state.count(.idle), "空闲", Theme.idle)
                statTile(state.count(.rest), "休息中", Theme.rest)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            // segmented
            HStack(spacing: 0) {
                segItem("按员工", .employee)
                segItem("按项目", .project)
                segItem("按机器", .machine)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .padding(.horizontal, 14).padding(.bottom, 10)

            // list（真实会话，按当前分组；行尾月亮=休息开关，同手机）
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(state.teamGroups) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Avatar(text: initials(g.title),
                                       grad: g.sessions.first?.grad ?? Grad.slate,
                                       size: 24, corner: 12, fontSize: 10,
                                       image: state.inspector == .employee ? state.avatar(g.title) : nil)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.title).font(Theme.ui(13, .bold))
                                    Text(g.sub).font(Theme.mono(10)).foregroundColor(Theme.dim)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 2)
                            ForEach(g.sessions) { s in teamRow(s) }
                        }
                    }
                    if state.teamGroups.isEmpty {
                        Text("无会话").font(Theme.ui(12)).foregroundColor(Theme.dim)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .frame(width: 296)
        .background(Color.white.opacity(0.03))
    }

    private func initials(_ s: String) -> String {
        String(s.replacingOccurrences(of: "-", with: "").prefix(2))
    }

    /// 一个真实会话行：点行=切到该会话；行尾月亮=休息/唤醒（写 iCloud KV，同步手机）。
    private func teamRow(_ s: Session) -> some View {
        Button { state.selectSession(s.id) } label: {
            HStack(spacing: 9) {
                Avatar(text: s.initials, grad: s.grad, size: 26, corner: 8, image: state.avatar(s.owner))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(Theme.ui(12, .semibold)).foregroundColor(Theme.fg)
                    Text(s.dir).font(Theme.mono(10)).foregroundColor(Theme.sub)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                StatusPill(status: s.status)
                Button { state.toggleRest(sessionID: s.id) } label: {
                    Image(systemName: s.status == .rest ? "moon.zzz.fill" : "moon")
                        .font(.system(size: 13))
                        .foregroundColor(s.status == .rest ? Theme.rest : Theme.dim)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(s.status == .rest ? "唤醒（在岗）" : "让 TA 休息")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(s.id == state.activeSessionID ? Theme.teal.opacity(0.10)
                      : (s.status == .rest ? Color.white.opacity(0.02) : Theme.panel)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(s.status == .wait ? Theme.wait.opacity(0.35) : Theme.hair))
            .opacity(s.status == .rest ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statTile(_ n: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(Theme.mono(20, .bold)).foregroundColor(color)
            Text(label).font(Theme.ui(11)).foregroundColor(Theme.sub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hair)))
    }

    private func segItem(_ label: String, _ mode: InspectorMode) -> some View {
        let on = state.inspector == mode
        return Button { state.inspector = mode } label: {
            Text(label).font(Theme.ui(12, on ? .semibold : .regular))
                .foregroundColor(on ? Theme.fg : Theme.sub)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.panel3 : .clear))
        }
        .buttonStyle(.plain)
    }
}
