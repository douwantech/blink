import SwiftUI

private let kChatBottom = "chat-bottom-anchor"

struct TerminalColumn: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if state.mode == .terminal { terminalBody } else { chatBody }
                if state.reconnecting { reconnectOverlay }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            quickBar
            statusBar
        }
        .background(Theme.term)
        .overlay(alignment: .bottom) { if let t = state.toast { toast(t) } }
    }

    // MARK: Terminal body — real SwiftTerm PTY

    @ViewBuilder
    private var terminalBody: some View {
        if state.activeSession.placeholder {
            VStack(spacing: 12) {
                if state.activeSession.id == "loading" {
                    ProgressView().controlSize(.large).tint(Theme.teal)
                    Text("正在枚举本机会话…").font(Theme.mono(12)).foregroundColor(Theme.sub)
                } else {
                    Image(systemName: "sidebar.left").font(.system(size: 26)).foregroundColor(Theme.dim)
                    Text("从左侧选择一个会话打开").font(Theme.ui(13)).foregroundColor(Theme.sub)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TerminalContainer()
                .padding(.horizontal, 6).padding(.vertical, 6)
        }
    }

    // MARK: Chat body

    private var chatBody: some View {
        VStack(spacing: 0) {
            // header：对话记录标题 + 返回终端
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 13)).foregroundColor(Theme.teal)
                Text("对话记录").font(Theme.ui(13, .semibold)).foregroundColor(Theme.fg)
                Text("cc-\(state.activeSession.name)").font(Theme.mono(11)).foregroundColor(Theme.sub)
                Spacer()
                Button { state.openHistory() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("终端").font(Theme.ui(12, .semibold))
                    }
                    .foregroundColor(Theme.sub)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(Color.white.opacity(0.02))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }

            ScrollViewReader { proxy in
                GeometryReader { geo in
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(state.activeSession.chat) { c in
                                ChatBubbleRow(block: c, maxBubble: geo.size.width * 0.74)
                            }
                            if state.activeSession.chat.isEmpty {
                                Text("（这个会话还没有对话记录）").font(Theme.ui(13)).foregroundColor(Theme.dim)
                            }
                            // 底部锚点：加载 / 有新内容后自动滚到这里（对话记录看最新的）
                            Color.clear.frame(height: 1).id(kChatBottom)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onChange(of: state.activeSession.chat.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(kChatBottom, anchor: .bottom) }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(kChatBottom, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Reconnect overlay

    private var reconnectOverlay: some View {
        ZStack {
            Theme.bg.opacity(0.72)
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Theme.work)
                Text("重连中 · tmux new-session -A · claude --resume")
                    .font(Theme.mono(13)).foregroundColor(Theme.sub)
            }
        }
    }

    // MARK: Quick bar

    private var quickBar: some View {
        HStack(spacing: 7) {
            PillButton(label: "刷新重连", system: "arrow.clockwise", tint: Theme.work, bg: Theme.work.opacity(0.12)) { state.reconnect() }
            PillButton(label: "休息", system: "moon", tint: Theme.rest, bg: Theme.rest.opacity(0.12)) { state.toggleRestActive() }
            PillButton(label: "关闭", system: "xmark", tint: Color(hex: 0xff5a5c), bg: Color(hex: 0xff5a5c).opacity(0.12)) {
                guard !state.activeSession.placeholder, !state.activeSessionID.isEmpty else { state.showToast("没有可关闭的会话"); return }
                state.closeTab(sessionID: state.activeSessionID)
            }
            VDivider().padding(.horizontal, 2)
            PillButton(label: "收藏", system: "star", tint: Color(hex: 0xf5c451), bg: Color.white.opacity(0.05)) {
                state.loadFavorites(); state.showFavorites.toggle()
            }
            .popover(isPresented: $state.showFavorites, arrowEdge: .bottom) {
                FavoritesPopover().environmentObject(state)
            }
            PillButton(label: "图片", system: "photo", bg: Color.white.opacity(0.05)) { state.showToast("插入图片…") }
            PillButton(label: "历史", system: "clock.arrow.circlepath",
                       tint: state.mode == .chat ? Theme.teal : Theme.sub,
                       bg: state.mode == .chat ? Theme.teal.opacity(0.12) : Color.white.opacity(0.05)) { state.openHistory() }
            PillButton(label: "浏览器", system: "globe", tint: Theme.rest, bg: Color.white.opacity(0.05)) { state.showToast("打开内置浏览器") }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("cc-\(state.activeSession.name)")
            Text("·"); Text("blinkd").foregroundColor(Theme.teal); Text("·"); Text("UTF-8")
            Spacer()
            Text("⌘R 重连"); Text("⌘K 清屏"); Text("⌘⇧V 语音")
        }
        .font(Theme.mono(11)).foregroundColor(Theme.dim)
        .padding(.horizontal, 16).frame(height: 24)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    // MARK: Toast

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(12.5)).foregroundColor(Theme.fg)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(hex: 0x1c2128).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hair2)))
            .padding(.bottom, 92)
            .transition(.opacity)
    }
}

