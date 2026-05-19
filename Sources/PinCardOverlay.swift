import AppKit
import SwiftUI

/// 桌面 Pin 卡片系统 —— 把聊天里的回答 / 快问的答案"钉"到桌面右上角。
///
/// 架构：
///   - `PinCard`：纯数据，Codable，持久化到 `~/.hermespet/pins.json`
///   - `PinStore`：单例，管理数组 + 持久化（含 customPosition 持久化）
///   - `PinCardController`：单例，管理 NSWindow 集合（每张 pin 一个独立 NSWindow，固定高度）
///   - `PinCardView`：SwiftUI 视图（静态精致摘要 + 单击转聊天）
///
/// v3 设计（2026-05-14 重做）：
///   - **去掉 hover 展开**：固定高度 130pt，hover 仅描边强调不变形（消除嵌套 layout 崩溃源）
///   - **单击 = 转聊天**：不再用双击，简化交互
///   - 卡片：mode 主色顶部色条 + 标题 + 2 行预览 + footer（mode label · 相对时间）
///   - 拖动位置持久化（NSWindowDelegate.windowDidMove → PinStore.updatePosition）
///
/// 触发点：
///   1. `QuickAskWindowController.handlePin()` — 快问回答的 📌 按钮
///   2. `ChatComponents.MessageBubble` hover overlay — assistant 气泡 hover 的 pin 按钮
///
/// 上限 8 张（避免桌面爆炸）；超出时调用方收到 false 返回值，自己提示用户

// MARK: - 数据模型

struct PinCard: Identifiable, Codable, Equatable {
    let id: String
    let title: String          // 截断的首行作为标题
    let content: String        // 完整 markdown 内容
    let modeRawValue: String   // AgentMode raw value（持久化用 string）
    let pinnedAt: Date
    /// 用户拖动后自定义的位置；nil 表示未自定义，跟随堆叠布局
    var customX: Double?
    var customY: Double?
    /// 是不是"任务 Pin"（AI 任务规划分解出来的）—— true 时卡片左侧多一个 checkbox
    var isTask: Bool
    /// 任务是否标记为完成（仅 isTask=true 时生效）。勾了**不会自渐隐**，
    /// 标题加删除线 + 灰阶留在桌面，用户手动关闭。让用户有"今天做完了 N 件"的成就感
    var isDone: Bool
    /// 来源对话 ID（从聊天气泡 pin 时记录，点击卡片时优先跳回原对话）
    var sourceConversationID: String?
    /// 来源消息 ID（用于滚动定位到原消息）
    var sourceMessageID: String?

    var mode: AgentMode { AgentMode(rawValue: modeRawValue) ?? .hermes }
    var hasCustomPosition: Bool { customX != nil && customY != nil }

    /// 普通 Pin 构造：从聊天回答 / Pin 按钮触发
    init(content: String, mode: AgentMode, sourceConversationID: String? = nil, sourceMessageID: String? = nil) {
        self.id = UUID().uuidString
        self.title = Self.makeTitle(from: content)
        self.content = content
        self.modeRawValue = mode.rawValue
        self.pinnedAt = Date()
        self.customX = nil
        self.customY = nil
        self.isTask = false
        self.isDone = false
        self.sourceConversationID = sourceConversationID
        self.sourceMessageID = sourceMessageID
    }

    /// 任务 Pin 构造：从 PlannedTask 转过来（AI 分解出来的待办）
    init(task: PlannedTask) {
        self.id = UUID().uuidString
        self.title = String(task.title.prefix(40))
        self.content = task.desc.isEmpty ? task.title : "\(task.title)\n\n\(task.desc)"
        self.modeRawValue = task.suggestedMode.rawValue
        self.pinnedAt = Date()
        self.customX = nil
        self.customY = nil
        self.isTask = true
        self.isDone = false
        self.sourceConversationID = nil
        self.sourceMessageID = nil
    }

