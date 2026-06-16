import AppKit
import SwiftUI

extension Notification.Name {
    /// ChatWindow 调 show()，通知 ChatView 强制 scrollToBottom（恢复用户期望的"看最新消息"位置）
    static let hermesPetChatWindowShown = Notification.Name("HermesPetChatWindowShown")
    /// 聊天窗"始终置顶"开关变化 —— userInfo["pinned"] = Bool
    static let hermesPetChatWindowPinChanged = Notification.Name("HermesPetChatWindowPinChanged")
}

/// 聊天窗"始终置顶" UserDefaults key —— ChatWindowController init 跟 ChatViewModel 用同一个 key
let kChatWindowAlwaysOnTopKey = "chatWindowAlwaysOnTop"

/// 聊天窗口控制器：用 NSWindow 替代 NSPopover，
/// 显示/隐藏时从灵动岛位置「展开/收回」动画，
/// 但保留 NSWindow 可拖拽调整大小的能力。
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    /// 全局单例引用 —— PetHeaderStrip / PermissionWindowController 等需要查 isVisible 来分发
    /// permission 卡片走 PetStrip 还是走原灵动岛卡片。weak 避免循环引用：实际持有者是 AppDelegate
    static weak var shared: ChatWindowController?

    private let window: NSWindow
    /// 聊天 ViewModel —— 窗口级 ⌘V 监听需要它把剪贴板图片塞进 pendingImages
    private let viewModel: ChatViewModel
    /// 窗口级 ⌘V 本地事件监听 token —— 见 installPasteMonitor 注释
    private var pasteEventMonitor: Any?

    /// 上次触发显示时用的锚点（灵动岛胶囊或菜单栏按钮），用于 hide 时收回方向
    private weak var lastAnchor: NSView?
    /// 动画进行中 —— 期间不要把动画 frame 当作"用户调整尺寸"保存
    private var isAnimating = false

    /// 进入写作模式前的普通聊天 frame —— 退出写作模式时恢复
    private var preWritingFrame: NSRect?
    /// 写作模式"最大化"前的 frame —— 再按一次绿键还原。非 nil = 当前处于最大化态
    private var preZoomFrame: NSRect?

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
        // 用户可在 header 切"始终置顶"。默认 true 保持老行为（聊天窗永远 .floating 不被其他 app 盖）
        let pinned = (UserDefaults.standard.object(forKey: kChatWindowAlwaysOnTopKey) as? Bool) ?? true
        window.level = pinned ? HermesWindowLevel.chat : .normal   // 见 WindowLevels.swift 规范
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
        self.viewModel = viewModel
        super.init()
        window.delegate = self
        Self.shared = self

        // 监听用户在 header 切 pin 图标
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePinChanged(_:)),
            name: .hermesPetChatWindowPinChanged,
            object: nil
        )

        // 监听写作模式切换 —— 放大/缩小窗口
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWritingModeChanged(_:)),
            name: .init("HermesPetWritingModeChanged"),
            object: nil
        )

        // 写作模式"最大化/还原"键（header 里那颗）—— SwiftUI 不直接碰 window，按下发通知到这里。
        // 关闭/最小化键已撤掉（关闭整窗收回灵动岛最易同帧崩）：退出写作走 isWritingMode=false，
        // 整窗关闭交回 ⌘W / 点刘海（系统标准关窗，走 windowShouldClose 安全路径）。
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWritingWindowZoom),
            name: .init("HermesPetWritingWindowZoom"), object: nil)

        installPasteMonitor()
    }

    /// 窗口级 ⌘V 监听 —— 修"截图工具截完图、切回聊天窗 ⌘V 粘不进图片"。
    /// 根因：本 App 是菜单栏 App（LSUIElement），没有标准「编辑」菜单，⌘V 只在输入框正好是
    /// firstResponder 时才会走 NSTextView.paste(_:)。用户从别的 app（如 Qt 截图工具）切回来时
    /// 输入框常常没拿到焦点，⌘V 就没人接 → 图片粘不进去。
    /// 这里在聊天窗是 key window 时拦 ⌘V：剪贴板有图就直接附加（无关焦点在哪）+ 吞掉事件；
    /// 没图则放行，交给正常的文字粘贴。只匹配**纯 ⌘V**（带 shift 的 ⌘⇧V 是语音热键，不碰）。
    private func installPasteMonitor() {
        pasteEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // NSEvent 不是 Sendable，不能跨进 @MainActor 闭包 —— 先在这里（主线程）抽出纯值判断，
            // 只把布尔结果带进 assumeIsolated。
            let isCmdV = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "v"
            guard isCmdV else { return event }
            // 事件监听回调在主线程触发；ChatWindowController 是 @MainActor，hop 进去同步决策。
            let consumed = MainActor.assumeIsolated { self.attachClipboardImageIfAny() }
            return consumed ? nil : event   // 已附加图片 → 吞掉；否则放行走正常文字粘贴
        }
    }

    /// 聊天窗是 key window 且剪贴板里有图片 → 附加进 pendingImages，返回 true（事件应被吞掉）。
    /// 否则返回 false（放行 ⌘V 给正常文字粘贴 / 其他响应者）。
    private func attachClipboardImageIfAny() -> Bool {
        guard window.isKeyWindow else { return false }
        // ⭐ "光标在哪贴哪"：焦点若在笔记编辑器，让它自己把图片插到光标处（NotesEditorTextView.paste），
        // 窗口级监听**不抢**也**不吞**事件 → 放行给编辑器。只有焦点不在编辑器时（如聊天输入栏没拿到焦点）
        // 才走"塞进聊天附件"这条兜底。
        if window.firstResponder is NotesEditorTextView { return false }
        if let data = PasteAwareTextView.imageData(from: .general) {
            viewModel.addPendingImage(data)
            return true
        }
        return false
    }

    @objc private func handlePinChanged(_ note: Notification) {
        let pinned = (note.userInfo?["pinned"] as? Bool) ?? true
        window.level = pinned ? HermesWindowLevel.chat : .normal
    }

    @objc private func handleWritingModeChanged(_ note: Notification) {
        let on = (note.userInfo?["on"] as? Bool) ?? false
        // 决策 #6：翻 state 与 setFrame 必须错帧。通知从 ViewModel didSet（SwiftUI 更新栈内）同步发来，
        // 这里隔到下一个 runloop 再 setFrame，绝不和 SwiftUI 换栏同帧撞 CA commit。
        DispatchQueue.main.async { [weak self] in self?.setWritingMode(on) }
    }

    // MARK: - 写作模式"最大化/还原"键动作（header 按钮发通知过来）
    //
    // ⚠️ 用 DispatchQueue.main.async **错一帧**再执行（决策 #6）：
    // 通知是从 SwiftUI 按钮事件里同步发来的，若在原栈里直接 setFrame，会跟 SwiftUI 更新撞同一个
    // CA 事务 → NSException。隔到下一个 runloop 再动窗口就安全。
    // （关闭/最小化键已撤掉——见 init 里注释。）

    /// 最大化 / 还原（自实现，不用系统 window.zoom）。
    /// 系统 zoom 的"标准框"算法不认我们这套刘海几何 + 透明 fullSizeContentView，会在顶部留一条空白；
    /// 这里直接铺满屏幕可见区（visibleFrame 已避开菜单栏/Dock，顶边贴菜单栏底）→ 不留空。
    /// 再按一次还原回最大化前的 frame。本窗是常驻置顶浮窗，不走系统全屏（会和窗口层级打架）。
    @objc private func handleWritingWindowZoom() {
        DispatchQueue.main.async { [weak self] in self?.toggleWritingMaximize() }
    }

    private func toggleWritingMaximize() {
        guard viewModel.isWritingMode, isVisible, !isAnimating else { return }
        let target: NSRect
        if let pre = preZoomFrame {
            target = pre
            preZoomFrame = nil
        } else {
            guard let screen = HermesIslandGeometry.targetScreen() ?? window.screen ?? NSScreen.main else { return }
            preZoomFrame = window.frame
            target = screen.visibleFrame
        }
        isAnimating = true
        window.contentMinSize = .zero
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window.contentMinSize = NSSize(width: 480, height: 420)
                self.isAnimating = false
                // 通知写作三栏按新宽度重新折叠/放宽
                NotificationCenter.default.post(
                    name: .init("HermesPetWritingWidthChanged"), object: nil,
                    userInfo: ["w": self.window.frame.width])
            }
        })
    }

    /// 写作模式三栏需要更宽窗口。复用 show() 已验证的 setFrame 安全姿势
    /// （isAnimating 守卫 + 动画期 contentMinSize=.zero + 完成回调 assumeIsolated 恢复）。
    /// 只动聊天窗自己、不碰灵动岛，HermesIslandGeometry 纯几何只读（决策 #1/#6）。
    private func setWritingMode(_ on: Bool) {
        guard isVisible, !isAnimating else { return }
        // 红绿灯三键改成 SwiftUI 自绘（贴在 header band 里、跟内容融为一体），
        // 系统原生 traffic light 始终保持隐藏（它浮在圆角窗角上、不对齐，看着突兀）。
        let screen = HermesIslandGeometry.targetScreen() ?? window.screen ?? NSScreen.main
        let target: NSRect
        if on {
            if preWritingFrame == nil { preWritingFrame = window.frame }
            let size = NSSize(width: 1080, height: 680)
            target = screen.map { frameBelowIsland(on: $0, size: size) } ?? window.frame
        } else {
            if let pre = preWritingFrame {
                target = pre
            } else if let scr = screen {
                target = frameBelowIsland(on: scr, size: defaultSize)
            } else {
                target = window.frame
            }
            preWritingFrame = nil
        }
        isAnimating = true
        window.contentMinSize = .zero
        // 写作模式放开 maxSize（绿键最大化要能铺满大屏）；普通聊天维持原上限
        if on { window.contentMaxSize = NSSize(width: 6000, height: 4000) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 写作模式最小宽度放到 480 —— 用户能拖很窄，三栏会自适应折叠成图标条而不是文字溢出
                self.window.contentMinSize = on
                    ? NSSize(width: 480, height: 420)
                    : NSSize(width: 360, height: 360)
                if !on {
                    self.window.contentMaxSize = NSSize(width: 1400, height: 1600)
                    self.preZoomFrame = nil
                }
                self.isAnimating = false
                if on {
                    // 首帧广播一次宽度，让三栏按实际窗宽决定初始折叠
                    NotificationCenter.default.post(
                        name: .init("HermesPetWritingWidthChanged"), object: nil,
                        userInfo: ["w": self.window.frame.width])
                }
            }
        })
    }

    // MARK: - Public

    func show(near anchor: NSView? = nil) {
        guard !isVisible else { return }
        self.lastAnchor = anchor

        // show() 总是回普通聊天(hide 时已复位 isWritingMode)，隐藏红绿灯；进写作模式由 setWritingMode 再显示
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // 聊天窗跟着灵动岛所在的屏弹出（多显示器）：
        // - savedFrame 已经在灵动岛这块屏 → 用它（保留用户拖过的精确位置/尺寸）。
        // - savedFrame 在别的屏（用户换了屏 / 灵动岛跟随过去了）→ 保留尺寸，挪到灵动岛这块屏、挂在岛正下方。
        // - 没存过位置 → 直接在灵动岛这块屏的岛正下方展开。
        let islandScreen = HermesIslandGeometry.targetScreen()
        let target: NSRect
        if let saved = savedFrame {
            if let scr = islandScreen, scr.frame.contains(NSPoint(x: saved.midX, y: saved.midY)) {
                target = saved
            } else if let scr = islandScreen {
                target = frameBelowIsland(on: scr, size: saved.size)
            } else {
                target = saved
            }
        } else if let scr = islandScreen {
            target = frameBelowIsland(on: scr, size: defaultSize)
        } else {
            target = defaultFrame(near: anchor)
        }
        isAnimating = true
        // ⭐ 决策 #6/#1（#141/#140/#137 闪退根治）：窗口尺寸一步到位、绝不做尺寸动画。
        // 旧版用 window.animator().setFrame 把窗口从刘海小药丸(100×30)缩放放大到完整窗，
        // 动画每帧改窗口尺寸 → 触发 NSHostingView.updateAnimatedWindowSize 反推约束更新 →
        // macOS 26 上约束 pass 不收敛抛 NSException 闪退（用户机 26.5.1 必崩、作者机 26.3.1 测不出）。
        // 招牌"从刘海出来"的观感改用「整窗淡入 + 从上方轻微下滑」实现 —— 全程 size 不变，
        // 只动 origin + alpha，NSHostingView 不会进 updateAnimatedWindowSize 通道。
        let slideOffset: CGFloat = 24
        let start = NSRect(x: target.origin.x, y: target.origin.y + slideOffset,
                           width: target.width, height: target.height)
        window.setFrame(start, display: false)
        window.alphaValue = 0
        window.orderFront(nil)
        // ⚠️ 立刻 makeKey + 把焦点设到输入框 —— 不能等动画结束才做。
        // 否则用户在 0.34s 入场动画期间打字，按键全被吞（NSWindow 不是 key + firstResponder 不接键盘）。
        // 第一次按键不被记录的 bug 就是这个 + 即使 makeKey 后 firstResponder 默认是 contentView 也不接键盘
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        focusInputField()

        // 显示窗口时强制滚到底部。NSWindow.orderFront 不会重新触发 SwiftUI 的 .onAppear，
        // 但 ScrollView 内 LazyVStack 在窗口隐藏期间会卸载 cell —— 再次显示时位置可能从顶部
        // lazy 加载，把用户带回对话开头。post 通知让 ChatView 主动 scrollToBottom 兜底。
        NotificationCenter.default.post(name: .hermesPetChatWindowShown, object: nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            // CA 没有 spring，用 easeOut + 略长 duration 模拟弹性入场
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            ctx.allowsImplicitAnimation = true
            // ⚠️ start 与 target 尺寸完全相同、只差 origin —— 这是「位移动画」不是「尺寸动画」，
            // NSHostingView 不会进 updateAnimatedWindowSize 反推通道（决策 #6 铁律的合规写法）。
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
                // 兜底再 post 一次 —— ScrollView 的 contentSize 在动画结束、LazyVStack
                // 全部 mount 完之后才稳定，这时再要求滚到底部最可靠
                NotificationCenter.default.post(name: .hermesPetChatWindowShown, object: nil)
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

    /// hide 完成回调 —— 截图流程需要等窗口真正不可见才能开拍，
    /// 不然会拍到半透明的退出动画中间帧。完成 handler 里调一次
    func hide(completion: (@MainActor () -> Void)? = nil) {
        guard isVisible else {
            completion?()
            return
        }

        // 广播即将隐藏 —— PetHeaderStrip 收到后会把当前 pending permission 移交给灵动岛
        // 避免用户在 permission 决策中途 ⌘W 关聊天窗导致决策被丢
        NotificationCenter.default.post(name: .init("HermesPetChatWindowWillHide"), object: nil)

        // 关窗时退出写作模式（下次开窗回普通聊天，不直接进大窗踩尺寸坑）。
        // 进过写作模式 → 把"进入前的普通 frame"存为 savedFrame，别把大窗尺寸存成默认。
        let wasWriting = viewModel.isWritingMode
        if wasWriting { viewModel.isWritingMode = false }   // didSet 发通知，但其 async setWritingMode 因 isAnimating 会 no-op
        if !isAnimating {
            if wasWriting, let pre = preWritingFrame {
                UserDefaults.standard.set(NSStringFromRect(pre), forKey: savedFrameKey)
            } else {
                saveFrame()
            }
        }
        preWritingFrame = nil

        let originalFrame = window.frame  // 隐藏前的真实 frame，结束后恢复
        // ⭐ 同 show：收回也不做尺寸动画，改「上滑 + 淡出」，size 全程不变（#141/#140/#137 根治）。
        let slideOffset: CGFloat = 24
        let end = NSRect(x: originalFrame.origin.x, y: originalFrame.origin.y + slideOffset,
                         width: originalFrame.width, height: originalFrame.height)

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.0, 0.85, 0.4)
            ctx.allowsImplicitAnimation = true
            // 只动 origin（上滑）+ alpha，size 不变 —— 不触发 NSHostingView 尺寸反推
            window.animator().setFrame(end, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.window.orderOut(nil)
                self.window.setFrame(originalFrame, display: false)
                self.window.alphaValue = 1
                self.window.contentMinSize = NSSize(width: 360, height: 360)
                self.window.contentMaxSize = NSSize(width: 1400, height: 1600)
                self.preZoomFrame = nil
                self.isAnimating = false
                completion?()
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
        if !isAnimating && !viewModel.isWritingMode { saveFrame() }
    }

    func windowDidMove(_ notification: Notification) {
        if !isAnimating && !viewModel.isWritingMode { saveFrame() }
    }

    /// 写作模式下用户拖窗口边改大小 —— 把内容区宽度广播给三栏，驱动自适应折叠（窄了收边栏、宽了展开）。
    /// ⚠️ 决策 #6（22:07 崩溃栈正是这个）：windowDidResize 在窗口布局/动画的 CA commit 里被**反复**调到，
    /// 绝不能在此**同步**改 SwiftUI @State（reflow 折叠/夹宽）—— 会在 `_layoutViewTree` 内再触发一次布局
    /// → 嵌套布局 NSException 必崩。两道闸：
    /// ① 我们自己的 setFrame 动画期间（isAnimating）直接跳过 —— 动画每帧都发 didResize 会刷爆，且
    ///    各动画 completion 已各自补发一次最终宽度；
    /// ② 用户手动拖边：错一帧（async）到下一个 runloop 再广播，让 reflow 脱离这次布局 pass。
    func windowDidResize(_ notification: Notification) {
        guard viewModel.isWritingMode, !isAnimating else { return }
        let w = window.frame.width
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewModel.isWritingMode, !self.isAnimating else { return }
            NotificationCenter.default.post(
                name: .init("HermesPetWritingWidthChanged"), object: nil,
                userInfo: ["w": w])
        }
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

    // collapsedFrame（旧"刘海小药丸"起点尺寸）已随尺寸动画一起移除（#141/#140/#137 根治）——
    // show/hide 改为窗口 size 一步到位 + origin 滑入/淡入，不再需要折叠尺寸。

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

    /// 在指定屏的灵动岛正下方算聊天窗 frame（给定尺寸）。
    /// 用 HermesIslandGeometry 的岛中心 x / 岛底边 y 定位，不依赖 anchor 视图——
    /// 这样聊天窗能可靠落在灵动岛当前所在的那块屏（含 QuickAsk 的 nil anchor 路径）。
    /// 高度不够自动收紧（不被屏幕底裁掉），横向夹回可见区。
    private func frameBelowIsland(on screen: NSScreen, size: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        let centerX = HermesIslandGeometry.islandCenterX(on: screen)
        let islandBottomY = HermesIslandGeometry.islandBottomY(on: screen)
        let topPadding: CGFloat = 8
        let bottomMargin: CGFloat = 12
        let available = (islandBottomY - topPadding) - visible.minY - bottomMargin
        let minHeight: CGFloat = 360            // 跟 contentMinSize 一致
        let h = max(minHeight, min(size.height, available))
        var x = centerX - size.width / 2
        x = max(visible.minX + bottomMargin, min(visible.maxX - size.width - bottomMargin, x))
        let y = islandBottomY - h - topPadding
        return NSRect(x: x, y: y, width: size.width, height: h)
    }
}
