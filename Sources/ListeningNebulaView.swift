import SwiftUI

// MARK: - 聆听态星云动效（按 docs/specs/listening-nebula.md 实现）
//
// 「正在聆听」状态的粒子星云：大量细碎发光粒子聚拢在卡片中段、向两端快速淡出，
// 整体缓慢横向流动 + 个体闪烁。TimelineView(.animation) + Canvas + plusLighter 加色混合。
//
// ⚠️ 稳定性（守 CLAUDE.md 决策 #21 + 规格 §2/§6）：
// - 粒子状态放引用类型 NebulaParticleStore（@StateObject、无 @Published），每帧在 Canvas
//   绘制闭包里原地更新，**不写任何 @State / @Observable** → 不会每帧 invalidate 视图树；
// - 纯时间驱动 + 固定 frame，不读几何、不发 preference → 不构成布局反馈环；
// - isActive=false 时 0.4s 淡出后暂停 TimelineView（paused:）→ 关闭后零 CPU 占用。

/// 参数已在浏览器原型锁定（规格 §3），默认值勿改；要微调通过构造传入。
struct NebulaConfig {
    var speed: Double = 1.5           // 原型值 2.8 偏快，落地默认 1.5
    var particleCount: Int = 900      // 粒子总数；低功耗模式减半（§6）
    var glowSize: Double = 0.5        // 粒子辉光半径系数 → 细碎星点
    var waveAmplitude: Double = 20    // 中心线正弦波幅（pt）
    var verticalSpread: Double = 30   // 纵向发散（pt）→ 星云的"高"
    var focusRange: Double = 0.12     // 高斯聚光 σ = 宽度 × 0.12 → 聚在中段
    var coreWhiteness: Double = 1.0   // 粒子核心趋白程度（0~1）
    var color: (r: Double, g: Double, b: Double) = (95 / 255, 217 / 255, 245 / 255)  // #5FD9F5
}

/// 粒子容器：一次分配、帧循环原地更新（规格 §6：连续运行内存零增长）。
/// 无 @Published —— @StateObject 只为「跟视图生命周期、只建一次」，不参与视图失效。
final class NebulaParticleStore: ObservableObject {
    var x: [Double]        // 沿胶囊宽度的归一化位置 [0,1)
    let off: [Double]      // 纵向偏移基准 [-1,1]
    let drift: [Double]    // 个体相位 0~2π
    let size: [Double]     // 0.4 + rand×0.9
    let tw: [Double]       // 闪烁速度 0.5 + rand×1.8
    let v: [Double]        // 个体流速 0.5 + rand×0.9
    var lastTime: Double = .nan   // 上一帧时间（归一帧步进用）

    init(count: Int) {
        var x = [Double](), off = [Double](), drift = [Double]()
        var size = [Double](), tw = [Double](), v = [Double]()
        x.reserveCapacity(count); off.reserveCapacity(count); drift.reserveCapacity(count)
        size.reserveCapacity(count); tw.reserveCapacity(count); v.reserveCapacity(count)
        for _ in 0..<count {
            x.append(.random(in: 0..<1))
            off.append(.random(in: -1...1))
            drift.append(.random(in: 0..<(2 * .pi)))
            size.append(0.4 + .random(in: 0..<1) * 0.9)
            tw.append(0.5 + .random(in: 0..<1) * 1.8)
            v.append(0.5 + .random(in: 0..<1) * 0.9)
        }
        self.x = x; self.off = off; self.drift = drift
        self.size = size; self.tw = tw; self.v = v
    }
}

/// 聆听态星云（规格 §5 对外接口）。
/// isActive=true 渐显并驱动；false 时 0.4s 淡出后停掉 TimelineView。
struct ListeningNebulaView: View {
    let config: NebulaConfig
    let isActive: Bool

