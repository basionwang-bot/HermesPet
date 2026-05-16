import AppKit
import SwiftUI

/// 灵动岛下方的选项下拉菜单 —— 当 AI 输出 markdown 编号列表时自动弹出，
/// 让用户从灵动岛位置直接做选择（比聊天气泡里的 ChoiceCard 更"原生"）。
///
/// 触发：`HermesPetChoiceListReady` 通知，userInfo: `["options": [String]]`
/// 选中：post `HermesPetChoiceSelected` 通知，userInfo: `["text": String]`，由 ChatViewModel 接管
/// 自动关闭：选完 / 新流式开始 / 30s 超时
@MainActor
final class ChoiceMenuOverlayController {
    static let shared = ChoiceMenuOverlayController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<ChoiceMenuView>?
    private let viewState = ChoiceMenuState()
    private var autoHideTask: Task<Void, Never>?

    /// 给 MiniReplyCardController 判断"当前是否有选项菜单在显示"。
    /// 有的话 mini card 应该让位 —— 因为选项菜单是更直接的交互（点了就发送），
    /// 而 mini card 只是预览 + "展开聊天"，重叠没意义
    var isShowing: Bool { viewState.isVisible }

    private init() {
        registerNotifications()
    }

    // MARK: - Notifications

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetChoiceListReady"),
            object: nil, queue: .main
        ) { [weak self] note in
            let options = (note.userInfo?["options"] as? [String]) ?? []
            Task { @MainActor in
                self?.show(options: options)
            }
        }
        // 新一轮流式开始 → 之前的选项菜单失效，关掉
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetTaskStarted"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    // MARK: - Show / Hide

    private func show(options: [String]) {
        guard !options.isEmpty else { return }
        if window == nil { createWindow() }
        viewState.options = options
        viewState.isVisible = true
        positionWindow(forOptionCount: options.count)
        window?.orderFront(nil)

        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            // 30s 不操作自动关，避免长期遮挡屏幕
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            hide()
        }
    }

    func hide() {
        autoHideTask?.cancel()
        viewState.isVisible = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            window?.orderOut(nil)
            viewState.options = []
        }
    }

    fileprivate func selectAndDismiss(_ text: String) {
        NotificationCenter.default.post(
            name: .init("HermesPetChoiceSelected"),
            object: nil,
            userInfo: ["text": text]
        )
        hide()
    }

    // MARK: - Window

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.auxiliary   // 低于灵动岛，跟 bubble / transcript 同级
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = false   // 关键：要接收点击
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: ChoiceMenuView(
            state: viewState,
            onSelect: { [weak self] text in self?.selectAndDismiss(text) },
            onDismiss: { [weak self] in self?.hide() }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        host.autoresizingMask = [.width, .height]
        w.contentView = host

        self.window = w
        self.hostingView = host
    }

    /// 位置：刘海正下方，灵动岛胶囊下方约 4pt 处。
    /// 宽度根据最长选项实际测量，min 360 / max 720。高度按行数。
    private func positionWindow(forOptionCount n: Int) {
        guard let window = window else { return }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen = screen else { return }
        let frame = screen.frame
        let safeArea = screen.safeAreaInsets
        let notchHeight: CGFloat = safeArea.top > 0 ? safeArea.top : 28

        let menuWidth = measureMenuWidth(options: viewState.options)

        // 单行 40pt 高（加大字号后单行更舒服） + 上下各 6pt padding
        let rowHeight: CGFloat = 40
        let displayCount = min(viewState.options.count, 8)   // 最多 8 行
        let menuHeight: CGFloat = CGFloat(displayCount) * rowHeight + 16

        let x = frame.midX - menuWidth / 2
        let y = frame.maxY - notchHeight - 32 - 4 - menuHeight

        window.setFrame(
            NSRect(x: x, y: y, width: menuWidth, height: menuHeight),
            display: true
        )
    }

    /// 用 NSAttributedString.boundingRect 真实测量最长选项的宽度，
    /// 加上序号 badge / 间距 / padding，再夹到 [360, 720] 区间
    private func measureMenuWidth(options: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let maxTextWidth = options.map { (text: String) -> CGFloat in
            (text as NSString).boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: 24),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            ).width
        }.max() ?? 0
        // 序号 badge 22 + spacing 12 + row 左右 padding 12*2 + 容器左右 padding 8*2
        let chrome: CGFloat = 22 + 12 + 24 + 16
        let raw = ceil(maxTextWidth) + chrome
        return min(720, max(360, raw))
    }
}

// MARK: - State

@Observable
@MainActor
final class ChoiceMenuState {
    var options: [String] = []
    var isVisible: Bool = false
}

// MARK: - SwiftUI Menu

/// 灵动岛下方的下拉菜单视图。
/// 黑色半透明卡片，每行一个选项，hover 高亮，点击发送
struct ChoiceMenuView: View {
    @Bindable var state: ChoiceMenuState
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.isVisible {
                menuCard
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(AnimTok.bouncy, value: state.isVisible)
    }

    private var menuCard: some View {
        VStack(spacing: 2) {
            ForEach(Array(state.options.prefix(8).enumerated()), id: \.offset) { idx, text in
                ChoiceMenuRow(
                    index: idx + 1,
                    text: text,
                    onTap: { onSelect(text) }
                )
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

/// 单行选项
struct ChoiceMenuRow: View {
    let index: Int
    let text: String
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 序号圆形 badge
                Text("\(index)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isHovering ? .black : .white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(isHovering ? Color.white : Color.white.opacity(0.18))
                    )

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }
}
