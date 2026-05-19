import SwiftUI

/// **fomo** —— OpenClaw 模式的桌宠 sprite，纯像素艺术风格白色小狐狸。
///
/// 设计要点（用户明确要求）：
/// - **白色小狐狸**（身体近白 #F5F8FF + palette 主色作阴影，跟参考图主调一致）
/// - **耳朵灵动是最大特征**：左右耳各自高频微抖 1.6Hz ±0.15pt + 每 4s 一次大幅 twitch
///   （像狐狸警觉时耳朵抖一下的真实生物感）
/// - **纯像素方块拼接**风格 —— 跟 ClawdView 完全一致，没有椭圆 / 复杂 path
///
/// viewBox 14×10，跟 ClawdView 同尺寸结构。pose enum 复用 ClawdPose。
@MainActor
struct FomoView: View {
    let pose: ClawdPose
    /// 精灵高度。最终 frame 宽 = height × 14/10
    let height: CGFloat
    /// 是否正在走路 —— 控制 4 条腿对角交替 + 尾巴摆动
    var isWalking: Bool = false
    /// 调色板 —— 主色作为狐狸阴影 / 派生色（身体硬编码近白色）
    var palette: PetPalette = .fomoDefault
    /// 是否启用 TimelineView 30fps 重绘
    var animated: Bool = true

    private static let viewBoxW: CGFloat = 14
    private static let viewBoxH: CGFloat = 10

    // 静态像素布局（viewBox 14×10），所有坐标参考左上 (0,0)
    // 头部 6×5：x=4-10, y=2-7
    private static let head     = FomoRect(x: 4,   y: 2,   w: 6,   h: 5)
    // 耳朵基础位置（实际绘制时叠加 wiggle / twitch 偏移）
    private static let leftEarBaseX:  CGFloat = 4.0
    private static let rightEarBaseX: CGFloat = 8.5
    private static let earBaseY:      CGFloat = 0.0
    // 眼睛 1×1 黑色
    private static let leftEye  = FomoRect(x: 5.2, y: 4.0, w: 1.0, h: 1.0)
    private static let rightEye = FomoRect(x: 7.8, y: 4.0, w: 1.0, h: 1.0)
    // 鼻：粉色小方块
    private static let nose     = FomoRect(x: 6.7, y: 5.4, w: 0.6, h: 0.5)
    // 身体 8×2.5：x=3-11, y=6.5-9
    private static let body     = FomoRect(x: 3,   y: 6.3, w: 8,   h: 2.5)
    // 4 条腿
    private static let legs: [FomoRect] = [
        FomoRect(x: 3.5, y: 8.5, w: 1.0, h: 1.5),
        FomoRect(x: 5.5, y: 8.5, w: 1.0, h: 1.5),
        FomoRect(x: 7.5, y: 8.5, w: 1.0, h: 1.5),
        FomoRect(x: 9.5, y: 8.5, w: 1.0, h: 1.5),
    ]
    // 地面阴影
    private static let shadow   = FomoRect(x: 3,   y: 9.7, w: 8,   h: 0.3)

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

        // —— 调色 ——
        // 身体硬编码近白（满足"白色小狐狸"硬需求）
        let bodyFill   = GraphicsContext.Shading.color(Color(red: 0.97, green: 0.98, blue: 1.0))
        // palette.primary 当作"阴影 / 体积感"色，让 PetPaletteStore 仍能影响视觉
        let bodyShadow = GraphicsContext.Shading.color(palette.primary)
        let bodyLow    = GraphicsContext.Shading.color(palette.derivedBottom)
        let pinkFill   = GraphicsContext.Shading.color(Color(red: 0.95, green: 0.72, blue: 0.82))
        let eyeFill    = GraphicsContext.Shading.color(.black)
        let highlight  = GraphicsContext.Shading.color(.white)
        let ground     = GraphicsContext.Shading.color(.black.opacity(0.18))

        // —— 动画参数 ——

        // 呼吸 3.2s ±2%
        let breatheT = sin(now * 2 * .pi / 3.2)
        let breatheSY: CGFloat = 1 - CGFloat(breatheT) * 0.02

        // 走路 4 条腿对角交替（leg 0/2 = group A，leg 1/3 = group B，反相）
        let walkPhase = isWalking ? now.truncatingRemainder(dividingBy: 0.9) / 0.9 : 0
        let bobY: CGFloat = isWalking ? CGFloat(sin(now * 2 * .pi / 0.9)) * 0.25 : 0

        // 眨眼 4.5s，0.18s 闭眼
        let blinkPhase = now.truncatingRemainder(dividingBy: 4.5) / 4.5
        let isBlinking = blinkPhase > 0.96