    @StateObject private var store: NebulaParticleStore
    @State private var visible = false        // 0.4s 淡入淡出
    @State private var engineRunning = false  // TimelineView 是否在驱动（淡出完→false→零 CPU）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(config: NebulaConfig = .init(), isActive: Bool) {
        self.config = config
        self.isActive = isActive
        _store = StateObject(wrappedValue: NebulaParticleStore(count: config.particleCount))
    }

    var body: some View {
        // 低功耗时帧率目标降到 30fps（§6）。注：body 只在 isActive/visible 变化时重建，
        // 帧率档位届时跟着刷新；粒子减半在 draw 内每帧实时读，立即生效。
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let rm = reduceMotion
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30.0 : 1.0 / 60.0,
                                paused: !engineRunning)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(into: &ctx, size: size, t: t, reduceMotion: rm)
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .task(id: isActive) {
            if isActive {
                engineRunning = true
                withAnimation(.easeOut(duration: 0.4)) { visible = true }
            } else {
                withAnimation(.easeIn(duration: 0.4)) { visible = false }
                // 淡出播完再停驱动；期间若重新激活，task(id:) 取消本任务 → 不停
                try? await Task.sleep(nanoseconds: 450_000_000)
                if !Task.isCancelled { engineRunning = false }
            }
        }
    }

    /// 每帧绘制（规格 §4 算法逐条对应）。只动 store（引用类型）与局部变量，不碰任何视图状态。
    private func draw(into ctx: inout GraphicsContext, size: CGSize, t: Double, reduceMotion: Bool) {
        let W = Double(size.width), H = Double(size.height)
        guard W > 1, H > 1, !store.x.isEmpty else { return }
        let cx = W / 2, midY = H / 2
        let padX = W * 0.16                      // 两端留白
        let span = W - 2 * padX
        let sigma = max(W * config.focusRange, 1)

        // 帧步进归一到 60fps（规格的 x += speed×0.0012×v 是按 60fps 一帧）；
        // 掉帧 / 暂停恢复时 clamp ≤ 4 帧防跳变
        var frames = 1.0
        if store.lastTime.isFinite {
            frames = min(max((t - store.lastTime) * 60.0, 0.0), 4.0)
        }
        store.lastTime = t

        // 低功耗：粒子减半（§6，每帧实时读）
        var count = store.x.count
        if ProcessInfo.processInfo.isLowPowerModeEnabled { count /= 2 }

        // 减弱动态效果：粒子静止（相位冻结），只保留整体 alpha 2s 周期呼吸（§6）
        let motion = !reduceMotion
        let tEff = motion ? t : 0
        let globalAlpha = motion ? 1.0 : (0.65 + 0.35 * sin(t * .pi))
        if !motion { frames = 0 }

        let base = config.color
        let baseColor = Color(red: base.r, green: base.g, blue: base.b)
        let wht = config.coreWhiteness
        let coreColor = Color(red: base.r + (1 - base.r) * wht,
                              green: base.g + (1 - base.g) * wht,
                              blue: base.b + (1 - base.b) * wht)
        // 三档径向渐变每帧只建一份；各粒子亮度走 ctx.opacity（核心 alpha → 基础色 alpha×0.5 → 透明，
        // 数值上与规格 §4.5 等价，省掉每粒子建 Gradient 的分配）
        let particleGradient = Gradient(stops: [
            .init(color: coreColor, location: 0),
            .init(color: baseColor.opacity(0.5), location: 0.4),
            .init(color: baseColor.opacity(0), location: 1)
        ])

        // 通透处理（2026-06-10 用户反馈"像被玻璃盖住"）：星云中心先垫一层暗色径向底——
        // 卡片是半透明玻璃、背景偏亮时加色(plusLighter)粒子会被洗白发灰；规格 §7 本就假设纯黑深底。
        // 暗底只罩中心 ~2.6σ、边缘渐隐，不破坏卡片整体玻璃感。
        let dimR = sigma * 2.6
        ctx.opacity = globalAlpha
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - dimR, y: midY - dimR, width: dimR * 2, height: dimR * 2)),
            with: .radialGradient(
                Gradient(colors: [Color.black.opacity(0.32), Color.black.opacity(0)]),
                center: CGPoint(x: cx, y: midY), startRadius: 0, endRadius: dimR))

        ctx.blendMode = .plusLighter

        // 底层柔光：中心半径 σ×1.1，峰值 alpha 0.08（§4.6）
        let glowR = sigma * 1.1
        ctx.opacity = globalAlpha
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - glowR, y: midY - glowR, width: glowR * 2, height: glowR * 2)),
            with: .radialGradient(
                Gradient(colors: [baseColor.opacity(0.08), baseColor.opacity(0)]),
                center: CGPoint(x: cx, y: midY), startRadius: 0, endRadius: glowR))

        let stepX = config.speed * 0.0012 * frames
        let twoSigmaSq = 2 * sigma * sigma

        for i in 0..<count {
            // 1. 流动（超过 1 回绕到 0）
            if frames > 0 {
                var nx = store.x[i] + stepX * store.v[i]
                if nx >= 1 { nx -= 1 }
                store.x[i] = nx
            }
            let xN = store.x[i]
            // 2. 绘制坐标
            let px = padX + xN * span
            let dx = px - cx
            let env = exp(-(dx * dx) / twoSigmaSq)   // 高斯包络（聚在中段）
            // 3. 亮度 —— 先算 alpha，两端粒子大量剔除（性能关键）。
            //    系数 0.9→1.0（2026-06-10 通透调亮，玻璃底上 0.9 偏闷）
            let twi = store.tw[i], dr = store.drift[i]
            let alpha = env * (0.55 + 0.45 * sin(tEff * twi * 1.6 + dr))
            if alpha < 0.01 { continue }

            let waveY = sin(xN * 3 * .pi + tEff * 1.4) * config.waveAmplitude
            let jitter = sin(tEff * twi + dr) * 0.5
            let py = midY + waveY + (store.off[i] + jitter) * config.verticalSpread * (0.4 + env)
            // 4. 半径（基数 1.1→1.35：星点略放大一点点，玻璃底上更立体 —— 2026-06-10 通透调参）
            let rad = (1.35 + store.size[i] * config.glowSize) + env * config.glowSize * 1.4
            // 5. 径向渐变三档 + 加色混合
            ctx.opacity = alpha * globalAlpha
            ctx.fill(
                Path(ellipseIn: CGRect(x: px - rad, y: py - rad, width: rad * 2, height: rad * 2)),
                with: .radialGradient(particleGradient,
                                      center: CGPoint(x: px, y: py),
                                      startRadius: 0, endRadius: rad))
        }
    }
}
