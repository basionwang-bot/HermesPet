import SwiftUI

// MARK: - 在线 AI（directAPI）：红色小怪兽 —— HermesPet Core 吉祥物
//
// 移植自 Windows 版 `Monster.tsx`，严格照官方《角色设计分析》像素规范复刻：
// - 8-bit 像素风，圆顶大头(~70%) + 简化身体 + 4 条短腿 + 无手臂无脖子
// - 眼睛（关键识别点）：2×6 竖矩形 #111 + 左上角 1px 白高光，冷静/专注的非拟人表情
// - 左上光源体积明暗：主 / 高光(顶左缘) / 阴影(右缘) / 深阴影(底缘)，4 色从 palette 派生
// 默认色 = Win 版同款官方红 #FF4A1A（见 PetPalette.monsterDefault）。
// 形象 100% 自家手画，不使用任何第三方 AGPL 资产。

/// 在线 AI 的灵动岛精灵 —— 红色小怪兽。
/// pose 驱动：idle 偶尔左右张望；working 抬头 + 快速张望 + 轻跳，表达"在忙着到处看"。
struct MonsterIslandSprite: View {
    let isWorking: Bool
    let size: CGFloat
    /// 调色板 —— 默认 Win 同款红，用户自定义后由调用方传入
    var palette: PetPalette = .monsterDefault
    /// 是否启用内部 Canvas 30fps 动画。false 时画静态帧（pose 变化仍会触发一次重绘）
    var animated: Bool = true
    /// QwenCode 变体：戴黑框眼镜（跟在线 AI 的红怪兽区别开）
    var wearsGlasses: Bool = false

    @State private var pose: ClawdPose = .rest
    @State private var workingTask: Task<Void, Never>?
    @State private var lookTask: Task<Void, Never>?

    var body: some View {
        MonsterPixelView(pose: pose, height: size * 1.15, isWorking: isWorking,
                         palette: palette, animated: animated, wearsGlasses: wearsGlasses)
            .onAppear { applyState(isWorking) }
            .onChange(of: isWorking) { _, w in applyState(w) }
            .onDisappear { workingTask?.cancel(); lookTask?.cancel() }
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

    /// working：抬头 → 静 → 看左 → 看右 循环（怪兽无手臂，靠头/眼朝向 + 轻跳表达"在忙"）
    private func startWorking() {
        workingTask?.cancel()
        workingTask = Task { @MainActor in
            let frames: [(ClawdPose, UInt64)] = [
                (.armsUp,    300_000_000),
                (.rest,      200_000_000),
                (.lookLeft,  260_000_000),
                (.lookRight, 260_000_000),
            ]
            while !Task.isCancelled {
                for (p, d) in frames {
                    pose = p
                    try? await Task.sleep(nanoseconds: d)
                    if Task.isCancelled { return }
                }
            }
        }
    }

    /// idle：每 20~40s 随机往一侧瞄一眼，0.6s 后回正
    private func startIdleLook() {
        lookTask?.cancel()
        lookTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 20_000_000_000...40_000_000_000))
                if Task.isCancelled { return }
                pose = Bool.random() ? .lookLeft : .lookRight
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { return }
                pose = .rest
            }
        }
    }
}

/// 红色小怪兽像素渲染器 —— 20×18 网格，Canvas 自绘。呼吸 / 眨眼 / 眼睛朝向(look) / working 轻跳。
struct MonsterPixelView: View {
    let pose: ClawdPose
    let height: CGFloat
    var isWorking: Bool = false
    var palette: PetPalette = .monsterDefault
    var animated: Bool = true
    /// QwenCode 变体：戴黑框眼镜（跟在线 AI 的红怪兽区别开）
    var wearsGlasses: Bool = false
    /// 休息态降帧（见 SpriteFrameIntervalKey）
    @Environment(\.spriteFrameInterval) private var spriteFrameInterval

