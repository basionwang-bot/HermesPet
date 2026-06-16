import AppKit
import SwiftUI

/// 「钉在桌面」的系统监控卡片控制器（单张，复用 PinCard 那套：独立 NSWindow + 可拖 + 记位置）。
///
/// - 从 hover 仪表盘右上角 📌 触发 `pin()`：弹出一张常驻桌面、可拖动、带关闭按钮的卡片。
/// - 拖动靠 `isMovableByWindowBackground`；位置在 `windowDidMove` 时存 UserDefaults，
///   App 重启时 `restoreIfNeeded()` 还原（记位置）。
/// - 跟灵动岛 NSWindow 完全独立，不碰任何 setFrame 旧雷（决策 #1 无关）。
@MainActor
final class SystemStatsPinController: NSObject, NSWindowDelegate {
    static let shared = SystemStatsPinController()

    private var window: NSWindow?
    private let cardW: CGFloat = 300   // 容下 3 圆环 + 分割线 + 网络上下行
    private let cardH: CGFloat = 138

    private let kPinned = "sysStatsPinned"
    private let kX = "sysStatsPinX"
    private let kY = "sysStatsPinY"

    /// 当前是否已钉出卡片（hover 面板用它避免重复显示）
    var isPinned: Bool { window != nil }

    private override init() {
        super.init()
        // 插拔显示器时自愈：若钉住的卡片落到了屏幕外（外接屏被拔），挪回可见屏。
        // 闭包是 Sendable，主线程执行也要 assumeIsolated 跳进 MainActor（决策 #5）。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.healOffscreen() }
        }
    }

    /// 屏幕配置变化后，钉住的卡片若已不在任何可见屏内，挪回默认落点并存盘。
    private func healOffscreen() {
        guard let w = window, !Self.frameVisibleEnough(w.frame) else { return }
        let f = defaultFrame()
        w.setFrame(f, display: true)   // 独立窗口、跟决策 #1 无关，可安全 setFrame
        UserDefaults.standard.set(Double(f.origin.x), forKey: kX)
        UserDefaults.standard.set(Double(f.origin.y), forKey: kY)
    }

    /// 钉出卡片（已存在则前置）
    func pin() {
        if let w = window { w.orderFront(nil); return }

        let frame = savedFrame()
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = HermesWindowLevel.chat
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false                            // 关掉窗口矩形阴影（就是那圈"黑框"的真凶）
        win.isMovableByWindowBackground = true          // 拖卡片背景即可移动
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.delegate = self

        // ⭐ #143/#144/#145 启动崩溃根治：常驻系统卡片在 restoreIfNeeded() 启动即 orderFront，
        // 且 applyFrame 会 setFrame 改尺寸 —— 裸 NSHostingView 在 macOS 26.5.1 显示周期/尺寸变更
        // 时反推约束 → NSException 必崩。改 NSHostingController + sizingOptions=[]（决策 #6 范式）。
        let host = NSHostingController(rootView: SystemStatsPinnedCard(onClose: { [weak self] in self?.unpin() }))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor   // 清空 hosting 背景，杜绝四角黑底
        win.contentViewController = host
        // ⭐ v1.4.5 回归修复：补回 autoresizingMask（照灵动岛范式），让卡片铺满全窗、不被 safe-area 顶移。
        host.view.autoresizingMask = [.width, .height]
        win.setContentSize(frame.size)

        win.orderFront(nil)
        window = win
        UserDefaults.standard.set(true, forKey: kPinned)
        SystemMonitor.shared.start()
    }

    /// 关闭卡片
    func unpin() {
        window?.orderOut(nil)
        window = nil
        UserDefaults.standard.set(false, forKey: kPinned)
    }

    /// App 启动时调用：上次钉着的话，原位置还原
    func restoreIfNeeded() {
        if UserDefaults.standard.bool(forKey: kPinned) { pin() }
    }

    // MARK: - 位置持久化

    func windowDidMove(_ notification: Notification) {
        guard let w = window else { return }
        UserDefaults.standard.set(Double(w.frame.origin.x), forKey: kX)
        UserDefaults.standard.set(Double(w.frame.origin.y), forKey: kY)
    }

    private func savedFrame() -> NSRect {
        let ud = UserDefaults.standard
        if ud.object(forKey: kX) != nil, ud.object(forKey: kY) != nil {
            let r = NSRect(x: ud.double(forKey: kX), y: ud.double(forKey: kY), width: cardW, height: cardH)
            // ⚠️ 关键修复：存的坐标可能落在已拔掉的外接屏上 → 校验还在可见屏内才用，否则回默认落点。
            if Self.frameVisibleEnough(r) { return r }
        }
        return defaultFrame()
    }

    /// 默认落点：带刘海的内置屏右上、避开刘海往下一点。
    private func defaultFrame() -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 200, y: 200, width: cardW, height: cardH)
        return NSRect(x: vf.maxX - cardW - 40, y: vf.maxY - cardH - 40, width: cardW, height: cardH)
    }

    /// 卡片中心是否落在某块当前屏幕内（用来判断存的位置是否因拔屏而失效）。
    static func frameVisibleEnough(_ r: NSRect) -> Bool {
        let center = NSPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.contains { $0.frame.contains(center) }
    }
}
