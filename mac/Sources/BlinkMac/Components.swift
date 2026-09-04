import SwiftUI

// MARK: - Gradient avatar with initials

struct Avatar: View {
    var text: String
    var grad: [Color]
    var size: CGFloat = 30
    var corner: CGFloat = 9
    var fontSize: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: grad, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Text(text)
                    .font(Theme.ui(fontSize, .bold))
                    .foregroundColor(.white)
            )
    }
}

// MARK: - Status pill

struct StatusPill: View {
    var status: WorkStatus
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 5, height: 5)
            Text(status.label).font(Theme.ui(10, .bold))
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(status.color.opacity(0.16)))
    }
}

// MARK: - Toolbar icon button (SF Symbol)

struct IconButton: View {
    var system: String
    var color: Color = Theme.sub
    var size: CGFloat = 30
    var iconSize: CGFloat = 16
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundColor(color)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Quick-action pill

struct PillButton: View {
    var label: String
    var system: String
    var tint: Color = Theme.fg
    var bg: Color = Theme.fill2
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system).font(.system(size: 12, weight: .semibold))
                Text(label).font(Theme.ui(12, .medium))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(hovering ? 0.10 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Small vertical divider chip

struct VDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hair2).frame(width: 1, height: 22)
    }
}
