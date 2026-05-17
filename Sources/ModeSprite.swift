import SwiftUI

/// 灵动岛左耳的 mode 精灵 —— 显示当前 AgentMode 的标志元素，
/// 并在"工作中"（流式生成时）播放各自专属的动画。
///
/// Claude → 橘色 asterisk 自转（Claude 品牌色）
/// Hermes → 绿色羽毛轻摆（信使羽毛）
/// Codex  → 青色 `</>` 旁边加一个闪烁光标
struct ModeSpriteView: View {
    let mode: AgentMode
    /// 是否正在"工作中" —— 播放各自的动画
    let isWorking: Bool
    let size: CGFloat

    var body: some View {
        switch mode {
        case .claudeCode:
            // Clawd 是 3:1 宽矮比例的像素精灵，让它用自己的 aspect ratio，不强行套正方形
            ClaudeKnotSprite(isWorking: isWorking, size: size)
        case .hermes:
            HermesFeatherSprite(isWorking: isWorking, size: size)
                .frame(width: size + 4, height: size + 4)
        case .directAPI:
            // 在线 AI 跑 opencode agent runtime，视觉用云朵小精灵区别于 Hermes 羽毛
            CloudPetIslandSprite(isWorking: isWorking, size: size)
                .frame(width: size + 4, height: size + 4)
        case .codex:
            CodexCursorSprite(isWorking: isWorking, size: size)
                .frame(width: size + 4, height: size + 4)
        }
    }
}

// MARK: - Claude：Clawd 🦞 (8-bit 像素小家伙，自家版本)

/// Clawd 的 pose 状态。形象**完全照搬 Anthropic 官方 SVG**（参考
/// marciogranzotto/clawd-tank/clawd-static-base.svg）：viewBox 15×10 上的
/// 几个矩形组件构成 —— torso 大矩形 + 左右手臂 + 4 条腿（2+2 不等距）+
/// 两个 1×2 竖长眼睛 + 半透明地面阴影。
///
/// pose 主要影响眼神方向和 armsUp（伸懒腰）。
/// 走路 / 呼吸 / 眨眼等动画由 ClawdView 内部 TimelineView 自动驱动
enum ClawdPose {
    case rest, lookLeft, lookRight, armsUp
}

/// Clawd sprite 的一个像素矩形组件。坐标在 viewBox 15×10 内
/// （已减去官方 SVG 原 y=6 偏移，让 sprite 从 y=0 开始）
struct ClawdRect {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
}

/// 官方 Clawd 像素渲染器
///
/// 像素图（viewBox 15×10）：
/// ```
///         0  1  2  3  4  5  6  7  8  9 10 11 12 13 14
/// row 0:           ████████████████████████████          ← torso 顶
/// row 1:           ████████████████████████████
/// row 2:           ██████ ▣  ██████████ ▣  ██████        ← 眼睛 col 4, col 10
/// row 3:        █████████████████████████████████        ← 手臂左右伸 col 0-1, col 13-14
/// row 4:        █████████████████████████████████
/// row 5:           ████████████████████████████
/// row 6:           ████████████████████████████          ← torso 底
/// row 7:                  ██    ██       ██    ██        ← 4 腿（col 3, 5, 9, 11）
/// row 8:                  ██    ██       ██    ██
/// row 9:                 ░░░░░░░░░░░░░░░░░░░░░           ← 半透明地面阴影
/// ```
///
/// 动画（TimelineView 自动驱动）：
/// 1. **呼吸** 3.2s loop，scale ±2% 横纵反向
/// 2. **眨眼** 5s 间隔，最后 200ms 闭眼
/// 3. **走路** (isWalking=true 时) 1s loop：身体 bob + 4 腿对角交替 + 手臂上下摆
/// 4. **眼神** lookLeft/lookRight → 眼睛 translate ±2 unit
/// 5. **伸懒腰** armsUp → 身体 scale(0.95, 1.10) + 手臂上抬
struct ClawdView: View {
    let pose: ClawdPose
    /// 精灵高度。最终 frame 宽 = height × 1.5（viewBox 15:10）
    let height: CGFloat
    /// 是否正在走路 —— 控制 4 条腿对角交替抬放
    var isWalking: Bool = false
    /// 眼睛是否要平滑跟随鼠标（pose 为 .rest 时才生效；
    /// .lookLeft/.lookRight/.armsUp 时仍用离散偏移以保留这些 pose 表达力）
    var followMouse: Bool = false

    /// Anthropic Clawd 官方色 #DE886D
    private static let bodyColor = Color(red: 222.0/255, green: 136.0/255, blue: 109.0/255)
    /// 顶部高光带：在官方色基础上提亮 ~12%（左上光源）
    private static let bodyTopColor = Color(red: 240.0/255, green: 161.0/255, blue: 135.0/255)
    /// 底部阴影带：在官方色基础上压暗 ~15%（增加体积感）
    private static let bodyBottomColor = Color(red: 192.0/255, green: 110.0/255, blue: 86.0/255)
    private static let viewBoxW: CGFloat = 15
    private static let viewBoxH: CGFloat = 10
    /// scale 锚点：sprite 中心
    private static let centerX: CGFloat = 7.5
    private static let centerY: CGFloat = 5.0

