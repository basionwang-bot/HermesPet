import AppKit
import CoreGraphics

/// 屏幕操控内核（v1.6「AI 看屏幕」里程碑 1）—— HermesPet 的「手」。
/// 用 `CGEvent` 模拟人类的鼠标 / 键盘操作，让 AI 将来能真去操作别的软件的 GUI。
///
/// ⚠️ **坐标系**：所有鼠标坐标都是**全局显示坐标、原点在左上角**（CGEvent / Quartz 习惯，
/// 跟 NSEvent / NSScreen 的左下角原点相反）。里程碑 2 把 OCR 方框映射成屏幕坐标时按这个来。
/// 工具方法 `screenTopLeftPoint(fromCocoa:)` 负责左下↔左上翻转。
///
/// ⚠️ **权限**：模拟鼠标键盘需要「辅助功能」权限（跟 `AccessibilityReader` 同一个）。
/// 未授权时系统会**静默拦截** post（不报错、动作不生效），所以调用前先 `ensureTrusted()`。
///
/// 线程：纯 CGEvent、无 `@MainActor` 状态，可在任意线程调用；down/up 之间留小延时让目标 app 接得住。
enum ScreenActuator {

    // MARK: - 权限

    /// 是否已获「辅助功能」授权（模拟事件能否生效的前提）
    static var isTrusted: Bool { AccessibilityReader.isTrusted }

    /// 检查授权，未授权则弹系统引导窗。返回当前是否已授权。
    @discardableResult
    static func ensureTrusted() -> Bool {
        if AccessibilityReader.isTrusted { return true }
        return AccessibilityReader.requestTrustWithPrompt()
    }

    // MARK: - 坐标工具

    /// 把 Cocoa 坐标（左下角原点，NSScreen / NSEvent 那套）翻成 CGEvent 用的左上角原点坐标。
    /// 仅按主屏高度翻转——多屏精确映射留到里程碑 2 跟窗口 frame 一起处理。
    static func screenTopLeftPoint(fromCocoa p: CGPoint) -> CGPoint {
        let h = NSScreen.main?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    // MARK: - 鼠标

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .combinedSessionState)
    }

    /// 移动鼠标到指定屏幕坐标（左上角原点）。
    static func moveMouse(to point: CGPoint) {
        postMouse(.mouseMoved, point, .left, clickState: 0)
    }

    /// 在指定坐标单击左键（先移过去，再按下抬起）。
    static func click(at point: CGPoint) {
        postMouse(.mouseMoved, point, .left, clickState: 0)
        postMouse(.leftMouseDown, point, .left, clickState: 1)
        postMouse(.leftMouseUp, point, .left, clickState: 1)
    }

    /// 双击左键。
    static func doubleClick(at point: CGPoint) {
        postMouse(.mouseMoved, point, .left, clickState: 0)
        postMouse(.leftMouseDown, point, .left, clickState: 1)
        postMouse(.leftMouseUp, point, .left, clickState: 1)
        postMouse(.leftMouseDown, point, .left, clickState: 2)
        postMouse(.leftMouseUp, point, .left, clickState: 2)
    }

    /// 右键单击（呼出上下文菜单）。
    static func rightClick(at point: CGPoint) {
        postMouse(.mouseMoved, point, .left, clickState: 0)
        postMouse(.rightMouseDown, point, .right, clickState: 1)
        postMouse(.rightMouseUp, point, .right, clickState: 1)
    }

    /// 从 from 拖拽到 to（按住左键移动）。中间插值 `steps` 步让轨迹更像人手，部分 app 才认。
    static func drag(from: CGPoint, to: CGPoint, steps: Int = 12) {
        postMouse(.leftMouseDown, from, .left, clickState: 1)
        let n = max(1, steps)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: from.x + (to.x - from.x) * t,
                            y: from.y + (to.y - from.y) * t)
            postMouse(.leftMouseDragged, p, .left, clickState: 1)
            usleep(8_000)
        }
        postMouse(.leftMouseUp, to, .left, clickState: 1)
    }

    private static func postMouse(_ type: CGEventType,
                                  _ point: CGPoint,
                                  _ button: CGMouseButton,
                                  clickState: Int64) {
        guard let e = CGEvent(mouseEventSource: source(),
                              mouseType: type,
                              mouseCursorPosition: point,
                              mouseButton: button) else { return }
        if clickState > 0 {
            // 双击 / 单击的 clickState 必须正确，否则部分 app 收不到「这是一次点击」
            e.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        e.post(tap: .cghidEventTap)
        usleep(6_000)   // ~6ms：给目标 app 反应时间，太快有些 app 收不到 down/up 配对
    }

    // MARK: - 键盘

    /// 输入任意文本（含中文 / emoji）—— 用 `keyboardSetUnicodeString` 注入，不依赖键位映射，
    /// 所以中文、特殊符号都能直接「打」进去，无需切输入法。
    static func typeText(_ text: String) {
        guard let src = source() else { return }
        for ch in text {
            var utf16 = Array(String(ch).utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
            }
            usleep(3_000)
        }
    }

    /// 按一个键（可带修饰键）。keyCode 用 Carbon 的 virtual key code。
    static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let src = source() else { return }
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(4_000)
        up?.post(tap: .cghidEventTap)
    }

    // 常用键位（Carbon virtual key code）
    enum Key {
        static let `return`: CGKeyCode = 36
        static let tab: CGKeyCode = 48
        static let space: CGKeyCode = 49
        static let delete: CGKeyCode = 51   // backspace
        static let escape: CGKeyCode = 53
        static let leftArrow: CGKeyCode = 123
        static let rightArrow: CGKeyCode = 124
        static let downArrow: CGKeyCode = 125
        static let upArrow: CGKeyCode = 126
    }

    /// 按回车（微信等无发送按钮、回车即发；或确认 / 换行）。
    static func pressReturn() { pressKey(Key.return) }
}
