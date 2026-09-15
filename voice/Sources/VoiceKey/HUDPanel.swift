import AppKit
import SwiftUI
import Combine

/// 承载 HUDView 的悬浮面板：不抢焦点（当前 app 仍持有输入焦点，转写完 ⌘V 才粘得回去），
/// 悬浮在所有窗口之上、跨所有桌面空间。监听听写状态自动显示 / 隐藏。
final class HUDPanelController {
    static let shared = HUDPanelController()

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    private init() {}

    func begin() {
        // 跟着听写状态走：非 idle 就显示，idle 就隐藏。
        cancellable = DictationController.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                if phase == .idle { self?.hide() } else { self?.show() }
            }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: HUDView())
        hosting.autoresizingMask = [.width, .height]

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 448, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true          // 纯展示，不吃鼠标，别挡住底下的 app
        p.contentView = hosting
        return p
    }

    private func show() {
        let p = panel ?? makePanel()
        panel = p
        p.setContentSize(p.contentView?.fittingSize ?? NSSize(width: 448, height: 96))
        reposition(p)
        p.orderFrontRegardless()             // 不 makeKey：不抢焦点
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    /// 放到当前鼠标所在屏幕的底部中间偏上。
    private func reposition(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = p.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.minY + vf.height * 0.16
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
