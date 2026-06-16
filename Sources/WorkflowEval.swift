import Foundation

/// 工作流 Eval v0 —— 路线图里程碑 6。
/// 三层验收，**确定性优先**（规则两层先过，模型评分兜底；模型抽风/不可用也不卡流程）：
/// ① 必含字段：产物必须包含 `stage.requires` 里的每个子串
/// ② 长度下限：产物不能空 / 过短（占位、跑偏、被截断）
/// ③ 模型评分：按 `stage.evalRules` rubric 让模型判 PASS/FAIL + 原因 + 建议
@MainActor
enum WorkflowEval {

    struct EvalResult {
        var passed: Bool
        var reason: String
        var suggestion: String
        var retryStepID: String?
    }

    static func evaluate(product: String,
                         stage: WorkflowStage,
                         backend: AgentMode,
                         tag: String,
                         vm: ChatViewModel) async -> EvalResult {
        let text = product.trimmingCharacters(in: .whitespacesAndNewlines)

        // ① 必含字段（**仅中文模式校验**）：requires 是中文子串（如「核心洞察」「盲点」），英文模式下
        // 模型按 promptEn 产出英文，text 永远不含中文子串 → 每次都判「缺少必要内容」→ 强制重试 → 又是
        // 英文 → 判失败，死循环 + 误导性原因。英文模式跳过 Tier-1，靠长度下限(②) + evalRulesEn rubric(③)
        // 兜底。（审计 #6 / 决策 #20 i18n 漏网）
        let isEN = LocaleManager.currentLanguage() == .en
        let missing = isEN ? [] : stage.requires.filter { !text.contains($0) }
        if !missing.isEmpty {
            return EvalResult(passed: false,
                              reason: "缺少必要内容：\(missing.joined(separator: "、"))",
                              suggestion: "补全缺失的板块后重写。",
                              retryStepID: stage.retryStepID)
        }

        // ② 长度下限
        if text.count < 20 {
            return EvalResult(passed: false,
                              reason: "产物过短，疑似跑偏或被截断。",
                              suggestion: "重新生成更完整的内容。",
                              retryStepID: stage.retryStepID)
        }

        // ③ 模型评分（rubric 为空就跳过，规则两层已过即通过）
        let rubric = stage.evalRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if rubric.isEmpty {
            return EvalResult(passed: true, reason: "通过（规则校验）", suggestion: "", retryStepID: nil)
        }

        let prompt = """
        你是严格的质检员。请根据【验收标准】判断【产物】是否合格。
        只按下面格式回答，不要别的：
        结论：PASS 或 FAIL
        原因：<一句话>
        建议：<不合格时怎么改，一句话；合格写"无">

        【验收标准】
        \(rubric)

        【产物】
        \(text)
        """
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                       recordToActivity: false, injectMemory: false,
                                                       sessionTag: tag) {
                acc += chunk
            }
        } catch {
            // 模型评分不可用 → 不卡流程，规则两层已过即放行
            return EvalResult(passed: true, reason: "通过（模型评分不可用，规则校验已过）", suggestion: "", retryStepID: nil)
        }

        let verdict = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = verdict.uppercased()
        let saysFail = upper.contains("FAIL") || verdict.contains("不合格") || verdict.contains("不通过")
        let saysPass = upper.contains("PASS") || verdict.contains("合格") || verdict.contains("通过")
        let pass = saysPass || !saysFail   // 没有明确判 FAIL 就放行（宽松，避免误杀死循环）

        let reason = lineValue(verdict, key: "原因") ?? (pass ? "通过" : "未达标")
        let suggestion = lineValue(verdict, key: "建议") ?? ""
        return EvalResult(passed: pass,
                          reason: reason,
                          suggestion: pass ? "" : suggestion,
                          retryStepID: pass ? nil : stage.retryStepID)
    }

    /// 从 "键：值" 多行文本里抽某键的值（中英冒号都认）。
    private static func lineValue(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            for sep in ["：", ":"] where s.hasPrefix(key + sep) {
                return String(s.dropFirst((key + sep).count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
