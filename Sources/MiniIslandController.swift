import AppKit
import SwiftUI

/// 灵动岛「第三形态」—— 菜单栏常驻迷你胶囊。
///
/// 跟「刘海」「悬浮胶囊」是同一层级、可在设置里切换的显示模式（`DisplayMode.mini`）。
/// 选了它之后：
///   - **不创建大灵动岛**（`DynamicIslandController` 在 AppDelegate 里被跳过，连它的点击/hover
///     全局监听都不挂 —— 避免空刘海误触）。
///   - 菜单栏上**常驻一颗主胶囊**：Clawd（当前 mode）头像 + 右上角连接状态点（绿/红/灰）。
///     点一下开/关聊天窗；hover 放大露出桌宠名 + 状态文字。
///   - 有对话在**后台流式**时，主胶囊右侧**并排**多出任务胶囊，每条一颗；hover 放大看对话名 +
///     已运行时长（实时跳秒）；点一下切到那条对话。后台没活动时只剩主胶囊一颗。
///   - 整体极小，几乎不占空间 —— 专治"刘海/悬浮太占地方"。
///
/// **为什么是独立 NSWindow**（守 CLAUDE.md 决策 #1 / #16）：窗口宽度会随胶囊数量 / hover 变化而
/// setFrame，灵动岛本体 NSWindow 永远不能 setFrame（macOS 26 一改就崩），所以走跟
/// `PermissionWindowController` 一样的独立窗口路线 —— 本窗口可安全 setFrame。
///
/// **数据来源**：`ChatViewModel.broadcastBackgroundStreamingCount` 的
/// `HermesPetBackgroundStreamingChanged` 通知（带 activities: id/mode/title/startedAt）+
/// `HermesPetModeChanged`（当前 mode）+ `HermesPetStatusChanged`（连接状态）。
@MainActor
final class MiniIslandController {

    static weak var shared: MiniIslandController?

    /// 主胶囊在 hover / 列表里的固定 id（区别于真实对话 id）
    static let mainID = "__hermes_mini_main__"

    /// 主胶囊被点击 —— AppDelegate 接到后开/关聊天窗（跟大灵动岛 onTapped 等价）
    var onTapped: (() -> Void)?

    private let window: NSWindow
    private let hosting: NSHostingController<MiniIslandView>
    private let state = MiniIslandState()

    /// 最近一次广播的后台活动（缓存供 hover / 重排时重算）
    private var latestItems: [ActivityItem] = []
    /// 是否已激活（= 当前确实是 mini 显示模式）
    private var active = false

    // MARK: - 形态参数（要改观感就调这几个）

    /// 主胶囊收起 / 放大宽度
    private let mainCollapsed: CGFloat = 34
    private let mainExpanded: CGFloat = 150
    /// 任务胶囊收起 / 放大宽度
    private let taskCollapsed: CGFloat = 30
    private let taskExpanded: CGFloat = 172
    /// 胶囊间距 / 整排内边距 / 距灵动岛位置的间隙
    private let spacing: CGFloat = 6
    private let railPadding: CGFloat = 3
    private let gapFromIsland: CGFloat = 14

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        win.level = HermesWindowLevel.dynamicIsland
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = false   // 胶囊要可点击 + 可 hover
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.alphaValue = 0   // activate() 才显示
        self.window = win

        // 初始 mode / 状态（跟大灵动岛同源，避免启动瞬间显示错头像）
        state.mode = Self.initialMode()
        state.status = Self.initialStatus()

        // ⚠️ 必须用 NSHostingController（不是 NSHostingView）——守 CLAUDE.md 决策 #1：
        // NSHostingView 即便 sizingOptions=[] 在 macOS 26 上仍会通过 updateAnimatedWindowSize
        // 在 CA commit 期间反推 NSWindow.setFrame → 嵌套 layout → SIGABRT。本窗口尺寸随 hover /
        // 活动数动态 setFrame，必须用 NSHostingController 才能真正禁掉反推、让 setFrame 安全。
        let host = NSHostingController(rootView: MiniIslandView(
            state: state,
            mainCollapsed: mainCollapsed, mainExpanded: mainExpanded,
            taskCollapsed: taskCollapsed, taskExpanded: taskExpanded,
            spacing: spacing, railPadding: railPadding
        ))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        win.contentViewController = host
        host.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗，动态 setFrame 后内容跟随（autoresizingMask 收口）
        self.hosting = host

