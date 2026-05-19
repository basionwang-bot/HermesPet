import SwiftUI

/// 聊天窗顶部 28pt 高的桌宠状态条（permission pending 时展开到 ~94pt）。
///
/// 这块区域以前被 NSWindow 的隐形 titlebar 占着 (.titled styleMask + .fullSizeContentView)
/// —— 视觉上一片空白，仅用作窗口拖动。现在让 SwiftUI 内容延伸到那里，承载：
///   1. 当前 mode 对应的迷你桌宠 sprite (Clawd/云朵/小马/coco)
///   2. 桌宠名 + 状态文本 (idle / 思考中 / 工具调用中 / 完成)
///   3. 右侧工具图标 + M/N 步进度
///   4. **Permission 决策面**（聊天窗开着时收到 HermesPetPermissionAsked → 展开成 90pt 卡片）
///
/// 让用户在聊天窗里也能感知"是哪只小宠物在帮我处理"，并看到具体在做什么。
///
/// 设计要点：
/// - sprite 紧贴 leading（traffic light 已 isHidden=true，不会跟系统按钮冲突）
/// - sprite 点击 = 摸摸头跳一下 (不切 mode，mode 切换保留在下方原 headerView 的 ModeSwitcherButton)
/// - 背景用 palette.primary 渐变（顶部浓 → 底部淡），跟桌宠主色一致并跟下面 header 平滑过渡
/// - 工作时整条 strip 颜色被"点亮"+ sprite 周围光圈呼吸，让桌宠看起来"嵌入"窗口顶部
/// - **Permission 路由**：聊天窗开着 → PetStrip 展开接管；关着 → 走原 PermissionWindowController
///   (由 PermissionWindowController.show(request:) 内部检查 ChatWindowController.shared?.isVisible 决定)
/// - 通知 schema 复用 PillView 已有的工具状态机 (决策 #13)
struct PetHeaderStrip: View {
    @Bindable var viewModel: ChatViewModel
    @State private var paletteStore = PetPaletteStore.shared
    /// 全局「桌宠动效」开关。quietMode=true → sprite 走静态帧省 CPU
    @AppStorage("quietMode") private var quietMode: Bool = false

    // MARK: - 工具状态机 (跟 DynamicIslandController PillView 同款逻辑)
    @State private var currentToolKind: ToolKind? = nil
    @State private var currentToolArg: String = ""
    @State private var stepStarted: Int = 0
    @State private var stepEnded: Int = 0

    // MARK: - 完成态短暂展示
    @State private var showDoneState: Bool = false
    @State private var doneTask: Task<Void, Never>?

    // MARK: - sprite 摸摸头跳动
    @State private var spriteJumping: Bool = false

    // MARK: - 工作中"桌宠融入窗口"过渡
    /// 工作态强度 0~1，控制 strip 整体颜色加深 + sprite 光圈不透明度。
    /// TaskStarted → 1，TaskFinished → 0（用 withAnimation 平滑过渡 0.5s）
    @State private var workingHighlight: Double = 0
    /// sprite 光圈呼吸 toggle，repeatForever 驱动；**仅工作态 / permission pending 时启动**
    /// （v1.2.9 之前永久循环 → 即便 idle 看不见，blur(4) + scaleEffect 仍每帧让 GPU 重算，WindowServer 高负载）
    @State private var spotPulse: Bool = false

    // MARK: - Permission 展开态
    /// 当前 pending 的 permission 请求。非 nil → strip 展开到 94pt 显示决策卡片。
    /// 聊天窗开着时由 HermesPetPermissionAsked 通知触发；关着时不接管（让 PermissionWindowController 弹独立窗口）
    @State private var pendingPermission: PermissionRequest? = nil
    /// 决策后短暂展示的结果（allow/always/reject），0.8s 后清空 + 收回展开态
    @State private var lastDecision: PermissionDecision? = nil
    @State private var permissionDismissTask: Task<Void, Never>?

    private static let stripHeight: CGFloat = 28
    /// permission 展开后总高度
    private static let permissionExpandedHeight: CGFloat = 94
    /// sprite 离左边的安全 padding —— traffic light 三个按钮 isHidden=true 后无 hit region，
    /// 留 10pt 避免 sprite 跟窗口左上圆角粘脸；窗口圆角 14pt，10pt sprite leading 不会被裁
    private static let spriteLeadingPad: CGFloat = 10
    /// sprite 视觉高度。strip 28pt 上下各留 4pt padding -> 20pt 可用
    private static let spriteHeight: CGFloat = 20

