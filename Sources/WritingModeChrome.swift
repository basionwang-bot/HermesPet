import SwiftUI
import AppKit

/// 写作模式三栏的"边栏控件"：可拖拽改宽的分隔把手 + 收起后的文件图标条 + 收起后的桌宠条。
/// 不用 HSplitView（它的动态重测会和聊天 ScrollView 的自动贴底打架致抖动），改用 HStack +
/// 自定义拖拽把手：只在用户拖动时改宽（非持续重测），既能调宽又不抖。

// MARK: - 可拖拽分隔把手（兼作分隔线）

/// 三栏之间的可拖拽分隔条。
/// ⚠️ 用 **NSView 实现而非纯 SwiftUI 的 DragGesture**：聊天窗开了 `isMovableByWindowBackground = true`，
/// 纯 SwiftUI 的 8pt 透明把手上按下拖动经常被 AppKit 当成"拖整个窗口"截走 → 手感很差、放大缩小不灵敏。
/// NSView 子类 `override mouseDownCanMoveWindow = false` 能从根上让窗口不抢这块区域的鼠标，
/// 再自己处理 mouseDragged 报告位移 + addCursorRect 上左右箭头光标 → 命中区宽 10pt、按下即拖、稳。
struct WMResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    let minW: CGFloat
    let maxW: CGFloat
    /// +1：向右拖变宽（左侧栏用）；-1：向左拖变宽（右侧栏用）
    let direction: CGFloat

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let v = ResizeHandleNSView()
        let coord = context.coordinator
        v.onDragBegan = { coord.startW = coord.currentWidth?() ?? 0 }
        v.onDragChanged = { dx in
            let base = coord.startW
            coord.setWidth?(min(coord.maxW, max(coord.minW, base + dx * coord.direction)))
        }
        return v
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        let coord = context.coordinator
        coord.minW = minW
        coord.maxW = maxW
        coord.direction = direction
        coord.currentWidth = { width }
        coord.setWidth = { width = $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var startW: CGFloat = 0
        var minW: CGFloat = 0
        var maxW: CGFloat = 0
        var direction: CGFloat = 1
        var currentWidth: (() -> CGFloat)?
        var setWidth: ((CGFloat) -> Void)?
    }
}

/// 分隔条 NSView：画一条 1pt 竖线（hover 时加粗高亮），命中区 10pt 宽，
/// 鼠标拖动时按"相对按下点的水平位移"回调，光标显示为左右箭头。
final class ResizeHandleNSView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?

    private var startX: CGFloat = 0
    private var hovering = false

    /// ⭐ 关键：让 isMovableByWindowBackground 的窗口不要把这块区域的鼠标按下当成"拖窗口"
    override var mouseDownCanMoveWindow: Bool { false }

    /// 固定 10pt 宽（命中区），高度交给 SwiftUI 撑满
    override var intrinsicContentSize: NSSize {
        NSSize(width: 10, height: NSView.noIntrinsicMetric)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent)  { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDragChanged?(event.locationInWindow.x - startX)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineW: CGFloat = hovering ? 3 : 1
        let x = (bounds.width - lineW) / 2
        let color = hovering
            ? NSColor.labelColor.withAlphaComponent(0.18)
            : NSColor.separatorColor
        color.setFill()
        NSBezierPath(rect: NSRect(x: x, y: 0, width: lineW, height: bounds.height)).fill()
    }
}

// MARK: - 收起后的左侧文件图标条

struct CollapsedFileRail: View {
    let store: NotesStore
    let tint: Color
    var onExpand: () -> Void

