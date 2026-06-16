import SwiftUI
import AppKit

/// AI 会议纪要控制台 —— 两个独立窗口：
/// ① **录音悬浮条**（贴灵动岛下方，小）：录音中红点 + 计时 + 实时字幕（含豆包式分段纠错跳变）+ 完成/取消。
/// ② **纪要结果窗**（右上角，留屏可拖动）：停录后弹出，AI 整理的纪要**流式**写进来；整理完留屏，
///    顶部显示 AI 提炼的**主题**，底部有 ▶ 回听录音 / 复制 / 打开笔记 / 完成。
///
/// 这是 WTF「会议纪要整理」workflow 的输入管道：录音 → 分段纠错 → AI 整理(含主题) → 留屏 + 存笔记。
///
/// **为什么独立 NSWindow**：守决策 #1（灵动岛 frame 永不变），都用独立 panel。
/// **可交互**：NSPanel + .nonactivatingPanel + becomesKeyOnlyIfNeeded → 点按钮才短暂成 key，
/// 不抢用户在开会 app 里的焦点。
/// **隔离**：@MainActor 纯 UI；通知更新都在 SwiftUI `.onReceive`（天然 MainActor，守决策 #5）。
@MainActor
final class MeetingOverlayController: NSObject {
    static let shared = MeetingOverlayController()

    private var recordingPanel: NSPanel?
    private var summaryPanel: NSPanel?
    private let model = MeetingPanelModel()
    private weak var viewModel: ChatViewModel?
    private var timerTask: Task<Void, Never>?
    private var player: NSSound?            // 回听录音的播放器（强引用，避免 play() 后被释放）
    private var isCollapsed = false         // 录音中是否已收进灵动岛（大窗隐藏、灵动岛声波）

    private override init() { super.init() }

    // MARK: - 入口（⌘⇧M / 菜单）—— toggle：没录→开始；录音中→结束并整理
    func toggle(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        if MeetingRecorder.shared.isRecording {
            finish()
        } else if MeetingRecorder.shared.state == .finishing {
            return   // 上一场正在收尾冲刷（stopAndFinalize），忽略
        } else if model.phase == .summarizing {
            return   // 正在整理，忽略重复触发
        } else {
            start()
        }
    }

    private func start() {
        Task { @MainActor in
            let (granted, errMsg) = await MeetingRecorder.shared.requestPermissions()
            guard granted else {
                Self.banner(errMsg ?? "无法获取麦克风 / 语音识别权限")
                return
            }
            // 注入豆包式分段纠错钩子：每段走在线后端快速纠同音字/标点/专名（默认在线 AI 最快）
            installSegmentRefiner()
            guard MeetingRecorder.shared.start() else { return }
            model.reset()
            model.phase = .recording
            isCollapsed = false
            showRecordingPanel()
            startTimer()
        }
    }

    func finishTapped() { finish() }

    func cancelTapped() {
        MeetingRecorder.shared.cancel()
        MeetingRecorder.shared.segmentRefiner = nil
        stopTimer()
        isCollapsed = false
        hideRecording()
    }

    // MARK: - 收起 / 展开（录音中大窗 ⇄ 灵动岛声波）
    /// 「⌃ 收起」：大窗消失，灵动岛右侧亮声波。录音后台继续不丢。
    func collapse() {
        guard MeetingRecorder.shared.isRecording else { return }
        isCollapsed = true
        recordingPanel?.orderOut(nil)
        NotificationCenter.default.post(name: .init("HermesPetMeetingCollapsed"), object: nil)
    }

    /// 点灵动岛声波 → 重新展开大窗（只展开、绝不停录，用户选的防误触）。
    func expandFromIsland() {
        guard MeetingRecorder.shared.isRecording, isCollapsed else { return }
        isCollapsed = false
        NotificationCenter.default.post(name: .init("HermesPetMeetingExpanded"), object: nil)
        showRecordingPanel()
    }

    /// 录音收起态查询 —— AppDelegate 点灵动岛时判断要不要展开大窗
    var isRecordingCollapsed: Bool { MeetingRecorder.shared.isRecording && isCollapsed }

