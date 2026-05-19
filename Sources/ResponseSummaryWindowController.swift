import AppKit
import SwiftUI

/// 聊天窗关着时任务完成 → 紧贴灵动岛下方弹出 AI 回复摘要卡片。
/// 解决 ⌘⇧V 语音 / ⌘⇧Space quickAsk 这类轻量场景"看不到回复"的痛点 —— 桌宠"端答案"过来给用户。
///
/// 跟 PermissionWindowController 同款架构（决策 #16）：
/// - 独立 NSWindow + .borderless + .nonactivatingPanel
/// - 紧贴菜单栏底部，等宽于灵动岛 (actualNotchWidth + 80pt idleExtra)
/// - 跟灵动岛同 z-order (HermesWindowLevel.dynamicIsland)
/// - 黑底 / 顶部直角 / 底部圆角 → 视觉延续灵动岛凹槽
///
/// **触发**：HermesPetResponseReady 通知（ChatViewModel 在 task 完成且聊天窗关着时 post）
/// **收回**：8s 无操作 / 用户点 × / 点 "查看完整" / HermesPetChatWindowShown
@MainActor
final class ResponseSummaryWindowController {
    /// 全局单例引用 —— 给 PermissionWindowController 查询用（v1.2.7-dev 暂未启用，
    /// 之前用来让 Question 卡片在摘要显示时让位，用户反馈"答复 Question 前用户需要先看完聊天窗内容"，
    /// 临时撤回。字段保留方便后续恢复）
    static weak var shared: ResponseSummaryWindowController?

    private let window: NSWindow
    private let hosting: NSHostingView<ResponseSummaryRoot>
    private let viewState = ResponseSummaryViewState()

    /// 当前是否正在显示摘要卡片（v1.2.7-dev 暂未被外部查询，保留接口）
    var isShowing: Bool { viewState.summary != nil }

    /// 8s 无操作 dismiss 计时器
    private var autoDismissTask: Task<Void, Never>?
    /// 复制反馈"已复制 ✓"短暂展示
    private var copyResetTask: Task<Void, Never>?

    /// PermissionWindow 是否在显示 permission / question 卡片。
    /// 由 NotificationCenter 上 Asked / Replied / DecisionMade / Answered 通知驱动维护。
    /// 这两个卡片都紧贴菜单栏底部同一位置，必须互斥避免重叠 —— PermissionWindow 优先（用户需要响应），
    /// 摘要卡片让位（被动展示，错过没关系）
    private var permissionActive: Bool = false

    /// 卡片宽度 = 灵动岛实际 NSWindow 宽度，computed 每次读 NSScreen（决策 #16 经验）
    private var cardWidth: CGFloat {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        let actualNotchWidth: CGFloat = {
            guard let screen = screen,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else {
                return 200
            }
            return right.minX - left.maxX
        }()
        let idleExtraWidth: CGFloat = 80
        return actualNotchWidth + idleExtraWidth
    }
    /// 固定卡片高度 240pt（200 字摘要 + header + 按钮）
    private let cardHeight: CGFloat = 240
    /// 卡片顶部跟灵动岛底部的间隔，让卡片视觉上独立而不是"灵动岛伸出来"
    private let topGap: CGFloat = 10

    init() {
        let initialWidth: CGFloat = 280
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        win.level = HermesWindowLevel.dynamicIsland
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        self.window = win

        let host = NSHostingView(rootView: ResponseSummaryRoot(state: viewState))
        host.frame = NSRect(x: 0, y: 0, width: initialWidth, height: cardHeight)
        host.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            host.sizingOptions = []   // 阻止 SwiftUI 反向请求 window setFrame
        }
        win.contentView = host
        self.hosting = host
        Self.shared = self

