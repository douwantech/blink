import AppKit
import SwiftUI
import Combine

/// 承载 HUDView 的悬浮面板：不抢焦点（当前 app 仍持有输入焦点，转写完 ⌘V 才粘得回去），
/// 悬浮在所有窗口之上、跨所有桌面空间。监听听写状态自动显示 / 隐藏。
final class HUDPanelController {
    static let shared = HUDPanelController()

    /// 比状态栏高一档。之前用 .statusBar(25)，和别的 app 的悬浮窗/HUD 同级——同级窗口按
    /// 谁后 orderFront 谁在上，对面一刷新就把我们压下去；全屏播放器、会议悬浮窗也盖得住。
    /// screenSaver(1000) 在系统里只比 Dock 拖拽反馈那几档低，正常 app 碰不到。
    private static let topLevel: NSWindow.Level = .screenSaver

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var keepTopTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    func begin() {
        // 跟着听写状态走：非 idle 就显示，idle 就隐藏。
        cancellable = DictationController.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                if phase == .idle { self?.hide() } else { self?.show() }
            }

        // 切 app / 切桌面空间 / 进出全屏时，系统可能把这个不激活面板排到别人后面，
        // 重新置顶一次（只在显示中才动，平时零开销）。
        let nc = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.raiseIfVisible()
            }
            workspaceObservers.append(token)
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
        p.level = Self.topLevel
        // .canJoinAllSpaces + .fullScreenAuxiliary：跟到每个桌面空间，也能浮在别的 app
        // 的全屏窗口之上（全屏 app 独占一个 space，少了 fullScreenAuxiliary 就只能看它背面）。
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
        p.level = Self.topLevel              // 每次显示都重设：被系统降过档也能回来
        p.orderFrontRegardless()             // 不 makeKey：不抢焦点
        startKeepingOnTop()
    }

    private func hide() {
        stopKeepingOnTop()
        panel?.orderOut(nil)
    }

    /// 只在显示中重新置顶；不重新定位，免得听写途中面板跳位置。
    private func raiseIfVisible() {
        guard let p = panel, p.isVisible else { return }
        p.level = Self.topLevel
        p.orderFrontRegardless()
    }

    /// 通知不一定覆盖所有把我们压下去的情形（比如别的 app 不激活就新开一个同级悬浮窗），
    /// 所以显示期间再补一个低频巡检。HUD 只在听写这几秒钟在，1 秒一次可以忽略不计。
    private func startKeepingOnTop() {
        guard keepTopTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.raiseIfVisible()
        }
        RunLoop.main.add(t, forMode: .common)
        keepTopTimer = t
    }

    private func stopKeepingOnTop() {
        keepTopTimer?.invalidate()
        keepTopTimer = nil
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
