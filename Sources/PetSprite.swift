import SwiftUI

// MARK: - 成长阶段（蛋 → 幼年 → 壮年 → 成年）
//
// 数码暴龙机式的「养成进化」第一条主线。形象=**纯代码自绘的像素 sprite**（守决策 #2），
// 用圆/椭圆这类「天生可爱」的几何积木精心搭出造型，再栅格化成低分辨率像素网格。
//
// 像素手法借鉴自数码暴龙机官方点阵图集（**只学方法、不搬其版权造型**）：
//   A. 三阶立体明暗（亮顶/中身/暗底，拉大色阶 → 体积感）；
//   B. 2 帧待机（呼吸浮动 + 眨眼）；
//   C. 情绪上脸（PetMood → 开心张嘴/累了眯眼/想你掉泪）；
//   D. 分件描边（高阶耳/尾用暗线和身体分开）。

enum PetGrowthStage: Int, CaseIterable {
    case egg = 0    // 蛋
    case baby       // 幼年期
    case prime      // 壮年期
    case adult      // 成年期

    var titleKey: String {
        switch self {
        case .egg:   return "pet.stage.egg"
        case .baby:  return "pet.stage.baby"
        case .prime: return "pet.stage.prime"
        case .adult: return "pet.stage.adult"
        }
    }

    var minLevel: Int {
        switch self {
        case .egg:   return 1
        case .baby:  return 2
        case .prime: return 4
        case .adult: return 7
        }
    }

    static func from(level: Int) -> PetGrowthStage {
        switch level {
        case ..<2:   return .egg
        case 2...3:  return .baby
        case 4...6:  return .prime
        default:     return .adult
        }
    }

    var next: PetGrowthStage? { PetGrowthStage(rawValue: rawValue + 1) }
}

/// 表情（由 PetMood + 眨眼推算）。
enum PetFace { case normal, happy, tired, lonely, blink }

// MARK: - 调色板（薄荷萌物；配色种子换这层即可个性化）

struct PetSpritePalette {
    static let empty = -1
    static let outline = 0, body = 1, bodyLight = 2, bodyShadow = 3
    static let belly = 4, eye = 5, sparkle = 6, cheek = 7, accent = 8, feet = 9
    static let shell = 10, shellShadow = 11, tear = 12

    let colors: [Color]

    func color(forSlot slot: Int) -> Color? {
        guard slot >= 0, slot < colors.count else { return nil }
        return colors[slot]
    }

    static let mint = PetSpritePalette(colors: [
        Color(red: 0.13, green: 0.19, blue: 0.24),  // outline
        Color(red: 0.39, green: 0.80, blue: 0.72),  // body
        Color(red: 0.75, green: 0.99, blue: 0.91),  // bodyLight（拉亮，明暗拉开做体积）
        Color(red: 0.19, green: 0.52, blue: 0.48),  // bodyShadow（压暗）
        Color(red: 0.97, green: 0.99, blue: 0.94),  // belly
        Color(red: 0.12, green: 0.15, blue: 0.19),  // eye
        Color(red: 1.00, green: 1.00, blue: 1.00),  // sparkle
        Color(red: 1.00, green: 0.60, blue: 0.62),  // cheek
        Color(red: 1.00, green: 0.83, blue: 0.40),  // accent
        Color(red: 0.27, green: 0.62, blue: 0.57),  // feet
        Color(red: 0.98, green: 0.95, blue: 0.86),  // shell
        Color(red: 0.85, green: 0.80, blue: 0.66),  // shellShadow
        Color(red: 0.55, green: 0.80, blue: 0.98),  // tear
    ])
}

// MARK: - 像素网格（几何积木 → 栅格化）

struct PixelGrid {
    let n: Int
    var cells: [Int]

    init(_ n: Int) {
        self.n = n
        self.cells = Array(repeating: PetSpritePalette.empty, count: n * n)
    }

    private func idx(_ x: Int, _ y: Int) -> Int { y * n + x }
    private func inBounds(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < n && y >= 0 && y < n }
    func get(_ x: Int, _ y: Int) -> Int { inBounds(x, y) ? cells[idx(x, y)] : PetSpritePalette.empty }
    mutating func set(_ x: Int, _ y: Int, _ s: Int) { if inBounds(x, y) { cells[idx(x, y)] = s } }