    // 官方静态 sprite 矩形（viewBox 15×10，已减去 y=6 偏移）
    private static let torso     = ClawdRect(x: 2,  y: 0, w: 11, h: 7)
    private static let leftArm   = ClawdRect(x: 0,  y: 3, w: 2,  h: 2)
    private static let rightArm  = ClawdRect(x: 13, y: 3, w: 2,  h: 2)
    /// 4 条腿。索引 0-3 = outer-left / inner-left / inner-right / outer-right
    /// 走路时 (0, 2) 一组（leg-a），(1, 3) 一组（leg-b）—— 对角交替
    private static let legs: [ClawdRect] = [
        ClawdRect(x: 3,  y: 7, w: 1, h: 2),
        ClawdRect(x: 5,  y: 7, w: 1, h: 2),
        ClawdRect(x: 9,  y: 7, w: 1, h: 2),
        ClawdRect(x: 11, y: 7, w: 1, h: 2),
    ]
    private static let leftEye  = ClawdRect(x: 4,  y: 2, w: 1, h: 2)
    private static let rightEye = ClawdRect(x: 10, y: 2, w: 1, h: 2)
    private static let shadow   = ClawdRect(x: 3,  y: 9, w: 9, h: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: height * Self.viewBoxW / Self.viewBoxH, height: height)
    }

    // MARK: - 绘制

    private func draw(ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        let unit = min(size.width / Self.viewBoxW, size.height / Self.viewBoxH)
        let bodyFill = GraphicsContext.Shading.color(Self.bodyColor)
        // body 顶部高光（更亮的橘）：模拟左上光源，让 sprite 立体
        let bodyTopShading = GraphicsContext.Shading.color(Self.bodyTopColor)
        // body 底部阴影（暗橘）：增加体积感
        let bodyBottomShading = GraphicsContext.Shading.color(Self.bodyBottomColor)
        let eyeFill  = GraphicsContext.Shading.color(.black)
        let highlightFill = GraphicsContext.Shading.color(.white)
        let shadowFill = GraphicsContext.Shading.color(.black.opacity(0.5))

        // —— 动画参数 ——

        // 呼吸 3.2s loop，scale ±2% 横纵反向
        let breatheT = sin(now * 2 * .pi / 3.2)
        let breatheSX: CGFloat = 1 + CGFloat(breatheT) * 0.02
        let breatheSY: CGFloat = 1 - CGFloat(breatheT) * 0.02

        // 走路 phase 0~1
        let walkPhase = isWalking ? now.truncatingRemainder(dividingBy: 1.0) : 0

        // 眨眼：每 4.5s 一次，最后 0.18s 闭眼（比之前略快眨频更俏皮）
        let blinkCycle = 4.5
        let blinkPhase = now.truncatingRemainder(dividingBy: blinkCycle) / blinkCycle
        let isBlinking = blinkPhase > 0.96

        // 眼神偏移（看左/看右）
        // pose 为 .rest 且 followMouse 时：眼睛连续跟随鼠标 x/y 坐标
        // 其他 pose（lookLeft/lookRight/armsUp）保留离散偏移，让这些 pose 仍能表达"刻意瞥一眼"
        let (eyeLookX, eyeLookY): (CGFloat, CGFloat) = {
            switch pose {
            case .lookLeft:  return (-2, 0)
            case .lookRight: return ( 2, 0)
            case .armsUp:    return ( 0, 0)
            case .rest:
                guard followMouse else { return (0, 0) }
                return Self.continuousMouseEyeOffset()
            }
        }()

        // 伸懒腰（armsUp pose）
        let stretching = (pose == .armsUp)
        let stretchSX: CGFloat = stretching ? 0.95 : 1.0
        let stretchSY: CGFloat = stretching ? 1.10 : 1.0
        let stretchDY: CGFloat = stretching ? -1.0 : 0.0
        let armRaise:  CGFloat = stretching ? -3.0 : 0.0

        // 走路身体 bob：0%/50% 下沉 +1，25%/75% 抬 0
        let bodyBobY: CGFloat = isWalking
            ? ((walkPhase < 0.25 || (walkPhase >= 0.5 && walkPhase < 0.75)) ? 1 : 0)
            : 0

        // 走路时身体左右微微 sway（±0.4 单位）—— 像企鹅一摇一摆，比原版纯上下 bob 更生动
        let walkSwayX: CGFloat = isWalking
            ? CGFloat(sin(walkPhase * 2 * .pi)) * 0.4
            : 0

        // 走路手臂 ±1.5 摆动（左右反向）—— 比原 ±1 略大，步态更有力
        let armSwingAmount: CGFloat = 1.5
        let armWaveL: CGFloat = isWalking
            ? ((walkPhase < 0.25 || (walkPhase >= 0.5 && walkPhase < 0.75)) ? -armSwingAmount : armSwingAmount)
            : 0
        let armWaveR: CGFloat = -armWaveL

        // 总变换
        let totalSX = breatheSX * stretchSX
        let totalSY = breatheSY * stretchSY
        let totalDY = bodyBobY + stretchDY
        let totalDX = walkSwayX

        // —— 渲染 ——

        // 阴影（不参与 body scale / sway，固定贴地）
        drawRect(Self.shadow, in: ctx, unit: unit,
                 offsetX: 0, offsetY: 0,
                 scaleX: 1, scaleY: 1, fill: shadowFill)

        // 4 条腿（对角交替；不跟 sway —— 保持地面接触感）
        for (idx, leg) in Self.legs.enumerated() {
            let (lx, ly) = legOffset(group: (idx == 0 || idx == 2) ? 0 : 1, phase: walkPhase)
            drawRect(leg, in: ctx, unit: unit,
                     offsetX: lx, offsetY: ly,
                     scaleX: totalSX, scaleY: totalSY, fill: bodyFill)
        }

        // torso（主体）
        drawRect(Self.torso, in: ctx, unit: unit,
                 offsetX: totalDX, offsetY: totalDY,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyFill)
        // torso 顶部 1 行加亮（亮橘高光带，左上光源效果）
        drawRect(ClawdRect(x: Self.torso.x, y: Self.torso.y, w: Self.torso.w, h: 1),
                 in: ctx, unit: unit, offsetX: totalDX, offsetY: totalDY,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyTopShading)
        // torso 底部 1 行压暗（暗橘阴影带，下沉量感）
        drawRect(ClawdRect(x: Self.torso.x, y: Self.torso.y + Self.torso.h - 1, w: Self.torso.w, h: 1),
                 in: ctx, unit: unit, offsetX: totalDX, offsetY: totalDY,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyBottomShading)

        // 手臂（走路摆动 + 伸懒腰上抬 + sway）
        drawRect(Self.leftArm, in: ctx, unit: unit,
                 offsetX: totalDX, offsetY: totalDY + armWaveL + armRaise,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyFill)
        drawRect(Self.rightArm, in: ctx, unit: unit,
                 offsetX: totalDX, offsetY: totalDY + armWaveR + armRaise,
                 scaleX: totalSX, scaleY: totalSY, fill: bodyFill)

        // 眼睛 + 高光（让眼神"活"起来的关键）
        let totalEyeDX = totalDX + eyeLookX
        let totalEyeDY = totalDY + eyeLookY
        if isBlinking {
            // 闭眼：压扁成 0.3 单位横线，无高光
            let centerEyeY = Self.leftEye.y + Self.leftEye.h / 2
            let blinkH: CGFloat = 0.3
            let blinkY = centerEyeY - blinkH / 2
            drawRect(ClawdRect(x: Self.leftEye.x,  y: blinkY, w: 1, h: blinkH),
                     in: ctx, unit: unit, offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: eyeFill)
            drawRect(ClawdRect(x: Self.rightEye.x, y: blinkY, w: 1, h: blinkH),
                     in: ctx, unit: unit, offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: eyeFill)
        } else {
            // 黑眼睛 1×2
            drawRect(Self.leftEye, in: ctx, unit: unit,
                     offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: eyeFill)
            drawRect(Self.rightEye, in: ctx, unit: unit,
                     offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: eyeFill)
            // 白色高光点 0.4×0.4 在眼睛左上角 —— 单一光源效果，眼神立刻有神
            let hlW: CGFloat = 0.4
            let hlH: CGFloat = 0.4
            let hlDX: CGFloat = 0.05
            let hlDY: CGFloat = 0.1
            drawRect(ClawdRect(x: Self.leftEye.x + hlDX, y: Self.leftEye.y + hlDY, w: hlW, h: hlH),
                     in: ctx, unit: unit, offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: highlightFill)
            drawRect(ClawdRect(x: Self.rightEye.x + hlDX, y: Self.rightEye.y + hlDY, w: hlW, h: hlH),
                     in: ctx, unit: unit, offsetX: totalEyeDX, offsetY: totalEyeDY,
                     scaleX: totalSX, scaleY: totalSY, fill: highlightFill)
        }
    }

    /// 读取当前鼠标在带刘海屏上的归一化偏移，转换为眼睛偏移单位
    /// - 返回 X: [-2, 2]（同 lookLeft/lookRight 离散值范围）
    /// - 返回 Y: [-0.5, 0.5]（眼高 2 单位 → 上下各 1/4 偏移，subtle but visible）
    /// NSEvent.mouseLocation 是无锁 class method，从主线程 Canvas draw 调用安全
    nonisolated private static func continuousMouseEyeOffset() -> (CGFloat, CGFloat) {
        let loc = NSEvent.mouseLocation
        // 优先用带刘海屏（Clawd 主要活动区域）
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen, screen.frame.contains(loc) else { return (0, 0) }
        let halfW = screen.frame.width / 2
        let halfH = screen.frame.height / 2
        let nx = max(-1, min(1, (loc.x - screen.frame.midX) / halfW))
        // macOS 坐标 y 是底部为 0，向上为正；眼睛 y 是顶部为 0，向下为正 → 取反
        let ny = max(-1, min(1, (loc.y - screen.frame.midY) / halfH))
        return (CGFloat(nx) * 2.0, CGFloat(-ny) * 0.5)
    }

    /// 还原自官方 walking SVG 的腿位移 keyframe（leg-a / leg-b 对角交替）
    private func legOffset(group: Int, phase: Double) -> (CGFloat, CGFloat) {
        guard isWalking else { return (0, 0) }
        let p = phase
        if group == 0 {  // leg-a (outer-left + inner-right)
            if p < 0.125 { return (-2, 0) }
            if p < 0.375 { return ( 0, 0) }
            if p < 0.625 { return ( 2, 0) }
            if p < 0.875 { return ( 0, -2) }
            return (-2, 0)
        } else {         // leg-b (inner-left + outer-right)
            if p < 0.125 { return ( 2, 0) }
            if p < 0.375 { return ( 0, -2) }
            if p < 0.625 { return (-2, 0) }
            if p < 0.875 { return ( 0, 0) }
            return ( 2, 0)
        }
    }

    /// 以 sprite 中心 (7.5, 5) 为锚点做 scale
    private func drawRect(_ r: ClawdRect, in ctx: GraphicsContext, unit: CGFloat,
                          offsetX: CGFloat, offsetY: CGFloat,
                          scaleX: CGFloat, scaleY: CGFloat,
                          fill: GraphicsContext.Shading) {
        let rx = r.x + offsetX
        let ry = r.y + offsetY
        let screenX = (rx - Self.centerX) * scaleX * unit + Self.centerX * unit
        let screenY = (ry - Self.centerY) * scaleY * unit + Self.centerY * unit
        let screenW = r.w * scaleX * unit
        let screenH = r.h * scaleY * unit
        ctx.fill(Path(CGRect(x: screenX, y: screenY, width: screenW, height: screenH)), with: fill)
    }
}

