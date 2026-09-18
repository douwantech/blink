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
            // 按员工时标题是「机器 · 员工」，头像/首字母要用员工名本身去查
            Avatar(text: initials(state.inspector == .employee ? (g.sessions.first?.owner ?? g.title) : g.title),
                   grad: headerGrad(g), size: 20, corner: 10, fontSize: 9,
                   image: state.inspector == .employee ? state.avatar(g.sessions.first?.owner ?? g.title) : nil)
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
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.name).font(Theme.ui(12.5, .semibold)).foregroundColor(Theme.fg)
                        // 按项目时一组里混着好几台机器，名字后面补机器名才分得清谁是谁
                        if state.inspector == .project {
                            Text(state.machineName(s.machineID))
                                .font(Theme.mono(9)).foregroundColor(Theme.dim)
                        }
                    }
                    // 在干嘛：读 claude 的 jsonl 拿到的最后一步动作，后面跟距今多久
                    if s.doing.isEmpty {
                        Text(s.dir).font(Theme.mono(10)).foregroundColor(Theme.sub)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(s.doing).font(Theme.ui(10.5)).foregroundColor(Theme.sub)
                            .lineLimit(2).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                        if let t = Self.agoText(s.doingAgo) {
                            Text(t).font(Theme.mono(9)).foregroundColor(Theme.dim)
                        }
                    }
                }
                Spacer(minLength: 4)
                agentGear(s)
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
        .contextMenu {
            Button(role: .destructive) { state.closeTab(sessionID: s.id) } label: {
                Label("关闭标签", systemImage: "xmark")
            }
        }
    }

    /// 行尾齿轮：配这个员工打开时进 claude / codex / deepseek。
    /// 不是默认 claude 时齿轮点亮并在前面挂个名字小标签，一眼看出这行不走 claude。
    private func agentGear(_ s: Session) -> some View {
        let cur = state.agent(for: s)
        return HStack(spacing: 4) {
            if cur != .claude {
                Text(cur.label).font(Theme.ui(9.5, .semibold)).foregroundColor(Theme.work)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.work.opacity(0.14)))
            }
            Menu {
                ForEach(AgentKind.allCases) { k in
                    Button { state.setAgent(k, for: s) } label: {
                        Label(k == cur ? "\(k.label)（当前）" : k.label, systemImage: k.symbol)
                    }
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundColor(cur == .claude ? Theme.dim : Theme.work)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("打开时进哪个 CLI：\(cur.label)")
        }
    }

    /// 「3 分钟前」这种相对时间；不知道就不显示
    static func agoText(_ sec: Int) -> String? {
        guard sec >= 0 else { return nil }
        if sec < 60 { return "刚刚" }
        if sec < 3600 { return "\(sec / 60) 分钟前" }
        if sec < 86400 { return "\(sec / 3600) 小时前" }
        return "\(sec / 86400) 天前"
    }

    // 行里不再显示 等你/干活中/空闲/休息 —— 探测出来的档位不准，看了误导。
    // 休息与否仍看行尾月亮（手动开关，那个是准的）。

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