    mutating func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ s: Int) {
        let minX = max(0, Int((cx - rx).rounded(.down))), maxX = min(n - 1, Int((cx + rx).rounded(.up)))
        let minY = max(0, Int((cy - ry).rounded(.down))), maxY = min(n - 1, Int((cy + ry).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = (Double(x) - cx) / rx
                let dy = (Double(y) - cy) / ry
                if dx * dx + dy * dy <= 1.0 { set(x, y, s) }
            }
        }
    }

    mutating func disc(_ cx: Double, _ cy: Double, _ r: Double, _ s: Int) { ellipse(cx, cy, r, r, s) }

    mutating func addOutline(_ s: Int) {
        var add = [Int]()
        for y in 0..<n {
            for x in 0..<n {
                if get(x, y) != PetSpritePalette.empty { continue }
                var near = false
                outer: for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let v = get(x + dx, y + dy)
                        if v != PetSpritePalette.empty && v != s { near = true; break outer }
                    }
                }
                if near { add.append(idx(x, y)) }
            }
        }
        for i in add { cells[i] = s }
    }

    func rows() -> [[Int]] {
        (0..<n).map { y in (0..<n).map { x in cells[idx(x, y)] } }
    }
}

// MARK: - 四阶段造型配方（含 A 立体明暗 / C 情绪脸 / D 分件描边）

enum PetSprite {
    static let canvas = 32

    static func grid(for stage: PetGrowthStage, face: PetFace = .normal) -> [[Int]] {
        var g = PixelGrid(canvas)
        switch stage {
        case .egg:   buildEgg(&g)
        case .baby:  buildBaby(&g, face)
        case .prime: buildPrime(&g, face)
        case .adult: buildAdult(&g, face)
        }
        g.addOutline(PetSpritePalette.outline)
        return g.rows()
    }

    // A. 三阶立体明暗圆身：暗全填 → 中色上移留底影 → 亮色压左上 = 球体体积
    private static func shadedBlob(_ g: inout PixelGrid, _ cx: Double, _ cy: Double, _ r: Double) {
        let P = PetSpritePalette.self
        g.disc(cx, cy, r, P.bodyShadow)
        g.disc(cx, cy - r * 0.10, r * 0.90, P.body)
        g.disc(cx - r * 0.24, cy - r * 0.30, r * 0.52, P.bodyLight)
    }

    // C. 情绪眼
    private static func drawEyes(_ g: inout PixelGrid, _ lx: Double, _ rx: Double, _ y: Double, _ r: Double, _ face: PetFace) {
        let P = PetSpritePalette.self
        switch face {
        case .normal, .happy:
            for cx in [lx, rx] {
                g.disc(cx, y, r, P.eye)
                g.disc(cx - r * 0.30, y - r * 0.32, r * 0.44, P.sparkle)
            }
        case .blink:   // 闭眼上弯弧 ‿（俏皮）
            for cx in [lx, rx] {
                let w = Int(r.rounded())
                for dx in -w...w { g.set(Int(cx.rounded()) + dx, Int(y.rounded()), P.eye) }
                g.set(Int((cx - Double(w)).rounded()), Int(y.rounded()) - 1, P.eye)
                g.set(Int((cx + Double(w)).rounded()), Int(y.rounded()) - 1, P.eye)
            }
        case .tired:   // 半眯：矮扁眼 + 上眼皮一道
            for cx in [lx, rx] {
                g.ellipse(cx, y + r * 0.28, r, r * 0.55, P.eye)
                g.disc(cx - r * 0.30, y + r * 0.10, r * 0.30, P.sparkle)
                let w = Int(r.rounded())
                for dx in -w...w { g.set(Int(cx.rounded()) + dx, Int((y - r * 0.45).rounded()), P.eye) }
            }
        case .lonely:  // 小眼下垂 + 一滴泪
            for cx in [lx, rx] {
                g.disc(cx, y + r * 0.15, r * 0.66, P.eye)
                g.disc(cx - r * 0.22, y - r * 0.06, r * 0.28, P.sparkle)
            }
            g.disc(lx - r * 0.5, y + r * 1.0, 0.9, P.tear)
        }
    }