/// Claude Code 工具类型分类 —— 把所有 tool_use name 映射到一种道具形象
enum ToolKind: Equatable {
    case read, write, bash, search, web, todo, task, thinking, other

    static func from(toolName: String) -> ToolKind {
        switch toolName {
        case "Read":              return .read
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return .write
        case "Bash", "BashOutput", "KillBash", "KillShell": return .bash
        case "Grep", "Glob":      return .search
        case "WebFetch", "WebSearch": return .web
        case "TodoWrite":         return .todo
        case "Task":              return .task
        default:
            // 兜底：按工具名关键字模糊匹配，覆盖 Codex 的 command_execution / file_change 等命名
            let lower = toolName.lowercased()
            if lower.contains("read")                              { return .read }
            if lower.contains("write") || lower.contains("edit")
                || lower.contains("patch") || lower.contains("change") { return .write }
            if lower.contains("shell") || lower.contains("bash")
                || lower.contains("command") || lower.contains("exec") { return .bash }
            if lower.contains("search") || lower.contains("grep")
                || lower.contains("find") || lower.contains("glob")   { return .search }
            if lower.contains("web") || lower.contains("fetch")
                || lower.contains("http") || lower.contains("url")    { return .web }
            return .other
        }
    }

    /// 道具的 SF Symbol
    var iconName: String {
        switch self {
        case .read:     return "magnifyingglass"      // 🔎 放大镜
        case .write:    return "pencil.tip"           // ✏️ 钢笔
        case .bash:     return "wrench.fill"          // 🔧 扳手
        case .search:   return "doc.text.magnifyingglass"
        case .web:      return "globe.americas.fill"
        case .todo:     return "checklist"
        case .task:     return "person.2.fill"
        case .thinking: return "brain"
        case .other:    return "wrench.fill"
        }
    }

    /// 中文动词，用在灵动岛展开文本里
    var verb: String {
        switch self {
        case .read:     return "正在读"
        case .write:    return "正在写"
        case .bash:     return "正在执行"
        case .search:   return "正在搜索"
        case .web:      return "正在浏览"
        case .todo:     return "更新清单"
        case .task:     return "派遣 subagent"
        case .thinking: return "正在思考"
        case .other:    return "正在调用"
        }
    }