        Self.shared = self
        registerObservers()
    }

    /// 进入 mini 显示模式（AppDelegate 在 `DisplayMode.isMini` 时调）—— 常驻显示主胶囊
    func activate() {
        active = true
        reposition()
        window.orderFront(nil)
        window.alphaValue = 1
    }

    /// 语音陪聊呼出/退出 → 迷你胶囊淡出/淡入（仅 mini 模式激活时）。
    private func fadeForVoiceChat(voiceActive: Bool) {
        guard active else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            window.animator().alphaValue = voiceActive ? 0 : 1
        }
    }

    // MARK: - 初值

    private static func initialMode() -> AgentMode {
        if let raw = UserDefaults.standard.string(forKey: "agentMode"),
           let m = AgentMode(rawValue: raw) { return m }
        return .hermes
    }

    private static func initialStatus() -> MiniConnStatus {
        let hasKey = !(UserDefaults.standard.string(forKey: "apiKey") ?? "").isEmpty
        return hasKey ? .connected : .unknown
    }

    private func mapStatus(_ raw: ChatViewModel.ConnectionStatus) -> MiniConnStatus {
        switch raw {
        case .connected:    return .connected
        case .disconnected: return .disconnected
        case .unknown:      return .unknown
        }
    }

    // MARK: - 通知监听

    private func registerObservers() {
        let nc = NotificationCenter.default

        // 当前 mode 变化 → 换主胶囊头像
        nc.addObserver(forName: .init("HermesPetModeChanged"), object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?["mode"] as? String
            MainActor.assumeIsolated {
                guard let self = self, let raw = raw, let m = AgentMode(rawValue: raw) else { return }
                withAnimation(AnimTok.snappy) { self.state.mode = m }
            }
        }

        // 连接状态变化 → 换主胶囊状态点颜色
        nc.addObserver(forName: .init("HermesPetStatusChanged"), object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?["status"] as? ChatViewModel.ConnectionStatus
            MainActor.assumeIsolated {
                guard let self = self, let raw = raw else { return }
                withAnimation(AnimTok.snappy) { self.state.status = self.mapStatus(raw) }
            }
        }

        // 后台活动列表变化 → 增减任务胶囊
        nc.addObserver(forName: .init("HermesPetBackgroundStreamingChanged"), object: nil, queue: .main) { [weak self] note in
            let rawList = note.userInfo?["activities"] as? [[String: String]] ?? []
            MainActor.assumeIsolated {
                self?.latestItems = Self.parse(rawList)
                self?.refresh()
            }
        }

        // hover 某颗胶囊（含主胶囊）→ 放大 / 复原
        nc.addObserver(forName: .init("HermesPetActivityCapsuleHover"), object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? String
            let inside = note.userInfo?["inside"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self = self, let id = id else { return }
                if inside {
                    self.setHover(id)
                } else if self.state.hoveredID == id {
                    self.setHover(nil)   // 只有离开的正是当前放大那颗才复原（防 A→B 误清）
                }
            }
        }

        // 点主胶囊 → 开/关聊天窗
        nc.addObserver(forName: .init("HermesPetMiniMainTapped"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTapped?() }
        }

        // 屏幕几何变化 → 重新定位
        nc.addObserver(forName: .init("HermesPetGeometry"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        // 语音陪聊呼出 → 迷你胶囊淡出让位；退出 → 淡回来
        nc.addObserver(forName: .init("HermesPetVoiceChatActive"), object: nil, queue: .main) { [weak self] note in
            let voiceActive = note.userInfo?["active"] as? Bool ?? false
            MainActor.assumeIsolated { self?.fadeForVoiceChat(voiceActive: voiceActive) }
        }
    }

    // MARK: - 数据解析

    private static func parse(_ raw: [[String: String]]) -> [ActivityItem] {
        raw.compactMap { dict in
            guard let id = dict["id"],
                  let modeRaw = dict["mode"],
                  let mode = AgentMode(rawValue: modeRaw) else { return nil }
            let startedAt = dict["startedAt"]
                .flatMap(Double.init)
                .map { Date(timeIntervalSinceReferenceDate: $0) }
            return ActivityItem(id: id, mode: mode, title: dict["title"] ?? "", startedAt: startedAt)
        }
    }

    // MARK: - 刷新 / 几何

    private func refresh() {
        // 当前放大那颗任务已消失（对话跑完）→ 清 hover
        if let h = state.hoveredID, h != Self.mainID,
           !latestItems.contains(where: { $0.id == h }) {
            state.hoveredID = nil
        }
        withAnimation(AnimTok.snappy) {
            state.activities = latestItems
        }
        if active { reposition() }
    }

    /// 当前内容总宽度（主胶囊 + 各任务胶囊，hover 那颗算放大宽）
    private func contentWidth() -> CGFloat {
        var w = railPadding * 2
        w += (state.hoveredID == Self.mainID) ? mainExpanded : mainCollapsed
        for item in state.activities {
            w += spacing
            w += (item.id == state.hoveredID) ? taskExpanded : taskCollapsed
        }
        return w
    }

    private func reposition() {
        guard active else { return }
        guard let screen = HermesIslandGeometry.targetScreen() else { return }

        let centerX = HermesIslandGeometry.islandCenterX(on: screen)
        let coreW = HermesIslandGeometry.islandCoreWidth(on: screen)
        let coreH = HermesIslandGeometry.islandCoreHeight(on: screen)

        // 灵动岛可见右沿 ≈ 中心 + 半个刘海宽 + 半个"耳朵"(idleExtraWidth/2 = 40)
        let islandRightEdge = centerX + coreW / 2 + 40
        let leftX = islandRightEdge + gapFromIsland

        let w = contentWidth()
        let h = coreH + 6   // 留点余量给呼吸辉光；胶囊在其中垂直居中
        let y = screen.frame.maxY - h

        window.setFrame(NSRect(x: leftX, y: y, width: w, height: h), display: false)
    }

    // MARK: - hover 放大 / 复原

    private func setHover(_ id: String?) {
        withAnimation(AnimTok.snappy) { state.hoveredID = id }
        if id != nil {
            reposition()   // 放大：立刻撑大窗口，内容不会被裁
        } else {
            // 复原：延后缩窗，让胶囊先动画收完再裁（避免文字被窗口边缘割掉）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                guard let self = self, self.state.hoveredID == nil else { return }
                self.reposition()
            }
        }
    }
}