    // Codable: 兼容旧版（customX/Y / isTask / isDone 字段缺失时 decode 不抛错）
    private enum CodingKeys: String, CodingKey {
        case id, title, content, modeRawValue, pinnedAt, customX, customY, isTask, isDone
        case sourceConversationID, sourceMessageID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.content = try c.decode(String.self, forKey: .content)
        self.modeRawValue = try c.decode(String.self, forKey: .modeRawValue)
        self.pinnedAt = try c.decode(Date.self, forKey: .pinnedAt)
        self.customX = try c.decodeIfPresent(Double.self, forKey: .customX)
        self.customY = try c.decodeIfPresent(Double.self, forKey: .customY)
        self.isTask = (try? c.decode(Bool.self, forKey: .isTask)) ?? false
        self.isDone = (try? c.decode(Bool.self, forKey: .isDone)) ?? false
        self.sourceConversationID = try c.decodeIfPresent(String.self, forKey: .sourceConversationID)
        self.sourceMessageID = try c.decodeIfPresent(String.self, forKey: .sourceMessageID)
    }

    /// 从 content 抽取标题：取第一行非空、去掉 markdown 前缀符号、最多 40 字
    private static func makeTitle(from content: String) -> String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? content
        let cleaned = firstLine
            .replacingOccurrences(of: #"^[#*`>\-\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count <= 40 { return cleaned }
        return String(cleaned.prefix(40)) + "…"
    }

    /// 摘要：从 content 抽 2~3 行有意义的内容做预览。
    /// 跳过标题行（如果存在）+ markdown 前缀符号，避免 "## 标题" 之类被当成预览
    var summary: String {
        let lines = content.components(separatedBy: .newlines)
        var collected: [String] = []
        var skippedTitle = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // 跳过第一行（已经做标题了）
            if !skippedTitle {
                skippedTitle = true
                let titleMatchesFirst = line
                    .replacingOccurrences(of: #"^[#*`>\-\s]+"#, with: "", options: .regularExpression)
                    .hasPrefix(title.replacingOccurrences(of: "…", with: ""))
                if titleMatchesFirst { continue }
            }
            // 去 markdown 前缀（# - * > 等）
            let cleaned = line
                .replacingOccurrences(of: #"^[#*`>\-\s]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty {
                collected.append(cleaned)
                if collected.count >= 3 { break }
            }
        }
        return collected.joined(separator: " ")
    }
}

// MARK: - 数据层 + 持久化

@MainActor
final class PinStore {
    static let shared = PinStore()
    static let maxPins = 8

    private(set) var pins: [PinCard] = []   // 按 pinnedAt 倒序（最新在前）

    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pins.json")
    }()

    private init() { load() }

    enum AddResult { case added, duplicate, full }

    @discardableResult
    func add(_ pin: PinCard) -> AddResult {
        if pins.contains(where: { $0.content == pin.content }) { return .duplicate }
        guard pins.count < Self.maxPins else { return .full }
        pins.insert(pin, at: 0)
        save()
        return .added
    }

    func remove(id: String) {
        pins.removeAll { $0.id == id }
        save()
    }

    func clear() {
        pins = []
        save()
    }

    /// 用户拖动 pin 后调用，把位置存进去
    func updatePosition(id: String, x: Double, y: Double) {
        guard let idx = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[idx].customX = x
        pins[idx].customY = y
        save()
    }

    /// 切换任务 Pin 的完成状态（仅 isTask=true 时有意义）
    func setDone(id: String, _ done: Bool) {
        guard let idx = pins.firstIndex(where: { $0.id == id }), pins[idx].isTask else { return }
        pins[idx].isDone = done
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.pins = try decoder.decode([PinCard].self, from: data)
        } catch {
            print("[PinStore] load 失败: \(error.localizedDescription)，跳过")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(pins)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[PinStore] save 失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - NSWindow 拖动监听

/// 每张 pin 的 window 有一个 delegate，监听**用户拖动**事件持久化位置。
///
/// ⚠️ 必须区分"用户拖动"和"代码 setFrame"。
/// NSWindow 没有原生 API 区分这两者 —— 只要 frame 变了就触发 windowDidMove。
/// controller 在每次程序化 setFrame **之前**刷新 `ignoreMovesUntil` 时间窗，
/// delegate 在窗口期内的所有 windowDidMove 都跳过（覆盖 animate 动画期 ~0.25s + 余量）。
final class PinWindowDelegate: NSObject, NSWindowDelegate {
    let pinID: String
    /// 程序化 setFrame 期间的 ignore 截止时间
    var ignoreMovesUntil: Date = .distantPast
    /// 防抖：拖动过程中频繁触发 windowDidMove，每 0.25s 才存一次
    private var saveTask: Task<Void, Never>?

    init(pinID: String) {
        self.pinID = pinID
    }

    func windowDidMove(_ notification: Notification) {
        if Date() < ignoreMovesUntil { return }
        guard let window = notification.object as? NSWindow else { return }
        let frame = window.frame
        let id = pinID
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            PinStore.shared.updatePosition(id: id, x: Double(frame.minX), y: Double(frame.minY))
        }
    }

    /// close 时由 controller 调用，避免 delegate 释放后 saveTask 还在 schedule
    func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }
}

