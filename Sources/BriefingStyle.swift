import Foundation

/// 日报 / 回顾的「风格」——由用户在设置里全局单选（v1.3 Phase 4-B）。
///
/// 注意：这是**用户主动选**的全局口吻，跟"桌宠别搞复杂人设"（[[feedback-subtle-proactive-tone]]）
/// 不冲突——那次否的是"我们自动给 4 只桌宠分配性格"，这个主动权在用户。
///
/// 风格只改"怎么说"，**不改"要说出对用户真实有用的东西"这个底线**（底线由各 prompt 主体保证）。
/// 早报（MorningBriefingService）和周期回顾（PeriodicReviewService）共用同一风格，口吻保持一致。
enum BriefingStyle: String, CaseIterable, Identifiable {
    case warm        // 温暖陪伴（默认）
    case concise     // 简洁干练
    case playful     // 俏皮活泼
    case encouraging // 鼓励打气
    case sharp       // 犀利点醒

    var id: String { rawValue }

    /// 设置面板显示名
    var label: String {
        switch self {
        case .warm:        return "温暖陪伴"
        case .concise:     return "简洁干练"
        case .playful:     return "俏皮活泼"
        case .encouraging: return "鼓励打气"
        case .sharp:       return "犀利点醒"
        }
    }

    /// 设置面板显示名的 i18n key —— rawValue 即 warm / concise / …（label 保留作原始中文参考）
    var labelKey: String { "briefing.style.\(rawValue)" }

    /// 注入 prompt 的"语气指令"（代词中立，早报/回顾都能用）。
    var toneInstruction: String {
        switch self {
        case .warm:
            return "整体口吻温暖、有人味，像个贴心的小家伙在关心对方。"
        case .concise:
            return "整体口吻简洁干练，直接给重点和有用的点，少寒暄，能短则短。"
        case .playful:
            return "整体口吻俏皮活泼、轻松，可以皮一点、emoji 多一点，但别油腻。"
        case .encouraging:
            return "整体口吻像个正向教练，多鼓励、多打气，肯定对方的努力、温柔推一把。"
        case .sharp:
            return "整体口吻犀利、直接、带点幽默吐槽，敢直说问题——但必须犀利得有料、对用户真有帮助，不刻薄、不打击。"
        }
    }

    /// 当前选定风格（默认温暖陪伴）
    static func current() -> BriefingStyle {
        let raw = UserDefaults.standard.string(forKey: "briefingStyle") ?? ""
        return BriefingStyle(rawValue: raw) ?? .warm
    }
}
