import Foundation

// MARK: - 模型价目表（公开标价，本地估算费用用）

/// 单个模型的价格（美元 / 百万 token）。取各厂商官网**公开标价**的常见档位；
/// 促销价 / 折扣价 / 阶梯价可能与你的真实账单有出入 —— 这里只为给个"大概花了多少 / 省了多少"的直观感受。
struct ModelPrice: Sendable {
    let inputPerM: Double       // 输入（非缓存）
    let outputPerM: Double      // 输出
    let cacheReadPerM: Double   // 缓存命中读取（通常远低于 input）
    let cacheWritePerM: Double  // 缓存写入（通常略高于 input）

    /// 没有单独缓存定价的模型：读 ≈ input、写 ≈ input（即缓存不省也不亏）。
    init(inputPerM: Double, outputPerM: Double, cacheReadPerM: Double? = nil, cacheWritePerM: Double? = nil) {
        self.inputPerM = inputPerM
        self.outputPerM = outputPerM
        self.cacheReadPerM = cacheReadPerM ?? inputPerM
        self.cacheWritePerM = cacheWritePerM ?? inputPerM
    }

    /// 一笔用量在该价格下折算成多少**美元**。
    func costUSD(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        (Double(input)     * inputPerM
         + Double(output)  * outputPerM
         + Double(cacheRead)  * cacheReadPerM
         + Double(cacheWrite) * cacheWritePerM) / 1_000_000.0
    }
}

/// 价目表 + 计费 / 省钱口径的纯函数集合（无状态、Sendable、可后台调用）。
enum ModelPricing {

    /// 美元 → 人民币汇率（折算展示用，粗略固定值）。
    static let usdToCNY: Double = 7.2

    /// 公开价目表（USD / 1M tokens）。key = 模型 id 关键字（小写**子串**匹配，跟 `TokenEstimator.contextWindow` 同思路）。
    /// 升级 / 改价时改这里即可；匹配顺序从上到下，先命中先用（所以把更具体的 opus/sonnet 放 claude 前面）。
    private static let table: [(key: String, price: ModelPrice)] = [
        // Claude：缓存读 ≈ 0.1×input，缓存写 ≈ 1.25×input（Anthropic 公开比例）
        ("opus",     ModelPrice(inputPerM: 15,   outputPerM: 75,  cacheReadPerM: 1.5,  cacheWritePerM: 18.75)),
        ("sonnet",   ModelPrice(inputPerM: 3,    outputPerM: 15,  cacheReadPerM: 0.3,  cacheWritePerM: 3.75)),
        ("haiku",    ModelPrice(inputPerM: 0.8,  outputPerM: 4,   cacheReadPerM: 0.08, cacheWritePerM: 1.0)),
        ("claude",   ModelPrice(inputPerM: 3,    outputPerM: 15,  cacheReadPerM: 0.3,  cacheWritePerM: 3.75)), // 兜底=sonnet 档
        // DeepSeek：缓存命中价极低（约 0.1×）
        ("deepseek", ModelPrice(inputPerM: 0.27, outputPerM: 1.1, cacheReadPerM: 0.027)),
        // 智谱 GLM
        ("glm",      ModelPrice(inputPerM: 0.6,  outputPerM: 2.2)),
        ("zhipu",    ModelPrice(inputPerM: 0.6,  outputPerM: 2.2)),
        // Kimi / Moonshot
        ("kimi",     ModelPrice(inputPerM: 0.6,  outputPerM: 2.5, cacheReadPerM: 0.15)),
        ("moonshot", ModelPrice(inputPerM: 0.6,  outputPerM: 2.5, cacheReadPerM: 0.15)),
        // MiniMax
        ("minimax",  ModelPrice(inputPerM: 0.3,  outputPerM: 1.2)),
        // OpenAI GPT / o-series / Codex
        ("o1",       ModelPrice(inputPerM: 15,   outputPerM: 60)),
        ("o3",       ModelPrice(inputPerM: 10,   outputPerM: 40)),
        ("o4",       ModelPrice(inputPerM: 10,   outputPerM: 40)),
        ("gpt",      ModelPrice(inputPerM: 2.5,  outputPerM: 10,  cacheReadPerM: 1.25)),
        ("codex",    ModelPrice(inputPerM: 2.5,  outputPerM: 10,  cacheReadPerM: 1.25)), // ≈ gpt 档
        ("openai",   ModelPrice(inputPerM: 2.5,  outputPerM: 10,  cacheReadPerM: 1.25)),
        // 通义千问
        ("qwen",     ModelPrice(inputPerM: 0.4,  outputPerM: 1.2)),
        // Gemini
        ("gemini",   ModelPrice(inputPerM: 1.25, outputPerM: 5)),
    ]

    /// 默认兜底价（未知模型）—— 取中庸值，避免 0 让"花费/省钱"全为 0 显得没在工作。
    static let fallback = ModelPrice(inputPerM: 1.0, outputPerM: 3.0)

    /// 按模型名匹配公开价；给不出模型名（子进程没回报 / openclaw）时按 mode 猜，再不行用 fallback。
    static func price(forModel model: String, mode: AgentMode) -> ModelPrice {
        let m = model.lowercased()
        for entry in table where m.contains(entry.key) { return entry.price }
        switch mode {
        case .claudeCode: return table.first { $0.key == "claude" }!.price
        case .codex:      return table.first { $0.key == "codex"  }!.price
        case .qwenCode:   return table.first { $0.key == "qwen"   }!.price
        default:          return fallback
        }
    }

    /// 该后端是否"订阅制"（用户付**固定月费**、不按 token 付费）。
    /// - Claude Code / Codex / 通义：CLI 子进程，复用本机已登录的**订阅**（Claude Pro/Max、ChatGPT Plus、通义）；
    ///   设置里可填月费 → 卡片按"如果走 API 要付多少"对比月费，算省了多少。
    /// - **Hermes / OpenClaw 不是订阅、是按量付费**：它们各自连真实模型、烧真实 token（Hermes=用户自建网关后端、
    ///   OpenClaw=npm gateway 背后的真实模型），跟在线 AI 一样按 token × 单价计入「实付」。
    static func isSubscriptionBacked(_ mode: AgentMode) -> Bool {
        switch mode {
        case .directAPI, .hermes, .openclaw: return false   // 按量付费
        case .claudeCode, .codex, .qwenCode: return true     // 订阅制
        }
    }

    /// 估算"省下一张图的视觉 token"：本地 OCR/抽文本代替把图片发给视觉模型时，每张图省下的视觉 token。
    /// 各家不一（OpenAI 高清 ~765-1100、Claude 按像素），取中庸值 ~1000，仅作"感受性"估算。
    static let visionTokensPerImage = 1000
}
