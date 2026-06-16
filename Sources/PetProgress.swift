import Foundation

/// 宠物养成系统的「纯数据模型」—— 不含任何逻辑/渲染，只是可 Codable 持久化的值类型。
///
/// 设计基石（三个已拍板的产品决策）：
/// 1. 养一份「你的」成长档案（灵魂归一，不按后端分散）；
/// 2. 渲染维持纯代码自绘；
/// 3. 养成数据与形象**解耦** —— 档案只存 `currentFormID`（当前穿哪件外衣），
///    换形象不动等级/经验/心情。
///
/// 第 0 步（地基）只负责「存」与「在设置面板显示」，不碰渲染（换形象真正上身、
/// 心情上脸、升级庆祝都是后续阶段的事）。

// MARK: - 心情

/// 宠物心情 —— 由养成中枢根据「干活 / 闲置」自动推算。
enum PetMood: String, Codable, CaseIterable {
    case happy      // 刚陪你打了胜仗，最开心
    case content    // 正常干活中，满足
    case neutral    // 平静（默认起始）
    case tired      // 高强度连轴转 / 失败多了，累
    case lonely     // 很久没理它，想你了

    /// i18n key（nonisolated，UI 层用 `L(mood.displayNameKey)`，守决策 #20：
    /// nonisolated enum 不能直接调 @MainActor 的 L()，只返回 key 字符串）
    var displayNameKey: String { "pet.mood.\(rawValue)" }

    /// 配套小图标（SF Symbol）—— 设置面板 + 后续气泡可用
    var symbolName: String {
        switch self {
        case .happy:   return "face.smiling.inverse"
        case .content: return "face.smiling"
        case .neutral: return "circle.dashed"
        case .tired:   return "zzz"
        case .lonely:  return "cloud.rain"
        }
    }
}

// MARK: - 形象（可切换的「外衣」）

/// 宠物形象「外衣」—— 第 0 步复用现有 5 只自绘 sprite 当外衣，档案只记
/// 「当前选哪件 + 解锁了哪些」。渲染层接 formID 让换形象真正生效是第 1 步。
enum PetForm: String, Codable, CaseIterable {
    case clawd      // 螃蟹（默认，Claude 同款）
    case fomo       // 九尾狐（OpenClaw 同款）
    case horse      // 金黄小马（Hermes 同款）
    case monster    // 红色小怪兽（在线 AI 同款）
    case terminal   // 终端机器人（Codex 同款）

    var displayNameKey: String { "pet.form.\(rawValue)" }

    /// 解锁所需等级（clawd 默认解锁，其余按等级逐级解锁）。初版数值，可调。
    var unlockLevel: Int {
        switch self {
        case .clawd:    return 1
        case .fomo:     return 3
        case .horse:    return 5
        case .monster:  return 8
        case .terminal: return 12
        }
    }
}

// MARK: - 累计战绩

/// 宠物陪你干活的累计统计 —— 后续「今日战报 / 成就」用。
struct PetStats: Codable, Equatable {
    var tasksSucceeded: Int = 0
    var tasksFailed: Int = 0
    var toolsUsed: Int = 0
}

// MARK: - 成长档案

/// 「你的」宠物成长档案：一份灵魂（等级 / 经验 / 心情 / 昵称），形象只是可换的外衣。
/// 存 UserDefaults `"petProgress.v1"`，由 `PetProgressStore` 读写。
///
/// ⚠️ 向后兼容：自定义 `init(from:)`（放在 extension 里，保留合成的 memberwise init）
/// 对每个字段都 `decodeIfPresent ?? 默认值`，这样以后给档案加新字段时，老存档不会
/// 因为缺字段而 decode 失败被整份重置。
struct PetProgress: Codable, Equatable {
    var level: Int = 1
    var exp: Int = 0                 // 当前等级内已累积的经验
    var totalExp: Int = 0            // 历史累计总经验（战报用）
    var mood: PetMood = .neutral
    var petName: String = ""         // 用户起的昵称（空 = 用当前形象默认名）
    var currentFormID: String = PetForm.clawd.rawValue
    var unlockedFormIDs: [String] = [PetForm.clawd.rawValue]
    var stats: PetStats = PetStats()
    var createdAt: Date = Date()
    var lastActiveAt: Date = Date()
    var lastMoodDecayAt: Date = Date()

    /// 当前形象（解析 currentFormID，非法则回退 clawd）
    var currentForm: PetForm {
        PetForm(rawValue: currentFormID) ?? .clawd
    }
}

extension PetProgress {
    enum CodingKeys: String, CodingKey {
        case level, exp, totalExp, mood, petName
        case currentFormID, unlockedFormIDs, stats
        case createdAt, lastActiveAt, lastMoodDecayAt
    }

    /// 宽容解码：缺失字段一律回退默认值（向后兼容未来新增字段）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = PetProgress()
        self.level           = try c.decodeIfPresent(Int.self, forKey: .level) ?? def.level
        self.exp             = try c.decodeIfPresent(Int.self, forKey: .exp) ?? def.exp
        self.totalExp        = try c.decodeIfPresent(Int.self, forKey: .totalExp) ?? def.totalExp
        self.mood            = try c.decodeIfPresent(PetMood.self, forKey: .mood) ?? def.mood
        self.petName         = try c.decodeIfPresent(String.self, forKey: .petName) ?? def.petName
        self.currentFormID   = try c.decodeIfPresent(String.self, forKey: .currentFormID) ?? def.currentFormID
        self.unlockedFormIDs = try c.decodeIfPresent([String].self, forKey: .unlockedFormIDs) ?? def.unlockedFormIDs
        self.stats           = try c.decodeIfPresent(PetStats.self, forKey: .stats) ?? def.stats
        self.createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? def.createdAt
        self.lastActiveAt    = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? def.lastActiveAt
        self.lastMoodDecayAt = try c.decodeIfPresent(Date.self, forKey: .lastMoodDecayAt) ?? def.lastMoodDecayAt
    }
}

// MARK: - 等级曲线

/// 升级 / 默认档案的纯计算逻辑（无状态，便于调参）。
enum PetLeveling {
    /// 从 `level` 升到「level+1」所需的本级经验（初版线性 `level * 100`，可调）。
    static func expNeeded(forLevel level: Int) -> Int {
        max(100, level * 100)
    }

    /// 全新档案（首次启动 / 无存档时用）。
    static func defaultProgress() -> PetProgress {
        PetProgress()
    }
}