    /// 道具的金属/品牌颜色
    var iconColor: LinearGradient {
        switch self {
        case .read, .search:
            return LinearGradient(colors: [Color(white: 0.95), Color(white: 0.65)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .write:
            return LinearGradient(colors: [Color(red: 1.00, green: 0.85, blue: 0.40),
                                           Color(red: 0.90, green: 0.55, blue: 0.15)],
                                  startPoint: .top, endPoint: .bottom)
        case .bash, .other:
            return LinearGradient(colors: [Color(white: 0.95), Color(white: 0.60)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .web:
            return LinearGradient(colors: [Color(red: 0.45, green: 0.85, blue: 0.95),
                                           Color(red: 0.20, green: 0.55, blue: 0.85)],
                                  startPoint: .top, endPoint: .bottom)
        case .todo:
            return LinearGradient(colors: [Color(red: 0.75, green: 0.55, blue: 0.95),
                                           Color(red: 0.55, green: 0.30, blue: 0.85)],
                                  startPoint: .top, endPoint: .bottom)
        case .task:
            return LinearGradient(colors: [Color(red: 1.00, green: 0.60, blue: 0.30),
                                           Color(red: 0.85, green: 0.30, blue: 0.15)],
                                  startPoint: .top, endPoint: .bottom)
        case .thinking:
            return LinearGradient(colors: [Color(red: 0.85, green: 0.70, blue: 0.95),
                                           Color(red: 0.55, green: 0.45, blue: 0.85)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 工作中 Clawd 手里挥舞的小工具 —— 模拟"在干活"
/// 根据 ToolKind 显示对应 SF Symbol，持续摆动旋转
/// 切换 kind 时用 .id() 强制重建 view，让动画从初始角度重启
struct ToolOverlay: View {
    let kind: ToolKind
    @State private var swing: Double = 35

    var body: some View {
        Image(systemName: kind.iconName)
            .font(.system(size: 6.5, weight: .heavy))
            .foregroundStyle(kind.iconColor)
            .shadow(color: .black.opacity(0.4), radius: 0.5, y: 0.5)
            .rotationEffect(.degrees(swing))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                    swing = -25
                }
            }
            .id(kind)   // kind 切换 → view 重建，扳手→放大镜的过渡更自然
    }
}

/// Claude 模式的左耳精灵 —— Clawd 像素小家伙。
///
/// 三套互斥动画 + 优先级 working > celebrate > look：
/// - **idle look**：静态 rest，每 25~50s 随机触发一次左右扫视
///   (rest → lookLeft → rest → lookRight → rest)，模拟"小家伙在打量你"
/// - **working jump**：流式生成时，rest ↔ armsUp 交替跳跃（250/350ms），
///   表达"在干活"
/// - **celebrate**：收到 `HermesPetTaskFinished`(success=true) 通知时，
///   连续 3 次 armsUp 庆祝（200/150ms），跟普通 working 区分开
///
/// 这套 pose 切换本身就是 Clawd 的"生命感"，所以 Claude 模式下外部
/// **不再挂** `LifeSignsModifier`（scaleEffect 会让像素艺术插值变糊）
struct ClaudeKnotSprite: View {
    let isWorking: Bool
    /// 灵动岛传进来的目标高度。Clawd 真实终端比例 1.5:1（不是 3:1），
    /// 这里取 1.15 倍让它比常规图标略大 15% 显眼一点
    let size: CGFloat

    @State private var pose: ClawdPose = .rest
    @State private var workingTask: Task<Void, Never>?
    @State private var celebrateTask: Task<Void, Never>?
    @State private var lookTask: Task<Void, Never>?
    /// 工作时水平方向"跑来跑去"的位移，±4pt 间循环
    @State private var runOffset: CGFloat = 0
    /// 当前工具类型（Read/Write/Bash/...），由 HermesPetToolStarted 通知驱动。
    /// 工作中没有特定工具时显示默认扳手（.other）
    @State private var currentTool: ToolKind = .other
    /// 鼠标在屏幕的相对区域，由 MouseTrackingController 通知驱动。
    /// idle 时 Clawd 的眼睛会跟着这个区域看（左/中/右）—— 让桌宠"活"起来
    @State private var mouseArea: MouseTrackingController.MouseArea = .center

    /// v2 像素更密 + 用户希望 Clawd 显得更大 → 系数从 1.15 拉到 1.4
    /// （配合调用点 size 13→18 一起，整体放大约 50~70%）
    private var clawdHeight: CGFloat { size * 1.4 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // followMouse 只在 idle（非工作、非庆祝）时打开：
            // 工作时 pose 在循环切换工具姿势，庆祝时 armsUp，都不希望被鼠标跟踪覆盖
            ClawdView(pose: pose, height: clawdHeight,
                      followMouse: !isWorking && celebrateTask == nil)

            // 工作时手里挥着工具在右上角；工具种类跟着 Claude tool_use 实时切换
            if isWorking {
                ToolOverlay(kind: currentTool)
                    .offset(x: 3, y: -2)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        // 整体跑来跑去 —— 拿着扳手在左耳区域水平来回小跑
        .offset(x: runOffset)
        .animation(AnimTok.smooth, value: isWorking)   // 扳手出场动画
        .onAppear {
            applyWorkingState(isWorking, animateRest: false)
            updateRunningAnimation(working: isWorking)
        }
        .onChange(of: isWorking) { _, working in
            applyWorkingState(working, animateRest: true)
            updateRunningAnimation(working: working)
            if !working {
                // 工作结束 → 工具重置为默认（下次工作前不会残留上次的工具）
                currentTool = .other
            }
        }
        .onDisappear {
            cancelAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            if success { startCelebrate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolStarted"))) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            let kind = ToolKind.from(toolName: name)
            withAnimation(AnimTok.snappy) {
                currentTool = kind
            }
            // 工具切换 → 重启 jump 用新工具的动画序列（每个工具的姿势节奏不同）
            if isWorking {
                startWorkingJump()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetMouseAreaChanged"))) { note in
            let raw = (note.userInfo?["area"] as? String) ?? "center"
            let newArea = MouseTrackingController.MouseArea(rawValue: raw) ?? .center
            mouseArea = newArea
            // 仅在 idle 状态生效（不被工作 / 庆祝抢占）
            if !isWorking, celebrateTask == nil {
                applyMousePoseIfIdle()
            }
        }
    }

    /// 鼠标驱动 idle 时的 pose
    /// 现在眼睛在 ClawdView 内部做连续跟踪了，这里不再用 mouseArea 强制 lookLeft/Right —
    /// 只保留 rest 时启动"随机偶尔扫视/伸懒腰"循环，让 Clawd 有自己的小动作
    private func applyMousePoseIfIdle() {
        withAnimation(AnimTok.snappy) { pose = .rest }
        startIdleLookCycle()
    }

    /// 工作时水平来回 ±4pt 平移 —— 配合 pose 跳跃 = 拿着扳手跑来跑去
    private func updateRunningAnimation(working: Bool) {
        if working {
            runOffset = -4
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                runOffset = 4
            }
        } else {
            withAnimation(AnimTok.smooth) {
                runOffset = 0
            }
        }
    }

    // MARK: - 状态切换

    private func applyWorkingState(_ working: Bool, animateRest: Bool) {
        if working {
            // 工作开始：取消 idle look，启动 jump
            lookTask?.cancel(); lookTask = nil
            startWorkingJump()
        } else {
            // 工作结束：取消 jump
            workingTask?.cancel(); workingTask = nil
            // celebrate 没在跑就 reset 到 rest（celebrate 会自己控制 pose）
            if celebrateTask == nil, animateRest {
                pose = .rest
            }
            // 让 idle 时优先尊重鼠标位置，鼠标在 center 才走随机扫
            if celebrateTask == nil {
                applyMousePoseIfIdle()
            }
        }
    }

    private func cancelAll() {
        workingTask?.cancel();   workingTask = nil
        celebrateTask?.cancel(); celebrateTask = nil
        lookTask?.cancel();      lookTask = nil
    }

    // MARK: - 动画 Task

    /// 工作中循环 —— 根据 currentTool 走不同的"姿势节奏"：
    /// - Read：lookLeft ↔ lookRight 慢扫（眯眼读书感）
    /// - Write/Edit：armsUp ↔ rest 快速（打字感）
    /// - Bash：armsUp ↔ rest 中速（敲命令感）
    /// - Search：lookLeft ↔ lookRight 快切（探头探脑找东西）
    /// - Web：rest → lookLeft → lookRight → rest 慢扫（环顾世界）
    /// - Task：armsUp 双弹（指挥 subagent）
    /// - Todo / Other：默认 armsUp ↔ rest
    /// currentTool 切换时（onReceive 里）会重启此 task，自动用新工具的节奏
    private func startWorkingJump() {
        workingTask?.cancel()
        let frames = workingFrames(for: currentTool)
        workingTask = Task { @MainActor in
            while !Task.isCancelled {
                for (frame, durationNs) in frames {
                    pose = frame
                    try? await Task.sleep(nanoseconds: durationNs)
                    if Task.isCancelled { return }
                }
            }
        }
    }

    /// 不同工具对应的姿势循环序列：[(姿势, 持续时间 ns)]
    private func workingFrames(for tool: ToolKind) -> [(ClawdPose, UInt64)] {
        switch tool {
        case .read:
            return [
                (.lookLeft,  600_000_000),
                (.rest,      150_000_000),
                (.lookRight, 600_000_000),
                (.rest,      150_000_000),
            ]
        case .write:
            return [
                (.armsUp, 180_000_000),
                (.rest,   200_000_000),
            ]
        case .bash:
            return [
                (.armsUp, 220_000_000),
                (.rest,   320_000_000),
            ]
        case .search:
            return [
                (.lookLeft,  240_000_000),
                (.lookRight, 240_000_000),
            ]
        case .web:
            return [
                (.rest,      350_000_000),
                (.lookLeft,  500_000_000),
                (.lookRight, 500_000_000),
            ]
        case .task:
            return [
                (.armsUp, 200_000_000),
                (.rest,   100_000_000),
                (.armsUp, 200_000_000),
                (.rest,   500_000_000),
            ]
        case .todo, .other, .thinking:
            return [
                (.armsUp, 250_000_000),
                (.rest,   350_000_000),
            ]
        }
    }

    /// 任务成功结束：连续 3 次开心举手
    private func startCelebrate() {
        // celebrate 优先级最高，抢占其他动画
        workingTask?.cancel(); workingTask = nil
        lookTask?.cancel();    lookTask = nil
        celebrateTask?.cancel()
        celebrateTask = Task { @MainActor in
            for i in 0..<3 {
                pose = .armsUp
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { celebrateTask = nil; return }
                pose = .rest
                if i < 2 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { celebrateTask = nil; return }
                }
            }
            celebrateTask = nil
            // 庆祝完，回到 idle look 循环（如果不在工作中）
            if !isWorking {
                startIdleLookCycle()
            }
        }
    }

    /// idle 时周期触发"左右看 / 偶尔伸懒腰"，让 Clawd 像个活物在打量周围
    /// - 70% → 左右扫视（看左 + 看右）
    /// - 20% → 伸懒腰（armsUp 0.6s）
    /// - 10% → 单侧扫视（只看一边）
    private func startIdleLookCycle() {
        lookTask?.cancel()
        lookTask = Task { @MainActor in
            while !Task.isCancelled {
                // 等 22~42s 随机（比之前略短，让动作更密一点）
                let delayNs = UInt64.random(in: 22_000_000_000...42_000_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                if Task.isCancelled || isWorking { return }

                let roll = Int.random(in: 0..<10)

                if roll < 2 {
                    // 伸懒腰：举手 0.6s → 放下
                    pose = .armsUp
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = .rest
                } else {
                    let bothSides = roll < 9
                    let leftFirst = Bool.random()
                    let firstSide: ClawdPose  = leftFirst ? .lookLeft  : .lookRight
                    let secondSide: ClawdPose = leftFirst ? .lookRight : .lookLeft

                    pose = firstSide
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = .rest

                    guard bothSides else { continue }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = secondSide
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = .rest
                }
            }
        }
    }
}

// MARK: - Hermes：绿色羽毛（左右轻摆，工作时摆得更大）

struct HermesFeatherSprite: View {
    let isWorking: Bool
    let size: CGFloat

    @State private var animating = false
    /// 庆祝时旋转一周（0 → 360°），由 HermesPetTaskFinished(success=true) 触发
    @State private var celebrateRotation: Double = 0
    @State private var celebrateScale: CGFloat = 1.0
    @State private var celebrateGlow: Double = 0
    @State private var celebrateTask: Task<Void, Never>?

    private static let featherGradient = LinearGradient(
        colors: [
            Color(red: 0.42, green: 0.86, blue: 0.52),
            Color(red: 0.22, green: 0.68, blue: 0.40)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        ZStack {
            // 庆祝光晕：成功后从中心扩散的绿色淡圈
            Circle()
                .stroke(Color(red: 0.42, green: 0.86, blue: 0.52), lineWidth: 1.5)
                .frame(width: size + 4, height: size + 4)
                .scaleEffect(1.0 + celebrateGlow * 1.5)
                .opacity(celebrateGlow > 0 ? (1 - celebrateGlow) * 0.8 : 0)
                .blur(radius: 0.6)

            // feather SF Symbol 是 iOS 17+，旧系统兜底用 leaf.fill
            Image(systemName: "leaf.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Self.featherGradient)
                .rotationEffect(.degrees(animating ? (isWorking ? 12 : 4) : -(isWorking ? 12 : 4)))
                .animation(
                    .easeInOut(duration: isWorking ? 1.2 : 3.0).repeatForever(autoreverses: true),
                    value: animating
                )
                .rotationEffect(.degrees(celebrateRotation))   // 庆祝时叠加 360° 旋转
                .scaleEffect(celebrateScale)
        }
        .onAppear {
            animating = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            if success { startCelebrate() }
        }
        .onDisappear {
            celebrateTask?.cancel()
        }
    }

    /// 任务成功结束：羽毛转一圈 + 弹跳 + 绿色光圈扩散
    private func startCelebrate() {
        celebrateTask?.cancel()
        celebrateTask = Task { @MainActor in
            // 起势：scale 弹起 + 旋转启动 + 光圈出现
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                celebrateScale = 1.25
            }
            withAnimation(.easeOut(duration: 0.55)) {
                celebrateRotation += 360
                celebrateGlow = 1.0
            }
            try? await Task.sleep(nanoseconds: 320_000_000)
            if Task.isCancelled { return }
            // 收势：scale 回到 1.0
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                celebrateScale = 1.0
            }
            // 等光圈淡完
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            celebrateGlow = 0   // reset，下次再触发能从 0 开始
        }
    }
}

// MARK: - Codex：青色 `</>` + 闪烁光标

struct CodexCursorSprite: View {
    let isWorking: Bool
    let size: CGFloat

    @State private var cursorVisible = true
    /// 庆祝时整体 scale 弹跳
    @State private var celebrateScale: CGFloat = 1.0
    /// 庆祝光晕的 0 → 1 推进值（用于扩散圆环）
    @State private var celebrateGlow: Double = 0
    /// 庆祝时光标超速闪烁（≥1 时切到 0.08s 频率）
    @State private var celebrateBlinkBurst: Int = 0
    @State private var celebrateTask: Task<Void, Never>?

    private static let codeGradient = LinearGradient(
        colors: [
            Color(red: 0.35, green: 0.86, blue: 0.95),
            Color(red: 0.18, green: 0.62, blue: 0.88)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        ZStack {
            // 庆祝光晕：青色圆圈从中心扩散
            Circle()
                .stroke(Color.cyan, lineWidth: 1.5)
                .frame(width: size + 4, height: size + 4)
                .scaleEffect(1.0 + celebrateGlow * 1.5)
                .opacity(celebrateGlow > 0 ? (1 - celebrateGlow) * 0.8 : 0)
                .blur(radius: 0.6)

            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.95, weight: .heavy))
                .foregroundStyle(Self.codeGradient)

            if isWorking || celebrateBlinkBurst > 0 {
                // 工作中（或庆祝时）：右侧叠一个闪烁的细竖线作为"光标"
                Rectangle()
                    .fill(Color.cyan)
                    .frame(width: 1.2, height: size * 0.72)
                    .offset(x: size * 0.62)
                    .opacity(cursorVisible ? 1.0 : 0.0)
                    .onAppear {
                        cursorVisible = true
                        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                            cursorVisible = false
                        }
                    }
            }
        }
        .scaleEffect(celebrateScale)
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            if success { startCelebrate() }
        }
        .onDisappear {
            celebrateTask?.cancel()
        }
    }

    /// 任务成功结束：scale 弹跳 + 光标超速闪烁 + 青色光圈扩散
    private func startCelebrate() {
        celebrateTask?.cancel()
        celebrateTask = Task { @MainActor in
            // 起势
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                celebrateScale = 1.22
            }
            withAnimation(.easeOut(duration: 0.55)) {
                celebrateGlow = 1.0
            }
            celebrateBlinkBurst = 1   // 让光标出现（即使非 working 状态）
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            // 收势
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                celebrateScale = 1.0
            }
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            celebrateGlow = 0
            celebrateBlinkBurst = 0
        }
    }
}
// MARK: - DirectAPI：云朵精灵（indigo 像素小云，有眼睛 + 呼吸 + 飘浮）

/// 在线 AI 的灵动岛精灵 —— 跟 ClaudeKnotSprite 类似的 pose 驱动 + 工具动画
struct CloudPetIslandSprite: View {
    let isWorking: Bool
    let size: CGFloat

    @State private var pose: ClawdPose = .rest
    @State private var workingTask: Task<Void, Never>?
    @State private var lookTask: Task<Void, Never>?
    @State private var currentTool: ToolKind = .other
    /// 戴眼镜动画进度（0~1）。监听 HermesPetCloudPetWearGlasses 通知触发
    @State private var glassesProgress: Double = 0
    @State private var glassesHideTask: Task<Void, Never>?

    private var cloudHeight: CGFloat { size * 1.3 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CloudPetView(pose: pose, height: cloudHeight, isWalking: false,
                         glassesProgress: glassesProgress)
            if isWorking {
                ToolOverlay(kind: currentTool)
                    .offset(x: 3, y: -2)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(AnimTok.smooth, value: isWorking)
        .onAppear { applyState(isWorking) }
        .onChange(of: isWorking) { _, w in applyState(w) }
        .onDisappear { workingTask?.cancel(); lookTask?.cancel(); glassesHideTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolStarted"))) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            withAnimation(AnimTok.snappy) { currentTool = ToolKind.from(toolName: name) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetCloudPetWearGlasses"))) { note in
            // OpenCodeHTTPClient 自动切到 vision model 时 post 此通知。
            // 默认保持 6 秒（一个 vision 请求够长，再短就刚戴上就摘了）
            let duration = (note.userInfo?["duration"] as? Double) ?? 6.0
            triggerGlasses(duration: duration)
        }
    }

    /// 戴上眼镜 → 保持 duration 秒 → 取下
    /// **关键**：用 Task 手动每帧驱动 @State，**不能用 withAnimation**
    /// 原因：CloudPetView 内 Canvas 是 immediate-mode 自绘，SwiftUI 不会自动给 Canvas
    /// 插值动画进度参数。withAnimation 只会改最终值，Canvas 看到的是 0 → 突然 1
    private func triggerGlasses(duration: Double) {
        glassesHideTask?.cancel()
        glassesHideTask = Task { @MainActor in
            // 戴上动画：0 → 1，约 1.4s（用户要求看清"掏眼镜→戴上"的整个过程），easeOutBack 略弹
            let onFrames = 84   // 60fps × 1.4s
            for i in 1...onFrames {
                if Task.isCancelled { return }
                let t = Double(i) / Double(onFrames)
                glassesProgress = easeOutBack(t)
                try? await Task.sleep(nanoseconds: 16_666_666)
            }
            glassesProgress = 1
            // 保持戴着
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            // 摘下动画：1 → 0，0.6s ease-in 慢慢消失
            let offFrames = 36
            for i in 1...offFrames {
                if Task.isCancelled { return }
                let t = 1 - Double(i) / Double(offFrames)
                glassesProgress = t * t   // ease-in
                try? await Task.sleep(nanoseconds: 16_666_666)
            }
            glassesProgress = 0
        }
    }

    /// EaseOutBack 缓动 —— 在 1.0 附近会略微超过再回落，模拟「啪嗒戴上」的弹性
    private func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        let x = t - 1
        return 1 + c3 * x * x * x + c1 * x * x
    }

    private func applyState(_ working: Bool) {
        if working {
            lookTask?.cancel(); lookTask = nil
            startWorking()
        } else {
            workingTask?.cancel(); workingTask = nil
            pose = .rest
            startIdleLook()
        }
    }

    private func startWorking() {
        workingTask?.cancel()
        workingTask = Task { @MainActor in
            while !Task.isCancelled {
                pose = .armsUp
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                pose = .rest
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    private func startIdleLook() {
        lookTask?.cancel()
        lookTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 20_000_000_000...40_000_000_000))
                if Task.isCancelled { return }
                pose = Bool.random() ? .lookLeft : .lookRight
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                pose = .rest
            }
        }
    }
}

/// 云朵精灵像素渲染器 —— viewBox 14×10 的 indigo 小云，带两只眼睛。
/// 动画：呼吸（上下浮动 ±1pt）+ 眨眼 + 走路时左右摇摆
struct CloudPetView: View {
    let pose: ClawdPose
    let height: CGFloat
    var isWalking: Bool = false
    /// 戴眼镜动画进度：0 = 不戴 / 隐藏在身后；1 = 完全戴在脸上。
    /// 外层用 withAnimation 改这个值，draw 内按 progress 单参数计算 alpha / offset / scale。
    /// 0→1 的过渡视觉上是「从身后掏出 → 飞到脸上戴好」
    var glassesProgress: Double = 0