    private var mode: AgentMode { viewModel.agentMode }
    private var palette: PetPalette { paletteStore.palette(for: mode) }

    /// 桌宠中文名 —— idle 时显示在状态文本前作为身份标识
    private var petName: String {
        switch mode {
        case .claudeCode: return "Clawd"
        case .directAPI:  return "云朵"
        case .openclaw:   return "fomo"   // PR-B 上线龙虾 sprite
        case .hermes:     return "小马"
        case .codex:      return "coco"
        }
    }

    /// 状态描述文本 (不含桌宠名)。permission pending 时会被 permission 卡片覆盖，此处仍计算给"在岛上等待"场景
    private var statusText: String {
        if let dec = lastDecision { return dec.shortResultText }
        if pendingPermission != nil { return "请你看一眼" }
        if showDoneState { return "搞定！" }
        if let tool = currentToolKind {
            let argShort = displayArg(currentToolArg)
            if argShort.isEmpty { return tool.verb }
            return "\(tool.verb) · \(argShort)"
        }
        if viewModel.isLoading { return "思考中..." }
        return "在这呢"
    }

    /// sprite 内部动画状态：工具调用中 / 流式中都视为"在干活"。permission pending 时也算"求救态"算工作
    private var spriteIsWorking: Bool {
        pendingPermission != nil
            || currentToolKind != nil
            || (viewModel.isLoading && !showDoneState)
    }

    /// 当前是否处于 permission 展开态（包含决策后短暂展示结果阶段）
    private var inPermissionMode: Bool {
        pendingPermission != nil
    }

    /// sprite 是否切到 armsUp pose（permission pending 时举手"求救"）
    private var spritePose: ClawdPose {
        inPermissionMode ? .armsUp : .rest
    }

    /// 光圈颜色 —— permission pending 时切到 systemOrange 表达紧迫感
    private var spotColor: Color {
        inPermissionMode ? Color(NSColor.systemOrange) : palette.primary
    }

    /// 光圈强度 —— permission pending 时拉高
    private var spotOpacity: Double {
        if inPermissionMode { return 0.55 }
        return 0.45 * workingHighlight
    }

    /// 工具进度 "M/N"（只在多步工具调用时显示，单步省略避免视觉噪音）
    private var stepText: String? {
        guard stepStarted >= 2 else { return nil }
        return "\(min(stepEnded, stepStarted))/\(stepStarted)"
    }

