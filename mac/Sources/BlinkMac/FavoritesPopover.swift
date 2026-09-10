import SwiftUI

/// 收藏短语弹窗（同手机）：列出收藏短语，点一条=发到当前终端并回车；可删、可加。
/// 数据走 FavoritesStore（正式版 iCloud 同步）。
struct FavoritesPopover: View {
    @EnvironmentObject var state: AppState
    @State private var newText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill").font(.system(size: 12)).foregroundColor(Color(hex: 0xf5c451))
                Text("收藏短语").font(Theme.ui(14, .bold))
                Spacer()
                Text(state.cloudAvailable ? "iCloud 同步" : "本地")
                    .font(Theme.mono(10)).foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            Divider().overlay(Theme.hair)

            ScrollView {
                VStack(spacing: 4) {
                    if state.favorites.isEmpty {
                        Text("还没有收藏。下面加一条，或在手机上收藏会同步过来。")
                            .font(Theme.ui(12)).foregroundColor(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 16)
                    }
                    ForEach(state.favorites, id: \.self) { fav in
                        FavoriteRow(text: fav)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(maxHeight: 300)

            Divider().overlay(Theme.hair)
            HStack(spacing: 8) {
                TextField("新增收藏短语…", text: $newText, onCommit: addNew)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                Button(action: addNew) {
                    Text("添加").font(Theme.ui(13, .semibold)).foregroundColor(Theme.teal)
                        .padding(.horizontal, 12).frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.teal.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 360)
        .background(Theme.bg)
    }

    private func addNew() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        state.addFavorite(t)
        newText = ""
    }
}

private struct FavoriteRow: View {
    @EnvironmentObject var state: AppState
    let text: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button { state.sendFavorite(text) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.teal)
                    Text(text).font(Theme.ui(13)).foregroundColor(Theme.fg)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("发到当前终端并回车")

            Button { state.removeFavorite(text) } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundColor(Theme.dim)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("删除收藏")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.white.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
    }
}
