import SwiftUI
import AppKit

/// 画布主视图 —— Conversation.kind == .canvas 时取代 messagesView 渲染。
///
/// **画廊感布局**（v2）：左大右小不对称 ——
/// - 左列（约 70%）：所有图片卡（heroImage / sceneImage），主图最大，场景图次之
/// - 右列（约 30%）：文字卡集中（标题 / 卖点 ×N / CTA / 普通文本）
/// 这样主次分明，符合"产品页 / 海报"的视觉直觉
struct CanvasView: View {
    @Bindable var viewModel: ChatViewModel
    let conversationID: String

    /// 当前选中"想看大图"的卡片 id —— 非空时弹 Lightbox
    @State private var lightboxFocusID: String?

    private var board: CanvasBoard? {
        viewModel.conversations.first(where: { $0.id == conversationID })?.canvas
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let board = board {
                    canvasToolbar(board: board)
                    Divider()
                    canvasGallery(board: board)
                } else {
                    emptyState
                }
            }

            // 全屏 Lightbox 看大图（聚焦某一张时 overlay 整个画布）
            if let id = lightboxFocusID,
               let board = board,
               let element = board.elements.first(where: { $0.id == id }),
               element.imagePath != nil {
                ImageLightboxView(
                    board: board,
                    focusID: id,
                    onClose: { lightboxFocusID = nil },
                    onFocusChange: { lightboxFocusID = $0 }
                )
                .transition(.opacity)
                .zIndex(200)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lightboxFocusID)
    }

    // MARK: - 顶部 toolbar

    private func canvasToolbar(board: CanvasBoard) -> some View {
        HStack(spacing: 10) {
            Image(systemName: CanvasTemplates.find(id: board.templateID).icon)
                .font(.system(size: 13))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(board.topic.isEmpty ? "未命名画布" : board.topic)
                    .font(.system(size: 13, weight: .semibold))
                Text(CanvasTemplates.find(id: board.templateID).name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if isBoardGenerating(board: board) {
                generatingProgressView(board: board)
            } else if let progress = boardProgress(board: board) {
                Text(progress)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Menu {
                Button {
                    viewModel.regenerateFailedCanvasElements(canvasID: conversationID)
                } label: { Label("仅重生失败的卡", systemImage: "exclamationmark.arrow.circlepath") }
                Button {
                    viewModel.regenerateAllCanvasImages(canvasID: conversationID)
                } label: { Label("重生所有图片", systemImage: "photo.stack") }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("重新生成")

            // 打包下载：把全套主图按 "主图1.png / 主图2.png / ..." 命名规则
            // 导出到桌面一个文件夹里。电商团队拿到文件夹直接上架
            Button {
                exportAllToDesktop(board: board)
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
            .help("打包下载到桌面")
            .disabled(!hasAnyDoneImage(board: board))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func hasAnyDoneImage(board: CanvasBoard) -> Bool {
        board.elements.contains { $0.status == .done && $0.imagePath != nil }
    }

    /// 整套打包导出 —— 在桌面建一个以"画布主题-时间戳"命名的文件夹，把所有
    /// 完成的图按淘宝命名规则拷进去（主图1.png ... 主图5.png）。
    /// 完成后调起 Finder 让用户看到目录
    private func exportAllToDesktop(board: CanvasBoard) {
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "MMdd-HHmm"
            return f.string(from: Date())
        }()
        let safeTopic = board.topic.replacingOccurrences(of: "/", with: "-")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        let folder = desktop.appendingPathComponent("\(safeTopic)-主图套图-\(stamp)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let sorted = board.elements
                .filter { $0.status == .done && $0.imagePath != nil }
                .sorted(by: { $0.slot < $1.slot })
            for (idx, element) in sorted.enumerated() {
                guard let path = element.imagePath else { continue }
                let src = URL(fileURLWithPath: path)
                // 命名规则：主图1-核心卖点海报.png（slot 顺序 + 卡片标题）
                let cleanCaption = element.caption
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: "·", with: "-")
                let filename = "主图\(idx + 1)-\(cleanCaption).png"
                let dst = folder.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
            }
            // 打开 Finder 让用户看到目录
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            viewModel.errorMessage = "✅ 已导出到桌面：\(folder.lastPathComponent)"
        } catch {
            viewModel.errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func boardProgress(board: CanvasBoard) -> String? {
        let total = board.elements.count
        let done = board.elements.filter { $0.status == .done }.count
        let generating = board.elements.filter { $0.status == .generating }.count
        if generating == 0 && done == total { return nil }
        return "\(done)/\(total)\(generating > 0 ? " · \(generating) 生成中" : "")"
    }

    /// 是否有任意元素在生成中（决定 toolbar 是否显示带计时的进度条）
    private func isBoardGenerating(board: CanvasBoard) -> Bool {
        board.elements.contains { $0.status == .generating || $0.status == .pending }
    }

    /// 生成中的实时进度文案：N/总 + 已用时间。
    /// 因为画布串行执行（5 张 ~6 分钟），用 TimelineView 每秒刷新让用户知道还在跑没卡死
    @ViewBuilder
    private func generatingProgressView(board: CanvasBoard) -> some View {
        let totalImages = board.elements.filter { $0.kind == .heroImage || $0.kind == .sceneImage }.count
        let doneImages = board.elements.filter { ($0.kind == .heroImage || $0.kind == .sceneImage) && $0.status == .done }.count
        let currentSlot = doneImages + 1   // 正在生成的是第几张
        let startedAt = boardGenerationStartTime(board: board)

        TimelineView(.periodic(from: Date(), by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("生成中 \(min(currentSlot, totalImages))/\(totalImages)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.indigo)
                if let startedAt {
                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                    Text("⏱ \(formatElapsed(elapsed))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 找出 board 里最早开始生成的元素的"开始时间"。
    /// 如果元素没记 startedAt（旧画布兼容），退回到当前时间（计时器从 0 开始）
    private func boardGenerationStartTime(board: CanvasBoard) -> Date? {
        // CanvasElement 当前没有 startedAt 字段，先用 board.createdAt 兜底
        // 后续若要更精准，给 CanvasElement 加 startedAt 字段（status = .generating 时设值）
        return board.createdAt
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - 主图宫格布局（电商五图：每张都是带文字的成品）

    private func canvasGallery(board: CanvasBoard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heroImagesSection(board: board)
                // 非图片元素如果有（旧画布可能还有 title/cta 这种文字卡）兼容显示
                let legacyTexts = board.elements
                    .filter { $0.kind != .heroImage && $0.kind != .sceneImage }
                    .sorted(by: { $0.slot < $1.slot })
                if !legacyTexts.isEmpty {
                    Divider()
                    Text("辅助文案")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(legacyTexts) { element in
                        CanvasTextCard(
                            element: element,
                            onRegenerate: { viewModel.regenerateCanvasElement(canvasID: conversationID, elementID: element.id) },
                            onDelete: { viewModel.deleteCanvasElement(canvasID: conversationID, elementID: element.id) }
                        )
                    }
                }
            }
            .padding(14)
        }
    }

    /// 主图区 —— 所有图卡（heroImage / sceneImage）按 slot 顺序铺，每张都是带文字的成品
    private func heroImagesSection(board: CanvasBoard) -> some View {
        let images = board.elements
            .filter { $0.kind == .heroImage || $0.kind == .sceneImage }
            .sorted(by: { $0.slot < $1.slot })

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(images) { element in
                CanvasImageCard(
                    element: element,
                    isHero: true,   // 现在所有图都是主图级（电商五图都是 1:1 大图）
                    onOpen: { lightboxFocusID = element.id },
                    onRegenerate: { viewModel.regenerateCanvasElement(canvasID: conversationID, elementID: element.id) },
                    onSave: { saveToDesktop(element: element) },
                    onDelete: { viewModel.deleteCanvasElement(canvasID: conversationID, elementID: element.id) }
                )
            }
        }
    }

    // MARK: - 保存图片到桌面

    private func saveToDesktop(element: CanvasElement) {
        guard let path = element.imagePath else { return }
        let src = URL(fileURLWithPath: path)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        // 文件名用 "<画布主题>-<卡片标题>.png"，方便用户辨认
        let safeTopic = (board?.topic ?? "canvas").replacingOccurrences(of: "/", with: "-")
        let safeCaption = element.caption.replacingOccurrences(of: "/", with: "-")
        let target = desktop.appendingPathComponent("\(safeTopic)-\(safeCaption).png")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: src, to: target)
            viewModel.errorMessage = "✅ 已保存到桌面：\(target.lastPathComponent)"
        } catch {
            viewModel.errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("画布加载中…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 图片卡（主图 / 场景图通用）

struct CanvasImageCard: View {
    let element: CanvasElement
    /// 是否是主图 —— 决定卡片最小高度（主图 > 场景图）
    let isHero: Bool
    let onOpen: () -> Void
    let onRegenerate: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var didLoadAnimate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            captionRow
            imageArea
        }
    }

    private var captionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: isHero ? "photo.fill" : "photo")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHero ? .indigo : .blue)
            Text(element.caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            statusInline
        }
    }

    @ViewBuilder
    private var statusInline: some View {
        switch element.status {
        case .generating:
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.indigo)
                Text("AI 正在画…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help(element.errorMessage ?? "生成失败")
        default:
            EmptyView()
        }
    }

    private var imageArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))

            switch element.status {
            case .done where element.imagePath != nil:
                completedImage
            case .generating:
                generatingPlaceholder
            case .failed:
                failedPlaceholder
            default:
                pendingPlaceholder
            }
        }
        .frame(minHeight: isHero ? 320 : 200)
        .overlay(alignment: .bottomTrailing) {
            // hover 浮出操作条
            if isHovering && element.status == .done {
                hoverOps
                    .padding(8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .scaleEffect(didLoadAnimate ? 1.0 : 0.96)
        .opacity(didLoadAnimate ? 1.0 : 0)
        .onChange(of: element.status) { _, newStatus in
            if newStatus == .done {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    didLoadAnimate = true
                }
            } else {
                didLoadAnimate = false
            }
        }
        .onAppear {
            // 历史画布打开时已经是 done 的图片，直接呈现完成态（不要再播入场动画）
            didLoadAnimate = (element.status == .done)
        }
    }

    // MARK: 状态各形态

    private var completedImage: some View {
        Group {
            if let path = element.imagePath, let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { onOpen() }
            }
        }
    }

    /// 生成中：sparkles 脉冲 + 文字 + 柔光呼吸背景
    private var generatingPlaceholder: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = (sin(t * 1.6) + 1) / 2  // 0~1
            ZStack {
                // 柔光呼吸（紫色径向渐变）
                RadialGradient(
                    colors: [
                        Color.indigo.opacity(0.18 * breathe + 0.06),
                        Color.indigo.opacity(0.0)
                    ],
                    center: .center,
                    startRadius: 4,
                    endRadius: 160
                )
                VStack(spacing: 10) {
                    ZStack {
                        // 旋转 sparkles
                        Image(systemName: "sparkles")
                            .font(.system(size: 28))
                            .foregroundStyle(.indigo)
                            .rotationEffect(.degrees(sin(t * 1.2) * 8))
                            .scaleEffect(0.95 + CGFloat(breathe) * 0.1)
                    }
                    Text("AI 正在创作 · \(element.caption)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    // 三点波浪
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(Color.indigo.opacity(0.6))
                                .frame(width: 4, height: 4)
                                .offset(y: sin(t * 3 + Double(i) * 0.6) * 3)
                        }
                    }
                }
            }
        }
    }

    private var failedPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(.orange.opacity(0.7))
            Text("这张没生成成功")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                onRegenerate()
            } label: {
                Label("再试一次", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    private var pendingPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text("等待生成…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// hover 时浮出的操作条：[看大图 / 保存 / 重生 / 删除]
    private var hoverOps: some View {
        HStack(spacing: 6) {
            iconButton("eye.fill", help: "查看大图", action: onOpen)
            iconButton("square.and.arrow.down", help: "保存到桌面", action: onSave)
            iconButton("arrow.clockwise", help: "重新生成", action: onRegenerate)
            iconButton("trash", help: "删除此卡", color: .red, action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private func iconButton(_ name: String, help: String, color: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var borderColor: Color {
        switch element.status {
        case .failed: return .orange.opacity(0.4)
        case .generating: return .indigo.opacity(0.35)
        default: return .secondary.opacity(0.12)
        }
    }
}

// MARK: - 文字卡（标题 / 卖点 / CTA / 文本通用）

struct CanvasTextCard: View {
    let element: CanvasElement
    let onRegenerate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            captionRow
            contentArea
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var captionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: kindIcon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(kindColor)
            Text(element.caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if element.status == .generating {
                ProgressView().controlSize(.small).scaleEffect(0.5)
            }
            if isHovering {
                Menu {
                    Button(action: onRegenerate) {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 16)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        switch element.kind {
        case .title:
            Text(text)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        case .sellingPoint:
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(3)
        case .cta:
            HStack {
                Spacer()
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [.indigo, .purple],
                            startPoint: .leading, endPoint: .trailing
                        ))
                    )
                Spacer()
            }
        default:
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String {
        element.content.isEmpty ? "（生成中…）" : element.content
    }

    private var kindIcon: String {
        switch element.kind {
        case .title:        return "textformat.size"
        case .sellingPoint: return "star.fill"
        case .cta:          return "hand.tap.fill"
        case .text:         return "text.alignleft"
        default:            return "doc"
        }
    }

    private var kindColor: Color {
        switch element.kind {
        case .title:        return .purple
        case .sellingPoint: return .orange
        case .cta:          return .pink
        default:            return .secondary
        }
    }
}

// MARK: - 全屏 Lightbox 看大图

struct ImageLightboxView: View {
    let board: CanvasBoard
    let focusID: String
    let onClose: () -> Void
    let onFocusChange: (String) -> Void

    /// 画布里所有有图的卡片，按 slot 排序 —— Lightbox 支持左右翻看
    private var images: [CanvasElement] {
        board.elements
            .filter { ($0.kind == .heroImage || $0.kind == .sceneImage) && $0.imagePath != nil }
            .sorted(by: { $0.slot < $1.slot })
    }

    private var currentIndex: Int {
        images.firstIndex(where: { $0.id == focusID }) ?? 0
    }

    var body: some View {
        ZStack {
            // 半透明黑色遮罩
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            if let element = images.first(where: { $0.id == focusID }),
               let path = element.imagePath,
               let nsImage = NSImage(contentsOfFile: path) {
                VStack(spacing: 14) {
                    HStack {
                        Text(element.caption)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            saveToDesktop(element: element)
                        } label: {
                            Label("保存到桌面", systemImage: "square.and.arrow.down")
                                .font(.system(size: 12))
                        }
                        .controlSize(.small)
                        Button {
                            onClose()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape)
                    }
                    .padding(.horizontal, 24)

                    HStack(spacing: 12) {
                        if images.count > 1 {
                            navButton("chevron.left") {
                                let prev = (currentIndex - 1 + images.count) % images.count
                                onFocusChange(images[prev].id)
                            }
                        }

                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 900, maxHeight: 600)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.4), radius: 20, y: 6)

                        if images.count > 1 {
                            navButton("chevron.right") {
                                let next = (currentIndex + 1) % images.count
                                onFocusChange(images[next].id)
                            }
                        }
                    }

                    // 缩略图条 —— 多张图时显示
                    if images.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(images) { img in
                                thumbnail(img)
                            }
                        }
                    }
                }
                .padding(.vertical, 30)
            }
        }
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func thumbnail(_ img: CanvasElement) -> some View {
        Group {
            if let path = img.imagePath, let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(img.id == focusID ? Color.white : Color.white.opacity(0.2),
                                    lineWidth: img.id == focusID ? 2 : 0.5)
                    )
                    .onTapGesture { onFocusChange(img.id) }
            }
        }
    }

    private func saveToDesktop(element: CanvasElement) {
        guard let path = element.imagePath else { return }
        let src = URL(fileURLWithPath: path)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        let safeTopic = board.topic.replacingOccurrences(of: "/", with: "-")
        let safeCaption = element.caption.replacingOccurrences(of: "/", with: "-")
        let target = desktop.appendingPathComponent("\(safeTopic)-\(safeCaption).png")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: src, to: target)
        } catch {
            // 静默失败 —— Lightbox 里无 toast 通道
        }
    }
}