// MARK: - NSWindow 管理

@MainActor
final class PinCardController {
    static let shared = PinCardController()

    private var windows: [String: NSWindow] = [:]
    private var delegates: [String: PinWindowDelegate] = [:]   // 强引用住 delegate
    /// 单击 pin 时调用，由外部（HermesPetApp）注入 —— 转新对话需要 ChatViewModel
    var onOpenInChat: ((PinCard) -> Void)?

    /// 卡片固定尺寸 —— **不再 hover 展开**。从根本上消除了多窗口嵌套 layout cycle 崩溃
    private static let cardWidth: CGFloat = 280
    private static let cardHeight: CGFloat = 124
    private static let cardSpacing: CGFloat = 10
    private static let rightMargin: CGFloat = 16
    private static let topMargin: CGFloat = 16

    private init() {}

    /// AppDelegate 启动时调用 —— 为已持久化的 pin 都创建窗口
    func bootstrap() {
        for pin in PinStore.shared.pins {
            createWindow(for: pin)
        }
        layoutAll()
    }

    /// 公开入口：把一段内容 pin 到桌面
    /// 触发点是 SwiftUI 同步栈（聊天气泡 / 快问的 📌 按钮）；layoutAll 跨窗口
    /// setFrame，异步到下一个 runloop，避免嵌套 layout cycle 引起 SIGABRT
    @discardableResult
    static func pin(content: String, mode: AgentMode, conversationID: String? = nil, messageID: String? = nil) -> PinStore.AddResult {
        let pin = PinCard(content: content, mode: mode, sourceConversationID: conversationID, sourceMessageID: messageID)
        let result = PinStore.shared.add(pin)
        if result == .added {
            shared.createWindow(for: pin)
            DispatchQueue.main.async { shared.layoutAll() }
        }
        return result
    }

    @discardableResult
    static func pinTask(_ task: PlannedTask) -> Bool {
        let pin = PinCard(task: task)
        guard PinStore.shared.add(pin) == .added else { return false }
        shared.createWindow(for: pin)
        DispatchQueue.main.async { shared.layoutAll() }
        return true
    }

    /// 任务 Pin 上勾 / 取消勾 checkbox 时调用 —— 仅更新数据 + 重渲染卡片，不动 frame
    func toggleTaskDone(id: String) {
        guard let idx = PinStore.shared.pins.firstIndex(where: { $0.id == id }) else { return }
        let current = PinStore.shared.pins[idx].isDone
        PinStore.shared.setDone(id: id, !current)
        // 重新创建 NSHostingView 让 SwiftUI 拿到最新的 pin 数据
        // （PinCardView 是值类型不会自动重新订阅 PinStore）
        if let win = windows[id], let newPin = PinStore.shared.pins.first(where: { $0.id == id }) {
            let host = NSHostingView(rootView: PinCardView(
                pin: newPin,
                onClose: { [weak self] in self?.close(id: id) },
                onCopy: { [weak self] in self?.copy(content: newPin.content) },
                onOpen: { [weak self] in self?.openInChat(pin: newPin) },
                onToggleDone: { [weak self] in self?.toggleTaskDone(id: id) }
            ))
            host.frame = NSRect(origin: .zero, size: win.frame.size)
            host.autoresizingMask = [.width, .height]
            if #available(macOS 13.0, *) { host.sizingOptions = [] }  // 决策 #6
            win.contentView = host
        }
    }

    func close(id: String) {
        delegates[id]?.cancelPendingSave()
        if let win = windows[id] {
            win.delegate = nil
            win.orderOut(nil)
        }
        windows.removeValue(forKey: id)
        delegates.removeValue(forKey: id)
        PinStore.shared.remove(id: id)
        DispatchQueue.main.async { [weak self] in
            self?.layoutAll()
        }
    }

