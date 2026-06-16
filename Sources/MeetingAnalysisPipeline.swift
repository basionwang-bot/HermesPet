import Foundation

/// 会议纪要「精读管线」—— 把"读一遍就总结"(草率根源)换成多阶段精读,根治草率。
///
/// 五步(专业纪要师的流程搬到 AI 上):
/// ① 分段精读(map)—— 长稿切段,每段忠实结构化提取,不 skim、不丢细节
/// ② 归并 + 定类型(reduce)—— 各段要点归并去重排序 + 判断内容类型(工作会/讲座/访谈…)
/// ③ 成稿(compose,流式)—— 按类型选骨架写纪要,具体不空话
/// ④ 自检补漏(critique,流式替换)—— 拿草稿对照要点查漏补缺、去空话、删编造
///
/// **设计成自包含**:只依赖 `ChatViewModel.streamOneShotAsk` + 一个 backend,
/// 未来可整体包装成 WTF workflow(inputs=[transcript] / output=纪要)。
@MainActor
enum MeetingAnalysisPipeline {

    /// 跑完整精读管线,返回最终纪要(首行含 `主题：`)。失败返回 nil(调用方回退)。
    /// - onStage: 阶段进度文字("精读第 2/5 段…")
    /// - onPartial: 成稿 / 自检 的流式文本(写进 model.summary 让用户看着长)
    static func run(transcript: String,
                    vm: ChatViewModel,
                    backend: AgentMode,
                    tag: String,
                    onStage: @escaping (String) -> Void,
                    onPartial: @escaping (String) -> Void) async -> String? {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return nil }

        let chunks = chunkize(clean, maxChars: 2800)

        // ① 分段精读(只有真的长才分;短稿直接把转写当要点喂给归并)
        var notes: [String] = []
        if chunks.count > 1 {
            for (i, c) in chunks.enumerated() {
                onStage("精读第 \(i + 1)/\(chunks.count) 段…")
                if let n = await callOnce(vm: vm, backend: backend, tag: "\(tag)-map\(i)",
                                          prompt: mapPrompt(chunk: c, idx: i + 1, total: chunks.count)) {
                    notes.append(n)
                }
            }
        } else {
            notes = [clean]
        }
        guard !notes.isEmpty else { return nil }

        // ② 归并 + 定类型
        onStage("归并整理脉络…")
        let merged = notes.joined(separator: "\n\n")
        let organized = await callOnce(vm: vm, backend: backend, tag: "\(tag)-reduce",
                                       prompt: reducePrompt(notes: merged)) ?? merged