    private static let bodyColor = Color(red: 0.45, green: 0.40, blue: 0.85)
    private static let bodyTopColor = Color(red: 0.58, green: 0.52, blue: 0.95)
    private static let bodyBottomColor = Color(red: 0.35, green: 0.30, blue: 0.72)
    private static let viewBoxW: CGFloat = 14
    private static let viewBoxH: CGFloat = 10
    private static let centerX: CGFloat = 7
    private static let centerY: CGFloat = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: height * Self.viewBoxW / Self.viewBoxH, height: height)
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        let unit = min(size.width / Self.viewBoxW, size.height / Self.viewBoxH)
        let bodyFill = GraphicsContext.Shading.color(Self.bodyColor)
        let topFill = GraphicsContext.Shading.color(Self.bodyTopColor)
        let bottomFill = GraphicsContext.Shading.color(Self.bodyBottomColor)
        let eyeFill = GraphicsContext.Shading.color(.white)
        let pupilFill = GraphicsContext.Shading.color(.black)
        let shadowFill = GraphicsContext.Shading.color(.black.opacity(0.3))

        // 呼吸：上下浮动
        let breatheT = sin(now * 2 * .pi / 3.5)
        let floatY: CGFloat = CGFloat(breatheT) * 0.4

        // 走路摇摆
        let swayX: CGFloat = isWalking ? CGFloat(sin(now * 2 * .pi / 0.8)) * 0.3 : 0

