import SwiftUI

/// 悬浮听写条：屏幕底部中间的一张深色圆角卡，显示录音状态 + 实时/最终文字。
struct HUDView: View {
    @ObservedObject var d = DictationController.shared
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indicator
            VStack(alignment: .leading, spacing: 4) {
                Text(d.statusLine.isEmpty ? "语音键" : d.statusLine)
                    .font(Theme.ui(12, .semibold))
                    .foregroundColor(d.isError ? Theme.red : statusColor)
                Text(bodyText)
                    .font(Theme.ui(15))
                    .foregroundColor(Theme.fg)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hair2))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        )
        .padding(14)
        .onAppear { pulse = true }
    }

    private var bodyText: String {
        if d.phase == .done && !d.isError { return d.finalText }
        if d.isError { return "" }
        if d.liveText.isEmpty {
            return d.phase == .listening ? "说点什么…" : ""
        }
        return d.liveText
    }

    private var statusColor: Color {
        switch d.phase {
        case .listening: return Theme.red
        case .transcribing: return Theme.teal
        case .done: return Theme.green
        case .idle: return Theme.dim
        }
    }

    @ViewBuilder private var indicator: some View {
        switch d.phase {
        case .listening:
            Circle()
                .fill(Theme.red)
                .frame(width: 13, height: 13)
                .scaleEffect(pulse ? 1.0 : 0.6)
                .opacity(pulse ? 1.0 : 0.5)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                .padding(.top, 3)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .padding(.top, 1)
        case .done:
            Image(systemName: d.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(d.isError ? Theme.red : Theme.green)
                .padding(.top, 2)
        case .idle:
            Circle().fill(Theme.dim).frame(width: 13, height: 13).padding(.top, 3)
        }
    }
}