        // ③ 成稿(流式)
        onStage("撰写纪要…")
        var draft = ""
        await stream(vm: vm, backend: backend, tag: "\(tag)-compose",
                     prompt: composePrompt(organized: organized)) { acc in
            draft = acc; onPartial(acc)
        }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            return organized.isEmpty ? nil : organized
        }

        // ④ 自检补漏(流式替换)
        onStage("自检补漏…")
        var refined = ""
        await stream(vm: vm, backend: backend, tag: "\(tag)-critique",
                     prompt: critiquePrompt(draft: draft, groundTruth: organized)) { acc in
            refined = acc; onPartial(acc)
        }
        let refinedClean = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        // 自检结果异常短(可能跑偏/被截断)→ 保留草稿,不让质量倒退
        return refinedClean.count > draft.count / 2 ? refinedClean : draft
    }

    // MARK: - AI 调用封装

    /// 非流式:累加完整结果返回。
    private static func callOnce(vm: ChatViewModel, backend: AgentMode,
                                 tag: String, prompt: String) async -> String? {
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                       recordToActivity: false, sessionTag: tag) {
                acc += chunk
            }
        } catch { return nil }
        let t = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 流式:每次累加后回调(给 UI 看着长)。
    private static func stream(vm: ChatViewModel, backend: AgentMode,
                               tag: String, prompt: String, onAcc: (String) -> Void) async {
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                       recordToActivity: false, sessionTag: tag) {
                acc += chunk
                onAcc(acc)
            }
        } catch { /* 保留已累加部分 */ }
    }

    // MARK: - 分段(按句子边界,尽量不拦腰截断)

    private static func chunkize(_ text: String, maxChars: Int) -> [String] {
        if text.count <= maxChars { return [text] }
        var chunks: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if cur.count >= maxChars, "。！？\n.!?".contains(ch) {
                chunks.append(cur); cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(cur) }
        // 极端:某段过长无标点 → 硬切,防单段过大
        return chunks.flatMap { seg -> [String] in
            guard seg.count > maxChars * 2 else { return [seg] }
            return stride(from: 0, to: seg.count, by: maxChars).map {
                let s = seg.index(seg.startIndex, offsetBy: $0)
                let e = seg.index(s, offsetBy: maxChars, limitedBy: seg.endIndex) ?? seg.endIndex
                return String(seg[s..<e])
            }
        }
    }

    // MARK: - 四步提示词(管线的灵魂)

    private static func mapPrompt(chunk: String, idx: Int, total: Int) -> String {
        """
        你在分段精读一份语音转写稿(可能有错别字、口语啰嗦,请结合上下文理解)。这是第 \(idx)/\(total) 段。
        只针对这一段,提取**忠实、具体**的要点(markdown 列表):
        - 这段讲了什么(按小主题分条)
        - 出现的具体事实 / 数字 / 名称 / 结论 / 决定 / 待办 / 疑问 / 分歧
        - 贴着原文,**不泛化、不编造、不写"讨论了X"这类空话**;原文没说清的标「(不确定)」
        只输出要点列表,不要任何前后缀。

        【本段】:
        \(chunk)
        """
    }

    private static func reducePrompt(notes: String) -> String {
        """
        下面是一份长录音**分段精读**出来的要点(按时间顺序)。请你:
        1. 判断内容类型(从:工作会议 / 技术讲座 / 学习讨论 / 头脑风暴 / 访谈 / 复盘 / 其它 里选一个)
        2. 把要点按主题**归并、去重、排出逻辑顺序**,保留所有具体事实 / 数字 / 结论
        严格按此格式输出:
        类型：<一个词>
        <归并组织后的结构化要点,markdown>

        【各段要点】:
        \(notes)
        """
    }

    private static func composePrompt(organized: String) -> String {
        """
        你是顶级会议纪要整理大师。根据下面的「类型」和「结构化要点」,写一份高质量纪要。
        - 第一行输出 `主题：xxx`(8-16字,精准概括这场到底讲了什么)
        - **按类型选骨架**:
          · 工作会议 → 议题 / 关键讨论 / 决议 / 行动项(谁·何时) / 遗留问题
          · 技术讲座·学习讨论 → 主线脉络 / 核心知识点 / 重点难点 / 易混淆点 / 待消化的问题
          · 头脑风暴 → 抛出的想法 / 形成的方向 / 待验证
          · 访谈 → 核心观点 / 关键事实 / 金句
          · 其它 → 自拟最贴切的结构
        - **具体、有依据、敢下结论;杜绝"进行了交流 / 讨论了相关问题"这类正确的废话**
        - 只基于给定要点,不编造
        直接输出 markdown 纪要(含首行 `主题：`)。

        \(organized)
        """
    }

    private static func critiquePrompt(draft: String, groundTruth: String) -> String {
        """
        你是严格的纪要质检员。下面是一份纪要**草稿**和它依据的**原始要点**。请对照,产出**改进后的最终版**:
        - 草稿漏掉了原始要点里哪些重要结论 / 数字 / 决定 / 行动项 / 分歧?**补回去**
        - 哪里太笼统、有空话?**换成具体的**
        - 有没有原始要点里没有的内容(编造)?**删掉**
        - 结构清晰、措辞凝练,保留首行 `主题：xxx`
        **直接输出改进后的完整纪要 markdown**,不要"以下是改进版"之类任何解释或前缀。

        【草稿】:
        \(draft)

        【原始要点(以此为准)】:
        \(groundTruth)
        """
    }
}
