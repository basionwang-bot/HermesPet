import AppKit
import SwiftUI

/// 知识图谱「云图」全屏覆盖层 —— 全局快捷键（默认 ⌘⇧G）呼出。
///
/// 透明 + behind-window 毛玻璃（macOS 26 液态玻璃质感，桌面隐约可见）。可交互（悬停/点击），
/// Esc 或点空白处关闭。点对话节点 → 重开那段对话并关掉云图。
///
/// 形态参考 `IntelligenceOverlayController`（全屏 borderless + clear 背景），但这层要收鼠标，
/// 所以 `ignoresMouseEvents = false` + 自定义可成 key 的窗口（Esc / 键盘要 key 窗口）。
@MainActor
final class KnowledgeGraphOverlayController {
    static let shared = KnowledgeGraphOverlayController()

    private var window: GraphOverlayWindow?
    private var effectView: NSVisualEffectView?
    private var hostingView: NSHostingView<AnyView>?
    private(set) var isShown = false

    private init() {}

    func toggle(viewModel: ChatViewModel) {
        if isShown { hide() } else { show(viewModel: viewModel) }
    }

    func show(viewModel: ChatViewModel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if window == nil { createWindow(screen: screen) }
        guard let window, let effectView else { return }
        window.setFrame(screen.frame, display: true)
        effectView.frame = window.contentLayoutRect

        // 实测当前屏幕的系统栏占用：窗口仍全屏铺满（背景沉浸），但把云图元素收进这些安全区，
        // 避免对话点落在顶部菜单栏(含刘海)或底部/侧边 Dock 下面导致点不中。
        let f = screen.frame, vf = screen.visibleFrame
        let menuBarH = max(0, f.maxY - vf.maxY)
        let dockB = max(0, vf.minY - f.minY)
        let dockL = max(0, vf.minX - f.minX)
        let dockR = max(0, f.maxX - vf.maxX)

        let root = AnyView(
            KnowledgeGraphView(
                viewModel: viewModel,
                onOpen: { [weak self] id in
                    self?.hide()
                    viewModel.openFromHistory(id: id)
                },
                onDismiss: { [weak self] in self?.hide() },
                menuBarHeight: menuBarH,
                dockBottom: dockB,
                dockLeft: dockL,
                dockRight: dockR
            )
        )
        let host = NSHostingView(rootView: root)
        host.frame = effectView.bounds
        host.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) { host.sizingOptions = [] }   // 决策 #6：禁反向 resize
        // 换掉旧 host
        hostingView?.removeFromSuperview()
        effectView.addSubview(host)
        hostingView = host

        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isShown = true
    }

    func hide() {
        isShown = false
        guard let window else { return }
        // 退场溶解：窗口 alpha 淡出，再真正 orderOut + 卸 host（停 TimelineView）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // completionHandler 是 @Sendable，显式 hop 回主 actor 再访问 @MainActor 状态（决策 #5）
            MainActor.assumeIsolated {
                self?.window?.orderOut(nil)
                self?.window?.alphaValue = 1
                self?.hostingView?.removeFromSuperview()
                self?.hostingView = nil
            }
        })
    }

    private func createWindow(screen: NSScreen) {
        let w = GraphOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false

        // behind-window 毛玻璃：桌面被柔和模糊，云图浮在上面（macOS 26 质感 + 仍"透明"看得见后面）
        let effect = NSVisualEffectView(frame: w.contentLayoutRect)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        w.contentView = effect

        window = w
        effectView = effect
    }
}

/// borderless 窗口默认不能成 key；覆盖让它能收键盘（Esc）+ 鼠标。
final class GraphOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
