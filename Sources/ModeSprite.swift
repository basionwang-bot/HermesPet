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
    /// 是否启用内部 sprite 的 TimelineView 重绘。
    /// 默认读 `quietMode` UserDefaults —— 用户在设置里关「桌宠动效」时全局静音。
    /// 调用方可显式覆盖（如 mini sprite 传 `isHovering` 让 hover 才动）
    var animated: Bool? = nil

    /// 全局调色板存储 —— @Observable，用户改色后此 View 自动 invalidate 重渲染
    @State private var paletteStore = PetPaletteStore.shared
    /// 全局「桌宠动效」开关。reverse 语义：quietMode=true 表示用户**关**了动效
    @AppStorage("quietMode") private var quietMode: Bool = false

    /// 最终 animated 值：显式传 → 用显式；否则按 quietMode 倒推
    private var effectiveAnimated: Bool { animated ?? !quietMode }

    var body: some View {
        let palette = paletteStore.palette(for: mode)
        let anim = effectiveAnimated
        switch mode {
        case .claudeCode:
            // Clawd 是 3:1 宽矮比例的像素精灵，让它用自己的 aspect ratio，不强行套正方形
            ClaudeKnotSprite(isWorking: isWorking, size: size, palette: palette, animated: anim)
        case .hermes:
            HermesHorseSprite(isWorking: isWorking, size: size, palette: palette, animated: anim)
                .frame(width: size + 4, height: size + 4)
        case .directAPI:
            // 在线 AI 跑 opencode agent runtime，视觉用云朵小精灵区别于 Hermes 羽毛
            CloudPetIslandSprite(isWorking: isWorking, size: size, palette: palette, animated: anim)
                .frame(width: size + 4, height: size + 4)
        case .openclaw:
            // PR-B：fomo 九尾狐专属 sprite（银白 / 异色瞳 / 大狐耳 + 蓬松尾巴）
            FomoIslandSprite(isWorking: isWorking, size: size, palette: palette, animated: anim)
                .frame(width: size + 4, height: size + 4)
        case .codex:
            CodexTerminalSprite(isWorking: isWorking, size: size, palette: palette, animated: anim)
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
    /// 调色板 —— 主色 + 派生高光/阴影。默认 Anthropic 官方橙；用户调色后从 PaletteStore 传入
    var palette: PetPalette = .clawdDefault
    /// 是否启用 TimelineView 30fps 重绘。
    /// `false` 时画**一张静态帧**（now=0 → 呼吸/眨眼/走路相位都归零、不读鼠标位置）。
    /// 用户在设置里关「桌宠动效」、或 mini sprite 未 hover 时传 false 以省 CPU。
    var animated: Bool = true

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
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                // 静态帧：now=0 让所有动画相位归零；followMouse 在 draw 里被 `animated` AND 掉
                Canvas(rendersAsynchronously: false) { ctx, size in
                    draw(ctx: ctx, size: size, now: 0)
                }
            }
        }
        .frame(width: height * Self.viewBoxW / Self.viewBoxH, height: height)
    }

    // MARK: - 绘制

    private func draw(ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        let unit = min(size.width / Self.viewBoxW, size.height / Self.viewBoxH)
        let bodyFill = GraphicsContext.Shading.color(palette.primary)
        // body 顶部高光（自动从主色 +12% brightness 派生）：模拟左上光源，让 sprite 立体
        let bodyTopShading = GraphicsContext.Shading.color(palette.derivedTop)
        // body 底部阴影（自动从主色 -15% brightness 派生）：增加体积感
        let bodyBottomShading = GraphicsContext.Shading.color(palette.derivedBottom)
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
                // animated=false 时不读鼠标 —— 静态帧时眼睛回到中央
                guard followMouse, animated else { return (0, 0) }
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
    /// 调色板 —— 默认 Anthropic 官方橙，用户自定义后由调用方传入
    var palette: PetPalette = .clawdDefault
    /// 是否启用内部 ClawdView 的 30fps 动画。false 时 Clawd 画静态帧
    var animated: Bool = true

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
                      followMouse: !isWorking && celebrateTask == nil,
                      palette: palette,
                      animated: animated)

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

// MARK: - Hermes：金黄像素小马 🐴（致敬希腊神话信使飞马 Pegasus）

/// Hermes mode 的左耳精灵 —— 金黄像素小马
///
/// 三套互斥动画 + 优先级 working > celebrate > idle look：
/// - **idle look**：rest 状态周期性扫视 + 偶尔抬头嘶鸣（armsUp）
/// - **working**：根据 currentTool（Read/Write/Bash/Search/Web/Task）走不同节奏
/// - **celebrate**：成功时连续 3 次抬头跳跃
///
/// CloudPetIslandSprite / ClaudeKnotSprite 的同类设计。HorseView 内部已经
/// 用 TimelineView Canvas 处理走路 / 鬃毛 / 尾巴 / 呼吸 / 眨眼，所以外部 LifeSignsModifier
/// 不再叠加（pixel art 用 scaleEffect 会插值变糊）
struct HermesHorseSprite: View {
    let isWorking: Bool
    let size: CGFloat
    /// 调色板 —— 默认金黄，用户自定义后由调用方传入
    var palette: PetPalette = .horseDefault
    /// 是否启用内部 HorseView 的 30fps 动画。false 时画静态帧
    var animated: Bool = true

    @State private var pose: ClawdPose = .rest
    @State private var workingTask: Task<Void, Never>?
    @State private var celebrateTask: Task<Void, Never>?
    @State private var lookTask: Task<Void, Never>?
    @State private var currentTool: ToolKind = .other

