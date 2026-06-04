import AppKit
import SwiftUI

/// Apple Intelligence 风格的全屏边缘光环。
/// 按住语音热键时显示，松开时淡出。
/// 配合系统音效，模拟 Siri 召唤的视觉听觉体验。
@MainActor
final class IntelligenceOverlayController {
    static let shared = IntelligenceOverlayController()

    private var window: NSWindow?
    /// 用 NSHostingController 而非 NSHostingView。
    /// NSHostingView 在 macOS 26 上即便 sizingOptions=[] 仍会通过 windowDidLayout →
    /// updateAnimatedWindowSize 反推 NSWindow.setFrame → 嵌套 layout → 死循环（issue #109）。
    /// NSHostingController 能真正禁掉该路径（DynamicIslandController 同一教训，见其 init 注释）。
    private var hostingController: NSHostingController<IntelligenceGlowView>?

    private init() {}

    func show() {
        if window == nil { createWindow() }
        // 同步把 window 移到当前主屏的 frame，多屏场景也对得上
        if let screen = NSScreen.main {
            window?.setFrame(screen.frame, display: false)
        }
        // 触发视图内 active = true 的 transition 动画
        hostingController?.rootView = IntelligenceGlowView(isActive: true)
        window?.orderFront(nil)

        // 召唤音效 —— 由 SoundManager 统一管理（用户可在设置选 / 关 / 换自定义音频文件）
        SoundManager.play(.voiceStart)
    }

    func hide() {
        // 触发淡出 transition；动画结束后真正 orderOut
        hostingController?.rootView = IntelligenceGlowView(isActive: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            // 如果在动画期间又 show 了，hostingController 已经是 active=true，就不 hide
            if self?.hostingController?.rootView.isActive == false {
                self?.window?.orderOut(nil)
            }
        }
    }

    private func createWindow() {
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 跟聊天窗同级（HermesWindowLevel.chat）—— 见 WindowLevels.swift 规范。
        // 不挡灵动岛麦克风脉冲是关键设计点。
        w.level = HermesWindowLevel.intelligence
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true          // 关键：让用户能正常操作底下的 app
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false

        let hosting = NSHostingController(rootView: IntelligenceGlowView(isActive: false))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }  // 决策 #6
        w.contentViewController = hosting

        self.window = w
        self.hostingController = hosting
    }
}

// MARK: - SwiftUI 光环视图

/// 屏幕边缘流动的 6 色 Apple Intelligence 光环。
/// isActive=true 时显示，false 时 fade out（用 transition 处理）。
struct IntelligenceGlowView: View {
    var isActive: Bool

    /// 主色环 6 个颜色，循环用 —— 直接照搬 SF System Colors
    private static let colors: [Color] = [
        Color(red: 1.00, green: 0.18, blue: 0.33),   // #FF2D55 systemPink
        Color(red: 1.00, green: 0.58, blue: 0.00),   // #FF9500 systemOrange
        Color(red: 1.00, green: 0.80, blue: 0.00),   // #FFCC00 systemYellow
        Color(red: 0.20, green: 0.78, blue: 0.35),   // #34C759 systemGreen
        Color(red: 0.35, green: 0.78, blue: 0.98),   // #5AC8FA systemTeal
        Color(red: 0.69, green: 0.32, blue: 0.87),   // #AF52DE systemPurple
        Color(red: 1.00, green: 0.18, blue: 0.33),   // 闭环回到粉红
    ]