    // C. 情绪嘴（closedBaby=true 用小微笑，否则猫嘴 ω）
    private static func drawMouth(_ g: inout PixelGrid, _ x: Int, _ y: Int, closedBaby: Bool, face: PetFace) {
        let e = PetSpritePalette.eye
        switch face {
        case .normal, .blink:
            if closedBaby { g.set(x - 1, y, e); g.set(x, y + 1, e); g.set(x + 1, y, e) }
            else { g.set(x - 2, y, e); g.set(x - 1, y + 1, e); g.set(x, y, e); g.set(x + 1, y + 1, e); g.set(x + 2, y, e) }
        case .happy:   // 张嘴笑 + 粉舌
            g.set(x - 1, y, e); g.set(x, y, e); g.set(x + 1, y, e)
            g.set(x - 1, y + 1, e); g.set(x + 1, y + 1, e)
            g.set(x, y + 1, PetSpritePalette.cheek)
        case .tired:   // 平嘴
            g.set(x - 1, y, e); g.set(x, y, e); g.set(x + 1, y, e)
        case .lonely:  // 小 ∧ 抿嘴
            g.set(x - 1, y + 1, e); g.set(x, y, e); g.set(x + 1, y + 1, e)
        }
    }

    private static func buildEgg(_ g: inout PixelGrid) {
        let P = PetSpritePalette.self
        g.ellipse(16, 18, 9, 11, P.shellShadow)
        g.ellipse(15.4, 17.2, 8.6, 10.6, P.shell)
        g.disc(12.5, 11, 1.6, P.sparkle)
        g.disc(12, 14, 2.0, P.body)
        g.disc(20, 17, 1.8, P.body)
        g.disc(15, 23, 2.2, P.body)
        g.disc(19.5, 23, 1.4, P.body)
    }

    private static func buildBaby(_ g: inout PixelGrid, _ face: PetFace) {
        let P = PetSpritePalette.self
        shadedBlob(&g, 16, 19, 7)
        g.ellipse(16, 21, 4.2, 3.2, P.belly)
        g.set(16, 12, P.bodyShadow); g.set(16, 11, P.bodyShadow)
        g.disc(16, 9.5, 1.4, P.accent)
        drawEyes(&g, 12.5, 19.5, 18, 2.4, face)
        g.disc(10.5, 20.5, 1.5, P.cheek)
        g.disc(21.5, 20.5, 1.5, P.cheek)
        drawMouth(&g, 16, 21, closedBaby: true, face: face)
    }

    private static func buildPrime(_ g: inout PixelGrid, _ face: PetFace) {
        let P = PetSpritePalette.self
        g.disc(10.5, 10, 2.8, P.body)
        g.disc(21.5, 10, 2.8, P.body)
        g.disc(10.5, 10.5, 1.3, P.cheek)
        g.disc(21.5, 10.5, 1.3, P.cheek)
        shadedBlob(&g, 16, 18, 8)
        g.ellipse(16, 20.5, 5, 4, P.belly)
        g.ellipse(10.5, 12.4, 1.8, 0.8, P.bodyShadow)   // D 耳根分件
        g.ellipse(21.5, 12.4, 1.8, 0.8, P.bodyShadow)
        drawEyes(&g, 12.0, 20.0, 17, 2.7, face)
        g.disc(16, 19.8, 0.9, P.cheek)
        drawMouth(&g, 16, 21, closedBaby: false, face: face)
        g.disc(8.5, 19.5, 1.7, P.cheek)
        g.disc(23.5, 19.5, 1.7, P.cheek)
        g.disc(12.5, 26, 2.0, P.feet)
        g.disc(19.5, 26, 2.0, P.feet)
        g.disc(25, 22, 2.2, P.body)
        g.disc(26.5, 20.5, 1.6, P.body)
        g.ellipse(23.6, 22.6, 0.8, 1.4, P.bodyShadow)   // D 尾根分件
    }

