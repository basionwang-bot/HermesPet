import Foundation

/// 画布生成调度器 —— 两阶段：
///
/// **Stage 1 · 规划**：调用 Online AI / Hermes，把模板 slot 列表 + 用户主题
/// 喂给 LLM，让它返回一份 `[ElementPlan]` JSON（每个 slot 的具体 prompt + 文本初稿）。
///
/// **Stage 2 · 填充**：根据每个 element 的 kind 并行启动生成 ——
/// - 图（heroImage / sceneImage）→ CodexClient 单图生成
/// - 文（title / sellingPoint / cta / text）→ 直接用 Stage 1 出的文本（不再二次跑）
/// 每个 element 独立 streaming 状态，UI 实时显示 skeleton → 完成
///
/// **意图识别（v1）**：用户在画布底部输入框输入 → 调 Online AI 返回 action JSON，
/// 客户端按 action 应用（replace_element / add_element / regenerate_all 等）
@MainActor
final class CanvasService {

    /// 用 ChatViewModel 持有的两个 OpenAI 兼容 client 之一来做"规划" + "微调意图识别"。
    /// 优先用 directClient（在线 AI，零依赖），fallback 到 apiClient（Hermes Gateway）
    private let textClient: APIClient
    private let codexClient: CodexClient
    private let storage: StorageManager

    init(textClient: APIClient, codexClient: CodexClient, storage: StorageManager) {
        self.textClient = textClient
        self.codexClient = codexClient
        self.storage = storage
    }

    // MARK: - Stage 1：规划