        // ⭐ 耳朵灵动 —— 这是 fomo 的核心特征
        // 高频微抖 1.6Hz ±0.15pt（左右耳相位差 0.7π 让它们看起来各自独立）
        let leftEarWiggleX  = CGFloat(sin(now * 2 * .pi * 1.6)) * 0.15
        let rightEarWiggleX = CGFloat(sin(now * 2 * .pi * 1.6 + .pi * 0.7)) * 0.15

        // 大幅 twitch：每 4s 一次，0.15s 窗口（像真实狐狸警觉时耳朵猛抖一下）
        // 左右耳延迟错开（左耳在 phase 0.00 触发，右耳在 phase 0.20 触发）
        let twitchCycle = 4.0
        let leftPh  = now.truncatingRemainder(dividingBy: twitchCycle) / twitchCycle
        let rightPh = (now + 0.8).truncatingRemainder(dividingBy: twitchCycle) / twitchCycle
        let leftEarTwitch: CGFloat = {
            guard leftPh < 0.038 else { return 0 }   // 4s × 0.038 ≈ 0.15s window
            return CGFloat(sin(leftPh / 0.038 * .pi)) * 0.55
        }()
        let rightEarTwitch: CGFloat = {
            guard rightPh < 0.038 else { return 0 }
            return CGFloat(sin(rightPh / 0.038 * .pi)) * 0.50
        }()

        // armsUp pose：耳朵稍微往下（吓到/求救态），尾巴垂
        let earDownY: CGFloat = (pose == .armsUp) ? 0.5 : 0

        // 眼神偏移
        let (eyeLookX, _): (CGFloat, CGFloat) = {
            switch pose {
            case .lookLeft:  return (-0.3, 0)
            case .lookRight: return ( 0.3, 0)
            default:         return ( 0,   0)
            }
        }()

        // —— 整体 transform：呼吸 + walking bob ——
        var c = ctx
        // ⭐ 水平镜像：让 sprite 默认朝右（跟 ClawdView / HorseView 等约定一致 ——
        // ClawdWalkView 的 scaleEffect(x: facingRight ? 1 : -1) 假设默认朝右，
        // 而我画的 fomo 因尾巴在右、头部居中导致视觉"朝左"，不镜像会让移动方向跟翻转反过来）
        c.translateBy(x: size.width, y: 0)
        c.scaleBy(x: -1.0, y: 1.0)
        let cx = Self.viewBoxW / 2 * unit
        let cy = Self.viewBoxH / 2 * unit
        c.translateBy(x: cx, y: cy + bobY * unit)
        c.scaleBy(x: 1.0, y: breatheSY)
        c.translateBy(x: -cx, y: -cy)

        // helper：画一个 FomoRect
        func paint(_ r: FomoRect, _ shading: GraphicsContext.Shading) {
            let rect = CGRect(x: r.x * unit, y: r.y * unit, width: r.w * unit, height: r.h * unit)
            c.fill(Path(rect), with: shading)
        }

        // ============ 绘制顺序 ============
        // 1. 地面阴影（最底层）
        // 2. 尾巴（被身体遮一部分）
        // 3. 后腿（在身体后）—— 简化省略，4 腿全在前
        // 4. 身体
        // 5. 4 条腿
        // 6. 头部
        // 7. 耳朵
        // 8. 眼睛 / 鼻 / 嘴

        // 1. 地面阴影
        paint(Self.shadow, ground)

        // 2. 尾巴（左右摆动 + 走路时摆得更大）
        let tailSwing: CGFloat = isWalking
            ? CGFloat(sin(now * 2 * .pi / 0.6)) * 0.5
            : CGFloat(sin(now * 2 * .pi / 2.5)) * 0.25
        let tailX = 10.5 + tailSwing
        // 尾巴主体（3 个矩形叠加成蓬松感）
        paint(FomoRect(x: tailX,        y: 5.0, w: 2.5, h: 3.0), bodyFill)
        paint(FomoRect(x: tailX + 1.8,  y: 5.8, w: 1.5, h: 2.2), bodyFill)
        paint(FomoRect(x: tailX + 2.5,  y: 6.5, w: 1.0, h: 1.5), highlight)
        // 尾巴根阴影
        paint(FomoRect(x: tailX,        y: 7.2, w: 1.5, h: 1.0), bodyShadow)

        // 3+4. 身体 + 腹部高光
        paint(Self.body, bodyFill)
        paint(FomoRect(x: 3.5, y: 7.5, w: 7, h: 1), highlight)

        // 5. 4 条腿（走路时对角交替抬起）
        for (i, leg) in Self.legs.enumerated() {
            let groupA = (i == 0 || i == 2)
            let phase = groupA ? walkPhase : (walkPhase + 0.5).truncatingRemainder(dividingBy: 1.0)
            let lift: CGFloat = isWalking && phase < 0.5
                ? -CGFloat(sin(phase * 2 * .pi)) * 0.35
                : 0
            paint(FomoRect(x: leg.x, y: leg.y + lift, w: leg.w, h: leg.h), bodyFill)
            // 腿底阴影
            paint(FomoRect(x: leg.x, y: leg.y + leg.h - 0.3 + lift, w: leg.w, h: 0.3), bodyShadow)
        }