    /// 小马 viewBox 14:10，size 是图标常规高度。× 1.4 让它跟 Clawd 视觉重量接近
    private var horseHeight: CGFloat { size * 1.4 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HorseView(pose: pose, height: horseHeight, isWalking: false, palette: palette, animated: animated)
            if isWorking {
                ToolOverlay(kind: currentTool)
                    .offset(x: 3, y: -2)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(AnimTok.smooth, value: isWorking)
        .onAppear { applyState(isWorking) }
        .onChange(of: isWorking) { _, w in
            applyState(w)
            if !w { currentTool = .other }
        }
        .onDisappear {
            workingTask?.cancel()
            celebrateTask?.cancel()
            lookTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            if success { startCelebrate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolStarted"))) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            withAnimation(AnimTok.snappy) {
                currentTool = ToolKind.from(toolName: name)
            }
            if isWorking { startWorking() }
        }
    }

    private func applyState(_ working: Bool) {
        if working {
            lookTask?.cancel(); lookTask = nil
            startWorking()
        } else {
            workingTask?.cancel(); workingTask = nil
            if celebrateTask == nil {
                pose = .rest
                startIdleLook()
            }
        }
    }

    /// 工作中循环 —— 根据 currentTool 走不同的"姿势节奏"
    private func startWorking() {
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

    /// 工具姿势映射 —— armsUp 在 HorseView 里 = 仰头嘶鸣
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
                (.armsUp, 200_000_000),
                (.rest,   220_000_000),
            ]
        case .bash:
            return [
                (.armsUp, 250_000_000),
                (.rest,   300_000_000),
            ]
        case .search:
            return [
                (.lookLeft,  260_000_000),
                (.lookRight, 260_000_000),
            ]
        case .web:
            return [
                (.rest,      350_000_000),
                (.lookLeft,  500_000_000),
                (.lookRight, 500_000_000),
            ]
        case .task:
            return [
                (.armsUp, 220_000_000),
                (.rest,   100_000_000),
                (.armsUp, 220_000_000),
                (.rest,   500_000_000),
            ]
        case .todo, .other, .thinking:
            return [
                (.armsUp, 280_000_000),
                (.rest,   360_000_000),
            ]
        }
    }

    /// 任务成功结束：连续 3 次抬头嘶鸣
    private func startCelebrate() {
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
            if !isWorking { startIdleLook() }
        }
    }

    /// idle 时周期触发"扫视 / 抬头嘶鸣"
    private func startIdleLook() {
        lookTask?.cancel()
        lookTask = Task { @MainActor in
            while !Task.isCancelled {
                let delayNs = UInt64.random(in: 22_000_000_000...42_000_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                if Task.isCancelled || isWorking { return }

                let roll = Int.random(in: 0..<10)
                if roll < 2 {
                    // 抬头嘶鸣 0.6s
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

/// 金黄像素小马渲染器 —— viewBox 14×10
///
/// 像素图（侧视，朝右）：
/// ```
///        0  1  2  3  4  5  6  7  8  9 10 11 12 13
/// row 0:                                  ▒▒▒▒        ← 耳朵（两只）
/// row 1:                                ███████        ← 鬃毛顶 + 耳前
/// row 2:                          ▒▒▒▒█████ ▣ ████    ← 鬃毛 + 头 + 眼睛
/// row 3:                       ▒▒▒▒██████████████     ← 鬃毛 + 颈 + 头下
/// row 4:        ▒██████████████████████████████        ← 尾根 + 躯干顶
/// row 5:     ▒▒▒██████████████████████████████        ← 尾巴 + 躯干
/// row 6:     ▒▒▒██████████████████████████████        ← 尾巴 + 躯干底
/// row 7:           ██   ██   ██   ██                   ← 4 蹄（trot 步态）
/// row 8:           ██   ██   ██   ██                   ← 蹄底深棕
/// row 9:          ░░░░░░░░░░░░░░░░░░░                  ← 阴影
/// ```
///
/// 动画（TimelineView 30fps 自驱）：
/// 1. **呼吸** 3.2s loop ±2% 横纵反向
/// 2. **眨眼** 5s 间隔，最后 200ms 闭眼
/// 3. **走路 trot** 0.8s/loop：4 条腿对角抬放 + 身体轻微 bob
/// 4. **鬃毛 / 尾巴飘动**：走路时频率高、幅度大；idle 时微飘
/// 5. **抬头** armsUp pose：头 + 颈 + 耳朵 + 鬃毛上移 -1.2pt（仰头嘶鸣）
/// 6. **眼神** lookLeft/Right：眼睛在头内偏移 ±0.5pt
struct HorseView: View {
    let pose: ClawdPose
    /// 精灵高度。最终 frame 宽 = height × 1.4（viewBox 14:10）
    let height: CGFloat
    /// 是否在走路 —— 控制 trot 步态 + 鬃毛/尾巴飘动幅度
    var isWalking: Bool = false
    /// 调色板 —— 主色 + 派生高光/阴影；鬃毛 / 翅膀 / 蹄子 保持默认（保留小马辨识度）
    var palette: PetPalette = .horseDefault
    /// 是否启用 TimelineView 30fps 重绘。false 时画静态帧（now=0 相位归零）
    var animated: Bool = true

    // 默认色（palette 不变时跟原版完全一致）—— 鬃毛 / 翅膀 / 蹄子 不参与调色保留视觉特征
    private static let maneColor       = Color(red: 217.0/255, green: 178.0/255, blue: 102.0/255)  // #D9B266 深 amber 金
    private static let hoofColor       = Color(red: 91.0/255,  green: 58.0/255,  blue: 31.0/255)   // #5B3A1F 蹄子深棕
    private static let wingColor       = Color(red: 255.0/255, green: 250.0/255, blue: 229.0/255)  // #FFFAE5 奶油白
    private static let wingShadowColor = Color(red: 230.0/255, green: 215.0/255, blue: 170.0/255)  // #E6D7AA 翼根阴影 / 羽缝

    private static let viewBoxW: CGFloat = 14
    private static let viewBoxH: CGFloat = 10
    private static let centerX: CGFloat = 7
    private static let centerY: CGFloat = 5

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    draw(ctx: ctx, size: size, now: 0)
                }
            }
        }
        .frame(width: height * Self.viewBoxW / Self.viewBoxH, height: height)
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        let unit = min(size.width / Self.viewBoxW, size.height / Self.viewBoxH)
        // 主色 + 派生（用户调色后自动跟着变）
        let bodyFill       = GraphicsContext.Shading.color(palette.primary)
        let bodyTopFill    = GraphicsContext.Shading.color(palette.derivedTop)
        let bodyBottomFill = GraphicsContext.Shading.color(palette.derivedBottom)
        // 鬃毛 / 翅膀 / 蹄子保持默认（不参与调色，保留小马视觉特征）
        let maneFill       = GraphicsContext.Shading.color(Self.maneColor)
        let hoofFill       = GraphicsContext.Shading.color(Self.hoofColor)
        let wingFill       = GraphicsContext.Shading.color(Self.wingColor)
        let wingShadowFill = GraphicsContext.Shading.color(Self.wingShadowColor)
        let eyeFill        = GraphicsContext.Shading.color(.black)
        let highlightFill  = GraphicsContext.Shading.color(.white)
        let shadowFill     = GraphicsContext.Shading.color(.black.opacity(0.4))

        // —— 动画参数 ——

        // 呼吸 3.2s loop ±2%（同 Clawd）
        let breatheT = sin(now * 2 * .pi / 3.2)
        let breatheSX: CGFloat = 1 + CGFloat(breatheT) * 0.02
        let breatheSY: CGFloat = 1 - CGFloat(breatheT) * 0.02

        // 走路 phase 0~1（0.8s/loop —— trot 比 Clawd 螃蟹走得稍快，马步节奏）
        let walkPhase = isWalking ? (now / 0.8).truncatingRemainder(dividingBy: 1.0) : 0

        // 眨眼 5s 间隔，最后 4% 闭眼（≈200ms）
        let blinkPhase = (now / 5.0).truncatingRemainder(dividingBy: 1.0)
        let isBlinking = blinkPhase > 0.96

        // 抬头嘶鸣（armsUp pose）：头 / 颈 / 鬃毛 / 耳朵整体上移
        let headRaise: CGFloat = (pose == .armsUp) ? -1.2 : 0

        // 眼神偏移
        let eyeShiftX: CGFloat = {
            switch pose {
            case .lookLeft:  return -0.4
            case .lookRight: return  0.4
            case .armsUp, .rest: return 0
            }
        }()

        // 走路时身体上下 bob ±0.3pt
        let bodyBob: CGFloat = isWalking ? CGFloat(sin(walkPhase * 2 * .pi * 2)) * 0.3 : 0

        // 鬃毛 / 尾巴飘动 —— 走路时频率高幅度大；idle 时由时间慢驱
        // v2 调整：飘动幅度加大（idle 0.15 → 0.22，walking 0.4 → 0.55），让鬃毛真正"飞起来"
        let maneFreq = isWalking ? walkPhase * 2 * .pi * 2 : now * 1.2
        let maneFloat: CGFloat = CGFloat(sin(maneFreq)) * (isWalking ? 0.55 : 0.22)
        // 鬃毛末梢相位略落后 → 看起来像波浪一节一节传递
        let maneFloatLag: CGFloat = CGFloat(sin(maneFreq - 0.6)) * (isWalking ? 0.7 : 0.3)
        let tailWaveX: CGFloat = CGFloat(sin(maneFreq * 0.8)) * (isWalking ? 0.45 : 0.22)
        let tailWaveY: CGFloat = CGFloat(cos(maneFreq * 0.8)) * (isWalking ? 0.35 : 0.18)
        // 翅膀扑扇（v2.1）—— 频率略快于鬃毛，幅度跟随 walking
        let wingFlap: CGFloat = CGFloat(sin(maneFreq * 1.4)) * (isWalking ? 0.5 : 0.18)

        let sx = breatheSX
        let sy = breatheSY
        let dy = bodyBob

        // —— 渲染（背→前 z-order：阴影 → 后腿 → 尾巴 → 躯干 → 鬃毛背段 → 颈 → 头 → 鬃毛颈/顶段 → 耳朵 → 眼睛）——
        //
        // v2 调整（2026-05-18 用户反馈）：
        // - 躯干 w 10 → 7（更精致，不再"长马"）
        // - 头 / 颈 / 耳朵 整体左移（10.5 → 8），让形象重心居中
        // - 鬃毛拆成 4 段：头顶 / 颈背 / 躯干背中 / 飘逸末梢，越靠后幅度越大 → 飞驰感

        // 阴影（椭圆，不参与 sprite scale）
        let shadowRect = CGRect(
            x: 2.5 * unit, y: 9.2 * unit,
            width: 7 * unit, height: 0.55 * unit
        )
        ctx.fill(Path(ellipseIn: shadowRect), with: shadowFill)

        // 4 条腿（对角 trot 步态）：后左 + 前右 = group A，后右 + 前左 = group B
        // 收窄后腿距：后腿 [3, 4]、前腿 [6.8, 7.8]，间距更紧凑
        let legXs: [CGFloat] = [3, 4, 6.8, 7.8]
        let legGroups: [Int] = [0, 1, 1, 0]
        for (idx, x) in legXs.enumerated() {
            let liftY = legLiftOffset(group: legGroups[idx], phase: walkPhase)
            // 腿（金黄）
            fillRect(x: x, y: 7 + dy + liftY, w: 1, h: 1.7,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
            // 蹄子（深棕）
            fillRect(x: x, y: 8.55 + dy + liftY, w: 1, h: 0.4,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: hoofFill)
        }

        // 尾巴（3 段，越往末梢飘动幅度越大）
        // 根（紧贴躯干，幅度小）
        fillRect(x: 1.5 + tailWaveX * 0.4, y: 4.2 + dy, w: 0.7, h: 1.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: maneFill)
        // 中段
        fillRect(x: 0.8 + tailWaveX * 0.9, y: 5.2 + dy + tailWaveY * 0.5, w: 1, h: 1.6,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: maneFill)
        // 飘逸末梢（最大幅度）
        fillRect(x: 0.3 + tailWaveX * 1.4, y: 6.4 + dy + tailWaveY, w: 0.8, h: 1.2,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: maneFill)

        // 躯干（更精致：x=2 → 9，h=2.6）
        fillRect(x: 2, y: 4 + dy, w: 7, h: 2.6,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        // 躯干顶部高光带（左上光源）
        fillRect(x: 2.3, y: 4 + dy, w: 6.4, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyTopFill)
        // 躯干底部阴影带（体积感）
        fillRect(x: 2.3, y: 6.2 + dy, w: 6.4, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyBottomFill)

        // 鬃毛 1（躯干背中段，长长一片飘逸）—— 在颈后躯干上方
        // 比鬃毛颈段更靠后、相位落后，看起来像被风吹起的一缕
        fillRect(x: 4.5 + maneFloatLag * 0.6, y: 3.4 + dy + maneFloatLag * 0.8, w: 2.6, h: 0.9,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: maneFill)
        // 鬃毛 2（飘逸末梢，最远 / 最飘）
        fillRect(x: 3.2 + maneFloatLag * 1.0, y: 3.7 + dy + maneFloatLag * 1.3, w: 1.6, h: 0.7,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: maneFill)

        // —— 翅膀 🪽（v2.1 飞马标配）——
        // 3 段堆叠模拟羽毛层次：翼根（贴背）→ 翼中 → 翼尖（最高最飘）
        // 走路 / idle 时整体扑扇 wingFlap：翼尖幅度最大，翼根几乎不动（铰链感）
        //
        // 翼根（贴背，奶油白）
        fillRect(x: 4.8, y: 3.4 + dy + wingFlap * 0.2, w: 2.2, h: 1.0,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: wingFill)
        // 翼根阴影线（区分翼根 vs 躯干背）
        fillRect(x: 4.8, y: 4.2 + dy + wingFlap * 0.2, w: 2.2, h: 0.2,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: wingShadowFill)
        // 翼中段（向左上后掠）
        fillRect(x: 3.8 + wingFlap * 0.3, y: 2.7 + dy + wingFlap * 0.6, w: 2.0, h: 0.9,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: wingFill)
        // 翼中羽缝（细深线让羽毛分明）
        fillRect(x: 4.5 + wingFlap * 0.3, y: 3.0 + dy + wingFlap * 0.6, w: 0.25, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: wingShadowFill)
        // 翼尖（最飘）
        fillRect(x: 2.9 + wingFlap * 0.6, y: 2.3 + dy + wingFlap * 1.1, w: 1.6, h: 0.8,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: wingFill)
        // 翼尖羽边（少量金色高光，跟身体呼应）
        fillRect(x: 2.9 + wingFlap * 0.6, y: 2.9 + dy + wingFlap * 1.1, w: 1.6, h: 0.2,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: wingShadowFill)

        // 颈（弹性连接，v2.2 修复仰头时缝隙）
        //
        // 问题：v2.1 颈 y 跟着 headRaise 走 → 仰头时颈整体抬高 1.2pt 但躯干没动，
        // 中间出现 0.8pt 缝隙（用户反馈"脖子会断掉一块"）
        //
        // 修法：颈顶贴头底动 → 颈底固定在躯干交界（y=4.4）→ 颈高度自动拉长
        // - idle (headRaise=0)：颈 y=3 → 4.4, h=1.4（保持原版视觉）
        // - armsUp (headRaise=-1.2)：颈 y=1.8 → 4.4, h=2.6（脖子被拉长，仰头嘶鸣感更真实）
        let neckTopY: CGFloat = 3 + headRaise   // 跟头底走
        let neckBottomY: CGFloat = 4.4          // 固定贴躯干交界
        let neckH: CGFloat = neckBottomY - neckTopY
        fillRect(x: 6.5, y: neckTopY + dy, w: 1.8, h: neckH,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)

        // 鬃毛 3（颈背，紧贴头后）—— 紧贴头部，幅度小
        fillRect(x: 6.4 + maneFloat * 0.3, y: 2.5 + dy + headRaise + maneFloat * 0.7, w: 1.8, h: 1.1,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: maneFill)

        // 头（左移到 x=8，整体形象重心居中）
        fillRect(x: 8, y: 2 + dy + headRaise, w: 2.5, h: 2.5,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        // 嘴部加长（v2.1）+ 下移（v2.2）—— 从头部右下侧突出，符合马头解剖（眼睛上、嘴在底）
        // 嘴主体（金黄，跟头同色，做出一截突出）
        fillRect(x: 10.4, y: 3.6 + dy + headRaise, w: 1.0, h: 0.7,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        // 嘴底沿阴影（深金，体积感）
        fillRect(x: 10.4, y: 4.15 + dy + headRaise, w: 1.0, h: 0.18,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyBottomFill)
        // 鼻孔 / 嘴线（深棕小点，靠近嘴尖）
        fillRect(x: 11.0, y: 3.85 + dy + headRaise, w: 0.35, h: 0.3,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: hoofFill)

        // 鬃毛 4（头顶后侧）—— 跟头一起仰起
        fillRect(x: 7.5 + maneFloat * 0.4, y: 1.4 + dy + headRaise + maneFloat * 1.2, w: 1.5, h: 1.0,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: maneFill)

        // 两只耳朵（头顶上方，左右各一）
        fillRect(x: 9, y: 0.7 + dy + headRaise, w: 0.6, h: 1.3,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        fillRect(x: 9.7, y: 0.7 + dy + headRaise, w: 0.6, h: 1.3,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)

        // 眼睛（头中央偏前，可眨眼可左右瞟）
        let eyeX: CGFloat = 9.5 + eyeShiftX
        let eyeY: CGFloat = 2.7 + dy + headRaise
        if isBlinking {
            fillRect(x: eyeX, y: eyeY + 0.35, w: 0.6, h: 0.2,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: eyeFill)
        } else {
            fillRect(x: eyeX, y: eyeY, w: 0.6, h: 0.6,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: eyeFill)
            // 高光小点（左上）—— 让眼神立刻有神
            fillRect(x: eyeX + 0.05, y: eyeY + 0.08, w: 0.22, h: 0.22,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: highlightFill)
        }
    }

    /// trot 步态：group 0 在 phase 0~0.5 抬腿（sin 曲线最高 -0.8pt），group 1 在 0.5~1.0 抬腿
    private func legLiftOffset(group: Int, phase: Double) -> CGFloat {
        guard isWalking else { return 0 }
        let p = phase
        let groupPhase = (group == 0) ? p : (p + 0.5).truncatingRemainder(dividingBy: 1.0)
        if groupPhase < 0.5 {
            return CGFloat(-sin(groupPhase * 2 * .pi)) * 0.8
        }
        return 0
    }

    /// 以 sprite 中心 (7, 5) 为锚点做 scale 后填充矩形
    private func fillRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                          ctx: GraphicsContext, unit: CGFloat,
                          sx: CGFloat, sy: CGFloat,
                          fill: GraphicsContext.Shading) {
        let screenX = (x - Self.centerX) * sx * unit + Self.centerX * unit
        let screenY = (y - Self.centerY) * sy * unit + Self.centerY * unit
        let screenW = w * sx * unit
        let screenH = h * sy * unit
        ctx.fill(Path(CGRect(x: screenX, y: screenY, width: screenW, height: screenH)), with: fill)
    }
}

// MARK: - Codex：终端窗口精灵 💻（macOS 风格 mini Terminal.app + 两条小腿）

/// Codex mode 的左耳精灵 —— 终端窗口小精灵
///
/// 形象设计：macOS 风格 mini Terminal.app
/// - 黑色窗口 + 标题栏 + 3 颗交通灯（红/黄/绿）
/// - 内容区底部 `$` 提示符 + 闪烁青色光标
/// - 两条小腿（trot 步态走路）
/// - 工作时内容区"代码字符滚动"（assistantLines 抖动模拟正在敲码）
///
/// pose 映射：
/// - rest：正常静态
/// - lookLeft / lookRight：光标位置左右偏移（"在另一边敲码"）
/// - armsUp：内容区中央显示放大 `>` 字符 + scale 微跳（终端"喊话"）
struct CodexTerminalSprite: View {
    let isWorking: Bool
    let size: CGFloat
    /// 调色板 —— 默认深空蓝，用户自定义后由调用方传入
    var palette: PetPalette = .terminalDefault
    /// 是否启用内部 TerminalView 的 30fps 动画。false 时画静态帧
    var animated: Bool = true

    @State private var pose: ClawdPose = .rest
    @State private var workingTask: Task<Void, Never>?
    @State private var celebrateTask: Task<Void, Never>?
    @State private var lookTask: Task<Void, Never>?
    @State private var currentTool: ToolKind = .other

    /// 终端 viewBox 14:10，size 是常规图标高。× 1.4 跟 Clawd / 小马视觉重量一致
    private var terminalHeight: CGFloat { size * 1.4 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalView(pose: pose, height: terminalHeight, isWalking: false,
                         isWorking: isWorking, palette: palette, animated: animated)
            if isWorking {
                ToolOverlay(kind: currentTool)
                    .offset(x: 3, y: -2)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(AnimTok.smooth, value: isWorking)
        .onAppear { applyState(isWorking) }
        .onChange(of: isWorking) { _, w in
            applyState(w)
            if !w { currentTool = .other }
        }
        .onDisappear {
            workingTask?.cancel()
            celebrateTask?.cancel()
            lookTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            if success { startCelebrate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolStarted"))) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            withAnimation(AnimTok.snappy) {
                currentTool = ToolKind.from(toolName: name)
            }
            if isWorking { startWorking() }
        }
    }

    private func applyState(_ working: Bool) {
        if working {
            lookTask?.cancel(); lookTask = nil
            startWorking()
        } else {
            workingTask?.cancel(); workingTask = nil
            if celebrateTask == nil {
                pose = .rest
                startIdleLook()
            }
        }
    }

    private func startWorking() {
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

    private func workingFrames(for tool: ToolKind) -> [(ClawdPose, UInt64)] {
        switch tool {
        case .read:    return [(.lookLeft, 500_000_000), (.lookRight, 500_000_000)]
        case .write:   return [(.armsUp, 220_000_000), (.rest, 200_000_000)]
        case .bash:    return [(.armsUp, 280_000_000), (.rest, 320_000_000)]
        case .search:  return [(.lookLeft, 200_000_000), (.lookRight, 200_000_000)]
        case .web:     return [(.rest, 350_000_000), (.lookLeft, 500_000_000), (.lookRight, 500_000_000)]
        case .task:    return [(.armsUp, 240_000_000), (.rest, 100_000_000), (.armsUp, 240_000_000), (.rest, 500_000_000)]
        case .todo, .other, .thinking: return [(.armsUp, 300_000_000), (.rest, 350_000_000)]
        }
    }

    private func startCelebrate() {
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
            if !isWorking { startIdleLook() }
        }
    }

    private func startIdleLook() {
        lookTask?.cancel()
        lookTask = Task { @MainActor in
            while !Task.isCancelled {
                let delayNs = UInt64.random(in: 22_000_000_000...42_000_000_000)
                try? await Task.sleep(nanoseconds: delayNs)
                if Task.isCancelled || isWorking { return }
                let roll = Int.random(in: 0..<10)
                if roll < 2 {
                    pose = .armsUp
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = .rest
                } else {
                    pose = Bool.random() ? .lookLeft : .lookRight
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled || isWorking { return }
                    pose = .rest
                }
            }
        }
    }
}

/// 钢铁侠风格小方块机器人 —— viewBox 14×10
///
/// v3 重设计（用户反馈：终端 + 字符抖动机械感太重）
/// 形象：会飞的小机器人 —— 头部黑屏 + 双眼 + 嘴 + 胸前 `</>` LED + 双喷射器
/// 灵魂来源：眼睛会看你 + 表情会变 + LED 像心跳 + 喷射器像呼吸
///
/// 像素图（喷射推进器版，不用腿走路用悬浮飞行）：
/// ```
///        0  1  2  3  4  5  6  7  8  9 10 11 12 13
/// row 0:              ██████████████              ← 头壳顶（深空蓝）
/// row 1:              ██ ◉      ◉ ██              ← 屏幕 + 双眼（白圆+黑瞳+高光）
/// row 2:              ██   ───   ██              ← 嘴（lime 横线 / armsUp 时变 ◡）
/// row 3:                █████████                  ← 颈连接
/// row 4:        ██████████████████████             ← 身体顶 + 手臂
/// row 5:        ████  ◢ </> ◣  ████              ← 身体 + 胸前 LED 心跳
/// row 6:        ██████████████████████             ← 身体底
/// row 7:              ▓▓        ▓▓                ← 2 个推进器口（深黑）
/// row 8:              🔥🔥      🔥🔥              ← 三层火焰：内白 + 中青 + 外橙
/// row 9:             ░░░░░░░░░░░░                  ← 阴影光圈
/// ```
///
/// 动画（TimelineView 30fps 自驱）：
/// 1. **悬浮浮动** 1.8s loop：idle ±0.25pt / walking ±0.5pt —— 永远漂浮不踏地
/// 2. **火焰脉冲** 高频抖动 ±0.3pt + 宽度 ±0.12pt，3 层叠色 cyan→white→orange
/// 3. **呼吸** 3.2s loop ±1.5%
/// 4. **眨眼** 5s 普通眨；working 时 ~1.8s 加快频率（思考感）
/// 5. **眼神跟随鼠标** rest 状态自动跟（同 Clawd 的 continuousMouseEyeOffset）；lookLeft/Right 离散偏移
/// 6. **LED `</>` 心跳** 颜色脉冲：idle 0.8Hz 慢呼吸 / working 4Hz 急闪
/// 7. **嘴部表情** rest=横线 / armsUp=三段 ◡ 半圆笑容 / lookL/R=嘴角微抬
/// 8. **走路时** 不动腿，火焰拉长 ×1.9 + 浮动幅度 ×2 + 阴影模糊大（飞行加速感）
struct TerminalView: View {
    let pose: ClawdPose
    let height: CGFloat
    /// 是否"走路"中 —— 实际是飞行加速：火焰拉长 + 浮动幅度加大
    var isWalking: Bool = false
    /// 工作中 —— LED 心跳加快、眨眼频率提高
    var isWorking: Bool = false
    /// 调色板 —— 主色 + 派生高光/阴影；屏幕黑 / 眼白 / 嘴 / LED / 火焰保持默认（保留 Codex 辨识度）
    var palette: PetPalette = .terminalDefault
    /// 是否启用 TimelineView 30fps 重绘。false 时画静态帧（now=0 相位归零、不读鼠标）
    var animated: Bool = true

    // 不参与调色的默认色（保留 Codex 视觉特征）
    private static let screenColor     = Color(red: 10.0/255,  green: 15.0/255,  blue: 31.0/255)   // #0A0F1F 头部黑屏
    private static let eyeWhiteColor   = Color(red: 240.0/255, green: 248.0/255, blue: 255.0/255)  // #F0F8FF 冷白眼
    private static let mouthColor      = Color(red: 168.0/255, green: 224.0/255, blue: 122.0/255)  // #A8E07A lime 嘴
    private static let ledColor        = Color(red: 91.0/255,  green: 212.0/255, blue: 230.0/255)  // #5BD4E6 Codex cyan LED
    private static let flameInnerColor = Color(white: 1.0)                                          // 内焰纯白
    private static let flameMidColor   = Color(red: 91.0/255,  green: 212.0/255, blue: 230.0/255)  // cyan 中焰
    private static let flameOuterColor = Color(red: 255.0/255, green: 180.0/255, blue: 107.0/255)  // #FFB46B 外焰暖橙

    private static let viewBoxW: CGFloat = 14
    private static let viewBoxH: CGFloat = 10
    private static let centerX: CGFloat = 7
    private static let centerY: CGFloat = 5

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    draw(ctx: ctx, size: size, now: 0)
                }
            }
        }
        .frame(width: height * Self.viewBoxW / Self.viewBoxH, height: height)
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        let unit = min(size.width / Self.viewBoxW, size.height / Self.viewBoxH)
        // 主色 + 派生（用户调色后自动跟着变）
        let bodyFill        = GraphicsContext.Shading.color(palette.primary)
        let bodyTopFill     = GraphicsContext.Shading.color(palette.derivedTop)
        let bodyBottomFill  = GraphicsContext.Shading.color(palette.derivedBottom)
        let screenFill      = GraphicsContext.Shading.color(Self.screenColor)
        let eyeWhiteFill    = GraphicsContext.Shading.color(Self.eyeWhiteColor)
        let pupilFill       = GraphicsContext.Shading.color(Self.screenColor)
        let mouthFill       = GraphicsContext.Shading.color(Self.mouthColor)
        let flameInnerFill  = GraphicsContext.Shading.color(Self.flameInnerColor)
        let flameMidFill    = GraphicsContext.Shading.color(Self.flameMidColor)
        let flameOuterFill  = GraphicsContext.Shading.color(Self.flameOuterColor)
        let highlightFill   = GraphicsContext.Shading.color(.white.opacity(0.9))
        let shadowFill      = GraphicsContext.Shading.color(.black.opacity(0.35))
        let cyanLineFill    = GraphicsContext.Shading.color(Self.ledColor)

        // 呼吸 3.2s ±1.5%（比其他 sprite 略柔，机器人是钢的）
        let breatheT = sin(now * 2 * .pi / 3.2)
        let sx: CGFloat = 1 + CGFloat(breatheT) * 0.015
        let sy: CGFloat = 1 - CGFloat(breatheT) * 0.015

        // 悬浮浮动 1.8s 周期 —— idle ±0.25 / walking ±0.5
        let hoverFreq = now * 2 * .pi / 1.8
        let hoverFloat: CGFloat = CGFloat(sin(hoverFreq)) * (isWalking ? 0.5 : 0.25)
        let dy = hoverFloat

        // 火焰脉冲（高频抖动 + 宽度噪声）
        let flameBaseLen: CGFloat = isWalking ? 1.9 : 1.0
        let flamePulse: CGFloat = CGFloat(sin(now * 18)) * 0.3
        let flameLen = max(0.6, flameBaseLen + flamePulse)
        let flameWNoise: CGFloat = CGFloat(sin(now * 22 + 1.5)) * 0.12

        // 眨眼 5s 普通眨；working 时 1.8s 加快频率（思考感）
        let blinkPhase = (now / 5.0).truncatingRemainder(dividingBy: 1.0)
        let isBlinking = blinkPhase > 0.96
        let workBlinkPhase = (now / 1.8).truncatingRemainder(dividingBy: 1.0)
        let workBlinking = isWorking && (workBlinkPhase > 0.88 && workBlinkPhase < 0.94)
        let actualBlinking = isBlinking || workBlinking

        // 眼神偏移
        let (eyeShiftX, eyeShiftY): (CGFloat, CGFloat) = {
            switch pose {
            case .lookLeft:  return (-0.32, 0)
            case .lookRight: return ( 0.32, 0)
            case .armsUp:    return (0, -0.08)
            case .rest:
                // animated=false 时不读鼠标 —— 静态帧眼睛回到中央
                guard animated else { return (0, 0) }
                return Self.continuousMouseEyeOffset()
            }
        }()

        let showSmile = (pose == .armsUp)

        // LED `</>` 颜色心跳：working 4Hz 急闪 / idle 0.8Hz 慢呼吸
        let ledFreq = isWorking ? now * 4.0 : now * 0.8
        let ledPulse: Double = (sin(ledFreq * 2 * .pi) + 1) * 0.5
        let ledOpacity = 0.55 + ledPulse * 0.45
        let ledFill = GraphicsContext.Shading.color(Self.ledColor.opacity(ledOpacity))

        // —— 渲染 z-order ——
        // 阴影 → 火焰(外→中→内) → 推进器口 → 手臂 → 身体 → 胸前 LED 框 → </> →
        // 颈连接 → 头壳 → 屏幕 → 眼 → 嘴

        // 阴影（推进器下方光圈；walking 时模糊更大）
        let shadowW: CGFloat = isWalking ? 8.5 : 7
        let shadowH: CGFloat = isWalking ? 0.6 : 0.45
        let shadowRect = CGRect(
            x: (7 - shadowW / 2) * unit, y: 9.25 * unit,
            width: shadowW * unit, height: shadowH * unit
        )
        ctx.fill(Path(ellipseIn: shadowRect), with: shadowFill)

        // 双火焰（左右各一，3 层叠色 outer→mid→inner）
        let flameXs: [CGFloat] = [4.2, 8.8]
        for fx in flameXs {
            fillRect(x: fx - 0.45 + flameWNoise * 0.3, y: 6.5 + dy,
                     w: 1.5 + flameWNoise, h: flameLen,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: flameOuterFill)
            fillRect(x: fx - 0.2, y: 6.5 + dy,
                     w: 1.0, h: flameLen * 0.85,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: flameMidFill)
            fillRect(x: fx + 0.05, y: 6.5 + dy,
                     w: 0.5, h: flameLen * 0.55,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: flameInnerFill)
        }

        // 推进器口（深黑圆边盖在火焰头部）
        for fx in flameXs {
            fillRect(x: fx - 0.55, y: 5.95 + dy, w: 1.7, h: 0.65,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyBottomFill)
            fillRect(x: fx - 0.45, y: 6.0 + dy, w: 1.5, h: 0.15,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        }

        // 手臂（左右各一短臂垂在身体两侧）
        fillRect(x: 1.5, y: 4 + dy, w: 0.7, h: 1.5,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        fillRect(x: 11.8, y: 4 + dy, w: 0.7, h: 1.5,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        // 手掌（深一档作为手套）
        fillRect(x: 1.4, y: 5.3 + dy, w: 0.9, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyBottomFill)
        fillRect(x: 11.7, y: 5.3 + dy, w: 0.9, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyBottomFill)

        // 身体方块
        fillRect(x: 2.3, y: 3.5 + dy, w: 9.4, h: 2.5,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        fillRect(x: 2.6, y: 3.5 + dy, w: 8.8, h: 0.35,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyTopFill)
        fillRect(x: 2.6, y: 5.65 + dy, w: 8.8, h: 0.35,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyBottomFill)

        // 胸前 LED 框（黑底凹槽）
        fillRect(x: 5.3, y: 4.0 + dy, w: 3.4, h: 1.6,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: screenFill)
        // `</>` LED：左 chevron + 中斜杠 + 右 chevron，全部用 ledFill（颜色心跳）
        fillRect(x: 5.85, y: 4.3 + dy, w: 0.3, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)
        fillRect(x: 5.7, y: 4.6 + dy, w: 0.3, h: 0.35,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)
        fillRect(x: 5.85, y: 4.85 + dy, w: 0.3, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)
        fillRect(x: 6.55, y: 4.95 + dy, w: 0.3, h: 0.35,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)
        fillRect(x: 6.7, y: 4.65 + dy, w: 0.3, h: 0.35,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)
        fillRect(x: 6.85, y: 4.3 + dy, w: 0.3, h: 0.35,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)
        fillRect(x: 7.5, y: 4.3 + dy, w: 0.3, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)
        fillRect(x: 7.65, y: 4.6 + dy, w: 0.3, h: 0.35,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)
        fillRect(x: 7.5, y: 4.85 + dy, w: 0.3, h: 0.4,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: ledFill)

        // 颈连接（身体到头部的短桥）
        fillRect(x: 5.8, y: 3.0 + dy, w: 2.4, h: 0.6,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)

        // 头壳（深空蓝，屏幕外框）
        fillRect(x: 3.5, y: 0.5 + dy, w: 7, h: 2.7,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyFill)
        fillRect(x: 3.8, y: 0.5 + dy, w: 6.4, h: 0.35,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyTopFill)
        fillRect(x: 3.8, y: 2.9 + dy, w: 6.4, h: 0.3,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: bodyBottomFill)

        // 屏幕黑底
        fillRect(x: 4.0, y: 0.9 + dy, w: 6, h: 1.95,
                 ctx: ctx, unit: unit, sx: sx, sy: sy, fill: screenFill)

        // 双眼 + 嘴（生命核心）
        let leftEyeCX: CGFloat = 5.3 + eyeShiftX
        let leftEyeCY: CGFloat = 1.55 + dy + eyeShiftY
        let rightEyeCX: CGFloat = 8.7 + eyeShiftX
        let rightEyeCY: CGFloat = 1.55 + dy + eyeShiftY

        if actualBlinking {
            // 闭眼：两条 cyan 短横线（机器人眯眼科技感）
            fillRect(x: leftEyeCX - 0.4, y: leftEyeCY + 0.25, w: 0.8, h: 0.18,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: cyanLineFill)
            fillRect(x: rightEyeCX - 0.4, y: rightEyeCY + 0.25, w: 0.8, h: 0.18,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: cyanLineFill)
        } else {
            // 眼白（白圆，半径 0.55）
            ctx.fill(Path(ellipseIn: ellipseRect(cx: leftEyeCX, cy: leftEyeCY, r: 0.55,
                                                 sx: sx, sy: sy, unit: unit)), with: eyeWhiteFill)
            ctx.fill(Path(ellipseIn: ellipseRect(cx: rightEyeCX, cy: rightEyeCY, r: 0.55,
                                                 sx: sx, sy: sy, unit: unit)), with: eyeWhiteFill)
            // 瞳孔（黑圆）
            ctx.fill(Path(ellipseIn: ellipseRect(cx: leftEyeCX, cy: leftEyeCY + 0.05, r: 0.27,
                                                 sx: sx, sy: sy, unit: unit)), with: pupilFill)
            ctx.fill(Path(ellipseIn: ellipseRect(cx: rightEyeCX, cy: rightEyeCY + 0.05, r: 0.27,
                                                 sx: sx, sy: sy, unit: unit)), with: pupilFill)
            // 高光（左上白点，眼神立刻有神）
            ctx.fill(Path(ellipseIn: ellipseRect(cx: leftEyeCX - 0.15, cy: leftEyeCY - 0.08, r: 0.12,
                                                 sx: sx, sy: sy, unit: unit)), with: highlightFill)
            ctx.fill(Path(ellipseIn: ellipseRect(cx: rightEyeCX - 0.15, cy: rightEyeCY - 0.08, r: 0.12,
                                                 sx: sx, sy: sy, unit: unit)), with: highlightFill)
        }

        // 嘴部
        if showSmile {
            // armsUp：三段 ◡ 半圆笑容（lime）
            fillRect(x: 5.8, y: 2.5 + dy, w: 0.5, h: 0.2,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: mouthFill)
            fillRect(x: 6.3, y: 2.62 + dy, w: 1.4, h: 0.22,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: mouthFill)
            fillRect(x: 7.7, y: 2.5 + dy, w: 0.5, h: 0.2,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: mouthFill)
        } else {
            // rest / lookL/R：两段横线嘴；lookL/R 时一端略抬（微笑感）
            let baseMouthY: CGFloat = 2.55 + dy
            let leftMouthY: CGFloat = (pose == .lookRight) ? baseMouthY - 0.08 : baseMouthY
            let rightMouthY: CGFloat = (pose == .lookLeft) ? baseMouthY - 0.08 : baseMouthY
            fillRect(x: 5.8, y: leftMouthY, w: 1.2, h: 0.2,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: mouthFill)
            fillRect(x: 7.0, y: rightMouthY, w: 1.2, h: 0.2,
                     ctx: ctx, unit: unit, sx: sx, sy: sy, fill: mouthFill)
        }
    }

    /// 把 viewBox 坐标的圆映射到屏幕坐标 + 应用 scale 锚点 (centerX, centerY)
    private func ellipseRect(cx: CGFloat, cy: CGFloat, r: CGFloat,
                             sx: CGFloat, sy: CGFloat, unit: CGFloat) -> CGRect {
        let screenCX = (cx - Self.centerX) * sx * unit + Self.centerX * unit
        let screenCY = (cy - Self.centerY) * sy * unit + Self.centerY * unit
        let screenR = r * sx * unit
        return CGRect(x: screenCX - screenR, y: screenCY - screenR,
                      width: screenR * 2, height: screenR * 2)
    }

    /// 读当前鼠标位置 → 转成眼神偏移
    /// rest 状态下让机器人"看着鼠标"，跟 Clawd 同款生命感来源
    /// NSEvent.mouseLocation 是无锁 class method，从主线程 Canvas draw 调用安全
    nonisolated private static func continuousMouseEyeOffset() -> (CGFloat, CGFloat) {
        let loc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen, screen.frame.contains(loc) else { return (0, 0) }
        let halfW = screen.frame.width / 2
        let halfH = screen.frame.height / 2
        let nx = max(-1, min(1, (loc.x - screen.frame.midX) / halfW))
        let ny = max(-1, min(1, (loc.y - screen.frame.midY) / halfH))
        return (CGFloat(nx) * 0.3, CGFloat(-ny) * 0.15)
    }

    /// 以 sprite 中心 (7, 5) 为锚点 scale 后填充矩形
    private func fillRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                          ctx: GraphicsContext, unit: CGFloat,
                          sx: CGFloat, sy: CGFloat,
                          fill: GraphicsContext.Shading) {
        let screenX = (x - Self.centerX) * sx * unit + Self.centerX * unit
        let screenY = (y - Self.centerY) * sy * unit + Self.centerY * unit
        let screenW = w * sx * unit
        let screenH = h * sy * unit
        ctx.fill(Path(CGRect(x: screenX, y: screenY, width: screenW, height: screenH)), with: fill)
    }
}
// MARK: - DirectAPI：云朵精灵（indigo 像素小云，有眼睛 + 呼吸 + 飘浮）

/// 在线 AI 的灵动岛精灵 —— 跟 ClaudeKnotSprite 类似的 pose 驱动 + 工具动画
struct CloudPetIslandSprite: View {
    let isWorking: Bool
    let size: CGFloat
    /// 调色板 —— 默认 indigo，用户自定义后由调用方传入
    var palette: PetPalette = .cloudDefault
    /// 是否启用内部 CloudPetView 的 30fps 动画。false 时画静态帧
    var animated: Bool = true

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
                         glassesProgress: glassesProgress, palette: palette,
                         animated: animated)
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
            // 30fps 协调 —— 跟 TimelineView 频率对齐，省一半 state-push 开销
            let onFrames = 42
            for i in 1...onFrames {
                if Task.isCancelled { return }
                let t = Double(i) / Double(onFrames)
                glassesProgress = easeOutBack(t)
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
            glassesProgress = 1
            // 保持戴着
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            // 摘下动画：1 → 0，0.6s ease-in 慢慢消失（30fps × 0.6s = 18 frames）
            let offFrames = 18
            for i in 1...offFrames {
                if Task.isCancelled { return }
                let t = 1 - Double(i) / Double(offFrames)
                glassesProgress = t * t   // ease-in
                try? await Task.sleep(nanoseconds: 33_333_333)
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
    /// 调色板 —— 主色 + 派生高光/阴影。默认 indigo
    var palette: PetPalette = .cloudDefault
    /// 是否启用 TimelineView 30fps 重绘。false 时画静态帧（now=0 相位归零）
    var animated: Bool = true

    private static let viewBoxW: CGFloat = 14
    private static let viewBoxH: CGFloat = 10
    private static let centerX: CGFloat = 7
    private static let centerY: CGFloat = 5

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    draw(ctx: ctx, size: size, now: 0)
                }
            }
        }
        .frame(width: height * Self.viewBoxW / Self.viewBoxH, height: height)
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        let unit = min(size.width / Self.viewBoxW, size.height / Self.viewBoxH)
        // 主色 + 派生（用户调色后自动跟着变）
        let bodyFill = GraphicsContext.Shading.color(palette.primary)
        let topFill = GraphicsContext.Shading.color(palette.derivedTop)
        let bottomFill = GraphicsContext.Shading.color(palette.derivedBottom)
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


