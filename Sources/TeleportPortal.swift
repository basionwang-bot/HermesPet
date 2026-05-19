import SwiftUI

/// 桌宠传送门 —— 像素艺术风格圆形门。
///
/// 出现场景：桌宠 chasing 鼠标 / patrol 目标位于灵动岛另一侧时，触发 0.6s 传送动画：
///   阶段 1（0.0-0.2s 出发侧开门）：原地门从 scale 0 弹开 → scale 1，桌宠淡出 + 缩小
///   阶段 2（0.2s 瞬移）：portal NSWindow 跟桌宠 NSWindow 一起 setFrameOrigin 到目标位置
///   阶段 3（0.2-0.4s 到达侧）：目标位置同款门继续保持 scale 1，桌宠淡入 + 放大复原
///   阶段 4（0.4-0.6s 关门）：门 scale 1 → 0 收掉
///
/// 视觉设计（pixel art 风格 viewBox ≈ 24×24）：
///   - 外圈：4 个 mode 主色像素小方块沿圆周顺时针旋转（最外圈光晕）
///   - 门框：8 个 mode 主色像素方块组成八边形，呼吸 ±0.06 opacity
///   - 内部：纯黑底 + 4 颗白色像素小星按四角对角旋转（虫洞感）
///   - 中心：1 颗 mode 主色像素方块作"奇点"
@MainActor
@Observable
final class TeleportPortalState {
    /// 当前展开进度 0~1：0=未出现，1=完全展开。controller 用 withAnimation 改这个值驱动 SwiftUI
    var openness: Double = 0
    /// 门主色（跟桌宠 mode 主色一致）
    var tintColor: Color = .indigo
}

struct TeleportPortalView: View {
    @Bindable var state: TeleportPortalState
    /// 内部旋转动画相位（自驱动，0~1 循环）
    @State private var rotation: Double = 0

    var body: some View {
        // 性能优化：传送门收起来时（openness 接近 0）停掉 TimelineView。
        // 之前 paused: false 让 Canvas 永远 30fps 跑 sin/cos/Path，即使 .opacity(0) 视觉不可见。
        // 桌宠没在传送时整天空跑动画占 CPU。openness 阈值用 0.01 给 spring 动画收尾留余量。
        TimelineView(.animation(minimumInterval: 1.0/30.0, paused: state.openness < 0.01)) { context in
            Canvas { ctx, size in
                drawPortal(in: &ctx, size: size, t: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .scaleEffect(state.openness)
        .opacity(state.openness)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: state.openness)
    }

    /// 画一帧像素艺术门
    /// - t 用作旋转 phase 输入（30fps 自驱动）
    private func drawPortal(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let cx = size.width / 2
        let cy = size.height / 2

        // 每个像素的实际渲染大小 —— 让门看起来"是 24x24 像素艺术"
        let pixel = min(size.width, size.height) / 24.0
        let baseR = min(size.width, size.height) * 0.42      // 门框半径
        let outerR = min(size.width, size.height) * 0.50     // 外圈光晕半径

        // —— 内部黑底圆 ——
        let innerR = baseR - pixel
        let innerRect = CGRect(x: cx - innerR, y: cy - innerR,
                                width: innerR * 2, height: innerR * 2)
        ctx.fill(Path(ellipseIn: innerRect), with: .color(.black.opacity(0.92)))

        // —— 门框：8 个像素方块组成八边形 ——
        // 8 个固定角度，每帧用 t 控制呼吸 opacity
        let breathe = 0.78 + 0.22 * sin(t * 4.5)
        for i in 0..<8 {
            let theta = Double(i) * .pi / 4.0
            let x = cx + cos(theta) * baseR
            let y = cy + sin(theta) * baseR
            let rect = CGRect(x: x - pixel/2, y: y - pixel/2,
                              width: pixel * 1.2, height: pixel * 1.2)
            ctx.fill(Path(rect), with: .color(state.tintColor.opacity(breathe)))
        }

        // —— 外圈：4 个 mode 主色像素方块顺时针旋转 ——
        let outerPhase = t * 1.4   // rad/s
        for i in 0..<4 {
            let theta = outerPhase + Double(i) * .pi / 2.0
            let x = cx + cos(theta) * outerR
            let y = cy + sin(theta) * outerR
            let rect = CGRect(x: x - pixel/2, y: y - pixel/2,
                              width: pixel * 1.1, height: pixel * 1.1)
            ctx.fill(Path(rect), with: .color(state.tintColor.opacity(0.45)))
        }

        // —— 内部：4 颗白色像素小星，对角逆时针旋转（虫洞感） ——
        let starR = baseR * 0.45
        let starPhase = -t * 2.8
        for i in 0..<4 {
            let theta = starPhase + Double(i) * .pi / 2.0 + .pi / 4.0
            let x = cx + cos(theta) * starR
            let y = cy + sin(theta) * starR
            let rect = CGRect(x: x - pixel/2, y: y - pixel/2,
                              width: pixel, height: pixel)
            ctx.fill(Path(rect), with: .color(.white.opacity(0.85)))
        }

        // —— 中心奇点：1 颗 mode 主色像素方块 ——
        let coreRect = CGRect(x: cx - pixel/2, y: cy - pixel/2,
                               width: pixel, height: pixel)
        ctx.fill(Path(coreRect), with: .color(state.tintColor))
    }
}