// MARK: - Chat bubble (方案 A：iMessage 式气泡)

/// 一条对话气泡：你靠右绿气泡，Claude 靠左深卡＋蓝头像。maxBubble = 气泡最大宽度。
/// 正文里的图片（markdown ![](url) / 图床 URL / 本地绝对路径）直接渲染出来。
struct ChatBubbleRow: View {
    let block: ChatBlock
    let maxBubble: CGFloat

    private var isYou: Bool { block.role == "YOU" }
    private var cap: CGFloat { min(max(maxBubble, 140), 600) }

    var body: some View {
        // 用 Spacer 把气泡挤到一边：你靠右、Claude 靠左。气泡按内容宽度自适应
        // （封顶 cap），短消息就短、长消息才换行，不再撑满整行。
        HStack(alignment: .top, spacing: 9) {
            if isYou { Spacer(minLength: 44) }
            if !isYou { avatar }
            bubble
            if !isYou { Spacer(minLength: 44) }
        }
    }

    private var bubble: some View {
        // BubbleWidth 自定义布局：给内容提议 cap-26 宽，取内容「实际用到」的宽度——
        // 短消息按内容收窄、长消息在 cap 处换行（不截断），都不撑满整行。
        BubbleWidth(maxWidth: cap - 26) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AppState.chatSegments(block.text)) { seg in
                    switch seg {
                    case .text(let t):
                        MarkdownText(raw: t, base: isYou ? Color(hex: 0xd8f6e8) : Theme.fg)
                    case .remoteImage(let url):
                        ChatImage(remote: url, cap: cap)
                    case .localImage(let path):
                        ChatImage(localPath: path, cap: cap)
                    }
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 14, bottomLeadingRadius: isYou ? 14 : 5,
                bottomTrailingRadius: isYou ? 5 : 14, topTrailingRadius: 14, style: .continuous)
                .fill(isYou ? Theme.green2.opacity(0.14) : Theme.panel3)
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14, bottomLeadingRadius: isYou ? 14 : 5,
                        bottomTrailingRadius: isYou ? 5 : 14, topTrailingRadius: 14, style: .continuous)
                        .stroke(isYou ? Theme.green2.opacity(0.28) : Theme.hair))
        )
    }

    private var avatar: some View {
        Text("C")
            .font(.system(size: 10, weight: .heavy)).foregroundColor(Color(hex: 0x04122b))
            .frame(width: 22, height: 22)
            .background(Circle().fill(LinearGradient(colors: [Theme.blue, Color(hex: 0x3f7fe0)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .padding(.top, 2)
    }
}

/// 让气泡按内容宽度 hug、但封顶 maxWidth：给子视图提议 maxWidth 宽，取它换行后
/// 「实际用到」的宽度（短内容 < maxWidth、长内容换行到 = maxWidth），不填充、不截断。
struct BubbleWidth: Layout {
    var maxWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews.first?.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil)) ?? .zero
        return CGSize(width: min(s.width, maxWidth), height: s.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// 气泡里的一张图：远端 URL 走 AsyncImage，本地路径直接 NSImage 读盘。
/// 加载不出（门禁 / 404 / 文件没了）就显示一枚小占位，不撑破气泡。
struct ChatImage: View {
    var remote: URL? = nil
    var localPath: String? = nil
    let cap: CGFloat

    private var side: CGFloat { min(cap - 26, 460) }

    var body: some View {
        Group {
            if let url = remote {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .empty: placeholder(spinning: true)
                    default: placeholder(spinning: false)
                    }
                }
            } else if let p = localPath, let ns = NSImage(contentsOfFile: p) {
                Image(nsImage: ns).resizable().scaledToFit()
            } else {
                placeholder(spinning: false)
            }
        }
        .frame(maxWidth: side, maxHeight: side)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.hair))
    }

    private func placeholder(spinning: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Theme.panel2)
            if spinning { ProgressView().controlSize(.small).tint(Theme.dim) }
            else { Image(systemName: "photo").font(.system(size: 18)).foregroundColor(Theme.dim) }
        }
        .frame(width: 120, height: 84)
    }
}

// MARK: - Blinking caret

struct Caret: View {
    @State private var on = false
    var body: some View {
        Rectangle().fill(Theme.cyan)
            .frame(width: 8, height: 15)
            .opacity(on ? 0.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