    private func finish() {
        MeetingRecorder.shared.segmentRefiner = nil   // 先摘钩子：尾段不再走纠错，加快收尾
        stopTimer()
        isCollapsed = false
        hideRecording()
        Task { @MainActor in
        // stopAndFinalize 会等引擎把没落地的"最后一句"冲出来再封卷（封顶 5s）——
        // SpeechAnalyzer 的 final 在说完后 ~1-2s 才送达，同步 stop 会丢尾段
        let (transcript, audioPath) = await MeetingRecorder.shared.stopAndFinalize()
        let rawTranscript = MeetingRecorder.shared.rawTranscript
        let realtimeClean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard realtimeClean.count >= 2 else {
            Self.banner("这次没录到可识别的内容")
            return
        }
        model.summary = ""
        model.title = ""
        model.notePath = nil
        model.audioPath = audioPath
        model.meetingDate = Self.nowText()
        model.phase = .summarizing
        showSummaryWindow()

        // ⭐ 渐进式呈现（用户定的"两波"方案）：
        // 第一波（快）：用实时稿**立刻**整理出纪要 → 用户秒看到反馈，不干等。
        // 第二波（后台慢）：完整重转音频 → 拿完整文字 → **静默**重生成纪要替换 + 更新笔记。
        let token = model.sessionToken     // 快照这场会的身份，第二波回写前校验（防覆盖新会议）
        // 双路会议（系统音频出过声）跳过第二波：完整重转只有麦克风一路，
        // 替换会把「【对方】」的话全部弄丢——实时双路稿就是这场会的终稿。
        let hadSystemAudio = MeetingRecorder.shared.hasSystemAudioContent
        await summarize(transcript: realtimeClean, rawTranscript: rawTranscript, audioPath: audioPath)
        if let audioPath, !audioPath.isEmpty, !hadSystemAudio {
            await refineWithFullTranscript(audioPath: audioPath, realtimeLen: realtimeClean.count, token: token)
        }
        }   // Task end
    }

    /// 第二波：后台完整重转 → 若拿到明显更完整的文字，**静默**重生成纪要替换（不打扰用户，用户定）。
    /// **token 校验**：转写要跑几分钟，期间用户可能关窗/开下一个会 → reset 换了 token → 这里失配就放弃，
    /// 绝不把旧会议的稿写到新会议的 model/笔记上（审查抓到的 P0）。
    private func refineWithFullTranscript(audioPath: String, realtimeLen: Int, token: UUID) async {
        guard let vm = viewModel else { return }
        guard model.sessionToken == token else { return }
        model.refining = true
        defer { if model.sessionToken == token { model.refining = false } }

        let url = URL(fileURLWithPath: audioPath)
        guard let better = try? await MeetingFileTranscriber.transcribe(audioURL: url, progress: nil) else {
            NSLog("[Meeting] 完整转写失败/无结果，保留实时稿纪要"); return
        }
        guard model.sessionToken == token else { NSLog("[Meeting] 会议已切换，丢弃旧完整稿"); return }
        let fullClean = better.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fullClean.count >= 10, fullClean.count > Int(Double(realtimeLen) * 1.15) else {
            NSLog("[Meeting] 完整稿未明显更全（实时 \(realtimeLen) / 完整 \(fullClean.count)），不重生成"); return
        }
        let windowOpen = (summaryPanel?.isVisible == true)
        model.cleanTranscript = fullClean

        // 第二波：用精读管线重整理(质量优先),带会议 id 独立 session 不串上下文（审查 P2）
        let finalText = await MeetingAnalysisPipeline.run(
            transcript: fullClean, vm: vm, backend: vm.meetingSummaryBackend,
            tag: "meeting-full-\(token.uuidString.prefix(8))",
            onStage: { s in if windowOpen, self.model.sessionToken == token { self.model.stageText = s } },
            onPartial: { acc in
                if windowOpen, self.model.sessionToken == token {
                    let (t, b) = Self.splitTitleAndBody(acc)
                    if !t.isEmpty { self.model.title = t }
                    self.model.summary = b
                }
            }
        )
        if model.sessionToken == token { model.stageText = "" }
        guard model.sessionToken == token else { NSLog("[Meeting] 会议已切换，丢弃旧重整理结果"); return }
        guard let finalText, !finalText.isEmpty else { NSLog("[Meeting] 完整稿重整理失败，保留实时稿纪要"); return }
        let (title, body) = Self.splitTitleAndBody(finalText)
        let finalTitle = title.isEmpty ? model.title : title
        if windowOpen { model.title = finalTitle; model.summary = body }
        rewriteNoteWithFull(title: finalTitle, summary: body, fullTranscript: fullClean, audioPath: audioPath, token: token)
        NSLog("[Meeting] ✅ 已用完整稿（\(fullClean.count)字）精读管线刷新纪要")
    }

    /// 洞察段界标 —— 用明确起止标记包裹，重写笔记时精确保留（不靠"标记到文件末尾"的脆弱假设，审查 P0#2）
    static let insightStart = "<!-- INSIGHTS_START -->"
    static let insightEnd = "<!-- INSIGHTS_END -->"

