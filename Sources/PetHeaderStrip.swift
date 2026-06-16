import SwiftUI

/// 聊天窗顶部薄条：默认 0pt 完全消失（v1.5 顶部 chrome 简化后状态展示搬到对话胶囊），
/// **仅在 Permission pending 时**展开成 ~66pt 决策卡片紧贴 chat 顶部。
///
/// 设计沿革：
/// - v1.2.5 ~ v1.4：常驻 28pt 状态条（sprite + 桌宠名 + 状态 + 4 只 mode rail）
/// - v1.5（现）：常驻部分整条删掉 —— sprite/mode rail/状态文本搬走，桌宠形象由欢迎页大 sprite +
///   对话胶囊 mini icon 承担；执行状态搬到当前对话胶囊（前台流式时拉长，决策 #13 数据流复用）；
///   mode 切换搬到输入栏右侧。**只剩 Permission 决策展开**这一项还需要紧贴 chat 顶部出现
///
/// **Permission 路由**：
/// - 聊天窗开着 → PetStrip 监听 HermesPetPermissionAsked，展开 ~66pt 显示决策卡
/// - 聊天窗关着 → PermissionWindowController 用独立 NSWindow 接管
///   (由 PermissionWindowController.show(request:) 内部检查 ChatWindowController.shared?.isVisible 决定)
/// - 聊天窗即将隐藏 → 通过 HermesPetPermissionMigrateToIsland 把 pending 移交给灵动岛
struct PetHeaderStrip: View {
    @Bindable var viewModel: ChatViewModel

    // MARK: - Permission 展开态
    /// 当前 pending 的 permission 请求。非 nil → strip 展开到 ~66pt 显示决策卡片。
    /// 聊天窗开着时由 HermesPetPermissionAsked 通知触发；关着时不接管（让 PermissionWindowController 弹独立窗口）
    @State private var pendingPermission: PermissionRequest? = nil
    /// 决策后短暂展示的结果（allow/always/reject），0.8s 后清空 + 收回展开态
    @State private var lastDecision: PermissionDecision? = nil
    @State private var permissionDismissTask: Task<Void, Never>?

    /// permission 展开后总高度。**v1.5 默认 0pt（整条隐形）**，只有 pending 时才长出来
    private static let permissionExpandedHeight: CGFloat = 66

