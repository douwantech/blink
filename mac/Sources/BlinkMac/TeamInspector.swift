import SwiftUI

struct TeamInspector: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Text("团队").font(Theme.ui(14, .bold))
                Spacer()
                IconButton(system: "arrow.clockwise", size: 26, iconSize: 15) { state.showToast("正在探测各机器…") }
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

            // list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.teamItems) { it in
                        teamCard(it)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(width: 296)
        .background(Color.white.opacity(0.03))
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

    private func teamCard(_ it: TeamMember) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Avatar(text: it.initials, grad: it.grad, size: 32, corner: 16, fontSize: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.title).font(Theme.mono(13, .bold))
                    Text(it.sub).font(Theme.ui(11)).foregroundColor(Theme.dim)
                }
                Spacer(minLength: 4)
                StatusPill(status: it.status)
                if it.showMoon {
                    Button { state.showToast("已切换 在岗/休息") } label: {
                        Image(systemName: "moon").font(.system(size: 14))
                            .foregroundColor(it.status == .rest ? Theme.rest : Theme.dim)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !it.note.isEmpty {
                Text(it.note).font(Theme.ui(11)).foregroundColor(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(it.status == .wait ? Theme.wait.opacity(0.35) : Theme.hair)))
    }
}