// MARK: - 状态

@MainActor
@Observable
final class MiniIslandState {
    var mode: AgentMode = .hermes
    var status: MiniConnStatus = .unknown
    var activities: [ActivityItem] = []
    /// 当前被 hover 放大的胶囊 id（`MiniIslandController.mainID` = 主胶囊；其余 = 对话 id；nil = 全收起）
    var hoveredID: String? = nil
}

/// 主胶囊的连接状态点。
enum MiniConnStatus {
    case connected, disconnected, unknown

    var dotColor: Color {
        switch self {
        case .connected:    return .green
        case .disconnected: return .red
        case .unknown:      return Color.gray.opacity(0.6)
        }
    }
    var labelKey: String {
        switch self {
        case .connected:    return "island.mini.connected"
        case .disconnected: return "island.mini.disconnected"
        case .unknown:      return "island.mini.unknown"
        }
    }
}

/// 一条后台活动（= 一条后台流式对话）。
struct ActivityItem: Identifiable, Equatable {
    let id: String          // 对话 id（点击切换用）
    let mode: AgentMode     // 决定头像精灵 + 主色
    let title: String       // 放大态 / tooltip 显示
    let startedAt: Date?    // 这次流式开始时间 —— 放大态算"已运行时长"
}

// MARK: - SwiftUI Root

/// 主胶囊 + 一排并排任务胶囊。左端锚定，数量 / hover 变化时平滑增减、放大。
struct MiniIslandView: View {
    @Bindable var state: MiniIslandState
    let mainCollapsed: CGFloat
    let mainExpanded: CGFloat
    let taskCollapsed: CGFloat
    let taskExpanded: CGFloat
    let spacing: CGFloat
    let railPadding: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            // —— 主胶囊（常驻）——
            MainCapsule(
                mode: state.mode,
                status: state.status,
                collapsedWidth: mainCollapsed,
                expandedWidth: mainExpanded,
                expanded: state.hoveredID == MiniIslandController.mainID
            )
            .help(L(state.mode.petNameKey))
            .onHover { postHover(MiniIslandController.mainID, $0) }
            .onTapGesture {
                NotificationCenter.default.post(name: .init("HermesPetMiniMainTapped"), object: nil)
            }

            // —— 后台任务胶囊（并排）——
            ForEach(state.activities) { item in
                ActivityCapsule(
                    item: item,
                    collapsedWidth: taskCollapsed,
                    expandedWidth: taskExpanded,
                    expanded: state.hoveredID == item.id
                )
                .help(item.title)
                .onHover { postHover(item.id, $0) }
                .onTapGesture {
                    NotificationCenter.default.post(
                        name: .init("HermesPetActivityCapsuleTapped"),
                        object: nil, userInfo: ["id": item.id]
                    )
                }
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, railPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(AnimTok.snappy, value: state.activities)
    }

