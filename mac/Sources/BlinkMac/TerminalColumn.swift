import SwiftUI

struct TerminalColumn: View {
    @EnvironmentObject var state: AppState

    var hasText: Bool { !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(Theme.hair)

            ZStack {
                if state.mode == .terminal { terminalBody } else { chatBody }
                if state.reconnecting { reconnectOverlay }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            quickBar
            composer
            statusBar
        }
        .background(Theme.term)
        .overlay(alignment: .bottom) { if let t = state.toast { toast(t) } }
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(state.activeSession.status.color).frame(width: 7, height: 7)
                Text("claude").font(Theme.mono(12)).foregroundColor(Theme.fg)
            }
            .padding(.horizontal, 12).frame(height: 26)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                    .fill(Theme.term)
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).stroke(Theme.hair))
            )

            Button { state.showToast("切到 zsh 标签") } label: {
                Text("zsh").font(Theme.mono(12)).foregroundColor(Theme.dim)
                    .padding(.horizontal, 12).frame(height: 26)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { state.toggleMode() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 12))
                    Text(state.mode == .chat ? "终端" : "对话").font(Theme.ui(12, .semibold))
                }
                .foregroundColor(state.mode == .chat ? Theme.teal : Theme.sub)
                .padding(.horizontal, 10).frame(height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.white.opacity(0.02))
    }

    // MARK: Terminal body — real SwiftTerm PTY

    private var terminalBody: some View {
        TerminalContainer()
            .padding(.horizontal, 6).padding(.vertical, 6)
    }

    // MARK: Chat body

    private var chatBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(state.activeSession.chat) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.role).font(Theme.mono(11, .bold)).tracking(1.2).foregroundColor(c.color)
                        Text(c.text).font(Theme.ui(14)).foregroundColor(Theme.fg)
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(c.color).frame(width: 2)
                    }
                }
                if state.activeSession.chat.isEmpty {
                    Text("（这个会话还没有对话记录）").font(Theme.ui(13)).foregroundColor(Theme.dim)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            VDivider().padding(.horizontal, 2)
            PillButton(label: "收藏", system: "star", tint: Color(hex: 0xf5c451), bg: Color.white.opacity(0.05)) { state.showToast("已收藏本会话") }
            PillButton(label: "图片", system: "photo", bg: Color.white.opacity(0.05)) { state.showToast("插入图片…") }
            PillButton(label: "历史", system: "clock.arrow.circlepath", bg: Color.white.opacity(0.05)) { state.showToast("打开历史命令") }
            PillButton(label: "浏览器", system: "globe", tint: Theme.rest, bg: Color.white.opacity(0.05)) { state.showToast("打开内置浏览器") }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    // MARK: Composer

    private var composer: some View {
        ZStack(alignment: .top) {
            if state.recording { recordingBubble.offset(y: -58) }
            HStack(spacing: 10) {
                Button { state.toggleRecording() } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 18))
                        .foregroundColor(state.recording ? Color(hex: 0xff5a5c) : Color.white.opacity(0.82))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)

                TextField("输入命令，或点麦克风说话…", text: $state.draft)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(16))
                    .foregroundColor(Theme.fg)
                    .onSubmit { state.send() }

                Button { state.send() } label: {
                    Image(systemName: "arrowshape.up.fill")
                        .font(.system(size: 15))
                        .foregroundColor(hasText ? Color(hex: 0x06110c) : Color.white.opacity(0.5))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(hasText ? Theme.green : Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 7)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(hasText ? Theme.green.opacity(0.5) : Theme.hair2))
            )
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
    }

    private var recordingBubble: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: 0xff5a5c)).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在听 · 帮我把这个改动…").font(Theme.ui(13)).foregroundColor(Color.white.opacity(0.94))
                Text("本地识别 · 再点麦克风结束").font(Theme.mono(10)).foregroundColor(Theme.dim)
            }
            Spacer()
            Text("本地实时").font(Theme.ui(10, .bold)).foregroundColor(Color(hex: 0x5ff2b3))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0x5ff2b3).opacity(0.14)))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x1b1d21))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.09))))
        .padding(.horizontal, 16)
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
