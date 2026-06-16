import Foundation
import AppKit

/// 工作流 harness —— 路线图里程碑 3/4。
///
/// 把 `MeetingAnalysisPipeline` 那套"多阶段调模型 + 流式进度 + 质量护栏"**泛化成通用执行器**：
/// 顺序跑 `workflow.effectiveStages`，每步调 `vm.streamOneShotAsk`，
/// 人工节点暂停等用户确认，eval 不通过按 `retryStepID` 回退重跑，最终产出 `WorkflowProduct`。
///
/// 设计约束（守 CLAUDE.md）：
/// - 决策 #5：`@MainActor enum`，所有回调留在 MainActor（同 MeetingAnalysisPipeline），不跨线程
/// - sessionToken 防串：写任何状态前比对 `model.sessionToken`，旧运行绝不覆盖新运行
/// - 决策 #13：每个阶段 post `HermesPetToolStarted/Ended` → 灵动岛免费亮进度
@MainActor
enum WorkflowRunner {

    /// 跑完一次工作流。返回最终产物；中止 / 失败 / 空产出返回 nil。
    static func run(workflow: Workflow,
                    input: String,
                    backend: AgentMode,
                    vm: ChatViewModel,
                    model: RunModel) async -> WorkflowProduct? {
        let token = model.sessionToken
        func alive() -> Bool { model.sessionToken == token }

        let stages = workflow.effectiveStages
        var priorOutputs: [String: String] = [:]
        var prevOutput = ""
        var productMarkdown: String? = nil
        var retriesUsed: [String: Int] = [:]

        NotificationCenter.default.post(name: .init("HermesPetTaskStarted"), object: nil)

        var i = 0
        while i < stages.count {
            guard alive() else { return nil }
            let stage = stages[i]
            model.currentStepIndex = i
            model.partialText = ""
            model.statusLine = stage.title + "…"
            setStep(model, stage.id) { $0.status = "running"; $0.startedAt = Date() }
            postToolStarted(stage)

            // —— 人工确认节点（暂停 → 等用户 允许/跳过/中止）
            if stage.requireConfirm {
                model.run.status = "awaitingConfirm"
                persist(model)
                let decision = await model.awaitConfirm(title: stage.title)
                guard alive() else { return nil }
                model.run.status = "running"
                switch decision {
                case .abort:
                    postToolEnded(stage)
                    return nil   // abort 已在 model.abort() 里落状态 + 发 TaskFinished
                case .skip:
                    setStep(model, stage.id) { $0.status = "skipped"; $0.endedAt = Date() }
                    postToolEnded(stage); persist(model)
                    i += 1; continue
                case .allow:
                    break
                }
            }

            // —— eval 阶段：验收，不通过按 retryStepID 回退重跑
            if stage.kind == "eval" {
                let result = await WorkflowEval.evaluate(
                    product: productMarkdown ?? prevOutput, stage: stage, backend: backend,
                    tag: "wf-\(model.run.id)-\(stage.id)-\(retriesUsed[stage.id, default: 0])", vm: vm)
                guard alive() else { return nil }
                setStep(model, stage.id) {
                    $0.status = result.passed ? "succeeded" : "failed"
                    $0.evalVerdict = (result.passed ? "✓ " : "✗ ") + result.reason
                    $0.endedAt = Date()
                }
                postToolEnded(stage)
                if !result.passed {
                    model.evalReason = result.reason
                    model.evalSuggestion = result.suggestion
                    let used = retriesUsed[stage.id, default: 0]
                    // retryStepID 为 nil 时回退到当前阶段重跑（与 WorkflowStage 文档「nil=回退到 product 阶段」
                    // 一致）。原实现 `let target = result.retryStepID` 在 nil 时直接跳过 → maxRetries>0 但没设
                    // retryStepID 的工作流永远不会重试（审计发现的逻辑漏洞）。
                    let target = result.retryStepID ?? stage.id
                    if used < stage.maxRetries,
                       let targetIdx = stages.firstIndex(where: { $0.id == target }) {
                        retriesUsed[stage.id] = used + 1
                        for j in targetIdx...i { resetStep(model, stages[j].id) }   // 回退区间重置
                        persist(model)
                        i = targetIdx
                        continue
                    }
                    // 重试用尽：不硬失败，保留已有产物（别让用户白跑），原因留在面板
                }
                persist(model)
                i += 1
                continue
            }

            // —— transform / product 阶段：调模型
            let prompt = stage.buildPrompt(input: input, priorOutputs: priorOutputs, prevOutput: prevOutput)
            let tag = "wf-\(model.run.id)-\(stage.id)-\(retriesUsed[stage.id, default: 0])"
            var out = ""
            if stage.streaming {
                let err = await stream(vm: vm, backend: backend, tag: tag, prompt: prompt) { acc in
                    guard alive() else { return }
                    out = acc
                    model.partialText = acc
                }
                if let err { model.lastError = err }
            } else {
                let r = await callOnce(vm: vm, backend: backend, tag: tag, prompt: prompt)
                out = r.text ?? ""
                if let e = r.error { model.lastError = e }
            }
            guard alive() else { return nil }

            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            // product 阶段异常空 → 保留上一步，不让质量倒退（照 pipeline 护栏）
            if stage.kind == "product" && trimmed.count < 2 { out = prevOutput }

            priorOutputs[stage.id] = out
            prevOutput = out
            if stage.kind == "product" { productMarkdown = out }
            setStep(model, stage.id) {
                $0.status = "succeeded"
                $0.output = String(out.prefix(20000))   // 截断，避免 index.json 爆
                $0.endedAt = Date()
            }
            postToolEnded(stage)
            persist(model)
            i += 1
        }

        guard alive() else { return nil }
        let finalMD = (productMarkdown ?? prevOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalMD.isEmpty else {
            finish(model, status: "failed", success: false)
            return nil
        }
        model.productMarkdown = finalMD
        finish(model, status: "succeeded", success: true)
        return WorkflowProduct(kind: workflow.outputRender, markdown: finalMD, title: workflow.name)
    }

    // MARK: - AI 调用封装（照搬 MeetingAnalysisPipeline.callOnce / stream）

    private static func callOnce(vm: ChatViewModel, backend: AgentMode,
                                 tag: String, prompt: String) async -> (text: String?, error: String?) {
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                       recordToActivity: false, injectMemory: false,
                                                       sessionTag: tag) {
                acc += chunk
            }
        } catch {
            NSLog("[WorkflowRunner] callOnce(\(tag)) 后端 \(backend.rawValue) 报错: \(error)")
            return (nil, "\(error)")
        }
        let t = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            NSLog("[WorkflowRunner] callOnce(\(tag)) 后端 \(backend.rawValue) 返回空")
            return (nil, "后端返回空（无报错）")
        }
        return (t, nil)
    }

    /// 返回错误描述（nil = 成功）。
    private static func stream(vm: ChatViewModel, backend: AgentMode,
                               tag: String, prompt: String, onAcc: (String) -> Void) async -> String? {
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                       recordToActivity: false, injectMemory: false,
                                                       sessionTag: tag) {
                acc += chunk
                onAcc(acc)
            }
        } catch {
            NSLog("[WorkflowRunner] stream(\(tag)) 后端 \(backend.rawValue) 报错: \(error)")
            return "\(error)"
        }
        if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("[WorkflowRunner] stream(\(tag)) 后端 \(backend.rawValue) 返回空")
            return "后端返回空（无报错）"
        }
        return nil
    }

    // MARK: - 轨迹 / 进度 helpers

    private static func setStep(_ model: RunModel, _ stepID: String,
                                _ mut: (inout WorkflowStepRecord) -> Void) {
        guard let idx = model.run.steps.firstIndex(where: { $0.stepID == stepID }) else { return }
        mut(&model.run.steps[idx])
        model.run.updatedAt = Date()
    }
    private static func resetStep(_ model: RunModel, _ stepID: String) {
        setStep(model, stepID) {
            $0.status = "pending"; $0.output = ""; $0.evalVerdict = nil; $0.retryCount += 1
        }
    }
    private static func persist(_ model: RunModel) {
        WorkflowRunStore.shared.update(model.run)
    }
    private static func finish(_ model: RunModel, status: String, success: Bool) {
        model.run.status = status
        model.run.updatedAt = Date()
        WorkflowRunStore.shared.update(model.run)
        NotificationCenter.default.post(name: .init("HermesPetTaskFinished"),
                                        object: nil, userInfo: ["success": success])
    }
    private static func postToolStarted(_ stage: WorkflowStage) {
        NotificationCenter.default.post(name: .init("HermesPetToolStarted"), object: nil,
                                        userInfo: ["id": stage.id, "name": stage.title,
                                                   "arg": "", "file_path": ""])
    }
    private static func postToolEnded(_ stage: WorkflowStage) {
        NotificationCenter.default.post(name: .init("HermesPetToolEnded"), object: nil,
                                        userInfo: ["id": stage.id])
    }
}
