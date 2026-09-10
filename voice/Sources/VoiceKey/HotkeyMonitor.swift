import AppKit
import CoreGraphics

/// 全局按键监听（需「辅助功能」权限）：
///   • 地球键 / Fn（keyCode 63）：按一下 toggle 听写；顺手吃掉它，免得系统弹表情/切输入法
///   • ⌥Space 兜底：万一地球键被系统占用也能触发
///   • Esc：正在录/展示时取消（其余情况放行）
/// 用 CGEventTap 而不是 NSEvent 全局监听——只有 event tap 能「消费」掉按键。
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastToggle = Date.distantPast

    private let kGlobe = "VoiceKey.hotkey.globe"
    private let kOptSpace = "VoiceKey.hotkey.optSpace"

    var globeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: kGlobe) == nil ? true : UserDefaults.standard.bool(forKey: kGlobe) }
        set { UserDefaults.standard.set(newValue, forKey: kGlobe) }
    }
    var optSpaceEnabled: Bool {
        get { UserDefaults.standard.object(forKey: kOptSpace) == nil ? true : UserDefaults.standard.bool(forKey: kOptSpace) }
        set { UserDefaults.standard.set(newValue, forKey: kOptSpace) }
    }

    private init() {}

    var isRunning: Bool { tap != nil }

    /// 装上 event tap。没有辅助功能权限会失败（返回 false）。
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        runLoopSource = nil
        tap = nil
    }

    /// 触发一次听写开关，250ms 防抖（防单次按压产生两个事件时来回抵消）。
    private func fireToggle() {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.25 else { return }
        lastToggle = now
        DispatchQueue.main.async { DictationController.shared.toggle() }
    }

    // MARK: - 事件处理（返回 nil = 吃掉；返回 event = 放行）

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统在回调超时/异常时会禁用 tap，这里自愈重开。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // 地球键 / Fn：flagsChanged，keyCode 63。
        // 一次物理按压 = 一个「Fn 按下」事件（flags 含 secondaryFn）+ 一个「Fn 抬起」事件。
        // 只在「按下」那个事件 toggle，抬起的不管。不再持久追踪按下沿——消费 Fn 事件会让
        // 抬起的 flagsChanged 收不到、旧的 wasDown 卡死导致第二次按下关不掉。改成每个按下
        // 事件都 toggle + 防抖，既不依赖抬起、也不会卡。
        if type == .flagsChanged, keyCode == 63 {
            guard globeEnabled else { return Unmanaged.passUnretained(event) }
            if flags.contains(.maskSecondaryFn) { fireToggle() }
            return nil  // 吃掉地球键，免得系统弹表情/切输入法
        }

        if type == .keyDown {
            // ⌥Space 兜底触发（只认 option，不夹带 cmd/ctrl）
            if optSpaceEnabled, keyCode == 49,
               flags.contains(.maskAlternate),
               !flags.contains(.maskCommand), !flags.contains(.maskControl) {
                fireToggle()
                return nil
            }
            // Esc：只在正在录/展示时吃掉并取消；空闲时放行给前台 app
            if keyCode == 53, DictationController.shared.phase != .idle {
                DispatchQueue.main.async { DictationController.shared.cancel() }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