        // 6. 头部
        paint(Self.head, bodyFill)
        // 下颌阴影
        paint(FomoRect(x: 4, y: 6.0, w: 6, h: 1.0), bodyShadow)
        // 脸颊高光（小白点，圆润感）
        paint(FomoRect(x: 4.5, y: 3.0, w: 1.2, h: 0.7), highlight)
        paint(FomoRect(x: 8.3, y: 3.0, w: 1.2, h: 0.7), highlight)

        // 7. 耳朵 —— 灵动！⭐
        // 三角形耳朵用 3 段宽度递减的矩形堆叠成 "▲" 形
        // 左耳
        let lex = Self.leftEarBaseX + leftEarWiggleX + leftEarTwitch * 0.4
        let ley = Self.earBaseY + earDownY - leftEarTwitch * 0.3
        paint(FomoRect(x: lex,       y: ley + 2.0, w: 1.8, h: 1.0), bodyFill)  // 耳底
        paint(FomoRect(x: lex + 0.25, y: ley + 1.0, w: 1.3, h: 1.0), bodyFill) // 耳中
        paint(FomoRect(x: lex + 0.55, y: ley,       w: 0.7, h: 1.0), bodyFill) // 耳尖
        // 左耳内（粉）
        paint(FomoRect(x: lex + 0.5, y: ley + 1.3, w: 0.8, h: 1.3), pinkFill)
        // 左耳尖端深色（让三角形更明显）
        paint(FomoRect(x: lex + 0.7, y: ley,       w: 0.3, h: 0.4), bodyLow)

        // 右耳
        let rex = Self.rightEarBaseX + rightEarWiggleX - rightEarTwitch * 0.4
        let rey = Self.earBaseY + earDownY - rightEarTwitch * 0.3
        paint(FomoRect(x: rex,       y: rey + 2.0, w: 1.8, h: 1.0), bodyFill)
        paint(FomoRect(x: rex + 0.25, y: rey + 1.0, w: 1.3, h: 1.0), bodyFill)
        paint(FomoRect(x: rex + 0.55, y: rey,       w: 0.7, h: 1.0), bodyFill)
        paint(FomoRect(x: rex + 0.5, y: rey + 1.3, w: 0.8, h: 1.3), pinkFill)
        paint(FomoRect(x: rex + 0.7, y: rey,       w: 0.3, h: 0.4), bodyLow)

        // 8. 眼睛
        if !isBlinking {
            paint(FomoRect(x: Self.leftEye.x  + eyeLookX, y: Self.leftEye.y,  w: Self.leftEye.w,  h: Self.leftEye.h), eyeFill)
            paint(FomoRect(x: Self.rightEye.x + eyeLookX, y: Self.rightEye.y, w: Self.rightEye.w, h: Self.rightEye.h), eyeFill)
            // 眼睛白点高光
            paint(FomoRect(x: Self.leftEye.x  + 0.5 + eyeLookX, y: Self.leftEye.y  + 0.2, w: 0.3, h: 0.4), highlight)
            paint(FomoRect(x: Self.rightEye.x + 0.5 + eyeLookX, y: Self.rightEye.y + 0.2, w: 0.3, h: 0.4), highlight)
        } else {
            // 闭眼 —— 0.2pt 高的横线（眯眼弧线感）
            paint(FomoRect(x: Self.leftEye.x,  y: Self.leftEye.y  + 0.45, w: Self.leftEye.w,  h: 0.2), eyeFill)
            paint(FomoRect(x: Self.rightEye.x, y: Self.rightEye.y + 0.45, w: Self.rightEye.w, h: 0.2), eyeFill)
        }

        // 9. 鼻
        paint(Self.nose, pinkFill)
    }
}

/// 像素矩形定义 —— 跟 ClawdRect 同款，纯几何（无方法）
private struct FomoRect {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
}

// MARK: - 灵动岛左耳 wrapper

/// 灵动岛左耳的 fomo sprite。工作中 = sprite 整体上移 1pt + 切 armsUp pose（耳朵收下，"求救"感）
@MainActor
struct FomoIslandSprite: View {
    let isWorking: Bool
    let size: CGFloat
    var palette: PetPalette = .fomoDefault
    var animated: Bool = true

    var body: some View {
        FomoView(
            pose: isWorking ? .armsUp : .rest,
            height: size,
            isWalking: isWorking,
            palette: palette,
            animated: animated
        )
        .offset(y: isWorking ? -1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isWorking)
    }
}