        // 眨眼
        let blinkCycle = 5.0
        let blinkPhase = now.truncatingRemainder(dividingBy: blinkCycle) / blinkCycle
        let isBlinking = blinkPhase > 0.96

        // 眼神偏移
        let eyeLookX: CGFloat = {
            switch pose {
            case .lookLeft: return -1.5
            case .lookRight: return 1.5
            case .armsUp, .rest: return 0
            }
        }()

        let dy = floatY
        let dx = swayX

        // 阴影（椭圆，固定在底部）
        let shadowRect = CGRect(
            x: (3) * unit, y: 9 * unit,
            width: 8 * unit, height: 1 * unit
        )
        ctx.fill(Path(ellipseIn: shadowRect), with: shadowFill)

        // 云朵主体：圆润的形状用多个重叠矩形模拟
        // 底部宽体 (x:2, y:4, w:10, h:4)
        fillRect(x: 2 + dx, y: 4 + dy, w: 10, h: 4, ctx: ctx, unit: unit, fill: bodyFill)
        // 顶部凸起 (x:3, y:2, w:8, h:3)
        fillRect(x: 3 + dx, y: 2 + dy, w: 8, h: 3, ctx: ctx, unit: unit, fill: bodyFill)
        // 左凸 (x:1, y:5, w:2, h:2)
        fillRect(x: 1 + dx, y: 5 + dy, w: 2, h: 2, ctx: ctx, unit: unit, fill: bodyFill)
        // 右凸 (x:11, y: 5, w:2, h:2)
        fillRect(x: 11 + dx, y: 5 + dy, w: 2, h: 2, ctx: ctx, unit: unit, fill: bodyFill)
        // 顶部高光
        fillRect(x: 4 + dx, y: 2 + dy, w: 6, h: 1, ctx: ctx, unit: unit, fill: topFill)
        // 底部阴影
        fillRect(x: 3 + dx, y: 7 + dy, w: 8, h: 1, ctx: ctx, unit: unit, fill: bottomFill)

