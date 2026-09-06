import SwiftUI

/// 员工列表（B 方案·分组卡片）：紧凑统计条 + 每个分组一张卡（卡内细线分行），
/// 状态用「圆点＋文字」，行尾月亮=休息开关。数据来自真实会话（AppState.teamGroups）。
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

            // 紧凑统计条（替代 2×2 大块）
            HStack(spacing: 16) {
                statChip(state.count(.wait), "等你", Theme.wait)
                statChip(state.count(.work), "干活", Theme.work)
                statChip(state.count(.idle), "空闲", Theme.idle)
                statChip(state.count(.rest), "休息", Theme.rest)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

            // segmented
            HStack(spacing: 0) {
                segItem("按员工", .employee)
                segItem("按项目", .project)
                segItem("按机器", .machine)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)

            // list：每个分组一张卡，卡内细线分行
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(state.teamGroups) { g in
                        VStack(alignment: .leading, spacing: 7) {
                            groupHeader(g)
                            card(g)
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

    // 分组头：小头像 + 名 + 汇总（右对齐）
    private func groupHeader(_ g: TeamGroup) -> some View {
        HStack(spacing: 8) {
            Avatar(text: initials(g.title),
                   grad: headerGrad(g), size: 20, corner: 10, fontSize: 9,
                   image: state.inspector == .employee ? state.avatar(g.title) : nil)
            Text(g.title).font(Theme.ui(13, .bold)).foregroundColor(Theme.fg)
            Spacer()
            Text(g.sub).font(Theme.mono(10)).foregroundColor(Theme.dim)
        }
        .padding(.horizontal, 2)
    }

    // 分组卡：一张圆角卡，内部会话行用细线分隔，无逐行边框
    private func card(_ g: TeamGroup) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(g.sessions.enumerated()), id: \.element.id) { idx, s in
                if idx > 0 {
                    // 整条通到边的分隔线
                    Rectangle().fill(Theme.hair).frame(height: 1)
                }
                teamRow(s)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hair))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 一行会话：点行=切到该会话；行尾月亮=休息/唤醒（写 iCloud KV，同步手机）。
    private func teamRow(_ s: Session) -> some View {
        Button { state.selectSession(s.id) } label: {
            HStack(spacing: 9) {
                Avatar(text: s.initials, grad: s.grad, size: 26, corner: 8, image: state.avatar(s.owner))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(Theme.ui(12.5, .semibold)).foregroundColor(Theme.fg)
                    Text(s.dir).font(Theme.mono(10)).foregroundColor(Theme.sub)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                statusLabel(s.status)
                Button { state.toggleRest(sessionID: s.id) } label: {
                    Image(systemName: s.status == .rest ? "moon.zzz.fill" : "moon")
                        .font(.system(size: 13))
                        .foregroundColor(s.status == .rest ? Theme.rest : Theme.dim)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.status == .rest ? "唤醒（在岗）" : "让 TA 休息")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(s.id == state.activeSessionID ? Theme.teal.opacity(0.10) : Color.clear)
            .opacity(s.status == .rest ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 状态：圆点 + 文字（替代重胶囊）
    private func statusLabel(_ st: WorkStatus) -> some View {
        HStack(spacing: 6) {
            Circle().fill(st.color).frame(width: 7, height: 7)
            Text(st.label).font(Theme.ui(11, .semibold)).foregroundColor(st.color)
        }
    }

    private func statChip(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text("\(n)").font(Theme.mono(15, .bold)).foregroundColor(color)
            Text(label).font(Theme.ui(11)).foregroundColor(Theme.sub)
        }
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

    private func initials(_ s: String) -> String {
        String(s.replacingOccurrences(of: "-", with: "").prefix(2))
    }
    // 分组头像底色：员工用真头像（外层已传 image），项目/机器给个中性渐变
    private func headerGrad(_ g: TeamGroup) -> [Color] {
        switch state.inspector {
        case .employee: return g.sessions.first?.grad ?? Grad.slate
        case .project:  return Grad.slate
        case .machine:  return Grad.blue
        }
    }
}