    /// 用完整稿覆盖第一波那篇笔记（保留已生成的洞察）。token 校验防覆盖新会议笔记。
    private func rewriteNoteWithFull(title: String, summary: String, fullTranscript: String,
                                     audioPath: String?, token: UUID) {
        guard model.sessionToken == token, let path = model.notePath else { return }
        let existing = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? ""
        // 抽出界标包裹的洞察段（若有），重写时原样保留
        var insightBlock = ""
        if let s = existing.range(of: Self.insightStart), let e = existing.range(of: Self.insightEnd) {
            insightBlock = "\n\n---\n\n" + String(existing[s.lowerBound..<e.upperBound])
        }
        try? Self.composeNoteBody(title: title, summary: summary, fullTranscript: fullTranscript,
                                  audioPath: audioPath, insightBlock: insightBlock)
            .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .init("HermesPetNotesDocReplaced"), object: nil, userInfo: ["path": path])
    }

    /// 组装笔记正文（纪要 + 原始转写 + 可选录音链接 + 可选洞察块）。第一波/第二波共用，保证结构一致。
    static func composeNoteBody(title: String, summary: String, fullTranscript: String,
                               audioPath: String?, insightBlock: String) -> String {
        let now = Date()
        let dateDF = DateFormatter(); dateDF.dateFormat = "yyyy-MM-dd HH:mm"
        var body = "# \(title)\n\n> 🎙️ 会议记录 · \(dateDF.string(from: now))\n\n"
        body += summary + "\n\n## 原始转写\n\n"
        let quoted = fullTranscript.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        body += quoted.isEmpty ? "> （无）" : quoted
        body += "\n"
        if let audioPath, !audioPath.isEmpty { body += "\n[🎧 录音文件](file://\(audioPath))\n" }
        body += insightBlock
        return body
    }

    // MARK: - 分段纠错钩子（豆包式）
    private func installSegmentRefiner() {
        guard let vm = viewModel else { return }
        let backend = vm.meetingSummaryBackend
        MeetingRecorder.shared.segmentRefiner = { segment, context in
            let prompt = """
            你是语音转写纠错助手。下面是一段中文语音实时转写的文字，可能有同音字错误、专有名词识别错、缺标点。请只做"轻度纠错"：
            - 纠正明显的同音/近音错别字和专有名词
            - 补上自然的标点
            - 绝对不要改写、不要扩写、不要总结、不要删除信息，保持原话和长度基本一致
            - 只输出纠正后的这段文字本身，不要任何解释、引号或前后缀

            【前文（仅供理解上下文，不要纠正它、不要输出它）】：\(context)

            【需要纠正的文字】：\(segment)
            """
            var acc = ""
            do {
                for try await chunk in await vm.streamOneShotAsk(
                    prompt: prompt,
                    modeOverride: backend,
                    recordToActivity: false,
                    sessionTag: "meeting-refine"
                ) {
                    acc += chunk
                }
            } catch {
                return nil   // 纠错失败保留原文
            }
            let cleaned = acc.trimmingCharacters(in: .whitespacesAndNewlines)
            // 防 AI 跑偏：纠错结果长度与原文差太多就放弃（说明它在扩写/总结，不可信）
            guard !cleaned.isEmpty, cleaned.count < segment.count * 2 + 10 else { return nil }
            return cleaned
        }
    }

    // MARK: - 重新转写已有录音（用户要拿旧录音验证新引擎）

    /// 找最近一段录音，用新引擎重转 + 整理（结果窗 + 笔记）。菜单触发。
    func reanalyzeLatestRecording(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/meetings", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let m4as = files.filter { $0.pathExtension == "m4a" }
        guard let latest = m4as.max(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }) else {
            Self.banner("还没有录音文件可以转写")
            return
        }
        NSLog("[Meeting] 重新转写最近录音：\(latest.lastPathComponent)")
        transcribeExistingRecording(url: latest)
    }

    /// 对一段已有录音：新引擎完整转写 → AI 整理（复用 summarize：结果窗 + 存笔记 + 洞察 tab）。
    func transcribeExistingRecording(url: URL) {
        guard viewModel != nil else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.banner("找不到录音文件"); return
        }
        model.reset()
        model.audioPath = url.path
        model.meetingDate = Self.nowText()
        model.phase = .transcribing
        model.transcribeProgress = "正在用新引擎完整转写录音…"
        showSummaryWindow()

        let token = model.sessionToken
        Task { @MainActor in
            let full = try? await MeetingFileTranscriber.transcribe(audioURL: url) { text in
                Task { @MainActor in
                    let m = MeetingOverlayController.shared.model
                    guard m.sessionToken == token else { return }
                    m.transcribeChars = text.count
                    m.transcribeProgress = "已转写 \(text.count) 字…"
                }
            }
            guard model.sessionToken == token else { return }
            let clean = (full ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2 else {
                model.phase = .done
                model.title = "转写未出内容"
                model.summary = "_（没有转出文字。若首次使用，可能中文模型还在下载，稍等片刻再试一次。）_"
                return
            }
            model.phase = .summarizing
            await analyzeWithPipeline(transcript: clean, rawTranscript: clean, audioPath: url.path)
        }
    }

    /// 用「精读管线」整理一份完整转写(全套五步)→ 结果窗 + 存笔记。重转录音走这条。
    private func analyzeWithPipeline(transcript: String, rawTranscript: String, audioPath: String?) async {
        guard let vm = viewModel else { closeSummary(); return }
        model.cleanTranscript = transcript
        let token = model.sessionToken
        let final = await MeetingAnalysisPipeline.run(
            transcript: transcript, vm: vm, backend: vm.meetingSummaryBackend,
            tag: "meeting-pipe-\(token.uuidString.prefix(8))",
            onStage: { s in if self.model.sessionToken == token { self.model.stageText = s } },
            onPartial: { acc in
                guard self.model.sessionToken == token else { return }
                let (t, b) = Self.splitTitleAndBody(acc)
                if !t.isEmpty { self.model.title = t }
                self.model.summary = b
            }
        )
        guard model.sessionToken == token else { return }
        model.stageText = ""
        let (title, body) = Self.splitTitleAndBody(final ?? "")
        model.title = title.isEmpty ? (model.title.isEmpty ? "会议纪要" : model.title) : title
        if !body.isEmpty { model.summary = body }
        else if model.summary.isEmpty { model.summary = "_（整理失败，仅保留原始转写）_" }
        model.notePath = saveToNotes(title: model.title, summary: model.summary,
                                     rawTranscript: rawTranscript, audioPath: audioPath)
        model.phase = .done
    }

    // MARK: - AI 整理（一次调用同时出「主题」+「纪要」，流式写进结果窗）
    private func summarize(transcript: String, rawTranscript: String, audioPath: String?) async {
        guard let vm = viewModel else { closeSummary(); return }
        model.cleanTranscript = transcript     // 存住（纠错后的稿），供「深度洞察」按需分析
        let prompt = Self.buildSummaryPrompt(transcript)
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(
                prompt: prompt,
                modeOverride: vm.meetingSummaryBackend,  // 默认在线 AI 最快
                recordToActivity: false,
                sessionTag: "meeting-summary"
            ) {
                acc += chunk
                let (title, bodyText) = Self.splitTitleAndBody(acc)
                model.title = title
                model.summary = bodyText
            }
        } catch {
            Self.banner("AI 整理失败：\(error.localizedDescription)")
            let (title, bodyText) = Self.splitTitleAndBody(acc)
            model.title = title.isEmpty ? "会议纪要" : title
            model.summary = bodyText.isEmpty ? "_（AI 整理失败，仅保留原始转写）_" : bodyText
            model.notePath = saveToNotes(title: model.title, summary: model.summary,
                                         rawTranscript: rawTranscript, audioPath: audioPath)
            model.phase = .done
            return
        }
        let (title, bodyText) = Self.splitTitleAndBody(acc)
        model.title = title.isEmpty ? "会议纪要" : title
        model.summary = bodyText
        model.notePath = saveToNotes(title: model.title, summary: bodyText,
                                     rawTranscript: rawTranscript, audioPath: audioPath)
        model.phase = .done
    }

    /// 笔记里写干净的 markdown（不裸露 <details>/路径源码）：标题 + 日期 + 纪要正文 +
    /// markdown 引用块包原始转写（折叠交给预览模式，但即便看源码也整洁）。录音不写进正文（结果窗才回听）。
    @discardableResult
    private func saveToNotes(title: String, summary: String, rawTranscript: String, audioPath: String?) -> String? {
        let fileDF = DateFormatter(); fileDF.dateFormat = "MM-dd"
        let body = Self.composeNoteBody(title: title, summary: summary, fullTranscript: rawTranscript,
                                        audioPath: audioPath, insightBlock: "")
        // 文件名用 AI 提炼的主题 + 日期，不再干巴巴叫"会议纪要"
        let safeTitle = title.replacingOccurrences(of: "/", with: " ").prefix(20)
        let note = NotesStore.shared.createNote(title: "\(safeTitle) \(fileDF.string(from: Date()))", body: body)
        if note == nil {
            Self.banner("⚠️ 笔记保存失败，本次纪要仅在窗口显示，请手动复制")
        }
        return note?.path
    }

    // MARK: - 深度洞察（按需：点「洞察」tab 才生成）
    /// 切到「洞察」tab —— 首次切就触发生成（按需，省 token）；已生成/生成中则只切视图。
    func switchTab(_ tab: MeetingPanelModel.Tab) {
        model.tab = tab
        if tab == .insights, model.insightPhase == .none {
            Task { @MainActor in await generateInsights() }
        }
    }

    /// 基于纪要 + 转写深挖：核心洞察 / 盲点 / 灵魂拷问 / 延伸建议。流式写进洞察 tab，完成后追加进同一篇笔记。
    private func generateInsights() async {
        guard let vm = viewModel, !model.cleanTranscript.isEmpty || !model.summary.isEmpty else { return }
        model.insightPhase = .generating
        model.insights = ""
        let prompt = Self.buildInsightPrompt(summary: model.summary, transcript: model.cleanTranscript)
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(
                prompt: prompt,
                modeOverride: vm.meetingSummaryBackend,
                recordToActivity: false,
                sessionTag: "meeting-insight"
            ) {
                acc += chunk
                model.insights = acc
            }
        } catch {
            Self.banner("洞察生成失败：\(error.localizedDescription)")
            model.insightPhase = (acc.isEmpty ? .none : .done)   // 没出内容就允许重试
            if acc.isEmpty { return }
            model.insights = acc
        }
        model.insightPhase = .done
        appendInsightsToNote(model.insights)
    }

    /// 把洞察追加进已存的纪要笔记（两层都进文档——纪要是外置记忆、洞察是增值）。
    /// 用界标 `<!-- INSIGHTS_START/END -->` 包裹，让第二波重写笔记时能精确保留（审查 P0#2）。
    private func appendInsightsToNote(_ insights: String) {
        guard let path = model.notePath, !insights.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard !content.contains(Self.insightStart) else { return }   // 防重复追加
        content += "\n\n---\n\n\(Self.insightStart)\n## 💡 深度洞察\n\n\(insights)\n\(Self.insightEnd)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .init("HermesPetNotesDocReplaced"),
                                        object: nil, userInfo: ["path": path])
    }

    // MARK: - 回听录音
    func playbackTapped() {
        guard let path = model.audioPath, !path.isEmpty else { return }
        if let p = player, p.isPlaying { p.stop(); model.isPlaying = false; return }
        guard let sound = NSSound(contentsOfFile: path, byReference: false) else {
            Self.banner("录音文件打不开了")
            return
        }
        sound.delegate = self
        player = sound
        model.isPlaying = true
        sound.play()
    }

    // MARK: - 生成精美网页（Artifact）
    /// 把当前纪要（+洞察，若已生成）交给 AI，生成一张完整的精美 HTML 网页，在独立窗口里渲染。
    func makeWebpageTapped() {
        guard let vm = viewModel, !model.summary.isEmpty else {
            Self.banner("还没有可生成网页的内容")
            return
        }
        var doc = model.summary
        if !model.insights.isEmpty {
            doc += "\n\n## 💡 深度洞察\n\n\(model.insights)"
        }
        ArtifactWindowController.shared.present(
            markdown: doc,
            title: model.title.isEmpty ? "会议纪要" : model.title,
            mode: vm.meetingSummaryBackend,
            vm: vm
        )
    }

    // MARK: - 计时器
    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, MeetingRecorder.shared.isRecording else { break }
                self.model.elapsed = MeetingRecorder.shared.elapsedSeconds
            }
        }
    }
    private func stopTimer() { timerTask?.cancel(); timerTask = nil }

    // MARK: - 录音悬浮条窗口
    private func showRecordingPanel() {
        if recordingPanel == nil {
            // 决策 #1/#6 升级：裸 NSHostingView 即便 sizingOptions=[] 在 macOS 26 仍会经
        // updateAnimatedWindowSize 反推 setFrame（2026-06-11 00:09 崩溃实锤）；只有
        // NSHostingController + sizingOptions=[] 真正禁掉反推（照语音陪聊/迷你岛范本）
            let hosting = NSHostingController(rootView: MeetingConsoleView(model: model))
            if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.level = HermesWindowLevel.meeting
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            p.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）
            p.setContentSize(NSSize(width: 460, height: 220))
            recordingPanel = p
        }
        if let panel = recordingPanel, let screen = NSScreen.main {
            let sf = screen.frame
            let x = sf.midX - panel.frame.width / 2
            let y = sf.maxY - 38 - panel.frame.height - 6
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        recordingPanel?.orderFront(nil)
    }
    private func hideRecording() { recordingPanel?.orderOut(nil) }

    // MARK: - 纪要结果窗
    private func showSummaryWindow() {
        if summaryPanel == nil {
            // 决策 #1/#6 升级：裸 NSHostingView 即便 sizingOptions=[] 在 macOS 26 仍会经
        // updateAnimatedWindowSize 反推 setFrame（2026-06-11 00:09 崩溃实锤）；只有
        // NSHostingController + sizingOptions=[] 真正禁掉反推（照语音陪聊/迷你岛范本）（00:09 崩溃头号嫌疑：第二波重转的流式 markdown 正在这窗里不断长高）
            let hosting = NSHostingController(rootView: MeetingSummaryView(model: model))
            if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
            hosting.view.wantsLayer = true

            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.level = HermesWindowLevel.chat
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）
            p.setContentSize(NSSize(width: 440, height: 580))
            summaryPanel = p
        }
        if let panel = summaryPanel, let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let x = vf.maxX - panel.frame.width - 24
            let y = vf.maxY - panel.frame.height - 12
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        summaryPanel?.orderFront(nil)
    }

    func closeSummary() {
        player?.stop(); player = nil; model.isPlaying = false
        summaryPanel?.orderOut(nil)
        model.phase = .idle
        model.reset()
    }

    func openNotesTapped() {
        NotificationCenter.default.post(name: .init("HermesPetEnterWritingMode"), object: nil)
        closeSummary()
    }

    func copySummaryTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.summary, forType: .string)
        Self.banner("纪要已复制")
    }

    // MARK: - 工具
    private static func banner(_ text: String) {
        NotificationCenter.default.post(name: .init("HermesPetScreenshotAdded"),
                                        object: nil, userInfo: ["text": text, "count": 0])
    }

    private static func nowText() -> String {
        let df = DateFormatter(); df.dateFormat = "M月d日 HH:mm"
        return df.string(from: Date())
    }

    /// 从 AI 输出里拆出第一行的「主题:」+ 其余纪要正文。AI 被要求首行输出 `主题：xxx`。
    private static func splitTitleAndBody(_ raw: String) -> (title: String, body: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let nl = text.firstIndex(of: "\n") else {
            // 还没输出到换行：如果首行像主题就先拿来当 title，正文暂空
            if let t = parseTitleLine(text) { return (t, "") }
            return ("", text)
        }
        let firstLine = String(text[..<nl])
        if let t = parseTitleLine(firstLine) {
            let body = String(text[text.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (t, body)
        }
        return ("", text)
    }

    private static func parseTitleLine(_ line: String) -> String? {
        let l = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["主题：", "主题:", "标题：", "标题:"] {
            if l.hasPrefix(prefix) {
                let t = String(l.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
        }
        return nil
    }

    private static func buildSummaryPrompt(_ transcript: String) -> String {
        """
        你是专业的会议纪要整理助手。下面是一段会议的语音转写文字（可能有同音识别错误、口语化、缺标点）。请整理成结构清晰的中文会议纪要。

        **第一行**必须先输出一个简短主题，格式严格为：`主题：xxx`（6-16 字，概括这次会议在聊什么，用于做文件名）。
        从**第二行**开始输出纪要正文，用以下结构：

        ## 一句话总结
        ## 关键讨论点
        ## 决议事项
        ## 待办任务
        ## 待确认 / 遗留问题

        要求：
        - 待办任务用 markdown 表格：| 任务 | 负责人 | 时间 |，没提到就留空
        - 纠正明显的同音或识别错误，去掉口水话和重复
        - 忠于原意、不编造没说过的内容；信息不足处如实写"（未提及）"
        - 除第一行主题外，正文直接输出 markdown，不要开场白

        会议转写内容：

        \(transcript)
        """
    }

    /// 深度洞察 prompt —— 灵魂所在。要的不是复述会议（纪要已经做了），而是「看懂这场会、给用户思考」。
    /// 四个维度（用户选定）：核心洞察 / 盲点 / 灵魂拷问 / 延伸建议。**少而锋利**，宁缺毋滥。
    private static func buildInsightPrompt(summary: String, transcript: String) -> String {
        """
        你是一位犀利、有洞察力的资深顾问。下面是一场会议的纪要和转写。会议「发生了什么」已经被纪要记下了，**不要复述纪要**。你的任务是帮当事人「看懂这场会、想得更深一层」，输出真正有价值的思考。

        严格用以下四个部分（每部分用 `## ` 标题），少而锋利、宁缺毋滥，**不要正确的废话**：

        ## 🎯 核心洞察
        表面讨论之下，真正重要的 2-3 件事是什么。点破当事人可能没意识到的关键。

        ## ⚠️ 盲点 / 没说出口的
        这场会**该讨论却没讨论**的：被忽略的风险、缺位的关键角色、没人问出口的问题、过于乐观的假设。这部分最有价值，要敢说。

        ## ❓ 灵魂拷问
        3-4 个戳人的问题，逼当事人想得更深。要具体、扎到这场会的要害，不要泛泛（如"目标是否清晰"这种谁都能问的不要）。

        ## 💡 延伸建议
        超出明面待办的、更高一层的下一步建议。可以包含"如果是我会怎么做"。

        要求：
        - 基于会议真实内容，**绝不编造**没出现的事实；但允许基于内容做合理推断和延伸，并说明"这是推断"
        - 直接、有观点、像一个聪明朋友私下点拨你，不要打官腔、不要面面俱到
        - 直接输出 markdown，不要开场白

        ===== 会议纪要 =====
        \(summary)

        ===== 会议转写（更细节，供你深挖）=====
        \(transcript.prefix(8000))
        """
    }
}

// MARK: - NSSoundDelegate（回听播完复位按钮）
extension MeetingOverlayController: NSSoundDelegate {
    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor in self.model.isPlaying = false }
    }
}

// MARK: - Model
@Observable
@MainActor
final class MeetingPanelModel {
    enum Phase { case idle, recording, transcribing, summarizing, done }   // transcribing=完整离线重转
    enum Tab { case minutes, insights }                       // 纪要 / 深度洞察
    enum InsightPhase { case none, generating, done }         // 洞察按需生成的状态

    var phase: Phase = .idle
    var elapsed: Int = 0
    var transcript: String = ""
    var transcribeProgress: String = ""    // 完整离线重转的实时进度文字
    var transcribeChars: Int = 0           // 已转写字数（底部统计图标 + 进度反馈）
    var stageText: String = ""             // 精读管线阶段文字（"精读 2/5 段…"/"自检补漏…"）
    var level: Float = 0
    var title: String = ""
    var summary: String = ""
    var notePath: String?
    var audioPath: String?
    var meetingDate: String = ""
    var isPlaying = false
    var refining = false                  // 第二波完整转写精修中（角落小标，不挡操作）
    /// 会议实例身份 —— 每场会 reset 时换新。第二波后台 Task / 跨会议 session 用它校验
    /// "现在还是不是当初那场会"，防旧 Task 覆盖新会议状态/笔记（审查抓到的 P0）。
    var sessionToken = UUID()

    // 深度洞察（按需生成，点「洞察」tab 才触发）
    var tab: Tab = .minutes
    var insights: String = ""
    var insightPhase: InsightPhase = .none
    var cleanTranscript: String = ""        // 留着供洞察分析（纠错后的稿）

    func reset() {
        elapsed = 0; transcript = ""; transcribeProgress = ""; transcribeChars = 0; stageText = ""; level = 0; title = ""; summary = ""
        notePath = nil; audioPath = nil; meetingDate = ""; isPlaying = false; refining = false
        tab = .minutes; insights = ""; insightPhase = .none; cleanTranscript = ""
        sessionToken = UUID()       // 换新身份 → 任何在途的旧会议后台 Task 校验失配后作废
    }
}

// MARK: - 录音悬浮条 View
struct MeetingConsoleView: View {
    @Bindable var model: MeetingPanelModel

    private var timeText: String {
        let m = model.elapsed / 60, s = model.elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                    .opacity(0.55 + Double(min(max(model.level, 0), 1)) * 0.45)
                Text("录音中")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Text(timeText)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                // 收起到灵动岛（录音后台继续，屏幕腾空）
                Button { MeetingOverlayController.shared.collapse() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("收起到灵动岛")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {   // 决策 #21：不套 GeometryReader
                    Text(model.transcript.isEmpty ? "开始说话，实时字幕会显示在这里…" : model.transcript)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .id("sub")
                }
                .onChange(of: model.transcript) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("sub", anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                Button { MeetingOverlayController.shared.cancelTapped() } label: {
                    Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(MeetingButtonStyle(bg: Color.white.opacity(0.15)))
                Button { MeetingOverlayController.shared.finishTapped() } label: {
                    Text("完成并整理").frame(maxWidth: .infinity)
                }
                .buttonStyle(MeetingButtonStyle(bg: Color.accentColor))
            }
            .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 8)
        }
        .frame(width: 460, height: 220)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.9)))
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetMeetingPartial"))) { note in
            if let t = note.userInfo?["text"] as? String { model.transcript = t }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetMeetingLevel"))) { note in
            if let l = note.userInfo?["level"] as? Float { model.level = l }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetMeetingError"))) { note in
            if let m = note.userInfo?["message"] as? String {
                NotificationCenter.default.post(name: .init("HermesPetScreenshotAdded"),
                                                object: nil, userInfo: ["text": m, "count": 0])
            }
        }
    }
}