    /// 悬停预览的目标笔记（满 0.45s 才显）+ 鼠标 y（决定预览竖直位置）。
    /// ⭐ 预览**不再用 .popover**：popover 是 transient，弹出后点图标会被"点外面先关弹窗"吃掉点击 → 点不动。
    /// 改成挂在**窄条这一层**(ScrollView 之外，不被裁)的浮层 + `allowsHitTesting(false)` → 点击永远直达图标。
    @State private var peekNote: NotesStore.NoteFile? = nil
    @State private var peekY: CGFloat = 60
    @State private var peekTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            Button { onExpand() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .help(L("notes.sidebar.expand"))
                .padding(.top, 12)
            Button { store.createNote() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help(L("notes.action.new"))

            Divider().padding(.horizontal, 10)

            ScrollView {  // 决策 #21：不套 GeometryReader
                VStack(spacing: 5) {
                    ForEach(store.notes) { note in
                        CollapsedFileIcon(
                            note: note,
                            selected: note.id == store.selectedNoteID,
                            tint: tint,
                            onSelect: {                       // 点击：立刻取消/收预览 + 选中（无 popover 抢点击）
                                cancelPeek()
                                store.select(note.id)
                            },
                            onHoverChanged: { hovering in
                                if hovering { schedulePeek(note) }
                                else if peekNote?.id == note.id { cancelPeek() }
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
        // 鼠标在窄条里的 y —— 用来把预览浮层放到当前图标高度旁边
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase { peekY = p.y }
        }
        // 预览浮层：挂在窄条层(不进 ScrollView 裁剪)，推到窄条右侧，绝不拦点击
        .overlay(alignment: .topLeading) {
            if let note = peekNote {
                FilePeek(note: note, tint: tint)
                    .id(note.id)                       // 换笔记时重建 → onAppear 重新读片段
                    .allowsHitTesting(false)
                    .offset(x: 56, y: max(6, peekY - 30))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: peekNote?.id)
        .onDisappear { cancelPeek() }
    }

    private func schedulePeek(_ note: NotesStore.NoteFile) {
        peekTask?.cancel()
        peekTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)   // 悬停满 0.45s 才弹，快速点击不触发
            if !Task.isCancelled { peekNote = note }
        }
    }
    private func cancelPeek() {
        peekTask?.cancel()
        peekNote = nil
    }
}

/// 收起态单个文件图标 —— 悬停放大 + 弹出 peek 卡片（标题 + 内容片段，不是全文）。
private struct CollapsedFileIcon: View {
    let note: NotesStore.NoteFile
    let selected: Bool
    let tint: Color
    var onSelect: () -> Void
    /// 悬停态变化上报给父层 —— 由父层(窄条层)统一管预览浮层，本图标只是个普通按钮，点击永不被拦
    var onHoverChanged: (Bool) -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: selected ? "doc.text.fill" : "doc.text")
                .font(.system(size: 15))
                .foregroundStyle(selected ? tint : .secondary)
                .frame(width: 36, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? tint.opacity(0.16) : (hover ? Color.primary.opacity(0.07) : .clear))
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.12 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .onHover { inside in
            hover = inside
            onHoverChanged(inside)
        }
    }
}

/// 悬停 peek 卡片：标题 + 内容前几行（懒读文件，只取片段）
private struct FilePeek: View {
    let note: NotesStore.NoteFile
    let tint: Color
    @State private var snippet = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text").foregroundStyle(tint)
                Text(note.title).font(.headline).lineLimit(1)
            }
            Divider()
            Text(snippet.isEmpty ? "（空文档）" : snippet)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 250)
        .onAppear {
            let s = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            snippet = String(s.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - 收起后的右侧对话条（桌宠图标，点击重新展开）

struct CollapsedChatRail: View {
    let mode: AgentMode
    /// AI 正在回话 —— 波浪更亮（"它在思考"）
    var isThinking: Bool = false
    var onExpand: () -> Void

    private var tint: Color { PetPaletteStore.shared.palette(for: mode).primary }

    var body: some View {
        Button(action: onExpand) {
            ZStack {
                // 底材质
                Color(NSColor.windowBackgroundColor).opacity(0.3)
                // ⭐ 向上流动的 mode 色波浪 —— 收起竖条的灵动特效（学聊天窗底部光晕，做成竖向持续流动）
                ModeWaveRail(tint: tint, isThinking: isThinking)
                // 居中 mode 图标：标明这是 AI 栏 + 提示点击展开；材质圆底让它压在波浪上也清晰
                Image(systemName: mode.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.regularMaterial))
                    .overlay(Circle().stroke(tint.opacity(0.25), lineWidth: 0.5))
            }
        }
        .buttonStyle(.plain)
        .help(L("notes.chat.expand"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
    }
}

/// 收起竖条的柔光填充 —— **跟聊天窗底部 `ModeAmbientGlow` 同款**：
/// 软 mode 色渐变从底部向上溢出（clear→tint，色集中在下半部），透明度**呼吸**。
/// 不再做滚动波浪/亮带（用户嫌花、太差）。竖条 = 把那条底部柔光竖过来铺满。
/// AI 回话(isThinking)时更亮、呼吸更快。纯透明度动画，GPU 合成几乎不耗 CPU。
struct ModeWaveRail: View {
    let tint: Color
    var isThinking: Bool = false

    @State private var breathe = false

    /// 呼吸基线 —— 跟 ModeAmbientGlow 一个路子（流式态 0.30↔0.52，闲时 0.16↔0.30）
    private var glowOpacity: Double {
        if isThinking { return breathe ? 0.52 : 0.30 }
        else          { return breathe ? 0.30 : 0.16 }
    }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: tint.opacity(0.0),  location: 0.00),
                .init(color: tint.opacity(0.35), location: 0.45),
                .init(color: tint.opacity(0.95), location: 1.00),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .opacity(glowOpacity)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.5), value: isThinking)
        .onAppear { startBreathe() }
        .onChange(of: isThinking) { _, _ in startBreathe() }
    }

    /// 呼吸动画 —— 思考态 1.2s 快呼吸，闲时 2.4s 慢呼吸（跟聊天底部光晕同感觉）
    private func startBreathe() {
        breathe = false
        withAnimation(.easeInOut(duration: isThinking ? 1.2 : 2.4).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }
}