        // 注入 view → controller 的回调
        viewState.onClose = { [weak self] in self?.hide() }
        viewState.onCopy = { [weak self] in self?.handleCopy() }
        viewState.onViewFull = { [weak self] in self?.handleViewFull() }
        viewState.onHover = { [weak self] hovering in
            // hover 时暂停 dismiss，离开重置 8s
            if hovering { self?.cancelAutoDismiss() }
            else { self?.scheduleAutoDismiss() }
        }

        positionUnderIsland()

        // 屏幕几何变化 → 重新定位
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetGeometry"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.positionUnderIsland()
            }
        }

        // 任务完成且聊天窗关着 → ChatViewModel post 这条
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetResponseReady"),
            object: nil, queue: .main
        ) { [weak self] note in
            let content = (note.userInfo?["content"] as? String) ?? ""
            let cid = (note.userInfo?["conversationID"] as? String) ?? ""
            let modeRaw = (note.userInfo?["modeRaw"] as? String) ?? ""
            let mode = AgentMode(rawValue: modeRaw) ?? .hermes
            MainActor.assumeIsolated {
                self?.show(content: content, conversationID: cid, mode: mode)
            }
        }

        // 聊天窗被打开 → 立即收卡片（用户已经能看到正文了）
        NotificationCenter.default.addObserver(
            forName: .hermesPetChatWindowShown,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }

        // —— 工具权限卡片冲突避让 ——
        // 优先级：Permission > ResponseSummary > Question
        // Permission 是阻塞性的（工具权限必须用户响应才能继续），摘要让位
        // Question 是建议性的（AI 给的选项），让位给摘要 —— 由 PermissionWindow.show(question:)
        // 反向检查 ResponseSummary.shared.isShowing 实现，这里不监听 Question 事件
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetPermissionAsked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.permissionActive = true
                if self?.viewState.summary != nil {
                    self?.hide()
                }
            }
        }
        for name in ["HermesPetPermissionDecisionMade",
                     "HermesPetPermissionReplied"] {
            NotificationCenter.default.addObserver(
                forName: .init(name),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.permissionActive = false
                }
            }
        }
    }

    // MARK: - Show / Hide

    /// 显示摘要卡片。新 task 来时直接替换旧卡片不排队（最新优先）
    private func show(content: String, conversationID: String, mode: AgentMode) {
        // PermissionWindow 正在显示 permission / question 卡片 → 直接跳过摘要，避免重叠
        // 摘要错过没关系（用户能在聊天窗里看到完整内容），permission/question 必须用户响应
        guard !permissionActive else { return }

        let summary = SummaryProcessor.compress(content, maxChars: 200)
        guard !summary.isEmpty else { return }

        positionUnderIsland()
        window.orderFront(nil)
        window.alphaValue = 1

        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            viewState.summary = summary
            viewState.fullContent = content
            viewState.conversationID = conversationID
            viewState.mode = mode
            viewState.finishedAt = Date()
            viewState.copied = false
        }

        scheduleAutoDismiss()
    }

    private func hide() {
        cancelAutoDismiss()
        copyResetTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
            viewState.summary = nil
            viewState.fullContent = ""
            viewState.copied = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.viewState.summary == nil {
                self.window.alphaValue = 0
                self.window.orderOut(nil)
            }
        }
    }

    // MARK: - 8s 自动 dismiss

    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if Task.isCancelled { return }
            self?.hide()
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    // MARK: - 用户交互

    private func handleCopy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(viewState.fullContent, forType: .string)
        viewState.copied = true
        // 1.5s 后回原状（"复制" 字样）
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            self?.viewState.copied = false
        }
    }

    private func handleViewFull() {
        // 触发聊天窗打开 —— AppDelegate 监听 HermesPetOpenChatRequested 调 ChatWindowController.show()
        NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
        // hide 由 .hermesPetChatWindowShown 通知自动触发
    }

    // MARK: - 定位（紧贴菜单栏底部 + 灵动岛中心居中）

    private func positionUnderIsland() {
        guard let screen = HermesIslandGeometry.targetScreen() else { return }

        let notchCenterX = HermesIslandGeometry.islandCenterX(on: screen)
        let cardTopY = HermesIslandGeometry.islandBottomY(on: screen)
                     - HermesIslandGeometry.cardTopGapBelowIsland(on: screen)

        let x = notchCenterX - cardWidth / 2
        // 卡片顶部再下移 topGap (10pt) 让灵动岛和摘要卡之间有视觉间隔，独立感更强
        let y = cardTopY - cardHeight - topGap

        window.setFrame(
            NSRect(x: x, y: y, width: cardWidth, height: cardHeight),
            display: false
        )
    }
}