// MARK: - 纪要结果窗 View（留屏；主题大标题 + markdown 纪要 + 回听按钮）
struct MeetingSummaryView: View {
    @Bindable var model: MeetingPanelModel

    /// 底部字数：转写中用实时计数，有完整稿后用完整稿长度。
    private var displayCharCount: Int {
        model.cleanTranscript.isEmpty ? model.transcribeChars : model.cleanTranscript.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（可拖动区）—— AI 提炼的主题做大标题
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title.isEmpty ? "整理中…" : model.title)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(model.meetingDate).font(.system(size: 11)).foregroundStyle(.secondary)
                        if model.refining {
                            HStack(spacing: 3) {
                                ProgressView().controlSize(.mini)
                                Text("完整转写中，稍后自动更精准").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                        // 精读管线阶段（"精读 2/5 段…"/"自检补漏…"）
                        if model.phase == .summarizing, !model.stageText.isEmpty {
                            HStack(spacing: 3) {
                                ProgressView().controlSize(.mini)
                                Text(model.stageText).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Spacer()
                if model.phase == .summarizing { ProgressView().controlSize(.small) }
                Button { MeetingOverlayController.shared.closeSummary() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            // Tab 切换：📋 纪要（发生了什么）/ 💡 洞察（这意味着什么）。纪要好了才出现
            if model.phase == .done {
                HStack(spacing: 6) {
                    MeetingTabButton(title: "📋 纪要", active: model.tab == .minutes, badge: false) {
                        MeetingOverlayController.shared.switchTab(.minutes)
                    }
                    MeetingTabButton(title: "💡 洞察", active: model.tab == .insights,
                                     badge: model.insightPhase == .done && model.tab != .insights) {
                        MeetingOverlayController.shared.switchTab(.insights)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }

            Divider()

            // 分析中（转写 / 整理）顶部进度条 —— 让用户看到"正在跑"
            if model.phase == .transcribing || model.phase == .summarizing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.horizontal, 16).padding(.top, 6)
            }

            // 正文区：按 tab 显示 纪要 / 洞察（流式；不套 GeometryReader，决策 #21）
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if model.tab == .minutes {
                            if model.phase == .transcribing {
                                VStack(alignment: .leading, spacing: 8) {
                                    placeholderRow(icon: "waveform.and.magnifyingglass",
                                                   text: "正在完整转写录音（确保不漏内容）…")
                                    if !model.transcribeProgress.isEmpty {
                                        Text(model.transcribeProgress)
                                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                                            .lineLimit(3).truncationMode(.head)
                                    }
                                }
                            } else if model.summary.isEmpty {
                                placeholderRow(icon: "sparkles", text: "AI 正在整理纪要，请稍候…")
                            } else {
                                MarkdownTextView(content: model.summary)
                            }
                        } else {
                            // 洞察 tab
                            switch model.insightPhase {
                            case .generating where model.insights.isEmpty:
                                placeholderRow(icon: "brain", text: "AI 正在深挖这场会议的洞察…")
                            case .none:
                                placeholderRow(icon: "brain", text: "正在准备深度洞察…")
                            default:
                                MarkdownTextView(content: model.insights)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("body")
                }
                .onChange(of: model.summary) { _, _ in
                    if model.phase == .summarizing, model.tab == .minutes { proxy.scrollTo("body", anchor: .bottom) }
                }
                .onChange(of: model.insights) { _, _ in
                    if model.insightPhase == .generating, model.tab == .insights { proxy.scrollTo("body", anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)

            // 回听录音条（有录音文件就显示，整理中也能先听）
            if model.audioPath?.isEmpty == false {
                Divider()
                Button { MeetingOverlayController.shared.playbackTapped() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 18)).foregroundStyle(Color.accentColor)
                        Text(model.isPlaying ? "停止回放" : "回听本次录音")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            // 底部按钮
            if model.phase == .done {
                VStack(spacing: 8) {
                    // ✨ 把纪要变成一张精美网页（Artifact，全 AI 生成、独立窗口展示）
                    Button { MeetingOverlayController.shared.makeWebpageTapped() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles.rectangle.stack")
                            Text("生成精美网页").font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 9).fill(
                                LinearGradient(colors: [.indigo, .purple],
                                               startPoint: .leading, endPoint: .trailing))
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        Button { MeetingOverlayController.shared.copySummaryTapped() } label: {
                            Label("复制", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                        }
                        Button { MeetingOverlayController.shared.openNotesTapped() } label: {
                            Label("打开笔记", systemImage: "note.text").frame(maxWidth: .infinity)
                        }
                        Button { MeetingOverlayController.shared.closeSummary() } label: {
                            Text("完成").frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.large)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            } else {
                Text("正在生成，可先去忙别的，纪要会留在这里")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }

            // 最下面：字数统计图标（转写中实时涨 / 完成后显示总字数）
            if displayCharCount > 0 {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft").font(.system(size: 10))
                    Text("\(displayCharCount.formatted()) 字").font(.system(size: 11, weight: .medium))
                    if model.phase == .transcribing {
                        Text("· 转写中…").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 5)
            }
        }
        .frame(width: 440, height: 580)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(NSColor.windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder
    private func placeholderRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

/// 纪要/洞察 tab 切换按钮（active 高亮 + badge 红点提醒洞察已就绪）
struct MeetingTabButton: View {
    let title: String
    let active: Bool
    let badge: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                if badge {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct MeetingButtonStyle: ButtonStyle {
    let bg: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(bg))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
