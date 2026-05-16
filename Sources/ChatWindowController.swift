import AppKit
import SwiftUI

/// 聊天窗口控制器：用 NSWindow 替代 NSPopover，
/// 显示/隐藏时从灵动岛位置「展开/收回」动画，
/// 但保留 NSWindow 可拖拽调整大小的能力。
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    /// 上次触发显示时用的锚点（灵动岛胶囊或菜单栏按钮），用于 hide 时收回方向
    private weak var lastAnchor: NSView?
    /// 动画进行中 —— 期间不要把动画 frame 当作"用户调整尺寸"保存
    private var isAnimating = false

    /// 当前是"hover 模式"打开的吗？（鼠标悬停灵动岛 500ms 自动展开）
    /// hover 模式下额外行为：windowDidResignKey + 鼠标不在窗口内 → 立即 hide；Esc → hide。
    /// 用户主动 ⌘⇧H / 点关闭 hide 后 → 重置为 false
    private(set) var isInHoverMode: Bool = false

    /// hover 模式下的本地按键监听器（Esc 收回）
    private var hoverModeKeyMonitor: Any?

    /// hover 模式：提供灵动岛 NSWindow.frame，用于判断"鼠标在 island + chat 连通区"。
    /// 由 AppDelegate 在 island 创建后注入；nil 表示只判 chatWindow.frame
    var islandFrameProvider: () -> NSRect? = { nil }

    /// hover 模式下的鼠标位置 monitor（local + global，缺一不可：
    /// local 处理 app active 时；global 处理鼠标移到别的 app / 桌面时）
    private var hoverMouseLocalMonitor: Any?
    private var hoverMouseGlobalMonitor: Any?
    /// 鼠标"曾经"进入过 hover 区，才允许"离开"触发 hide。
    /// 防止聊天窗刚展开瞬间鼠标还没到达就立刻被判定为"已离开"
    private var hoverMouseEnteredOnce: Bool = false
    /// 鼠标离开 500ms 防抖 task
    private var hoverExitHideTask: Task<Void, Never>?

    private let savedFrameKey = "HermesPetChatFrame"
    private let defaultSize = NSSize(width: 420, height: 580)

    var isVisible: Bool { window.isVisible }

    init(viewModel: ChatViewModel) {
        let initialFrame = NSRect(origin: .zero, size: NSSize(width: 420, height: 580))
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 隐藏标题栏，但保留可拖拽 + 可调整大小
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = HermesWindowLevel.chat   // 见 WindowLevels.swift 规范
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentMinSize = NSSize(width: 360, height: 360)
        window.contentMaxSize = NSSize(width: 1400, height: 1600)
        window.title = "HermesPet"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true

        // 隐藏 traffic light 三个按钮（更像浮窗，不像普通应用窗口）
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // SwiftUI 内容
        let hosting = NSHostingController(rootView: ChatView(viewModel: viewModel))
        hosting.sizingOptions = []  // 让 SwiftUI 跟着窗口大小走
        window.contentViewController = hosting

        self.window = window
        super.init()
        window.delegate = self
    }

    // MARK: - Public

    func show(near anchor: NSView? = nil, hoverMode: Bool = false) {
        guard !isVisible else { return }
        self.lastAnchor = anchor
        self.isInHoverMode = hoverMode

        let target = savedFrame ?? defaultFrame(near: anchor)
        let start = collapsedFrame(near: anchor)

        isAnimating = true
        // 动画期间放开 contentMinSize，让 frame 能缩到很小
        window.contentMinSize = .zero
        window.setFrame(start, display: false)
        window.alphaValue = 0
        // SwiftUI 内容（NSHostingView）单独控制可见性：动画前 60% 维持 0，避免被压缩 frame 上的
        // 错位 layout 闪现给用户看（header 文字 wrap 成 3 行 / scrollbar 抖动 等）。
        // 跟 window.alphaValue 解耦：磨砂背景动画照跑，仅 SwiftUI 内容延迟淡入
        window.contentView?.alphaValue = 0
        window.orderFront(nil)
        // ⚠️ 立刻 makeKey + 把焦点设到输入框 —— 不能等动画结束才做。
        // 否则用户在 0.34s 入场动画期间打字，按键全被吞（NSWindow 不是 key + firstResponder 不接键盘）。
        // 第一次按键不被记录的 bug 就是这个 + 即使 makeKey 后 firstResponder 默认是 contentView 也不接键盘
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        focusInputField()

        // hover 模式下装一个 Esc 监听 + mouseMoved 监听 —— 用户按 Esc 或鼠标真离开都收回
        if hoverMode {
            installHoverModeKeyMonitor()
            installHoverMouseTracking()
        } else {
            uninstallHoverModeKeyMonitor()
            uninstallHoverMouseTracking()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            // CA 没有 spring，用 easeOut + 略长 duration 模拟弹性入场
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // 动画结束 —— 恢复 contentMinSize，让用户后续不能拖太小
                self.window.contentMinSize = NSSize(width: 360, height: 360)
                self.isAnimating = false
                // 兜底再设一次焦点：极端情况下 NSHostingView 在动画期间才完成 mount，
                // 第一次 focusInputField() 可能没找到 NSTextView
                self.focusInputField()
            }
        })

        // SwiftUI 内容淡入：setFrame 跑到 60%（0.20s）时再启动，让 frame 接近 target 再显现。
        // 期间 NSHostingView 仍在做 layout 计算（CPU 成本不变），但用户看不到中间帧的错位状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self = self, self.isVisible else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.window.contentView?.animator().alphaValue = 1
            }
        }
    }

    /// 把窗口的 firstResponder 设到聊天输入框的 NSTextView。
    /// 用递归 BFS 找 NSHostingView 里第一个 NSTextView —— SwiftUI 把 SendOnEnterTextEditor
    /// 包成 NSScrollView 里的 NSTextView，view 层级是动态的，没法静态拿引用
    private func focusInputField() {
        guard let root = window.contentView else { return }
        if let tv = Self.findFirstTextView(in: root) {
            window.makeFirstResponder(tv)
        }
    }

    private static func findFirstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findFirstTextView(in: sub) { return found }
        }
        return nil
    }

    func hide() {
        guard isVisible else { return }

        // hide 总是关闭 hover 模式：用户主动 ⌘⇧H / 点关闭 / Esc / windowDidResignKey / 鼠标离开 都走这里
        isInHoverMode = false
        uninstallHoverModeKeyMonitor()
        uninstallHoverMouseTracking()

        // 退出前先把当前 frame 保存（万一用户没动也保存一次默认值）
        if !isAnimating { saveFrame() }

        let end = collapsedFrame(near: lastAnchor)
        let originalFrame = window.frame  // 隐藏前的真实 frame，结束后恢复

        isAnimating = true
        window.contentMinSize = .zero  // 让窗口能缩到锚点尺寸
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.0, 0.85, 0.4)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(end, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.window.orderOut(nil)
                self.window.setFrame(originalFrame, display: false)
                self.window.alphaValue = 1
                self.window.contentMinSize = NSSize(width: 360, height: 360)
                self.isAnimating = false
            }
        })
    }

    func toggle(near anchor: NSView? = nil) {
        if isVisible {
            hide()
        } else {
            show(near: anchor)
        }
    }

    // MARK: - NSWindowDelegate

    /// 用户拖完调整大小才保存（动画期间不保存）
    func windowDidEndLiveResize(_ notification: Notification) {
        if !isAnimating { saveFrame() }
    }

    func windowDidMove(_ notification: Notification) {
        if !isAnimating { saveFrame() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// hover 模式下：用户切去别的 app，windowDidResignKey 触发 → 立即 hide。
    /// 这是"focus 锁定语义"的解锁路径：聊天窗获得 key 即锁，失去 key 即解锁并收回。
    /// 非 hover 模式（⌘⇧H / 点击灵动岛）打开的窗口不受此影响 —— 切到别处不会丢窗口
    func windowDidResignKey(_ notification: Notification) {
        guard isInHoverMode else { return }
        // 跨窗口 setFrame 安全：异步到下一个 runloop 避免嵌套 layout
        // （见 CLAUDE.md 决策 #5：聊天窗的 setFrame 不能同步触发别的 window 的 setFrame）
        DispatchQueue.main.async { [weak self] in
            self?.hide()
        }
    }

    // MARK: - hover 模式按键监听

    /// 装一个 local key monitor 拦截 Esc 收回 hover 展开的聊天窗。
    /// 仅在窗口是 key（即用户已经聚焦聊天窗）时才生效 —— 这是 local monitor 的天然特性。
    private func installHoverModeKeyMonitor() {
        if hoverModeKeyMonitor != nil { return }
        hoverModeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc keyCode = 53
            guard let self = self, event.keyCode == 53, self.isInHoverMode else {
                return event
            }
            // 类已 @MainActor → 此闭包推断为 @MainActor isolated，直接调 hide() 即可，
            // 不必再 Task { @MainActor in } 套一层（省一个 runloop hop，Esc 响应更跟手）
            self.hide()
            return nil   // 吞掉事件，不让 SwiftUI 再处理
        }
    }

    private func uninstallHoverModeKeyMonitor() {
        if let m = hoverModeKeyMonitor {
            NSEvent.removeMonitor(m)
            hoverModeKeyMonitor = nil
        }
    }

    // MARK: - hover 模式鼠标位置跟踪

    /// 装两个 mouseMoved monitor —— local 处理 app active 时（用户在聊天窗内）；
    /// global 处理鼠标移到别的 app / 桌面时。两者每次 mouseMoved 都调 `evaluateHoverMousePosition()`。
    ///
    /// 行为：
    /// - 鼠标在 chatWindow.frame 或 islandFrame 或两者间的 gap 内 → set `enteredOnce=true` + cancel hideTask
    /// - 鼠标不在上述区 + `enteredOnce=true` → schedule 500ms 后 hide
    /// - 鼠标不在 + 还没进过（`enteredOnce=false`） → 不动作（防聊天窗刚展开瞬间鼠标还没到就被收）
    private func installHoverMouseTracking() {
        uninstallHoverMouseTracking()
        hoverMouseEnteredOnce = false

        // local: app 是 frontmost 时（鼠标在我们自己的 window 内 / 上）
        hoverMouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.evaluateHoverMousePosition()
            }
            return event
        }
        // global: 鼠标在桌面 / 别的 app 上时（local 收不到）
        hoverMouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateHoverMousePosition()
            }
        }
    }

    private func uninstallHoverMouseTracking() {
        if let m = hoverMouseLocalMonitor {
            NSEvent.removeMonitor(m)
            hoverMouseLocalMonitor = nil
        }
        if let m = hoverMouseGlobalMonitor {
            NSEvent.removeMonitor(m)
            hoverMouseGlobalMonitor = nil
        }
        hoverExitHideTask?.cancel()
        hoverExitHideTask = nil
        hoverMouseEnteredOnce = false
    }

    /// 判定鼠标是否在 "聊天窗 ∪ 灵动岛 ∪ 两者间垂直走廊 ∪ 本 app 任何子窗口" 内。
    /// - 走廊：chat 顶沿和 island 底沿之间那段竖直空间，避免从灵动岛滑下聊天窗时短暂"不在"两个 rect 内
    /// - 本 app 子窗口：设置 popover / sheet / mini card / 桌宠 等，避免点 popover 时被误收
    @MainActor
    private func evaluateHoverMousePosition() {
        guard isInHoverMode, isVisible, !isAnimating else { return }
        let mouse = NSEvent.mouseLocation

        // 1) 鼠标在本 app 任何 visible window 内 → 视为还在交互中，不收
        // 覆盖：点击设置（NSPopover 独立窗口）/ 任何弹出 sheet / mini card / 桌宠 / 灵动岛 等
        // 鼠标完全离开本 app 所有窗口（到桌面 / 别的 app）才走下面的真离开判定
        let mouseInAnyAppWindow = NSApp.windows.contains { win in
            win.isVisible && win.frame.contains(mouse)
        }
        if mouseInAnyAppWindow {
            hoverMouseEnteredOnce = true
            hoverExitHideTask?.cancel()
            hoverExitHideTask = nil
            return
        }

        let chatFrame = window.frame
        var inside = chatFrame.contains(mouse)
        if let iframe = islandFrameProvider() {
            if !inside, iframe.contains(mouse) {
                inside = true
            }
            // 处理 island 跟 chatFrame 之间的 gap（默认 8pt topPadding，加上灵动岛 idle 半隐藏的几 pt）
            if !inside, chatFrame.maxY < iframe.minY {
                let gap = NSRect(
                    x: min(iframe.minX, chatFrame.minX),
                    y: chatFrame.maxY,
                    width: max(iframe.maxX, chatFrame.maxX) - min(iframe.minX, chatFrame.minX),
                    height: iframe.minY - chatFrame.maxY
                )
                if gap.contains(mouse) {
                    inside = true
                }
            }
        }

        if inside {
            hoverMouseEnteredOnce = true
            hoverExitHideTask?.cancel()
            hoverExitHideTask = nil
            return
        }

        // 鼠标在 hover 区外
        guard hoverMouseEnteredOnce else { return }   // 还没进过，忽略
        if hoverExitHideTask != nil { return }        // 已有 hideTask 在跑

        hoverExitHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            guard let self = self, self.isInHoverMode, self.isVisible else { return }
            // 跨窗口安全：异步到下一个 runloop 避免嵌套 layout（CLAUDE.md 决策 #5）
            self.hide()
        }
    }

    // MARK: - Frame 计算

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: savedFrameKey)
    }

    private var savedFrame: NSRect? {
        guard let str = UserDefaults.standard.string(forKey: savedFrameKey) else { return nil }
        let r = NSRectFromString(str)
        return (r.width >= 360 && r.height >= 360) ? r : nil
    }

    /// 起点/终点 frame：锚点位置，**小药丸尺寸**（不是 1×1，避免 view 极度挤压变形）。
    /// 大约 100×30，看起来就像从灵动岛胶囊"溢出"成窗口。
    private func collapsedFrame(near anchor: NSView?) -> NSRect {
        let collapseSize = NSSize(width: 100, height: 30)
        if let anchor = anchor, let anchorWindow = anchor.window {
            let anchorRect = anchor.convert(anchor.bounds, to: nil)
            let screenRect = anchorWindow.convertToScreen(anchorRect)
            return NSRect(
                x: screenRect.midX - collapseSize.width / 2,
                y: screenRect.minY - collapseSize.height / 2,
                width: collapseSize.width,
                height: collapseSize.height
            )
        }
        if let screen = NSScreen.main {
            return NSRect(
                x: screen.frame.midX - collapseSize.width / 2,
                y: screen.frame.midY - collapseSize.height / 2,
                width: collapseSize.width,
                height: collapseSize.height
            )
        }
        return .zero
    }

    /// 首次显示时的默认 frame（锚点正下方）。
    /// 如果锚点到屏幕底部空间不够 580pt，**自动收紧高度**避免窗口被屏幕底裁掉。
    /// 横向同理：超出屏幕左右边界时自动夹回 visibleFrame 内。
    private func defaultFrame(near anchor: NSView?) -> NSRect {
        let size = defaultSize
        if let anchor = anchor, let anchorWindow = anchor.window,
           let screen = anchorWindow.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let anchorRect = anchor.convert(anchor.bounds, to: nil)
            let screenRect = anchorWindow.convertToScreen(anchorRect)
            let visible = screen.visibleFrame

            // 高度：锚点底部到屏幕底部的可用空间（留 8pt margin）
            let topPadding: CGFloat = 8
            let bottomMargin: CGFloat = 12
            let available = (screenRect.minY - topPadding) - visible.minY - bottomMargin
            let minHeight: CGFloat = 360            // 跟 contentMinSize 一致
            let effectiveHeight = max(minHeight, min(size.height, available))

            // 横向：以锚点为中心，但夹到屏幕可见区
            var x = screenRect.midX - size.width / 2
            x = max(visible.minX + bottomMargin, min(visible.maxX - size.width - bottomMargin, x))

            let y = screenRect.minY - effectiveHeight - topPadding
            return NSRect(origin: NSPoint(x: x, y: y), size: NSSize(width: size.width, height: effectiveHeight))
        }
        if let screen = NSScreen.main {
            return NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        return NSRect(x: 100, y: 100, width: size.width, height: size.height)
    }
}