        // 小脚（走路时交替抬放）
        let walkPhase = isWalking ? now.truncatingRemainder(dividingBy: 0.8) / 0.8 : 0
        let leftFootDY: CGFloat = isWalking ? (walkPhase < 0.5 ? -0.5 : 0) : 0
        let rightFootDY: CGFloat = isWalking ? (walkPhase >= 0.5 ? -0.5 : 0) : 0
        fillRect(x: 4 + dx, y: 8 + dy + leftFootDY, w: 2, h: 1, ctx: ctx, unit: unit, fill: bodyFill)
        fillRect(x: 8 + dx, y: 8 + dy + rightFootDY, w: 2, h: 1, ctx: ctx, unit: unit, fill: bodyFill)

        // 眼睛
        let eyeY: CGFloat = 4 + dy
        let leftEyeX: CGFloat = 4.5 + dx + eyeLookX * 0.3
        let rightEyeX: CGFloat = 8.5 + dx + eyeLookX * 0.3

        if isBlinking {
            // 闭眼：横线
            fillRect(x: leftEyeX, y: eyeY + 0.7, w: 1.5, h: 0.3, ctx: ctx, unit: unit, fill: pupilFill)
            fillRect(x: rightEyeX, y: eyeY + 0.7, w: 1.5, h: 0.3, ctx: ctx, unit: unit, fill: pupilFill)
        } else {
            // 白色眼白
            fillRect(x: leftEyeX, y: eyeY, w: 1.8, h: 1.8, ctx: ctx, unit: unit, fill: eyeFill)
            fillRect(x: rightEyeX, y: eyeY, w: 1.8, h: 1.8, ctx: ctx, unit: unit, fill: eyeFill)
            // 黑色瞳孔
            let pupilDX = eyeLookX * 0.15
            fillRect(x: leftEyeX + 0.5 + pupilDX, y: eyeY + 0.5, w: 1.0, h: 1.0, ctx: ctx, unit: unit, fill: pupilFill)
            fillRect(x: rightEyeX + 0.5 + pupilDX, y: eyeY + 0.5, w: 1.0, h: 1.0, ctx: ctx, unit: unit, fill: pupilFill)
        }

