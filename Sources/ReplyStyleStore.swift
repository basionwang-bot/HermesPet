import Foundation

/// 回复风格库（v1.6「AI 看屏幕」里程碑 5）—— 让自动回复「像用户本人」。
///
/// 两个来源（用户选了全都要，这里先做前两个，知识库后续）：
/// 1. **自动学**：接管时把用户自己发过的消息（靠右气泡）收集成"语气样本"，回复时让 AI 模仿。
/// 2. **手动写**：用户填一句"我说话的风格"，直接注入 prompt。
/// 3. 知识库（远期）：产品理念/常见问答/立场——解决"答得对不对"的内容问题，不在这里。
///
/// 都持久化到 UserDefaults，跨会话累积，用得越久越像用户。
@MainActor
final class ReplyStyleStore {
    static let shared = ReplyStyleStore()

    private let descKey = "replyStyle.description"
    private let samplesKey = "replyStyle.voiceSamples"
    private let maxSamples = 20

    /// 用户手动填的风格说明（可空）
    var styleDescription: String {
        get { UserDefaults.standard.string(forKey: descKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: descKey) }
    }

    /// 自动学来的语气样本（用户自己发过的短消息）
    private(set) var voiceSamples: [String] {
        get { UserDefaults.standard.stringArray(forKey: samplesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: samplesKey) }
    }

    /// 收集用户自己发的消息当语气样本：过滤过短/过长，去重，限长保留最近的。
    func learn(_ messages: [String]) {
        var samples = voiceSamples
        var changed = false
        for raw in messages {
            let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 太短没风格信息、太长多半是代码/转发，都不要
            guard m.count >= 2, m.count <= 60 else { continue }
            // 去重（已在样本里、或跟末尾刚加的重复都跳过）
            if samples.contains(m) { continue }
            samples.append(m)
            changed = true
        }
        guard changed else { return }
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        voiceSamples = samples
    }

    func clearSamples() { voiceSamples = [] }

    /// 拼成给 AI 的"模仿用户风格"指令块。两个来源都空时返回空串（不影响原有行为）。
    func buildStyleBlock() -> String {
        var parts: [String] = []
        let desc = styleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            parts.append("用户自述的说话风格：\(desc)")
        }
        let samples = Array(voiceSamples.suffix(12))
        if !samples.isEmpty {
            let list = samples.map { "  - \($0)" }.joined(separator: "\n")
            parts.append("用户平时就是这样发消息的，请模仿其语气、用词、长短和标点习惯：\n\(list)")
        }
        guard !parts.isEmpty else { return "" }
        return "【请模仿用户本人的说话风格】\n" + parts.joined(separator: "\n")
    }
}