    /// 当前是否处于 permission 展开态
    private var inPermissionMode: Bool {
        pendingPermission != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // permission 展开区（仅 pending 时长出来；平时整条 0pt 完全不占位）
            if inPermissionMode {
                permissionExpandedSection
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: inPermissionMode ? Self.permissionExpandedHeight : 0)
        .background(
            // 仅 permission 模式才有 amber 警示底色；平时不渲染任何背景
            Group {
                if inPermissionMode {
                    Color(NSColor.systemOrange).opacity(0.12)
                }
            }
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.84), value: inPermissionMode)
        // —— Permission 监听：聊天窗开着时接管展开，关着时让 PermissionWindowController 弹独立窗口 ——
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetPermissionAsked"))) { note in
            guard let req = note.userInfo?["request"] as? PermissionRequest else { return }
            // 聊天窗关着 → 不接管（让 PermissionWindowController 用独立窗口接管）
            guard ChatWindowController.shared?.isVisible == true else { return }
            permissionDismissTask?.cancel()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
                pendingPermission = req
                lastDecision = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetPermissionReplied"))) { note in
            // 外部回执（如 AI 主动取消请求） → 立刻收回 PetStrip 展开
            let replyID = note.userInfo?["requestID"] as? String
            guard let cur = pendingPermission, cur.id == replyID else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                pendingPermission = nil
                lastDecision = nil
            }
            permissionDismissTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetPermissionDecisionMade"))) { note in
            // 决策来源可能是本地按钮也可能是别处（如灵动岛卡片）。两边都监听，UI 一致收回
            let id = note.userInfo?["requestID"] as? String
            guard let cur = pendingPermission, cur.id == id else { return }
            if lastDecision == nil,
               let raw = note.userInfo?["decision"] as? String,
               let d = PermissionDecision(rawValue: raw) {
                lastDecision = d
            }
            scheduleDismissAfterDecision()
        }
        // 聊天窗即将隐藏 —— 把 pending 移交给灵动岛 PermissionWindowController，避免决策被丢
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetChatWindowWillHide"))) { _ in
            guard let req = pendingPermission else { return }
            permissionDismissTask?.cancel()
            pendingPermission = nil
            lastDecision = nil
            NotificationCenter.default.post(
                name: .init("HermesPetPermissionMigrateToIsland"),
                object: nil,
                userInfo: ["request": req]
            )
        }
    }

    /// permission 展开区（约 66pt 高）：工具名 + 主参数 + 三按钮
    @ViewBuilder
    private var permissionExpandedSection: some View {
        if let req = pendingPermission {
            VStack(alignment: .leading, spacing: 6) {
                // 第一行：工具名 + 主参数（amber 风格）
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(NSColor.systemOrange))
                    Text(req.toolDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let arg = req.primaryArg, !arg.isEmpty {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(displayArgWide(arg))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }

                // 第二行：三按钮 OR 决策结果 banner
                if let dec = lastDecision {
                    decisionResultBanner(dec)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    decisionButtonsRow(for: req)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: lastDecision)
        }
    }

    /// 三按钮横排 —— 跟 PermissionCardView 颜色一致（灰/橙/蓝），用户已认得这套色码
    private func decisionButtonsRow(for req: PermissionRequest) -> some View {
        HStack(spacing: 6) {
            decisionButton(.reject, label: "Deny", tint: Color(NSColor.systemGray), for: req)
            decisionButton(.always, label: "Always", tint: Color(NSColor.systemOrange), for: req)
            decisionButton(.once, label: "Allow", tint: Color(NSColor.systemBlue), for: req)
        }
    }

    /// 决策结果 banner（"允许了 ✓" / "拒绝了 ✗"），0.8s 后展开收回
    private func decisionResultBanner(_ dec: PermissionDecision) -> some View {
        HStack {
            Spacer()
            Image(systemName: dec.resultIcon)
                .font(.system(size: 12, weight: .semibold))
            Text(dec.resultText)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dec.resultColor.opacity(0.88))
        )
    }

    private func decisionButton(_ decision: PermissionDecision,
                                label: String,
                                tint: Color,
                                for req: PermissionRequest) -> some View {
        Button {
            handleDecision(decision, for: req)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.88))
                )
        }
        .buttonStyle(.plain)
    }

    /// 用户点了某个决策按钮 —— 立刻 set lastDecision 触发结果 banner，post 通知让 hook server 回写
    private func handleDecision(_ decision: PermissionDecision, for req: PermissionRequest) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            lastDecision = decision
        }
        NotificationCenter.default.post(
            name: .init("HermesPetPermissionDecisionMade"),
            object: nil,
            userInfo: ["requestID": req.id, "decision": decision.rawValue]
        )
        scheduleDismissAfterDecision()
    }

    /// 决策后 0.8s 收回展开态
    private func scheduleDismissAfterDecision() {
        permissionDismissTask?.cancel()
        permissionDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                pendingPermission = nil
                lastDecision = nil
            }
        }
    }

    /// permission 展开区里参数显示宽一点（30 字阈值），路径取 lastPathComponent
    private func displayArgWide(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let last = (trimmed as NSString).lastPathComponent
        let candidate = last.isEmpty ? trimmed : last
        return candidate.count > 30 ? (String(candidate.prefix(28)) + "…") : candidate
    }

}

// MARK: - PermissionDecision 视觉扩展

private extension PermissionDecision {
    /// "请你看一眼"被决策后短暂展示的文本
    @MainActor
    var resultText: String {
        switch self {
        case .once:   return L("island.petstrip.decision.allowed")
        case .always: return L("island.petstrip.decision.whitelisted")
        case .reject: return L("island.petstrip.decision.rejected")
        }
    }

    /// 顶部 statusText 简版
    @MainActor
    var shortResultText: String {
        switch self {
        case .once:   return L("island.petstrip.decision.allowedShort")
        case .always: return L("island.petstrip.decision.alwaysShort")
        case .reject: return L("island.petstrip.decision.rejectedShort")
        }
    }

    var resultIcon: String {
        switch self {
        case .once, .always: return "checkmark.circle.fill"
        case .reject:        return "xmark.circle.fill"
        }
    }

    var resultColor: Color {
        switch self {
        case .once:   return Color(NSColor.systemBlue)
        case .always: return Color(NSColor.systemOrange)
        case .reject: return Color(NSColor.systemGray)
        }
    }
}