    var body: some View {
        ZStack {
            if isActive {
                AnimatedGlow()
                    .transition(.opacity.combined(with: .scale(scale: 1.05)))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(AnimTok.smooth, value: isActive)
    }
}

/// 实际的光环渲染 —— Apple Intelligence 风格的"液态玻璃"连续彩虹光环。
///
/// **性能注意（issue #3 教训）**：之前用 `TimelineView(.animation)` + 4 层 AngularGradient +
/// 36-52pt 高斯模糊 + `.compositingGroup()` 全屏渲染，每帧让 GPU/CPU 重算整套合成，60Hz 屏
/// 主线程被 GraphHost.flushTransactions 钉死（sample 显示 1273/1273 都在 SwiftUI 布局，
/// 物理内存峰值 2.6 GB）。现在的版本：
///   - **TimelineView 改为固定 30Hz**（`.periodic(from: .now, by: 1/30)`）—— 视觉差异不大但
///     CPU/GPU 工作量直接减半
///   - **从 4 层降到 3 层**（删除最贵的"内反光"`.overlay` 层）
///   - **外层柔光 blur 从 36~52pt 收到 18~24pt** —— 大尺寸高斯模糊是 SwiftUI 渲染中最贵的
///     一类操作，半径减半 → 着色器 cost 减少约 4 倍
///   - **scaleEffect / compositingGroup 保留** —— 这俩本身不贵，能保住质感
private struct AnimatedGlow: View {

    private var colors: [Color] { IntelligenceGlowView.appleAIColors }

    var body: some View {
        GeometryReader { geo in
            // 30Hz 已足够呈现"液态玻璃"呼吸感（眼睛对边缘光晕的时间分辨率远低于硬边动画），
            // 且 sample 显示之前 60Hz 的 TimelineView 是高占用主因之一。
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate

                // 三个错相的呼吸函数（0~1）—— 用于驱动各层呼吸
                let breath    = (sin(t * 2 * .pi / 1.8) + 1) / 2              // 1.8s 主呼吸（颠颠感）
                let breathAlt = (sin(t * 2 * .pi / 2.6 + 1.3) + 1) / 2        // 2.6s 错相
                let breathSlow = (sin(t * 2 * .pi / 5.0 + 0.7) + 1) / 2       // 5.0s 慢呼吸（驱动 hue / cornerRadius）

                // ── 各层 lineWidth 呼吸 —— 厚度脉动
                let outerWidth: CGFloat = 24 + 28 * CGFloat(breath)           // 24~52
                let midWidth:   CGFloat = 12 + 14 * CGFloat(breathAlt)        // 12~26
                let innerWidth: CGFloat = 4  + 6  * CGFloat(breath)           // 4~10

                // ── 形状本身呼吸：圆角脉动让矩形涌动
                let outerCorner: CGFloat = 18 + 6 * CGFloat(breathSlow)       // 18~24
                let midCorner:   CGFloat = 16 + 4 * CGFloat(breath)           // 16~20
                let innerCorner: CGFloat = 14 + 4 * CGFloat(breathAlt)        // 14~18

                // ── 角度速度 cos 调制 —— 旋转忽快忽慢
                let outerAngle = t * 360 / 4.5 + 25 * sin(t * 2 * .pi / 3.2)
                let midAngle   = -t * 360 / 6.5 + 90 + 30 * sin(t * 2 * .pi / 2.8 + 1.0)
                let innerAngle = t * 360 / 2.8 + 200 + 18 * sin(t * 2 * .pi / 2.1)

                // ── 整体呼吸
                let saturation: Double = 0.85 + 0.30 * breathAlt              // 0.85~1.15
                let scaleBreath: CGFloat = 1.0 + 0.022 * CGFloat(breath)      // 1.000~1.022
                let hueShift = Angle.degrees(12 * (breathSlow - 0.5) * 2)     // ±12° 颜色漂移

                ZStack {
                    // ── 层 1：外层柔光（氛围底）—— 顺时针 4.5s 一圈
                    // blur 半径减半（18~24pt，原 36~52pt）—— 全屏大半径高斯模糊是
                    // SwiftUI 渲染最贵的操作之一，halve 半径 ≈ shader cost / 4
                    AngularGradient(
                        gradient: Gradient(colors: colors),
                        center: .center,
                        angle: .degrees(outerAngle)
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: outerCorner, style: .continuous)
                            .stroke(lineWidth: outerWidth)
                            .blur(radius: 18 + 6 * CGFloat(breathAlt))
                    )
                    .opacity(1.0)

                    // ── 层 2：中层主体（颜色搅动核心）—— 逆时针 6.5s 一圈
                    AngularGradient(
                        gradient: Gradient(colors: colors),
                        center: .center,
                        angle: .degrees(midAngle)
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: midCorner, style: .continuous)
                            .stroke(lineWidth: midWidth)
                            .blur(radius: 10 + 4 * CGFloat(breath))
                    )
                    .blendMode(.plusLighter)
                    .opacity(0.92)

                    // ── 层 3：内层高光细描边（晶莹锐利边缘）—— 顺时针 2.8s 一圈
                    AngularGradient(
                        gradient: Gradient(colors: colors),
                        center: .center,
                        angle: .degrees(innerAngle)
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: innerCorner, style: .continuous)
                            .stroke(lineWidth: innerWidth)
                            .blur(radius: 3 + 2 * CGFloat(breathAlt))
                    )
                    .blendMode(.plusLighter)
                    .opacity(0.95)
                    // 第 4 层"内反光"已删除（issue #3 优化）—— 多一层
                    // .overlay blend 全屏合成约 +20% 帧时，但视觉收益微弱
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .hueRotation(hueShift)                                        // 颜色微漂移
                .saturation(saturation)
                .scaleEffect(scaleBreath)
                .compositingGroup()
            }
        }
    }
}

// 暴露给 AnimatedGlow 用
extension IntelligenceGlowView {
    static var appleAIColors: [Color] { colors }
}