// MARK: - 新建画布 Sheet
//
// 点 "+" 菜单选"新建画布"时弹出。两步：选模板 → 填主题 → 开始。

struct CanvasCreatorSheet: View {
    /// 提交回调：模板 + 主题 + 用户上传的参考图（绝对路径数组）
    let onCreate: (CanvasTemplate, String, [URL]) -> Void
    let onCancel: () -> Void

    @State private var selectedTemplate: CanvasTemplate = CanvasTemplates.ecommerce
    @State private var topic: String = ""
    @State private var referenceImages: [URL] = []
    @State private var isDropTargeted = false
    @FocusState private var topicFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.3.group.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.indigo)
                Text("新建画布")
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("选模板")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker(selection: $selectedTemplate) {
                    ForEach(CanvasTemplates.all, id: \.id) { tpl in
                        Label(tpl.name, systemImage: tpl.icon).tag(tpl)
                    }
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                Text(selectedTemplate.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("主题")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("如：可口可乐 / SwiftUI 入门课 / 一个孤独的灯塔", text: $topic)
                    .textFieldStyle(.roundedBorder)
                    .focused($topicFocused)
                    .onSubmit { submit() }
            }

            referenceImageSection

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    Label("开始生成", systemImage: "sparkles")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { topicFocused = true }
    }

    /// 真实产品图上传区 —— 解决 AI 画品牌乱画问题。可选，但顶部明确推荐
    private var referenceImageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("产品参考图")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("（强烈推荐 · 让品牌还原度大幅提升）")
                    .font(.caption2)
                    .foregroundStyle(.indigo)
            }

            // 已上传缩略图 + 添加按钮
            HStack(spacing: 8) {
                ForEach(Array(referenceImages.enumerated()), id: \.offset) { idx, url in
                    referenceThumb(url: url, index: idx)
                }
                addReferenceButton
            }

            Text("没上传也能生成，但 AI 会从零画，品牌细节大概率不对（如 logo 错版 / 标签糊）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func referenceThumb(url: URL, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.indigo.opacity(0.4), lineWidth: 1)
                    )
            }
            Button {
                referenceImages.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
        }
    }

    private var addReferenceButton: some View {
        Button {
            pickFiles()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? Color.indigo : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: 56, height: 56)
                Image(systemName: "plus")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .help("点击选图，或拖一张产品图进来")
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.message = "选择真实产品图（推荐多张：正面 / 侧面 / 细节）"
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !referenceImages.contains(url) {
                    referenceImages.append(url)
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in
                        if !referenceImages.contains(url) {
                            referenceImages.append(url)
                        }
                    }
                }
            }
        }
        return true
    }

    private func submit() {
        let trimmed = topic.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(selectedTemplate, trimmed, referenceImages)
    }
}
