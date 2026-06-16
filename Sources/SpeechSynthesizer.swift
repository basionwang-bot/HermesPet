import AVFoundation
import Foundation

/// TTS 服务：把 AI 的文字念出来（系统 `AVSpeechSynthesizer`，免费、离线、零依赖）。
///
/// **默认声音优先级**：用户选的 → 悦(Yue Premium) → 任意中文 高级/增强 版 →
/// 婷婷(Tingting 紧凑，人人预装) → 任意中文。
/// 悦/增强版需用户在「系统设置 → 辅助功能 → 朗读内容」里下载；没下载时自动回退婷婷紧凑版，
/// 保证装完 app 立刻能出声、绝不哑巴。
///
/// **隔离设计**（守 CLAUDE.md 决策 #5）：`@MainActor`。`AVSpeechSynthesizer` 的 speak/stop
/// 都在主线程调用，delegate 回调也在创建它的线程（= 主线程）触发，所以隔离与回调线程一致，
/// 不会出现「@MainActor 闭包被丢到后台线程执行」的 SIGTRAP。delegate 方法标 `nonisolated`
/// + `MainActor.assumeIsolated`，对 SDK 是否把协议方法标 @MainActor 两种情况都兼容。
@MainActor
final class SpeechSynthesizer: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    static let shared = SpeechSynthesizer()

    private let synth = AVSpeechSynthesizer()

    /// 当前是否在出声（含排队尚未念完的句子）
    private(set) var isSpeaking = false
    /// 未念完的 utterance 计数 —— 不依赖系统 `synth.isSpeaking`（didFinish 回调时它偶尔还没翻成
    /// false，导致「念完」信号漏发 → 陪聊不回听、要按空格）。用自己的计数判断「全部念完」最可靠。
    private var pendingCount = 0
    /// 卡拉OK进度回调：系统**即将念到** (utterance 内字符范围 NSRange/UTF-16, utterance 全文)。
    /// 主线程触发，词级频率（每秒 2~5 次，低频，不会触发渲染风暴）。语音陪聊用它做逐词高亮。
    /// 类型标 @MainActor：赋值方（VoiceChatController）闭包里要碰 @MainActor 状态。
    var onSpeakRange: (@MainActor (NSRange, String) -> Void)?
    /// 最近一次 speak 的时刻 —— 给 `reconcileSpeakingState` 留缓冲：刚调 speak、synth 还没启动起来时
    /// `synth.isSpeaking` 仍是 false，别在这个空窗里误判「已念完」。
    private var lastSpeakAt = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - UserDefaults keys / 固定标识

    /// 用户选定的声音 identifier（空 = 自动按优先级挑）
    static let voiceKey = "ttsVoiceIdentifier"
    /// 语速（0 = 用系统默认）
    static let rateKey = "ttsRate"

    /// 悦(Yue Premium) —— 第一优先的高级中文嗓音（需用户下载）
    static let yueIdentifier = "com.apple.voice.premium.zh-CN.Yue"
    /// 婷婷紧凑版 —— 人人预装的保底中文嗓音
    static let tingtingIdentifier = "com.apple.voice.compact.zh-CN.Tingting"

    private override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - 声音解析

    /// 按优先级挑当前要用的中文声音。
    static func resolveVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        // 1. 用户显式选定且仍可用
        let saved = UserDefaults.standard.string(forKey: voiceKey) ?? ""
        if !saved.isEmpty, let v = voices.first(where: { $0.identifier == saved }) {
            return v
        }
        // 2. 悦(Yue Premium)
        if let yue = voices.first(where: { $0.identifier == yueIdentifier }) { return yue }
        // 3. 任意中文 高级/增强 版（比紧凑版自然很多）
        if let hq = voices.first(where: { $0.language.hasPrefix("zh") && $0.quality != .default }) {
            return hq
        }
        // 4. 婷婷紧凑（保底，人人预装）
        if let t = voices.first(where: { $0.identifier == tingtingIdentifier }) { return t }
        // 5. 任意中文
        if let zh = voices.first(where: { $0.language.hasPrefix("zh") }) { return zh }
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }

    /// 当前生效声音的展示名（给设置/调试用）
    static func currentVoiceName() -> String {
        resolveVoice()?.name ?? "系统默认"
    }

    /// 列出所有中文声音（给「语音中心」面板用）。
    static func chineseVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    private func resolvedRate() -> Float {
        let saved = UserDefaults.standard.float(forKey: Self.rateKey)
        return saved > 0 ? saved : AVSpeechUtteranceDefaultSpeechRate
    }

    // MARK: - 念 / 停

    /// 念一段文字。连续调用多段会自动排队、依次念 —— 适合把流式回复**按句喂**进来降低延迟。
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let u = AVSpeechUtterance(string: trimmed)
        u.voice = Self.resolveVoice()
        u.rate = resolvedRate()
        u.pitchMultiplier = 1.0
        u.postUtteranceDelay = 0.04   // 句间留极小停顿更自然
        pendingCount += 1
        lastSpeakAt = Date()
        if !isSpeaking {
            isSpeaking = true
            postState(true)
        }
        synth.speak(u)
    }

    /// 立即停止（打断 / 退出陪聊用）。会清空排队未念的句子。
    func stop() {
        if synth.isSpeaking || synth.isPaused {
            synth.stopSpeaking(at: .immediate)
        }
        pendingCount = 0
        if isSpeaking {
            isSpeaking = false
            postState(false)
        }
    }

    /// 兜底对账（给陪聊看门狗每 0.25s 调一次）。
    ///
    /// macOS 上 `AVSpeechSynthesizer` 的 `didFinish` **偶发不回调**（短句/快语速更易中）—— 那样
    /// 我们的 `isSpeaking` 会一直挂 true、`postState(false)` 永不发出 → 陪聊卡在「说」不回听
    /// （用户表现为「有时要按一下空格才能继续」）。这里拿**系统真实** `synth.isSpeaking` 对账：
    /// 它确实已停、而我们还以为在说 → 强制归位 + 补发「念完」通知，让回听路径照常走。
    /// 留 0.6s 缓冲避开「刚 speak、synth 尚未启动」的空窗（否则会误判已念完、过早回听）。
    func reconcileSpeakingState() {
        guard isSpeaking, !synth.isSpeaking,
              Date().timeIntervalSince(lastSpeakAt) > 0.6 else { return }
        pendingCount = 0
        isSpeaking = false
        postState(false)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            // ⚠️ 不看 synth.isSpeaking（didFinish 回调时系统偶尔还没把它翻成 false → 漏发「念完」
            // → 陪聊不回听、要按空格）。改用自己的 pendingCount：每念完一段 -1，归零才算全部念完。
            pendingCount = max(0, pendingCount - 1)
            if pendingCount == 0, isSpeaking {
                isSpeaking = false
                postState(false)
            }
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        // 先取出 String（Sendable）再进闭包 —— 直接把非 Sendable 的 utterance 带进
        // assumeIsolated 会被 Swift 6 region 分析拦下（sending risks data races）。
        let full = utterance.speechString
        MainActor.assumeIsolated {
            onSpeakRange?(characterRange, full)
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            pendingCount = 0
            isSpeaking = false
            postState(false)
        }
    }

    // MARK: - 通知

    /// speaking 状态变化 → 驱动那张脸进入/退出「说话」表情。
    private func postState(_ speaking: Bool) {
        NotificationCenter.default.post(
            name: .init("HermesPetTTSStateChanged"),
            object: nil,
            userInfo: ["speaking": speaking]
        )
    }
}