        // armsUp 时顶部多一个小凸起（像伸手）
        if pose == .armsUp {
            fillRect(x: 5 + dx, y: 1 + dy, w: 4, h: 1.5, ctx: ctx, unit: unit, fill: topFill)
        }

        // 眼镜（vision 模式自动切换时戴上）—— 必须最后画，盖在眼睛上层
        drawGlasses(ctx: ctx, unit: unit, dx: dx, dy: dy, eyeY: eyeY, progress: glassesProgress)
    }

    /// 戴眼镜动画。progress 0→1 视觉上：
    /// - 0.0~0.15：藏在云朵右上方（offset x:+3.5, y:+1.5, alpha 0, scale 0.45）
    /// - 0.15~0.6：飞向脸（alpha 渐显，scale 渐大，offset 缩小）
    /// - 0.6~1.0：稳稳戴在眼睛上（offset 0, scale 1.0, alpha 1）
    private func drawGlasses(ctx: GraphicsContext, unit: CGFloat,
                             dx: CGFloat, dy: CGFloat, eyeY: CGFloat,
                             progress: Double) {
        guard progress > 0.02 else { return }
        let p = CGFloat(progress)
        let alpha = min(1, p * 3.5)             // 前 30% 就完全可见，让"飞行"过程也看得清
        let xOff = (1 - p) * 3.5                // 从右后方滑入（不要太远，避免飞出 viewBox）
        let yOff = (1 - p) * 1.5                // 微微从下方上浮
        let scale = 0.45 + p * 0.55             // 起始更大让看得清，到 1.0

        // 关键修正：cx 用眼睛中心 (4.5 + 8.5)/2 = 6.5（眼睛 1.8 宽，中心 5.4 / 9.4 → 整体中心 7.4）
        // 偏 7.4 而不是 7（云朵主体几何中心），让眼镜对齐眼睛
        let cx = 7.4 + dx + xOff
        let cy = eyeY + 0.9 + yOff

        // 镜框用深紫色（跟云朵主色系协调，不突兀的黑色），加粗到 1.5pt+ 让肉眼能清楚看见
        let frameColor = Color(red: 0.15, green: 0.10, blue: 0.30).opacity(Double(alpha))
        let lensColor = Color(red: 0.55, green: 0.80, blue: 1.0).opacity(Double(alpha) * 0.55)
        let frameFill = GraphicsContext.Shading.color(frameColor)
        let lensFill = GraphicsContext.Shading.color(lensColor)
        let lineW = max(1.5, scale * 2.0)        // 至少 1.5pt 粗，scale 大时更粗

        // 左镜片：宽 2.2（cover 眼睛 1.8 + padding），高 2.0，圆角 0.55
        let leftLens = CGRect(
            x: (cx - 2.0 - 1.1 * scale) * unit,
            y: (cy - 1.0 * scale) * unit,
            width: 2.2 * scale * unit,
            height: 2.0 * scale * unit
        )
        let leftPath = Path(roundedRect: leftLens, cornerRadius: 0.55 * scale * unit)
        ctx.fill(leftPath, with: lensFill)
        ctx.stroke(leftPath, with: frameFill, lineWidth: lineW)

        // 右镜片：右眼中心相对 cx 偏右 +2.0
        let rightLens = CGRect(
            x: (cx + 2.0 - 1.1 * scale) * unit,
            y: (cy - 1.0 * scale) * unit,
            width: 2.2 * scale * unit,
            height: 2.0 * scale * unit
        )
        let rightPath = Path(roundedRect: rightLens, cornerRadius: 0.55 * scale * unit)
        ctx.fill(rightPath, with: lensFill)
        ctx.stroke(rightPath, with: frameFill, lineWidth: lineW)

        // 中间桥梁（连接两镜片）—— 一根横向粗线
        let bridge = CGRect(
            x: (cx - 0.5 * scale) * unit,
            y: (cy - 0.15 * scale) * unit,
            width: 1.0 * scale * unit,
            height: 0.35 * scale * unit
        )
        ctx.fill(Path(bridge), with: frameFill)
    }

    private func fillRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                          ctx: GraphicsContext, unit: CGFloat,
                          fill: GraphicsContext.Shading) {
        ctx.fill(Path(CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)), with: fill)
    }
}


