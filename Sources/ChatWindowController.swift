import AppKit
import SwiftUI

/// 聊天窗口控制器：用 NSWindow 替代 NSPopover，
/// 显示/隐藏时从灵动岛位置「展开/收回」动画，
/// 但保留 NSWindow 可拖拽调整大小的能力。
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    /// 强引用 NSHostingController —— 因为我们用 NSVisualEffectView 作为 window.contentView，
    /// 不再走 contentViewController 的路径，但仍要让 hosting controller 活着持有 SwiftUI 状态
    private let hosting: NSHostingController<ChatView>

    /// 上次触发显示时用的锚点（灵动岛胶囊或菜单栏按钮），用于 hide 时收回方向
    private weak var lastAnchor: NSView?
    /// 动画进行中 —— 期间不要把动画 frame 当作"用户调整尺寸"保存
    private var isAnimating = false

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

        // 用 NSVisualEffectView 作为 contentView 提供"浮窗白磨砂" —— 这是 Spotlight /
        // 通知中心 / Control Center 同款效果。SwiftUI 的 .background(.regularMaterial)
        // 套在 backgroundColor = .clear 的 NSWindow 上偏灰偏暗，缺少原生 vibrancy；
        // 必须用 AppKit 原生的 NSVisualEffectView 才能拿到那种通透白磨砂。
        let effect = NSVisualEffectView()
        // .popover：Spotlight / Calendar popover 同款，亮、白、干净的浮窗磨砂
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active            // 即使窗口失焦也保持磨砂（浮窗一直在前）
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14   // 跟 ChatView 的 clipShape 对齐
        effect.layer?.masksToBounds = true
        // SwiftUI hosting view 作为子视图填满 effect，保证 SwiftUI 内容渲染在磨砂层之上
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        window.contentView = effect

        self.window = window
        self.hosting = hosting
        super.init()
        window.delegate = self
    }

    // MARK: - Public

    func show(near anchor: NSView? = nil) {
        guard !isVisible else { return }
        self.lastAnchor = anchor

        let target = savedFrame ?? defaultFrame(near: anchor)
        let start = collapsedFrame(near: anchor)

        isAnimating = true
        // 动画期间放开 contentMinSize，让 frame 能缩到很小
        window.contentMinSize = .zero
        window.setFrame(start, display: false)
        window.alphaValue = 0
        window.orderFront(nil)
        // ⚠️ 立刻 makeKey + 把焦点设到输入框 —— 不能等动画结束才做。
        // 否则用户在 0.34s 入场动画期间打字，按键全被吞（NSWindow 不是 key + firstResponder 不接键盘）。
        // 第一次按键不被记录的 bug 就是这个 + 即使 makeKey 后 firstResponder 默认是 contentView 也不接键盘
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        focusInputField()

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