    /// **事实调研** —— 在规划之前先让 LLM 用知识库输出 topic 的客观参数。
    /// 后续 plan() 把这份事实摘要塞给 LLM，让卖点带具体数据而不是"令人惊叹"这种空话。
    /// 失败不抛错，返回空字符串（plan() 自己处理空 fact 的情况）
    func researchTopic(_ topic: String) async -> String {
        let prompt = """
        请基于你的知识对产品/主题"\(topic)"做一次简短事实调研，给后续电商文案用。
        如果是真实存在的产品 / 品牌，输出客观信息：
        - 类别（饮料 / 数码 / 服装 / 食品 / ...）
        - 关键参数（容量 / 规格 / 成分 / 价格档）
        - 知名度档（全球品牌 / 区域品牌 / 小众 / 未知）
        - 3-5 个真实的、可验证的产品特征点（基于公开信息，不要编造）

        如果是抽象主题或虚构内容，简要说明它的基本属性即可。

        输出格式：纯文本，4-8 行，每行一条事实，不要 markdown 标题不要解释。
        """
        do {
            return try await streamAndCollect(messages: [ChatMessage(role: .user, content: prompt)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""   // 调研失败不影响主流程
        }
    }

    /// 让 AI 把模板 slot 列表填充成具体的 CanvasElement 数组。
    /// - 输入：模板 + 用户主题 + 事实摘要（researchSummary）
    /// - 输出：一组 CanvasElement，文本类卡片的 content 已经填好，图片类卡片 prompt 已经具体化但 imagePath 还空
    ///
    /// 失败兜底：若 LLM 输出 JSON 解析失败，直接用模板的 promptHint 替换 `<topic>` 占位作为 prompt
    func plan(template: CanvasTemplate, topic: String, researchSummary: String = "") async throws -> [CanvasElement] {
        // "自由规划" 模板：让 AI 自己设计 slot 数量和类型
        if template.id == "custom" {
            return try await planFreeform(topic: topic, researchSummary: researchSummary)
        }

        // 普通模板：用 LLM 把每个 slot 填具体
        let slotList = template.slots.enumerated().map { idx, slot in
            "\(idx). [\(slot.kind.rawValue)] \(slot.caption) — \(slot.promptHint.replacingOccurrences(of: "<topic>", with: topic))"
        }.joined(separator: "\n")

        // 事实摘要：有就拼进 prompt，让 LLM 知道客观参数；没有就跳过
        let researchSection = researchSummary.isEmpty ? "" : """

        **关于这个主题的客观事实**（基于公开信息，请把这些数据用进卖点和文案）：
        \(researchSummary)


        """

        let prompt = """
        你的工作：替换模板 prompt 里的中括号占位符为**具体的中文文字内容**。**不要改模板结构、不要改英文描述**，只填占位符。

        主题：\(topic)
        \(researchSection)
        下面是 5 个 slot 的模板 prompt（已经写好框架，里面 [...] 占位符需要你填）：

        \(slotList)

        ===========================================
        你的任务（精确执行，**不要发挥**）：
        ===========================================

        对每个 slot：
        1. 保留原英文 prompt 的整体结构、构图描述、风格 anchor —— **一个字不要改**
        2. 把 [TOPIC] 全部替换为：\(topic)
        3. 把所有 [CHINESE_XXX] / [BADGE_TEXT] / [SCENE_CONTEXT] / [FEATURE_N_LABEL] / [POINT_N_TITLE] / [POINT_N_DESC] 这种带方括号的占位符，替换为符合**字符数限制**和**风格要求**的实际中文文字。

        填中文文字的规则：
        - **基于上面的客观事实**（如有），不要空话不要"令人惊叹"
        - **严格符合占位符的字符数提示**（如 "[CHINESE_HEADLINE_4_TO_6_CHARS]" 就填 4-6 个汉字）
        - **数据具体**：用 "0 糖 0 卡 · 330ml" / "1886 年至今" 这种带数字的，不要泛泛
        - **品牌色暗示**：在 prompt 里"brand-color" / "brand-accent" 这类词后面附加颜色名（如 (#ff0000 vibrant red for Coca-Cola brand)），让 image-2 知道具体颜色

        返回 JSON 数组：
        [
          {"slot": 0, "kind": "heroImage", "caption": "主图 ① · 核心卖点海报", "prompt_or_content": "填好占位符的完整英文 prompt"},
          {"slot": 1, ...},
          ...共 5 条
        ]

        **只返回 JSON 数组**，不要 markdown fence，不要任何解释文字。
        """

        let messages = [ChatMessage(role: .user, content: prompt)]
        let rawJSON = try await streamAndCollect(messages: messages)
        let plans = try parsePlans(rawJSON)

        // 把 plan 跟模板 slot 对齐，组装 CanvasElement
        var elements: [CanvasElement] = []
        for (idx, slot) in template.slots.enumerated() {
            let plan = plans.first(where: { $0.slot == idx }) ?? ElementPlan(
                slot: idx,
                kind: slot.kind.rawValue,
                caption: slot.caption,
                promptOrContent: slot.promptHint.replacingOccurrences(of: "<topic>", with: topic)
            )
            let isImage = slot.kind == .heroImage || slot.kind == .sceneImage
            let element = CanvasElement(
                kind: slot.kind,
                caption: plan.caption.isEmpty ? slot.caption : plan.caption,
                prompt: plan.promptOrContent,
                slot: idx,
                content: isImage ? "" : plan.promptOrContent,
                // 图片类初始为 pending（等并行生成）；文字类规划阶段已经出内容了，直接 done
                status: isImage ? .pending : .done
            )
            elements.append(element)
        }
        return elements
    }

    /// "自由规划"模式 —— 让 AI 看主题自己决定生成什么卡片
    private func planFreeform(topic: String, researchSummary: String = "") async throws -> [CanvasElement] {
        let researchSection = researchSummary.isEmpty ? "" : "\n关于这个主题的客观事实：\n\(researchSummary)\n"
        let prompt = """
        用户想就主题"\(topic)"生成一个内容画布。请你自由设计 4-8 张卡片，
        组合用图（heroImage / sceneImage）+ 文（title / sellingPoint / cta / text）。
        \(researchSection)
        返回 JSON 数组，每项：
        {"slot": 序号, "kind": "类型", "caption": "小标题", "prompt_or_content": "图给英文prompt / 文给中文文案"}
        只返回 JSON，不要任何解释。
        """
        let messages = [ChatMessage(role: .user, content: prompt)]
        let rawJSON = try await streamAndCollect(messages: messages)
        let plans = try parsePlans(rawJSON)

        var elements: [CanvasElement] = []
        for plan in plans.sorted(by: { $0.slot < $1.slot }) {
            guard let kind = CanvasElementKind(rawValue: plan.kind) else { continue }
            let isImage = kind == .heroImage || kind == .sceneImage
            elements.append(CanvasElement(
                kind: kind,
                caption: plan.caption,
                prompt: plan.promptOrContent,
                slot: plan.slot,
                content: isImage ? "" : plan.promptOrContent,
                status: isImage ? .pending : .done
            ))
        }
        return elements
    }

    // MARK: - Stage 2：图片填充

    /// 串行生成所有 pending 的图片元素 —— 一次一个 codex 进程，挨个完成。
    ///
    /// **为什么不并发**（曾经踩过的坑）：CodexClient 是单例，内部 `_pendingImages`
    /// 数组共享；codex 生成图都写到固定目录 `~/.codex/generated_images/`。多个进程
    /// 并发跑时，A 进程结束扫目录会把 B/C 进程的图也算进自己的成果，takeGeneratedImages
    /// 又把全部图一次性取走，导致后续 element 拿到错位 / 重复的图（实测 5 张图重复 2 张）。
    /// 同时 4 个进程并发 post 灵动岛通知，stepStarted/stepEnded 计数错乱、elapsedTask
    /// timer 一直在跑导致灵动岛卡住。
    ///
    /// 串行解决两个问题：通知严格一一对应、图片归属明确。代价是 5 张图 ~6 分钟，
    /// 用 CanvasView 头部的进度文案缓解体感。
    func fillImages(board: CanvasBoard,
                    canvasID: String,
                    update: @MainActor @escaping (_ elementID: String, _ mutate: (inout CanvasElement) -> Void) -> Void
    ) async {
        let pending = board.elements.filter {
            ($0.kind == .heroImage || $0.kind == .sceneImage) && $0.status == .pending
        }
        let refs = board.referenceImagePaths

        for element in pending {
            // 用户主动 cancel / 切到别的对话 不会立刻打断这里的 task，
            // 但 Task.isCancelled 会变 true，提前结束循环避免继续 spawn 子进程
            if Task.isCancelled { break }

            await generateOneImage(
                element: element,
                canvasID: canvasID,
                referenceImagePaths: refs,
                update: update
            )
        }
    }

    /// 生成单张图 —— 走 CodexClient（spawn codex exec），完成后写盘 + 回调 update。
    /// 关键变化：如果传了 referenceImagePaths（用户上传的真实产品图），
    /// 把它们作为 ChatMessage.imagePaths 传给 Codex，让 codex 看图后再生成场景，
    /// 解决"AI 凭想象画品牌错版"的根本问题
    private func generateOneImage(element: CanvasElement,
                                  canvasID: String,
                                  referenceImagePaths: [String] = [],
                                  update: @MainActor @escaping (_ elementID: String, _ mutate: (inout CanvasElement) -> Void) -> Void) async {
        update(element.id) { $0.status = .generating }

        do {
            // 根据是否有参考图，prompt 措辞不同：
            // - 有参考图：明确告诉 codex "保持这件产品的真实外观，只变化场景/构图"
            // - 无参考图：原来的 "from scratch" 模式
            // **v4 prompt 简化**：去掉重复约束和大量 NOT 指令（image-2 对正向描述更敏感），
            // 把全部精力放在描述"成品参考"。size: 1024x1024 是 codex CLI 当前支持的方形最大尺寸，
            // 客户端导出时会保持原始分辨率（后续如果有需求可下采样到 800x800 标准）
            let request: String
            if !referenceImagePaths.isEmpty {
                request = """
                Generate ONE photorealistic 1:1 square image (1024x1024) following the detailed specification below.

                The attached reference image shows the actual product. Preserve its real-world appearance (brand identity, label text, packaging shape, exact colors) and render it in the new scene/layout described.

                Style baseline: professional 2025 Tmall flagship store main image (主图) aesthetic. High craftsmanship, premium feel, precise Chinese typography rendering with correct stroke weight and character spacing.

                Save the output as a PNG image.

                === DETAILED SPECIFICATION ===
                \(element.prompt)
                """
            } else {
                request = """
                Generate ONE photorealistic 1:1 square image (1024x1024) following the detailed specification below.

                Style baseline: professional 2025 Tmall flagship store main image (主图) aesthetic. High craftsmanship, premium feel, precise Chinese typography rendering with correct stroke weight and character spacing.

                Save the output as a PNG image.

                === DETAILED SPECIFICATION ===
                \(element.prompt)
                """
            }
            // 把参考图塞进 user message 的 imagePaths —— CodexClient 内部会用 -i 传给 codex CLI
            let userMessage = ChatMessage(
                role: .user,
                content: request,
                imagePaths: referenceImagePaths
            )
            // suppressIslandUpdates: 画布生图走自己 toolbar 显示进度，
            // 不让 codex 的 ToolStarted/Ended 通知去触发灵动岛状态机
            let stream = codexClient.streamCompletion(
                messages: [userMessage],
                suppressIslandUpdates: true
            )
            for try await _ in stream {
                // codex 的文本输出我们不关心，只关心生成的图
            }
            // 取出 codex 这一轮生成的图（CodexClient 内部缓存的 _pendingImages）
            let generated = codexClient.takeGeneratedImages()
            guard let first = generated.first else {
                update(element.id) {
                    $0.status = .failed
                    $0.errorMessage = "Codex 没有返回图片"
                }
                return
            }
            // 落盘到 ~/.hermespet/images/<canvasID>-<elementID>.png
            let paths = storage.persistImages([first], forMessage: canvasID + "-" + element.id)
            update(element.id) {
                $0.imagePath = paths.first
                $0.status = .done
            }
        } catch {
            update(element.id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 单卡重生

    /// 用户点单卡片"重新生成"按钮 —— 把这一张卡重新走一遍生成流程
    /// - referenceImagePaths：由 ChatViewModel 从 board 里取出来传过来
    func regenerateOne(element: CanvasElement,
                       canvasID: String,
                       referenceImagePaths: [String] = [],
                       update: @MainActor @escaping (_ elementID: String, _ mutate: (inout CanvasElement) -> Void) -> Void) async {
        let isImage = element.kind == .heroImage || element.kind == .sceneImage
        if isImage {
            await generateOneImage(
                element: element,
                canvasID: canvasID,
                referenceImagePaths: referenceImagePaths,
                update: update
            )
        } else {
            // 文字卡：重新跑一次 prompt 拿新文案
            update(element.id) { $0.status = .generating }
            do {
                let messages = [ChatMessage(role: .user, content: element.prompt)]
                let content = try await streamAndCollect(messages: messages)
                update(element.id) {
                    $0.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    $0.status = .done
                }
            } catch {
                update(element.id) {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 意图识别（底部对话微调）

    /// 用户在画布底部输入框说话 → AI 返回 action JSON → 应用到画布
    enum CanvasAction {
        case replaceElement(elementID: String, newPrompt: String)
        case addElement(kind: CanvasElementKind, caption: String, prompt: String)
        case editText(elementID: String, newContent: String)
        case regenerateAll
        case noop(reason: String)
    }

    func interpret(userInput: String, board: CanvasBoard) async throws -> CanvasAction {
        let elementsDesc = board.elements.enumerated().map { idx, e in
            "\(idx). id=\(e.id) kind=\(e.kind.rawValue) caption=\"\(e.caption)\""
        }.joined(separator: "\n")

        let prompt = """
        你正在帮用户编辑一个画布。当前画布主题：\(board.topic)
        卡片列表：
        \(elementsDesc)

        用户刚说：\(userInput)

        请判断用户意图，返回一个 JSON：
        - 替换某张图/文：{"action":"replace","element_id":"xxx","new_prompt":"新的英文图prompt或中文文案"}
        - 加一张新卡片：{"action":"add","kind":"heroImage|sceneImage|title|sellingPoint|cta|text","caption":"小标题","prompt":"内容"}
        - 编辑某张文字卡内容：{"action":"edit","element_id":"xxx","new_content":"新内容"}
        - 整个画布重做：{"action":"regenerate_all"}
        - 没听懂或不需要改：{"action":"noop","reason":"原因"}

        只返回 JSON，不要任何额外文字。
        """
        let raw = try await streamAndCollect(messages: [ChatMessage(role: .user, content: prompt)])
        return parseAction(raw, board: board)
    }

    // MARK: - 辅助：流式收集

    /// 把 streamCompletion 的 chunks 合并成完整字符串 —— 我们只关心最终文本
    private func streamAndCollect(messages: [ChatMessage]) async throws -> String {
        var full = ""
        for try await delta in textClient.streamCompletion(messages: messages) {
            full += delta
        }
        return full
    }

    // MARK: - 辅助：JSON 解析

    /// LLM 返回的 plan JSON 结构 —— 解析失败时 caller 用模板默认值兜底
    private struct ElementPlan: Codable {
        let slot: Int
        let kind: String
        let caption: String
        let promptOrContent: String

        enum CodingKeys: String, CodingKey {
            case slot, kind, caption
            case promptOrContent = "prompt_or_content"
        }
    }

    /// 从 LLM 返回的原始字符串里抽出 JSON 数组 —— 容忍 markdown fence、前后多余文本
    private func parsePlans(_ raw: String) throws -> [ElementPlan] {
        let cleaned = extractJSONArray(from: raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw NSError(domain: "Canvas", code: 1, userInfo: [NSLocalizedDescriptionKey: "规划 JSON 编码失败"])
        }
        return try JSONDecoder().decode([ElementPlan].self, from: data)
    }

    /// 在 LLM 输出里找到 `[ ... ]` 的部分；找不到就返回原文（让 JSONDecoder 报错给 caller）
    private func extractJSONArray(from raw: String) -> String {
        if let start = raw.firstIndex(of: "["),
           let end = raw.lastIndex(of: "]"),
           start < end {
            return String(raw[start...end])
        }
        return raw
    }

    /// 把意图识别返回的 JSON 解析成 CanvasAction
    private func parseAction(_ raw: String, board: CanvasBoard) -> CanvasAction {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .noop(reason: "未能解析 AI 响应")
        }
        let action = obj["action"] as? String ?? ""
        switch action {
        case "replace":
            guard let id = obj["element_id"] as? String,
                  let np = obj["new_prompt"] as? String,
                  board.elements.contains(where: { $0.id == id })
            else { return .noop(reason: "缺少 element_id 或匹配不到") }
            return .replaceElement(elementID: id, newPrompt: np)
        case "add":
            guard let kindStr = obj["kind"] as? String,
                  let kind = CanvasElementKind(rawValue: kindStr),
                  let caption = obj["caption"] as? String,
                  let p = obj["prompt"] as? String
            else { return .noop(reason: "add 参数不完整") }
            return .addElement(kind: kind, caption: caption, prompt: p)
        case "edit":
            guard let id = obj["element_id"] as? String,
                  let nc = obj["new_content"] as? String,
                  board.elements.contains(where: { $0.id == id })
            else { return .noop(reason: "缺少 element_id 或匹配不到") }
            return .editText(elementID: id, newContent: nc)
        case "regenerate_all":
            return .regenerateAll
        default:
            return .noop(reason: obj["reason"] as? String ?? "未识别")
        }
    }
}
