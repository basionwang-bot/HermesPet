import SwiftUI

/// 聊天窗底部 mode 色光晕（v1.5，学 Gemini 但跟系统状态强联动）。
///
/// 跟壁纸级静态光晕的关键区别：**不是渲染一次就完事，而是跟着 AI 一起呼吸**。
///
/// 联动规则（三态机）：
/// - **欢迎页**（空对话）：稳态 0.22 主色 → 切 mode 时颜色 0.4s 平滑过渡
/// - **流式中**（isStreaming）：呼吸在 0.18 ↔ 0.32 间往复，周期 1.2s（跟对话胶囊执行流同步）
/// - **任务完成瞬间**（HermesPetTaskFinished）：+0.33 boost 闪烁 → 0.5s 内淡回基线，作为"任务完成"视觉锚点
/// - **其它**（用户在静态读消息）：完全透明，不打扰阅读
///
/// 视觉细节：
/// - LinearGradient 从顶部 clear → 底部 tint，stops 集中在下半部分让光从底部"溢出"
/// - 高度 240pt，从 ChatView 底部 alignment 起算
/// - allowsHitTesting=false 不抢点击
struct ModeAmbientGlow: View {
    let tint: Color
    /// 是否处于欢迎页（空对话、无用户输入）—— 稳态显示
    let isWelcomePage: Bool
    /// 是否正在执行 —— 触发呼吸动画
    let isStreaming: Bool

    /// 呼吸 toggle —— 流式时在 .repeatForever 里反复 true/false 驱动 opacity 振荡
    @State private var breathePulse: Bool = false
    /// 任务完成瞬间的 +boost，由 HermesPetTaskFinished 通知触发
    @State private var flashIntensity: Double = 0

    /// 总不透明度 = 状态基线 + 完成 flash 叠加
    private var totalOpacity: Double {
        let base: Double
        if isStreaming {
            base = breathePulse ? 0.32 : 0.18
        } else if isWelcomePage {
            base = 0.22
        } else {
            base = 0
        }
        return min(base + flashIntensity, 0.6)
    }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: tint.opacity(0), location: 0),
                .init(color: tint.opacity(0.45), location: 0.6),
                .init(color: tint.opacity(1.0), location: 1.0)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .opacity(totalOpacity)
        .frame(height: 240)
        .allowsHitTesting(false)
        // 切 mode 时颜色平滑过渡
        .animation(.easeInOut(duration: 0.4), value: tint)
        // 进入/退出欢迎页时透明度软淡入淡出
        .animation(.easeInOut(duration: 0.6), value: isWelcomePage)
        .onAppear {
            if isStreaming { startBreathing() }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming { startBreathing() } else { stopBreathing() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { _ in
            triggerFlash()
        }
    }

    /// 流式时启动呼吸动画。已经在循环就不重启（避免 phase 跳）
    private func startBreathing() {
        guard !breathePulse else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            breathePulse = true
        }
    }

    /// 退出流式：把 breathePulse 拨回 false 打断 repeatForever
    private func stopBreathing() {
        withAnimation(.easeInOut(duration: 0.4)) {
            breathePulse = false
        }
    }

    /// 任务完成 flash：瞬间 +0.33，250ms 后 0.5s 内淡回 0
    private func triggerFlash() {
        withAnimation(.easeOut(duration: 0.12)) {
            flashIntensity = 0.33
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeOut(duration: 0.5)) {
                flashIntensity = 0
            }
        }
    }
}
