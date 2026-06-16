import SwiftUI

// MARK: - Token 估算 + 上下文窗口

/// 轻量 token 估算（本地、离线、全模式通用）。
/// 不追求精确 —— 目的是给用户一个"这个对话占了多少上下文"的直观感受，缓解 token 焦虑。
/// 真要精确得各家 tokenizer，没必要为一个进度条引那种依赖。
enum TokenEstimator {

    /// 估算一段文本的 token 数。
    /// 经验值：CJK（中日韩）字符 ≈ 1 token；其余（英文/符号/空格）≈ 0.25 token（约 4 字符/token）。
    static func estimateTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // CJK 统一表意 + 扩展A + 日文假名 + 韩文音节
            if (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x3040...0x30FF).contains(v)
                || (0xAC00...0xD7AF).contains(v) {
                cjk += 1
            } else {
                other += 1
            }
        }
        return Int(Double(cjk) * 1.0 + Double(other) * 0.25)
    }

    /// 估算多条消息合计 token（每条加 ~4 token 的结构开销，贴近真实请求体）。
    static func estimateMessagesTokens(_ texts: [String]) -> Int {
        texts.reduce(0) { $0 + estimateTokens($1) + 4 }
    }

    /// 按模型名 / mode 推断上下文窗口大小（token）。
    /// 各家差异大，这里给常见家族的合理默认值 + 兜底，仅用于进度条分母。
    /// 手动覆盖的 UserDefaults key（按 mode）—— 设置面板"上下文窗口"填了就用它。
    static func overrideKey(for mode: AgentMode) -> String { "ctxWindowOverride_\(mode.rawValue)" }

    /// 解析上下文窗口（分母）。顺序：① 用户手动覆盖 → ② models.dev 真实窗口 → ③ 内置兜底表。
    static func contextWindow(forModel model: String, mode: AgentMode) -> Int {
        // ① 手动覆盖（自部署 / 冷门模型 / 想强制指定）
        let override = UserDefaults.standard.integer(forKey: overrideKey(for: mode))
        if override > 0 { return override }

        // ② models.dev 真实窗口（随模型自动更新，覆盖 Claude/DeepSeek/Kimi/GPT… 当前规格）
        if let real = ModelCatalog.shared.contextWindow(for: model) { return real }

        // ③ 内置兜底（首次离线还没拉到 models.dev / 库里没收录的自部署模型）
        let m = model.lowercased()
        if m.contains("gemini") { return 1_000_000 }
        if m.contains("kimi") || m.contains("moonshot") { return 256_000 }
        if m.contains("deepseek") { return 1_000_000 }
        if m.contains("claude") || m.contains("sonnet") || m.contains("opus") || m.contains("haiku") { return 200_000 }
        if m.contains("glm") || m.contains("zhipu") { return 200_000 }
        if m.contains("minimax") { return 204_800 }
        if m.contains("qwen") { return 256_000 }
        if m.contains("codex") { return 272_000 }
        if m.contains("gpt") || m.contains("o1") || m.contains("o3") || m.contains("o4") { return 272_000 }
        switch mode {
        case .claudeCode: return 200_000
        case .codex:      return 272_000
        case .qwenCode:   return 256_000
        case .hermes, .directAPI, .openclaw: return 200_000
        }
    }

    /// 把 token 数格式化成短字符串：1234 → "1K"，1_200_000 → "1.2M"。
    static func format(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1000)K" }
        return "\(n)"
    }
}

// MARK: - Token 用量账本（为以后"宠物成长"联动沉淀数据）

/// 极简本地账本：累计 token 总量 + 当天用量。当前不展示，只默默记录，
/// 给将来"用得越多宠物越成长"之类的玩法留数据底座。用 UserDefaults（线程安全、够轻）。
enum UsageLedger {
    private static let totalKey = "usageTotalTokens"
    private static let todayKey = "usageTodayTokens"
    private static let todayDateKey = "usageTodayDate"

    private static func todayString() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// 记一笔 token 用量（输入 + 输出的估算合计）。
    static func record(_ tokens: Int) {
        guard tokens > 0 else { return }
        let d = UserDefaults.standard
        d.set(d.integer(forKey: totalKey) + tokens, forKey: totalKey)

        let today = todayString()
        if d.string(forKey: todayDateKey) != today {
            d.set(today, forKey: todayDateKey)
            d.set(0, forKey: todayKey)
        }
        d.set(d.integer(forKey: todayKey) + tokens, forKey: todayKey)
    }

    /// 累计总用量（将来宠物成长读这个）。
    static var total: Int { UserDefaults.standard.integer(forKey: totalKey) }
    /// 当天用量。
    static var today: Int {
        let d = UserDefaults.standard
        guard d.string(forKey: todayDateKey) == todayString() else { return 0 }
        return d.integer(forKey: todayKey)
    }
}

// MARK: - Context 进度条 UI

/// 对话框下方的上下文占用进度条 —— **颜色始终跟随当前桌宠主色** + 柔和光效。
/// 缓解 token 焦虑：让用户直观看到"这个对话快撑满上下文了没"。
/// 进度条本体短而克制（固定宽度、靠左），不抢视线。
struct ContextUsageBar: View {
    let used: Int
    let window: Int
    /// 桌宠主色（PetPaletteStore.palette(for:).primary）—— 用户改色会自动跟随
    let tint: Color

    /// 进度条本体固定宽度，短一些、不拉满
    private let barWidth: CGFloat = 88

    private var fraction: Double {
        guard window > 0 else { return 0 }
        return min(1.0, Double(used) / Double(window))
    }
    private var percent: Int { Int((fraction * 100).rounded()) }

    var body: some View {
        HStack(spacing: 7) {
            Text("Context")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: barWidth, height: 4)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.7), tint],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(3, barWidth * fraction), height: 4)
                    // 光效：桌宠主色的柔和外发光
                    .shadow(color: tint.opacity(0.6), radius: 3, x: 0, y: 0)
            }

            Text("\(percent)%")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()

            Text("\(TokenEstimator.format(used))/\(TokenEstimator.format(window))")
                .font(.system(size: 8.5, design: .rounded))
                .foregroundStyle(.quaternary)
                .monospacedDigit()

            Spacer(minLength: 0)   // 内容靠左，整体短
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .animation(AnimTok.smooth, value: fraction)
        .help("当前对话已占用约 \(percent)% 的上下文（估算 \(TokenEstimator.format(used)) / \(TokenEstimator.format(window)) tokens）")
    }
}