    private func postHover(_ id: String, _ inside: Bool) {
        NotificationCenter.default.post(
            name: .init("HermesPetActivityCapsuleHover"),
            object: nil, userInfo: ["id": id, "inside": inside]
        )
    }
}

/// 主胶囊：黑底 + mode 主色呼吸描边 + Clawd 头像；右上角连接状态点。
/// hover 放大露出 桌宠名 + 状态文字。
private struct MainCapsule: View {
    let mode: AgentMode
    let status: MiniConnStatus
    let collapsedWidth: CGFloat
    let expandedWidth: CGFloat
    let expanded: Bool

    @State private var pulse = false
    @AppStorage("quietMode") private var quietMode: Bool = false
    private var tint: Color { mode.railTint }

    var body: some View {
        content
            .frame(width: expanded ? expandedWidth : collapsedWidth, height: 22)
            .background(Capsule().fill(Color.black.opacity(0.92)))
            .overlay(Capsule().stroke(tint.opacity(pulse ? 0.85 : 0.4), lineWidth: 1.0))
            .overlay(alignment: .topTrailing) {
                if !expanded {
                    Circle()
                        .fill(status.dotColor)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .padding(.top, 1.5)
                        .padding(.trailing, 4)
                }
            }
            .shadow(color: tint.opacity(pulse ? 0.45 : 0.0), radius: 3)
            .contentShape(Capsule())
            .onAppear {
                guard !quietMode else { return }
                withAnimation(AnimTok.breathe) { pulse = true }
            }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            HStack(spacing: 5) {
                ModeSpriteView(mode: mode, isWorking: false, size: 15, animated: false)
                    .frame(width: 17)
                Text(L(mode.petNameKey))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L(status.labelKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(status.dotColor.opacity(0.95))
            }
            .padding(.horizontal, 8)
        } else {
            ModeSpriteView(mode: mode, isWorking: false, size: 15, animated: false)
        }
    }
}

/// 单颗任务胶囊：黑底 + mode 主色呼吸描边 + 头像；hover 放大露出对话名 + 已运行时长。
/// 头像用静态帧（`animated: false`）省 CPU —— "正在跑"靠描边/辉光呼吸表达。
private struct ActivityCapsule: View {
    let item: ActivityItem
    let collapsedWidth: CGFloat
    let expandedWidth: CGFloat
    let expanded: Bool

    @State private var pulse = false
    @AppStorage("quietMode") private var quietMode: Bool = false
    private var tint: Color { item.mode.railTint }

    var body: some View {
        content
            .frame(width: expanded ? expandedWidth : collapsedWidth, height: 22)
            .background(Capsule().fill(Color.black.opacity(0.92)))
            .overlay(Capsule().stroke(tint.opacity(pulse ? 0.85 : 0.35), lineWidth: 1.0))
            .shadow(color: tint.opacity(pulse ? 0.45 : 0.0), radius: 3)
            .contentShape(Capsule())
            .onAppear {
                guard !quietMode else { return }
                withAnimation(AnimTok.breathe) { pulse = true }
            }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            HStack(spacing: 5) {
                ModeSpriteView(mode: item.mode, isWorking: true, size: 15, animated: false)
                    .frame(width: 17)
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ElapsedLabel(startedAt: item.startedAt, tint: tint, pulsing: !quietMode)
            }
            .padding(.horizontal, 8)
        } else {
            ModeSpriteView(mode: item.mode, isWorking: true, size: 15, animated: false)
        }
    }
}

/// 放大态右侧「● 已运行时长」标签 —— 每秒跳一次（仅放大态渲染，收起时不跑 timer，省 CPU）。
private struct ElapsedLabel: View {
    let startedAt: Date?
    let tint: Color
    let pulsing: Bool

    @State private var dot = false

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(tint)
                .frame(width: 4, height: 4)
                .opacity(dot ? 1.0 : 0.4)
            if let started = startedAt {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text(Self.format(ctx.date.timeIntervalSince(started)))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
            }
        }
        .fixedSize()
        .onAppear {
            guard pulsing else { return }
            withAnimation(AnimTok.breathe) { dot = true }
        }
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension AgentMode {
    /// 迷你胶囊的 mode 主色（跟 DynamicIslandController.modeTint 保持一致）
    var railTint: Color {
        switch self {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        case .qwenCode:   return .teal
        }
    }
}
