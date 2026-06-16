import SwiftUI

/// 「全量模式」(AI 公司舰队) 输入栏通电特效 —— 学 Claude Code ultracode 的"火力全开"质感。
///
/// 视觉:紫色像素方块从输入栏底边中心向外一圈圈"涌"出来(方块涟漪)+ 一颗高亮方块沿描边游走 +
/// 整圈描边底光呼吸。只在 active(=pendingFleet) 时点亮。
///
/// 决策守约(照 TeleportPortal 范式):
///   - 纯 Canvas 自绘,Canvas 的 `size` 自带本视图尺寸,**不套 GeometryReader**(决策 #21)
///   - 只当输入栏 `.background` 的一层,`.clipShape` 锁在圆角内,绝不撑大父视图/反推窗口 frame(决策 #6/#1)
///   - `allowsHitTesting(false)` 不抢点击;TimelineView `paused:` 在熄灭 / quietMode 时停帧,空跑不耗 CPU(决策 #5 无 isolation 风险)
struct FleetInputCharge: View {
    /// 是否点亮(= pendingFleet)。false 时整体淡出且 TimelineView 停帧。
    var active: Bool
    /// 输入栏当前圆角(跟 inputRow 的 cornerRadius 同步)
    var cornerRadius: CGFloat
    /// 主色 —— 跟随当前 mode（由调用方传入），默认舰队紫兜底。
    var tint: Color = Color(hex: "#7C6CFF") ?? .purple

    // 注意：全量模式特效**不受 quietMode 影响** —— 它是"进入强力模式"的明确指示，
    // 不是桌宠 ambient 动效，所以只要 active 就一直动（用户明确要求）。
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            Canvas { ctx, size in
                drawCharge(in: &ctx, size: size, t: context.date.timeIntervalSinceReferenceDate)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: active)
        .allowsHitTesting(false)
    }

    /// 画一帧。坐标全用传入 size 自算,不读外部几何。
    private func drawCharge(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let w = size.width, h = size.height
        guard w > 1, h > 1 else { return }

        let breath = (sin(t * 2 * .pi / 1.6) + 1) / 2          // 1.6s 主呼吸
        let cell: CGFloat = 7                                  // 像素方块边长

        // 层 1:方块涟漪 —— 从底边中心向外一圈圈扩散
        let originX = w / 2, originY = h
        let waveSpeed: CGFloat = 46, waveLen: CGFloat = 34
        var x: CGFloat = cell / 2
        while x < w {
            var y: CGFloat = cell / 2
            while y < h {
                let dx = x - originX, dy = y - originY
                let dist = sqrt(dx * dx + dy * dy)
                let phase = (dist - CGFloat(t) * waveSpeed) / waveLen
                let wave = (sin(Double(phase) * 2 * .pi) + 1) / 2
                if wave > 0.62 {
                    let edgeBoost = min(1, dist / (h * 1.1))
                    let a = (wave - 0.62) / 0.38 * (0.16 + 0.22 * edgeBoost) * (0.6 + 0.4 * breath)
                    let r = CGRect(x: x - cell/2 + 0.5, y: y - cell/2 + 0.5, width: cell - 1, height: cell - 1)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(tint.opacity(a)))
                }
                y += cell
            }
            x += cell
        }

        // 层 2:沿描边游走的高亮方块(带拖尾)
        let perim = 2 * (w + h)
        let travel = (CGFloat(t) * 0.35).truncatingRemainder(dividingBy: 1) * perim   // 0.35 圈/s
        let segCount = 7
        for i in 0..<segCount {
            let raw = travel - CGFloat(i) * cell * 1.6
            let p = raw < 0 ? raw + perim : raw
            let pt = pointOnPerimeter(p: p, w: w, h: h)
            let trail = 1 - Double(i) / Double(segCount)
            let r = CGRect(x: pt.x - cell/2, y: pt.y - cell/2, width: cell, height: cell)
            ctx.fill(Path(roundedRect: r, cornerRadius: 1.5),
                     with: .color(tint.opacity(0.5 * trail * (0.7 + 0.3 * breath))))
        }

        // 层 3:整圈描边底光
        let border = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius)
        ctx.stroke(border, with: .color(tint.opacity(0.22 + 0.18 * breath)), lineWidth: 1)
    }

    /// 0..<周长 的标量 → 圆角矩形边界点(简化成直角矩形周长采样,圆角处误差几 pt 肉眼无感)。
    private func pointOnPerimeter(p: CGFloat, w: CGFloat, h: CGFloat) -> CGPoint {
        let top = w, right = h, bottom = w
        if p < top { return CGPoint(x: p, y: 0) }
        if p < top + right { return CGPoint(x: w, y: p - top) }
        if p < top + right + bottom { return CGPoint(x: w - (p - top - right), y: h) }
        return CGPoint(x: 0, y: h - (p - top - right - bottom))
    }
}