// MARK: - 旧版顶部 mode rail（v1.5 起整条 PetHeaderStrip 简化，mode 切换搬到输入栏右侧）
// 保留下方 ModeRailView/ModeRailButton 源码以防外部引用；当前未在任何视图里挂载
struct ModeRailView: View {
    let activeMode: AgentMode
    @Bindable var paletteStore: PetPaletteStore

    /// 重渲染触发器 —— enabledModes 变化时 +1 让 SwiftUI 重读 store
    @State private var refreshTick: Int = 0

    /// 按 AgentMode.allCases 顺序过滤出当前 enabled 的 mode
    private var visibleModes: [AgentMode] {
        let s = EnabledModesStore.shared.enabledModes
        return AgentMode.allCases.filter { s.contains($0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(visibleModes) { mode in
                ModeRailButton(
                    mode: mode,
                    isActive: mode == activeMode,
                    palette: paletteStore.palette(for: mode)
                )
            }
        }
        .id(refreshTick)   // store 变化时强制重新计算 visibleModes
        .onReceive(NotificationCenter.default.publisher(for: EnabledModesStore.didChangeNotification)) { _ in
            refreshTick &+= 1
        }
    }
}

private struct ModeRailButton: View {
    let mode: AgentMode
    let isActive: Bool
    let palette: PetPalette

    @State private var isHovering = false
    /// 全局「桌宠动效」开关。quietMode=true 时 hover 也不启动 60fps
    @AppStorage("quietMode") private var quietMode: Bool = false

    /// 每只 mini sprite 视觉高度
    private static let spriteHeight: CGFloat = 14

    var body: some View {
        ZStack {
            // active mode：圆形主色底（半透明）让用户一眼定位"当前在哪只"
            if isActive {
                Circle()
                    .fill(palette.primary.opacity(0.22))
                    .frame(width: Self.spriteHeight * 1.7,
                           height: Self.spriteHeight * 1.7)
            }
            sprite
                .frame(width: Self.spriteHeight * 1.4, height: Self.spriteHeight)
        }
        .scaleEffect(isHovering ? 1.22 : (isActive ? 1.05 : 0.92))
        .opacity(isHovering ? 1.0 : (isActive ? 1.0 : 0.78))
        .overlay(alignment: .bottom) {
            // active 标记小圆点 —— 主色 3pt，悬挂在 sprite 下边缘
            if isActive {
                Circle()
                    .fill(palette.primary)
                    .frame(width: 3, height: 3)
                    .offset(y: 3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: Self.spriteHeight * 1.6, height: Self.spriteHeight * 1.6)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            NotificationCenter.default.post(
                name: .init("HermesPetNewConversationWithMode"),
                object: nil,
                userInfo: ["mode": mode.rawValue]
            )
        }
        .help(L("island.petstrip.newConvHelp", L(mode.labelKey)))
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isActive)
    }

    /// 渲染对应 mode 的 mini sprite。
    /// **性能要点（v1.2.9）**：mini sprite 默认走静态帧（animated=false），
    /// hover 时才启动内部 60fps TimelineView。4 只 mini 不 hover 时 = 0 fps
    /// （之前 4×60=240 fps 是 v1.2.7 CPU 高负载主因）
    @ViewBuilder
    private var sprite: some View {
        let anim = isHovering && !quietMode
        switch mode {
        case .claudeCode:
            ClawdView(pose: .rest, height: Self.spriteHeight,
                      isWalking: isHovering, palette: palette, animated: anim)
        case .directAPI:
            // 在线 AI 的 mini 切换图标 = 红色小怪兽
            MonsterPixelView(pose: .rest, height: Self.spriteHeight,
                             isWorking: isHovering, palette: palette, animated: anim)
        case .qwenCode:
            // QwenCode 的 mini 切换图标 = 青色戴眼镜小怪兽
            MonsterPixelView(pose: .rest, height: Self.spriteHeight,
                             isWorking: isHovering, palette: palette, animated: anim, wearsGlasses: true)
        case .openclaw:
            FomoView(pose: .rest, height: Self.spriteHeight,
                     isWalking: isHovering, palette: palette, animated: anim)
        case .hermes:
            HorseView(pose: .rest, height: Self.spriteHeight,
                      isWalking: isHovering, palette: palette, animated: anim)
        case .codex:
            TerminalView(pose: .rest, height: Self.spriteHeight,
                         isWalking: isHovering,
                         isWorking: isHovering, palette: palette, animated: anim)
        }
    }
}