    private static let W = 20
    private static let H = 18

    /// 圆顶大头每行填充列区间 [lo,hi]（rows 0..15，上窄下宽）—— 与 Win Monster.tsx 逐行一致
    private static let headSpans: [(Int, Int)] = [
        (6, 13), (4, 15), (3, 16), (2, 17), (1, 18), (1, 18), (0, 19), (0, 19),
        (0, 19), (0, 19), (0, 19), (0, 19), (0, 19), (0, 19), (0, 19), (0, 19)
    ]
    /// 4 条短腿（rows 16,17），居中对称
    private static let legSpans: [(Int, Int)] = [(1, 3), (6, 8), (11, 13), (16, 18)]

    /// 填充网格（只算一次）
    private static let filled: [[Bool]] = {
        var f = Array(repeating: Array(repeating: false, count: W), count: H)
        for (y, span) in headSpans.enumerated() {
            for x in span.0...span.1 { f[y][x] = true }
        }
        for span in legSpans {
            for x in span.0...span.1 { f[16][x] = true; f[17][x] = true }
        }
        return f
    }()
    /// 每列最上 / 最下填充行（顶高光 / 底深阴影用）
    private static let colTop: [Int] = {
        var a = Array(repeating: -1, count: W)
        for x in 0..<W { for y in 0..<H where Self.filled[y][x] && a[x] < 0 { a[x] = y } }
        return a
    }()
    private static let colBottom: [Int] = {
        var a = Array(repeating: -1, count: W)
        for x in 0..<W { for y in 0..<H where Self.filled[y][x] { a[x] = y } }
        return a
    }()
    /// 每行最左 / 最右填充列（左高光 / 右阴影用）
    private static let rowLeft: [Int] = {
        var a = Array(repeating: -1, count: H)
        for y in 0..<H { for x in 0..<W where Self.filled[y][x] && a[y] < 0 { a[y] = x } }
        return a
    }()
    private static let rowRight: [Int] = {
        var a = Array(repeating: -1, count: H)
        for y in 0..<H { for x in 0..<W where Self.filled[y][x] { a[y] = x } }
        return a
    }()

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: spriteFrameInterval)) { timeline in
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                .id(spriteFrameInterval > 1.0 / 20.0)
            } else {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    draw(ctx: ctx, size: size, now: 0)
                }
            }
        }
        .frame(width: height * CGFloat(Self.W) / CGFloat(Self.H), height: height)
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: TimeInterval) {
        let w = Self.W, h = Self.H
        let unit = min(size.width / CGFloat(w), size.height / CGFloat(h))

        // 4 色（每帧算一次，从主色派生）：
        //  - 高光走「混白」而非加亮度 —— 官方红 #FF4A1A 亮度已满，单纯加亮度不变色
        //  - 阴影 / 深阴影走降亮度
        let cMain   = palette.primary
        let cHi     = palette.primary.mixed(with: .white, by: 0.22)
        let cShadow = palette.primary.darkened(by: 0.14)
        let cDeep   = palette.primary.darkened(by: 0.32)
        let shMain   = GraphicsContext.Shading.color(cMain)
        let shHi     = GraphicsContext.Shading.color(cHi)
        let shShadow = GraphicsContext.Shading.color(cShadow)
        let shDeep   = GraphicsContext.Shading.color(cDeep)

        // 呼吸：整体上下浮 ±0.4 单位（纯平移、不缩放，避免像素插值变糊）
        let breatheT = animated ? sin(now * 2 * .pi / 3.4) : 0
        var offY = CGFloat(breatheT) * 0.4
        // working：叠一个向上小跳
        if isWorking && animated {
            offY -= CGFloat(abs(sin(now * 2 * .pi / 0.55))) * 0.8
        }

        // 一个像素格（+0.5 弥合接缝，同 Win 版 CELL+0.4）
        func cell(_ x: Int, _ y: Int, _ shading: GraphicsContext.Shading) {
            let rx = CGFloat(x) * unit
            let ry = (CGFloat(y) + offY) * unit
            ctx.fill(Path(CGRect(x: rx, y: ry, width: unit + 0.5, height: unit + 0.5)), with: shading)
        }

        // 身体（左上光源体积明暗：底缘=深阴影 / 右缘=阴影 / 顶或左缘=高光 / 其余=主色）
        for y in 0..<h {
            for x in 0..<w where Self.filled[y][x] {
                let shading: GraphicsContext.Shading
                if y == Self.colBottom[x] { shading = shDeep }
                else if x >= Self.rowRight[y] - 1 { shading = shShadow }
                else if y == Self.colTop[x] || x == Self.rowLeft[y] { shading = shHi }
                else { shading = shMain }
                cell(x, y, shading)
            }
        }

        // —— 眼睛（关键识别点）——
        let eyeFill = GraphicsContext.Shading.color(Color(red: 0.067, green: 0.067, blue: 0.067)) // #111
        let hlFill  = GraphicsContext.Shading.color(.white)

        // 眼睛朝向偏移（按 pose）
        let (lx, ly): (CGFloat, CGFloat) = {
            switch pose {
            case .lookLeft:  return (-1.3, 0)
            case .lookRight: return ( 1.3, 0)
            case .armsUp:    return ( 0, -1.3)   // 抬头看上
            case .rest:      return ( 0, 0)
            }
        }()
        // 眨眼：每 4.5s 末尾 ~0.2s 闭眼
        let blinkPhase = now.truncatingRemainder(dividingBy: 4.5) / 4.5
        let closed = animated && blinkPhase > 0.95

        let eyeW: CGFloat = 2, eyeH: CGFloat = 5, eyeTop: CGFloat = 6
        func drawEye(_ xCells: CGFloat) {
            if closed {
                // 闭眼：一条圆头横线
                let cy = (eyeTop + eyeH / 2 + offY) * unit
                let rect = CGRect(x: xCells * unit, y: cy - 1.4, width: eyeW * unit + unit, height: 2.8)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.4), with: eyeFill)
                return
            }
            let ex = (xCells + lx) * unit
            let ey = (eyeTop + ly + offY) * unit
            let rect = CGRect(x: ex, y: ey, width: eyeW * unit + 0.5, height: eyeH * unit + 0.5)
            ctx.fill(Path(roundedRect: rect, cornerRadius: unit * 0.35), with: eyeFill)
            // 左上角白高光
            let hl = unit * 0.7
            let hlRect = CGRect(x: ex + unit * 0.3, y: ey + unit * 0.3, width: hl, height: hl)
            ctx.fill(Path(roundedRect: hlRect, cornerRadius: unit * 0.2), with: hlFill)
        }
        drawEye(5)
        drawEye(13)

        // QwenCode 变体：黑框圆眼镜（罩在两只眼上，跟在线 AI 红怪兽区别开）
        if wearsGlasses {
            let gShade = GraphicsContext.Shading.color(Color(red: 0.10, green: 0.10, blue: 0.11))
            let gr: CGFloat = 2.7
            func ring(_ cx: CGFloat) {
                let r = CGRect(x: (cx - gr) * unit, y: (8.5 - gr + offY) * unit,
                               width: 2 * gr * unit, height: 2 * gr * unit)
                ctx.stroke(Path(ellipseIn: r), with: gShade, lineWidth: 0.6 * unit)
            }
            ring(6); ring(14)
            var bridge = Path()
            bridge.move(to: CGPoint(x: 8.7 * unit, y: (8.5 + offY) * unit))
            bridge.addLine(to: CGPoint(x: 11.3 * unit, y: (8.5 + offY) * unit))
            ctx.stroke(bridge, with: gShade, style: StrokeStyle(lineWidth: 0.55 * unit, lineCap: .round))
        }
    }
}
