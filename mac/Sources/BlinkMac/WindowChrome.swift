import SwiftUI
import AppKit

/// 盖在自定义顶栏（TopBar）背景上的透明层，补回 `.hiddenTitleBar` 丢掉的标题栏交互：
/// - 双击 → 执行系统「双击窗口标题栏时」设置的动作（放大 / 最小化 / 无），和其它 mac app 一致；
/// - 单击拖拽 → 移动窗口（顶栏整条可拖）。
/// 放 .background(...) 里，前景的按钮/红绿灯照常吃自己的点击，只有空白处落到这层。
struct WindowChromeDragZoom: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragZoomView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragZoomView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { super.mouseDown(with: event); return }
            if event.clickCount == 2 {
                // 读系统「双击标题栏」偏好：Maximize(缺省)=zoom / Minimize / None。
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window.performMiniaturize(nil)
                case "None":      break
                default:          window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)   // 单击拖拽移动窗口
            }
        }
    }
}