// MARK: - ViewState

@MainActor
@Observable
final class ResponseSummaryViewState {
    var summary: String? = nil
    var fullContent: String = ""
    var conversationID: String = ""
    var mode: AgentMode = .hermes
    var finishedAt: Date = Date()
    /// 复制后短暂展示 "已复制 ✓" 1.5s
    var copied: Bool = false

    // Controller 注入的回调
    var onClose: () -> Void = {}
    var onCopy: () -> Void = {}
    var onViewFull: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
}

// MARK: - SwiftUI Root

struct ResponseSummaryRoot: View {
    @Bindable var state: ResponseSummaryViewState

    var body: some View {
        ZStack {
            if state.summary != nil {
                ResponseSummaryCardView(state: state)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SwiftUI Card

struct ResponseSummaryCardView: View {
    @Bindable var state: ResponseSummaryViewState
    @State private var paletteStore = PetPaletteStore.shared
    /// 让相对时间每秒更新（"5s 前" → "6s 前"）
    @State private var nowTick: Date = Date()
    /// 全局「桌宠动效」开关。摘要卡片是临时展示，quietMode 时 sprite 也走静态帧
    @AppStorage("quietMode") private var quietMode: Bool = false

    private var palette: PetPalette { paletteStore.palette(for: state.mode) }

    private var petName: String {
        switch state.mode {
        case .claudeCode: return "Clawd"
        case .directAPI:  return "云朵"
        case .openclaw:   return "fomo"
        case .hermes:     return "小马"
        case .codex:      return "coco"
        }
    }

    /// 相对时间显示
    private var relativeTime: String {
        let secs = Int(nowTick.timeIntervalSince(state.finishedAt))
        if secs < 3 { return "刚刚" }
        if secs < 60 { return "\(secs)s 前" }
        if secs < 3600 { return "\(secs/60)m 前" }
        return "\(secs/3600)h 前"
    }

    var body: some View {
        // 卡片整体改成全圆角 —— 不再延续灵动岛凹槽，跟灵动岛之间留 10pt 间隔
        // 视觉上是"独立卡片"而不是"灵动岛伸出来一截"
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape
                .fill(Color.black)
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.4), radius: 18, x: 0, y: 8)

            VStack(spacing: 0) {
                // —— 顶部彩色横梁（跟聊天窗 PetStrip 同款视觉）——
                // 用 palette.primary 渐变让用户一眼看出"这是哪个桌宠端来的回复"
                headerStrip
                    .background(
                        LinearGradient(
                            colors: [
                                palette.primary.opacity(0.38),
                                palette.primary.opacity(0.14)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                // —— 摘要正文 ——
                ScrollView(.vertical, showsIndicators: false) {
                    Text(state.summary ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .frame(maxHeight: .infinity)

                // —— 底部按钮 ——
                buttonRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .clipShape(shape)
        }
        .onHover { hovering in
            state.onHover(hovering)
        }
        // 每秒触发一次重渲染让 relativeTime 跟着走
        .onAppear {
            Task { @MainActor in
                while true {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    nowTick = Date()
                }
            }
        }
    }

    /// 顶部彩色横梁 (32pt 高)：sprite + 桌宠名 + " · 时间" + × 关闭
    private var headerStrip: some View {
        HStack(spacing: 8) {
            miniSprite(mode: state.mode, height: 20, palette: palette)

            Text(petName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            Text(relativeTime)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Button {
                state.onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    /// 底部按钮：[复制] [查看完整 →]
    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button {
                state.onCopy()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: state.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(state.copied ? "已复制" : "复制")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state.copied
                              ? Color(NSColor.systemGreen).opacity(0.85)
                              : Color.white.opacity(0.14))
                )
            }
            .buttonStyle(.plain)

            Button {
                state.onViewFull()
            } label: {
                HStack(spacing: 4) {
                    Text("查看完整")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.primary.opacity(0.85))
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// 按 mode 渲染对应桌宠迷你 sprite (20pt 高 × 1.5 宽 = 30pt)
    @ViewBuilder
    private func miniSprite(mode: AgentMode, height: CGFloat, palette: PetPalette) -> some View {
        let anim = !quietMode
        Group {
            switch mode {
            case .claudeCode:
                ClawdView(pose: .rest, height: height, isWalking: false, palette: palette, animated: anim)
            case .directAPI:
                CloudPetView(pose: .rest, height: height, isWalking: false,
                             glassesProgress: 0, palette: palette, animated: anim)
            case .openclaw:
                FomoView(pose: .rest, height: height, isWalking: false, palette: palette, animated: anim)
            case .hermes:
                HorseView(pose: .rest, height: height, isWalking: false, palette: palette, animated: anim)
            case .codex:
                TerminalView(pose: .rest, height: height, isWalking: false,
                             isWorking: false, palette: palette, animated: anim)
            }
        }
        .frame(width: height * 1.5, height: height)
    }
}

// MARK: - 摘要处理函数

/// 把 Markdown 正文压缩成 200 字摘要：代码块 / 表格 / 图片替换成 inline 标签
enum SummaryProcessor {
    /// 主入口：完整 Markdown → maxChars 摘要
    static func compress(_ content: String, maxChars: Int) -> String {
        var text = content

        // 1) 代码块 ```lang\n...\n``` → "【代码 · N 行 · 点查看】"
        text = replaceCodeBlocks(in: text)

        // 2) 表格 |...|...| 连续行 → "【表格 · N 行】"
        text = replaceTables(in: text)

        // 3) 图片 ![alt](url) → "【图】"
        text = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#,
            with: "【图】",
            options: .regularExpression
        )

        // 4) 链接 [text](url) → text
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )

        // 5) **bold** / *italic* / `code` 去标记保正文
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*([^*]+)\*"#,      with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"`([^`]+)`"#,        with: "$1", options: .regularExpression)

        // 6) header 标记 # / ## / ### → 去掉前缀
        text = text.replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)

        // 7) 多余空行合并
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        // 8) trim + 截断
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        return String(trimmed.prefix(maxChars - 1)) + "…"
    }

    /// 倒序替换避免 NSRange 失效
    private static func replaceCodeBlocks(in text: String) -> String {
        let pattern = #"```[^\n]*\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let nsText = text as NSString
        var result = text as NSString
        let matches = regex.matches(in: text, options: [],
                                    range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let bodyRange = match.range(at: 1)
            let body = nsText.substring(with: bodyRange)
            let lineCount = body.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            let replacement = "【代码 · \(lineCount) 行 · 点查看】"
            result = result.replacingCharacters(in: match.range, with: replacement) as NSString
        }
        return result as String
    }

    /// 连续 ≥ 2 行 |...| 视为表格，整段替换成"【表格 · N 行】"
    private static func replaceTables(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var resultLines: [String] = []
        var tableBuffer: [String] = []

        func flushTable() {
            if tableBuffer.count >= 2 {
                resultLines.append("【表格 · \(tableBuffer.count - 1) 行】")
            } else {
                resultLines.append(contentsOf: tableBuffer)
            }
            tableBuffer = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                tableBuffer.append(line)
            } else {
                flushTable()
                resultLines.append(line)
            }
        }
        flushTable()
        return resultLines.joined(separator: "\n")
    }
}
