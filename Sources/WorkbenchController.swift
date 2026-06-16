import SwiftUI
import AppKit

/// 「HermesPet 工作空间」原型的承载窗口。
///
/// 现阶段是**独立大窗口**（照 `FleetTheaterController` 范式：NSHostingView + `sizingOptions=[]` 守决策 #6、
/// 不碰灵动岛 #1），先把工作台视觉 + 双层主题跑出来给用户看真效果。
/// 审美确认后再迁进 `SystemStatsPanelController` 的 `.workspace` 分区（刘海展开成全屏的最终形态）。
@MainActor
final class WorkbenchController: NSObject {
    static let shared = WorkbenchController()
    private var window: NSWindow?
    private override init() { super.init() }

    func present() {
        // 复用已存在的窗口（关掉=orderOut 只是隐藏，重开不重建 hosting）→ 选中文件 / 滚动 / 预览态都留住；
        // 对话历史本就活在 WorkspaceState.shared 单例里，所以关掉重开能继续之前的任务。
        if window == nil {
            // ⭐ #143~#145 同族崩溃：本窗 `.resizable`，裸 NSHostingView 当 contentView 在 macOS 26.5.1
            // 上一缩放/显示周期就会经 updateWindowContentSizeExtremaIfNecessary 反推约束 → NSException 崩。
            // 必须 NSHostingController + sizingOptions=[]（决策 #6 范式），让缩放真正安全。
            let hosting = NSHostingController(rootView: WorkbenchView())
            if #available(macOS 13.0, *) { hosting.sizingOptions = [] }   // 决策 #6：禁反向 setFrame
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            win.level = .normal   // 标准窗口：不盖 Dock、可移动/缩放、能和其他 app 并排（独立工作台）
            win.isReleasedWhenClosed = false
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.title = "HermesPet 工作空间（实验）"
            win.contentMinSize = NSSize(width: 880, height: 560)
            win.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]   // v1.4.5 回归修复：内容随窗缩放铺满，照灵动岛范式
            win.setContentSize(NSSize(width: 1280, height: 820))
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }
}