    func closeAll() {
        for (id, win) in windows {
            delegates[id]?.cancelPendingSave()
            win.delegate = nil
            win.orderOut(nil)
        }
        windows.removeAll()
        delegates.removeAll()
        PinStore.shared.clear()
    }

    // MARK: - Private

    /// 程序化 setFrame 前调用：在接下来 0.5s 内忽略该 pin 的 windowDidMove
    private func suppressMoveTracking(for id: String) {
        delegates[id]?.ignoreMovesUntil = Date().addingTimeInterval(0.5)
    }

    private func createWindow(for pin: PinCard) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.chat
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true

        let delegate = PinWindowDelegate(pinID: pin.id)
        w.delegate = delegate
        delegates[pin.id] = delegate

        let pinID = pin.id
        let host = NSHostingView(rootView: PinCardView(
            pin: pin,
            onClose: { [weak self] in self?.close(id: pinID) },
            onCopy: { [weak self] in self?.copy(content: pin.content) },
            onOpen: { [weak self] in self?.openInChat(pin: pin) },
            onToggleDone: { [weak self] in self?.toggleTaskDone(id: pinID) }
        ))
        host.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight)
        host.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) { host.sizingOptions = [] }  // 决策 #6
        w.contentView = host

        windows[pin.id] = w

        if let cx = pin.customX, let cy = pin.customY {
            suppressMoveTracking(for: pin.id)
            w.setFrame(NSRect(x: cx, y: cy, width: Self.cardWidth, height: Self.cardHeight),
                       display: false)
        }
        w.orderFront(nil)
    }

    /// 单击 pin → 转聊天 / 打开聊天窗口。
    /// async 到下一个 runloop —— 避免在 SwiftUI .onTapGesture 同步栈里跨窗口操作引起嵌套 layout
    private func openInChat(pin: PinCard) {
        let cb = onOpenInChat
        Task { @MainActor in
            cb?(pin)
        }
    }

    /// 屏幕右上角自上而下堆叠所有 pin（固定高度，无需测算）。
    ///
    /// ⚠️ **必须用 animate: false**（瞬移而不是动画）—— macOS 26 + SwiftUI 多 NSHostingView
    /// 同时跑 animated setFrame 会触发：windowDidLayout → updateAnimatedWindowSize →
    /// SwiftUI invalidateSafeAreaInsets → setNeedsUpdateConstraints → AppKit 在 layout
    /// 阶段抛 NSException → SIGABRT。
    /// Pin 重排是布局事件不是 UI 入场动画，瞬移完全够用、体验也自然
    private func layoutAll() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var currentTopY = visible.maxY - Self.topMargin

        for pin in PinStore.shared.pins {
            guard let win = windows[pin.id] else { continue }
            if pin.hasCustomPosition { continue }
            let x = visible.maxX - Self.cardWidth - Self.rightMargin
            let y = currentTopY - Self.cardHeight
            suppressMoveTracking(for: pin.id)
            // 瞬移：animate: false。避免多个 pin 窗口同时跑动画 → SwiftUI 嵌套 layout 崩溃
            win.setFrame(
                NSRect(x: x, y: y, width: Self.cardWidth, height: Self.cardHeight),
                display: true,
                animate: false
            )
            currentTopY = y - Self.cardSpacing
        }
    }

    private func copy(content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    func exportAllPinsToMarkdown() {
        let pins = PinStore.shared.pins
        guard !pins.isEmpty else { return }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "yyyyMMdd-HHmm"

        var lines: [String] = ["# Pin 导出", "", "> 导出时间：\(dateFmt.string(from: Date()))  共 \(pins.count) 条", "", "---", ""]
        for pin in pins {
            lines.append("## \(pin.title)")
            lines.append("")
            lines.append("> \(pin.mode.label) · \(dateFmt.string(from: pin.pinnedAt))\(pin.isTask ? " · 任务\(pin.isDone ? "（已完成）" : "")" : "")")
            lines.append("")
            lines.append(pin.content)
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "pins-\(stampFmt.string(from: Date())).md"
        panel.title = "导出全部 Pin 为 Markdown"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - SwiftUI 视图

struct PinCardView: View {
    let pin: PinCard
    let onClose: () -> Void
    let onCopy: () -> Void
    /// 单击卡片 → 打开聊天（替代原来的双击）
    let onOpen: () -> Void
    /// 任务 Pin 的 checkbox 点击回调；非任务 Pin 不会触发
    var onToggleDone: () -> Void = {}

    @State private var isHovering = false
    @State private var didCopy = false

    private var modeTint: Color {
        switch pin.mode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    private var modeIcon: String {
        switch pin.mode {
        case .hermes:     return "sparkle"
        case .directAPI:  return "cloud.fill"
        case .openclaw:   return "bolt.circle.fill"
        case .claudeCode: return "terminal.fill"
        case .codex:      return "wand.and.stars"
        }
    }

    /// 相对时间 —— "刚刚 / 3 分钟前 / 1 小时前 / 昨天 / 2 月 14 日"
    private var relativeTime: String {
        let secs = Date().timeIntervalSince(pin.pinnedAt)
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(Int(secs / 60)) 分钟前" }
        if secs < 86400 { return "\(Int(secs / 3600)) 小时前" }
        if secs < 86400 * 2 { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = "M 月 d 日"
        return f.string(from: pin.pinnedAt)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // —— 底层卡片 ——
            VStack(alignment: .leading, spacing: 6) {
                headerRow
                summaryText
                Spacer(minLength: 0)
                footerRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                // 顶部 mode 主色细色条 —— 视觉锚点，让 pin 一眼能看出是哪个 AI 的回答
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [modeTint, modeTint.opacity(0.55)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(height: 2.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isHovering ? modeTint.opacity(0.65) : .white.opacity(0.14),
                        lineWidth: isHovering ? 1.2 : 0.6
                    )
            )
            // 任务 Pin 标记完成后整张卡变淡 —— 视觉上明显是"已完成"，但不消失（用户选择"不自渐隐"）
            .opacity(pin.isDone ? 0.55 : 1.0)
            .shadow(
                color: isHovering ? modeTint.opacity(0.2) : .black.opacity(0.18),
                radius: isHovering ? 14 : 8,
                y: isHovering ? 4 : 2
            )
            .scaleEffect(isHovering ? 1.015 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isHovering)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 单击卡片任何位置 → 打开聊天
            onOpen()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .help("点击转聊天 · 拖动调整位置")
    }

    // MARK: - 子视图

    private var headerRow: some View {
        HStack(spacing: 8) {
            // 任务 Pin 左侧 checkbox（点击切换 done 状态，不冒到外层的"单击转聊天"上）
            if pin.isTask {
                Button(action: onToggleDone) {
                    Image(systemName: pin.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(pin.isDone ? modeTint : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pin.isDone ? "标记为未完成" : "标记为已完成")
            } else {
                // 普通 Pin 显示 mode 图标圆形徽章
                ZStack {
                    Circle()
                        .fill(modeTint.opacity(0.18))
                        .frame(width: 22, height: 22)
                    Image(systemName: modeIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(modeTint)
                }
            }

            Text(pin.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(pin.isDone ? .secondary : .primary)
                .strikethrough(pin.isDone, color: .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // hover 时显示复制按钮
            if isHovering {
                actionButton(
                    systemName: didCopy ? "checkmark" : "doc.on.doc",
                    tint: didCopy ? .green : .secondary,
                    help: didCopy ? "已复制" : "复制内容"
                ) {
                    onCopy()
                    didCopy = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        didCopy = false
                    }
                }
                .transition(.opacity.combined(with: .scale))
            }

            actionButton(systemName: "xmark", tint: .secondary, help: "关闭") {
                onClose()
            }
        }
    }

    /// 2 行摘要 —— 足够让用户大致知道这是个什么内容
    private var summaryText: some View {
        Text(pin.summary.isEmpty ? pin.content : pin.summary)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 底部：mode label · 相对时间
    private var footerRow: some View {
        HStack(spacing: 6) {
            Text(pin.mode.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(modeTint.opacity(0.85))

            Circle()
                .fill(.tertiary)
                .frame(width: 2, height: 2)

            Text(relativeTime)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            Spacer()

            // hover 时显示"点击打开"提示
            if isHovering {
                HStack(spacing: 3) {
                    Text("打开")
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(modeTint)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }

    @ViewBuilder
    private func actionButton(systemName: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