    /// 简化参数：路径只保留 lastPathComponent，长字符串截断到 24 字
    private func displayArg(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let last = (trimmed as NSString).lastPathComponent
        let candidate = last.isEmpty ? trimmed : last
        return candidate.count > 24 ? (String(candidate.prefix(22)) + "…") : candidate
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部那一行（永远存在）：sprite + 桌宠名 + 状态文本 + 工具进度
            topRow

            // permission 展开区（pending 时显示，决策按钮 + 文件名）
            if inPermissionMode {
                permissionExpandedSection
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: inPermissionMode ? Self.permissionExpandedHeight : Self.stripHeight)
        .background(
            // 基础：顶部主色更浓（0.28）→ 底部淡（0.06），跟下面 headerView 自然渐变过渡
            // 工作中叠层：在基础之上再加一层实色，由 workingHighlight 控制（0 → 0.18）
            // permission 模式：额外叠 amber 层强化紧迫感
            ZStack {
                LinearGradient(
                    colors: [
                        palette.primary.opacity(0.28),
                        palette.primary.opacity(0.06)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                palette.primary.opacity(0.18 * workingHighlight)
                if inPermissionMode {
                    Color(NSColor.systemOrange).opacity(0.10)
                }
            }
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.84), value: inPermissionMode)
        // 工作 / permission pending 时才启动 spotPulse 呼吸动画（v1.2.9 性能优化）：
        // 之前永久 repeatForever 即便 idle 看不见（opacity=0），blur(4) + scaleEffect 仍每帧让
        // WindowServer 重算合成，是 idle 状态 CPU 高负载主因之一
        .onChange(of: workingHighlight) { _, new in
            updateSpotPulse(active: (new > 0) || inPermissionMode)
        }
        .onChange(of: inPermissionMode) { _, perm in
            updateSpotPulse(active: perm || (workingHighlight > 0))
        }
        // —— 通知监听：跟 DynamicIslandController PillView 同款 schema ——
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskStarted"))) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                currentToolKind = nil
                currentToolArg = ""
                stepStarted = 0
                stepEnded = 0
                showDoneState = false
            }
            // strip 整体被"点亮" —— 颜色加深 + sprite 光圈浮现
            withAnimation(.easeOut(duration: 0.45)) {
                workingHighlight = 1.0
            }
            doneTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolStarted"))) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            let kind = ToolKind.from(toolName: name)
            // 优先用 arg (短描述)，没有再降级到 file_path (Write/Edit 类工具)
            let arg = (note.userInfo?["arg"] as? String)
                ?? (note.userInfo?["file_path"] as? String)
                ?? ""
            stepStarted += 1
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                currentToolKind = kind
                currentToolArg = arg
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolEnded"))) { _ in
            stepEnded += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                currentToolKind = nil
                currentToolArg = ""
            }
            let success = (note.userInfo?["success"] as? Bool) ?? false
            // 不管 success 与否，工作高亮都该退掉
            doneTask?.cancel()
            if success {
                // 成功 → 短暂"搞定！" + sprite 跳一下，0.9s 后整体淡回 idle
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    showDoneState = true
                    spriteJumping = true
                }
                doneTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    spriteJumping = false
                    try? await Task.sleep(nanoseconds: 620_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.easeOut(duration: 0.5)) {
                        showDoneState = false
                        workingHighlight = 0
                    }
                }
            } else {
                // 失败 / 取消 → 直接淡回 idle
                withAnimation(.easeOut(duration: 0.45)) {
                    workingHighlight = 0
                }
            }
        }
        // —— Permission 监听：聊天窗开着时接管展开，关着时让 PermissionWindowController 弹独立窗口 ——
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetPermissionAsked"))) { note in
            guard let req = note.userInfo?["request"] as? PermissionRequest else { return }
            // 聊天窗关着 → 不接管（让 PermissionWindowController 用独立窗口接管）
            guard ChatWindowController.shared?.isVisible == true else { return }
            // 接管 → 展开 90pt
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
            // 如果是本地按钮发出的 lastDecision 已经被设置；远端发出的还得这里 set 一下兜底
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
            // 本地状态清掉（聊天窗收起就跟着收）
            permissionDismissTask?.cancel()
            pendingPermission = nil
            lastDecision = nil
            // 把请求"重新广播"成 Asked，让 PermissionWindowController 接管。
            // 此时 ChatWindowController.shared?.isVisible 还是 true（还没真正 hide 完），
            // 直接 re-post 会被 PermissionWindowController 短路掉。
            // 改用一条专属"移交"通知，PermissionWindowController 监听后无条件 show
            NotificationCenter.default.post(
                name: .init("HermesPetPermissionMigrateToIsland"),
                object: nil,
                userInfo: ["request": req]
            )
        }
    }

    /// 顶部那一行（28pt）：sprite + 桌宠名 + 状态文本 + 工具进度
    private var topRow: some View {
        HStack(spacing: 8) {
            // sprite + 周围呼吸光圈（光圈在 ZStack 底层，sprite 在上面）
            ZStack {
                // 工作中浮现的圆形光圈 —— "桌宠嵌入窗口"的视觉粘合点
                // permission pending 时颜色切到 systemOrange 表达紧迫感
                // v1.2.9：仅工作 / permission pending 时插入 Circle；idle 不挂以省 blur(4) GPU 成本
                if spotOpacity > 0 {
                    Circle()
                        .fill(spotColor.opacity(spotOpacity))
                        .frame(width: Self.spriteHeight * 1.6,
                               height: Self.spriteHeight * 1.6)
                        .scaleEffect(spotPulse ? 1.10 : 0.92)
                        .blur(radius: 4)
                        .transition(.opacity)
                }
                spriteView
                    .frame(width: Self.spriteHeight * 1.5, height: Self.spriteHeight)
            }
            .offset(y: spriteJumping ? -3 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: spriteJumping)
            .contentShape(Rectangle())
            .onTapGesture { headPat() }
            .help("\(petName) · 摸摸头")
            .padding(.leading, Self.spriteLeadingPad)

            // 名字 · 状态
            HStack(spacing: 5) {
                Text(petName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.88))
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(inPermissionMode
                                     ? Color(NSColor.systemOrange)
                                     : Color.secondary)
                    .lineLimit(1)
                    .id(statusText) // 文本变化时强制重建 → transition 生效
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: statusText)

            Spacer(minLength: 4)

            // 右侧工具图标 + 进度（permission 展开时隐藏 —— 决策栏更显眼）
            if let kind = currentToolKind, !inPermissionMode {
                HStack(spacing: 4) {
                    Image(systemName: kind.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(kind.iconColor)
                    if let step = stepText {
                        Text(step)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(palette.primary.opacity(0.25))
                )
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }

            // 4 只 mini sprite mode 切换器 —— 永远常驻最右侧，permission pending 时也保留
            // 点击任何一只 = 以该 mode 新建对话（哪怕是当前 mode 也开新对话方便并发）
            ModeRailView(activeMode: mode, paletteStore: paletteStore)
                .padding(.trailing, 10)
        }
        .frame(height: Self.stripHeight)
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

    /// 启停 sprite 光圈呼吸动画。active=true 时进入 repeatForever；
    /// active=false 时用普通短动画把 spotPulse 拨回 false 打断循环。
    /// （SwiftUI repeatForever 没法显式停，只能在 withAnimation 块外覆盖状态来"切断"）
    private func updateSpotPulse(active: Bool) {
        if active {
            // 已经在循环中就不重启（避免 phase 跳）
            guard spotPulse == false else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                spotPulse = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                spotPulse = false
            }
        }
    }

    /// 摸摸头：sprite 跳一下，无后续动作
    private func headPat() {
        spriteJumping = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            spriteJumping = false
        }
    }

    /// 按当前 mode 渲染对应 sprite
    @ViewBuilder
    private var spriteView: some View {
        let anim = !quietMode
        switch mode {
        case .claudeCode:
            ClawdView(pose: spritePose, height: Self.spriteHeight,
                      isWalking: spriteIsWorking, palette: palette, animated: anim)
        case .directAPI:
            CloudPetView(pose: spritePose, height: Self.spriteHeight,
                         isWalking: spriteIsWorking, glassesProgress: 0,
                         palette: palette, animated: anim)
        case .openclaw:
            FomoView(pose: spritePose, height: Self.spriteHeight,
                     isWalking: spriteIsWorking, palette: palette, animated: anim)
        case .hermes:
            HorseView(pose: spritePose, height: Self.spriteHeight,
                      isWalking: spriteIsWorking, palette: palette, animated: anim)
        case .codex:
            TerminalView(pose: spritePose, height: Self.spriteHeight,
                         isWalking: spriteIsWorking,
                         isWorking: spriteIsWorking, palette: palette, animated: anim)
        }
    }
}