    private static func buildAdult(_ g: inout PixelGrid, _ face: PetFace) {
        let P = PetSpritePalette.self
        g.disc(9.5, 8.5, 3.3, P.body)
        g.disc(22.5, 8.5, 3.3, P.body)
        g.disc(9.5, 9, 1.6, P.cheek)
        g.disc(22.5, 9, 1.6, P.cheek)
        g.disc(9.5, 5.6, 1.0, P.accent)
        g.disc(22.5, 5.6, 1.0, P.accent)
        shadedBlob(&g, 16, 18, 9)
        g.ellipse(16, 20.5, 5.6, 5, P.belly)
        g.ellipse(9.5, 11.0, 2.0, 0.9, P.bodyShadow)    // D 耳根分件
        g.ellipse(22.5, 11.0, 2.0, 0.9, P.bodyShadow)
        g.disc(16, 11.5, 1.5, P.accent)
        g.set(15, 11, P.sparkle)
        drawEyes(&g, 11.8, 20.2, 16.5, 2.9, face)
        g.disc(16, 19.8, 1.0, P.cheek)
        drawMouth(&g, 16, 21, closedBaby: false, face: face)
        g.disc(7.5, 18.5, 1.9, P.cheek)
        g.disc(24.5, 18.5, 1.9, P.cheek)
        g.disc(11.5, 27, 2.2, P.feet)
        g.disc(20.5, 27, 2.2, P.feet)
        g.disc(26, 21, 2.2, P.body)
        g.disc(27.5, 23, 1.8, P.body)
        g.disc(26.5, 25, 1.8, P.body)
        g.ellipse(24.4, 21.4, 0.9, 1.6, P.bodyShadow)   // D 尾根分件
    }
}

// MARK: - 渲染视图（B 待机动画：呼吸浮动 + 眨眼 / C 情绪上脸）

/// 把某个成长阶段画出来 + 让它活起来。
/// ⚠️ 守记忆 [[feedback_pixel_art_swiftui]]：像素图**绝不挂 scaleEffect**（插值变糊），
/// 呼吸只用 `.offset`（位移不重采样）；眨眼/情绪靠换网格（Canvas 重绘，开销极小）。
struct PetSpriteView: View {
    let stage: PetGrowthStage
    var mood: PetMood = .neutral
    var palette: PetSpritePalette = .mint
    var size: CGFloat = 168
    var animated: Bool = true

    @State private var bobUp = false
    @State private var blink = false

    private var face: PetFace {
        // 只有"睁眼"的心情才会眨眼；累/想你本就眯眼，不再叠加
        if blink, mood == .happy || mood == .content || mood == .neutral { return .blink }
        switch mood {
        case .happy:   return .happy
        case .content: return .normal
        case .neutral: return .normal
        case .tired:   return .tired
        case .lonely:  return .lonely
        }
    }

    var body: some View {
        let n = PetSprite.canvas
        let grid = PetSprite.grid(for: stage, face: face)
        let cell = size / CGFloat(n)

        Canvas { ctx, _ in
            for r in 0..<n {
                for c in 0..<n {
                    guard let color = palette.color(forSlot: grid[r][c]) else { continue }
                    let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                      width: cell + 0.6, height: cell + 0.6)  // +0.6 消除像素缝
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
        .offset(y: animated ? (bobUp ? -4 : 1) : 0)   // 呼吸浮动（offset 不重采样，像素不糊）
        .shadow(color: .black.opacity(0.28), radius: 6, y: 6)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bobUp = true }
        }
        .task(id: animated) { if animated { await blinkLoop() } }
    }

    /// 每隔 2.6~4.2s 眨一下眼（140ms）。只在眨眼瞬间重绘，开销极小。
    private func blinkLoop() async {
        while !Task.isCancelled {
            let gap = UInt64.random(in: 2_600_000_000...4_200_000_000)
            try? await Task.sleep(nanoseconds: gap)
            if Task.isCancelled { return }
            blink = true
            try? await Task.sleep(nanoseconds: 140_000_000)
            blink = false
        }
    }
}

// MARK: - 养成档案 → 阶段 / 战斗力 派生值

extension PetProgress {
    var growthStage: PetGrowthStage { PetGrowthStage.from(level: level) }

    var battlePower: Int {
        totalExp + stats.tasksSucceeded * 12 + stats.toolsUsed * 3 + max(0, level - 1) * 50
    }
}