// MARK: - PermissionDecision 视觉扩展

private extension PermissionDecision {
    /// "请你看一眼"被决策后短暂展示的文本
    var resultText: String {
        switch self {
        case .once:   return "允许了"
        case .always: return "已添加白名单"
        case .reject: return "拒绝了"
        }
    }

    /// 顶部 statusText 简版
    var shortResultText: String {
        switch self {
        case .once:   return "允许了 ✓"
        case .always: return "总是允许 ✓"
        case .reject: return "拒绝了"
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

// MARK: - 右侧 4 只 mini sprite mode 切换器

/// PetHeaderStrip 最右侧的 mode 入口栏：mini sprite 横排，**只展示 enabled 的 mode**
/// （v1.3.6 起新用户首启默认只 .directAPI，其余 mode 在设置里手动开启）。
/// 点击任何一只 = 新建对应 mode 对话。
///
/// 设计要点：
/// - 当前 active mode 那只下方加 3pt 主色圆点 + 主色 0.18 圆形底色
/// - hover 时整只 sprite scale 到 1.22 + 触发 sprite 内部的 isWalking 灵动呼吸
/// - 点击 = post HermesPetNewConversationWithMode 通知，由 ChatViewModel 接管新建
/// - 订阅 EnabledModesStore.didChangeNotification，设置里改 toggle 后自动刷新
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
        .help("新建 \(mode.label) 对话")
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
            CloudPetView(pose: .rest, height: Self.spriteHeight,
                         isWalking: isHovering, glassesProgress: 0,
                         palette: palette, animated: anim)
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
