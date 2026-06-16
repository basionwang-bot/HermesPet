import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

/// Artifact（AI 生成网页）子系统 —— 把一份 Markdown 文档交给 AI，让它产出一个
/// **完整、自包含、可直接渲染**的 HTML 网页，在独立窗口里用 WKWebView 展示。
///
/// 路线 = Claude / GPT 桌面端的「Artifacts」：AI 全程生成 HTML+CSS(+JS)，每次设计都不同。
///
/// 设计要点（踩过 / 规避的坑）：
/// - WKWebView 渲染 **本地临时文件**（`~/.hermespet/artifacts/<id>.html`）而非 `loadHTMLString`：
///   文件 URL 路径下 https CDN（Tailwind / Chart.js）子资源加载最稳，也方便「在浏览器打开 / 导出」复用同一份文件。
/// - **不注册任何 `WKScriptMessageHandler`** → 页面里的 JS 无法回调进 App，沙箱里的沙箱，足够安全。
/// - 生成走 `ChatViewModel.streamOneShotAsk`（跟随用户为会议选的 backend），流式累加，结束再渲染（避免半截 HTML 闪烁）。
/// - `sessionToken` 防串场：用户连开两次 / 关窗重开时，旧的在途生成 Task 校验失配即作废。

// MARK: - WKWebView 的 SwiftUI 封装

/// 渲染一个本地 HTML 文件 URL。仅在 URL 变化时重新加载（避免 SwiftUI 每次 update 都 reload 重置滚动）。
struct ArtifactWebView: NSViewRepresentable {
    let fileURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 允许页面跑 JS（Artifact 可能用 Chart.js 等）；无 message handler，JS 碰不到 App。
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")   // 透明底，跟窗口背景融合
        if let url = fileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            context.coordinator.lastURL = url
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url = fileURL, context.coordinator.lastURL != url else { return }
        context.coordinator.lastURL = url
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    final class Coordinator {
        var lastURL: URL?
    }
}

// MARK: - 状态模型

@MainActor
@Observable
final class ArtifactModel {
    enum Phase { case generating, done, failed }

    var phase: Phase = .generating
    var title: String = ""
    var streamingCode: String = ""      // 生成中：实时累加的原始输出（给用户「正在制作」的反馈）
    var fileURL: URL?                    // 完成后：渲染用的本地 HTML 文件
    var recordID: String?               // 对应 ArtifactStore 档案 id（重生成覆盖同一条、聊天链接指向它）
    var canRegenerate = true            // 从展览馆重开的没有源文档 → 不显示「换设计」
    var errorText: String = ""
    /// 生成实例身份 —— 每次 present/regenerate 换新，旧的在途 Task 校验失配即作废。
    var sessionToken = UUID()

    func resetForNewRun(title: String) {
        phase = .generating
        self.title = title
        streamingCode = ""
        fileURL = nil
        recordID = nil
        canRegenerate = true
        errorText = ""
        sessionToken = UUID()
    }
}

// MARK: - 窗口内容视图

struct ArtifactWindowView: View {
    @Bindable var model: ArtifactModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // 顶部细工具栏
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.indigo)
            Text(model.title.isEmpty ? "AI 网页" : model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)

            // 展览馆入口（始终可用）—— 看所有生成过的网页
            toolbarButton(icon: "rectangle.on.rectangle.angled", help: "网页展览馆") {
                ArtifactGalleryController.shared.show()
            }
            if model.phase == .done {
                if model.canRegenerate {
                    toolbarButton(icon: "arrow.clockwise", help: "换个设计重新生成") {
                        ArtifactWindowController.shared.regenerate()
                    }
                }
                toolbarButton(icon: "safari", help: "在浏览器打开") {
                    ArtifactWindowController.shared.openInBrowser()
                }
                toolbarButton(icon: "square.and.arrow.down", help: "导出 HTML 文件") {
                    ArtifactWindowController.shared.exportHTML()
                }
            } else if model.phase == .failed {
                toolbarButton(icon: "arrow.clockwise", help: "重试") {
                    ArtifactWindowController.shared.regenerate()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.ultraThinMaterial)
    }

    private func toolbarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .generating: generatingView
        case .done:
            if let url = model.fileURL {
                ArtifactWebView(fileURL: url)
            } else {
                generatingView
            }
        case .failed: failedView
        }
    }

    // 生成中：克制的「正在设计」状态 + 下方暗色实时代码预览（看得见在干活，但不喧宾夺主）
    private var generatingView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Spacer()
                ZStack {
                    Circle().fill(Color.indigo.opacity(0.12)).frame(width: 64, height: 64)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 26))
                        .foregroundStyle(.indigo)
                }
                ProgressView().controlSize(.small)
                Text("AI 正在为你设计网页…")
                    .font(.system(size: 15, weight: .semibold))
                Text("每一次都是独一无二的设计，请稍候")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 240)

            // 暗色实时代码区（dimmed，给"真的在生成"的踏实感）
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.streamingCode.isEmpty ? "等待 AI 输出…" : model.streamingCode)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                        .id("code")
                }
                .onChange(of: model.streamingCode) { _, _ in
                    proxy.scrollTo("code", anchor: .bottom)
                }
            }
            .frame(height: 150)
            .background(Color.black.opacity(0.85))
        }
    }

    private var failedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30)).foregroundStyle(.orange)
            Text("生成失败")
                .font(.system(size: 15, weight: .semibold))
            Text(model.errorText.isEmpty ? "请稍后重试" : model.errorText)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("重新生成") { ArtifactWindowController.shared.regenerate() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 窗口控制器（单例）

@MainActor
final class ArtifactWindowController: NSObject {
    static let shared = ArtifactWindowController()

    let model = ArtifactModel()
    private var window: NSWindow?
    private var genTask: Task<Void, Never>?

    /// 最近一次的输入 —— 供「重新生成」复用（换个设计再来一遍）。
    private var lastMarkdown = ""
    private weak var lastVM: ChatViewModel?
    private var lastMode: AgentMode?
    private var lastSourceMessageID: String?

    private override init() { super.init() }

    // MARK: 对外入口

    /// 把一份 Markdown 文档生成精美网页并展示。`mode` 为 nil 时跟随 vm 当前 mode。
    /// `sourceMessageID` 非空时（聊天里生成）会把档案挂到那条消息，气泡上自动出「查看网页」链接。
    func present(markdown: String, title: String, mode: AgentMode?, vm: ChatViewModel,
                 sourceMessageID: String? = nil) {
        lastMarkdown = markdown
        lastVM = vm
        lastMode = mode
        lastSourceMessageID = sourceMessageID
        ensureWindow()
        model.resetForNewRun(title: title)
        showWindow()
        startGeneration()
    }

    /// 同一份内容换个设计重来（覆盖同一条档案 → 聊天链接始终指向最新设计）。
    func regenerate() {
        guard !lastMarkdown.isEmpty, lastVM != nil else { return }
        model.sessionToken = UUID()
        model.phase = .generating
        model.streamingCode = ""
        model.errorText = ""
        // 保留 model.recordID → finishGeneration 走 update 覆盖同一条档案
        startGeneration()
    }

    /// 从展览馆 / 聊天链接重新打开一张已生成的网页（只看，不重生成）。
    func reopen(artifactID: String) {
        guard let rec = ArtifactStore.shared.record(id: artifactID) else { return }
        lastMarkdown = ""               // 无源文档 → 不能换设计
        lastSourceMessageID = rec.sourceMessageID
        ensureWindow()
        model.resetForNewRun(title: rec.title)
        model.recordID = rec.id
        model.canRegenerate = false
        model.fileURL = rec.fileURL
        model.phase = .done
        window?.title = rec.title
        showWindow()
    }

    // MARK: 生成

    private func startGeneration() {
        genTask?.cancel()
        let token = model.sessionToken
        let markdown = lastMarkdown
        let title = model.title
        guard let vm = lastVM else { return }
        let mode = lastMode ?? vm.meetingSummaryBackend

        genTask = Task { @MainActor in
            let prompt = Self.buildPrompt(title: title, markdown: markdown)
            var acc = ""
            do {
                for try await chunk in vm.streamOneShotAsk(
                    prompt: prompt,
                    modeOverride: mode,
                    recordToActivity: false,
                    sessionTag: "artifact-webpage"
                ) {
                    guard self.model.sessionToken == token else { return }   // 串场作废
                    acc += chunk
                    // 只显示尾部，避免超长文本拖累 SwiftUI
                    self.model.streamingCode = String(acc.suffix(4000))
                }
            } catch {
                guard self.model.sessionToken == token else { return }
                self.model.errorText = error.localizedDescription
                self.model.phase = .failed
                return
            }
            guard self.model.sessionToken == token else { return }
            self.finishGeneration(rawOutput: acc, token: token)
        }
    }

    /// 流式结束：抽取 HTML → 建档/覆盖 → 渲染。
    private func finishGeneration(rawOutput: String, token: UUID) {
        guard model.sessionToken == token else { return }
        let html = Self.extractHTML(rawOutput)
        guard html.contains("<") else {
            model.errorText = "AI 没有返回有效的网页内容"
            model.phase = .failed
            return
        }
        let store = ArtifactStore.shared
        if let rid = model.recordID {
            // 「换个设计」覆盖同一条档案
            model.fileURL = store.update(id: rid, html: html, title: model.title)
        } else {
            let modeRaw = (lastMode ?? lastVM?.agentMode)?.rawValue
            let rec = store.add(title: model.title, html: html,
                                modeRaw: modeRaw, sourceMessageID: lastSourceMessageID)
            model.recordID = rec.id
            model.fileURL = rec.fileURL
        }
        model.phase = .done
        window?.title = model.title.isEmpty ? "AI 网页" : model.title
    }

    // MARK: 工具栏动作

    func openInBrowser() {
        guard let url = model.fileURL else { return }
        NSWorkspace.shared.open(url)
    }

    func exportHTML() {
        guard let src = model.fileURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (model.title.isEmpty ? "AI 网页" : model.title) + ".html"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dst = panel.url {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }

    // MARK: 窗口

    private func ensureWindow() {
        guard window == nil else { return }
        // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 显示周期反推约束 → NSException 崩。
        // 本窗 .resizable + 流式长高（生成网页时内容不断变），正是反推高发场景 → 转 NSHostingController。
        let hosting = NSHostingController(rootView: ArtifactWindowView(model: model))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }   // 决策 #6：禁反推 setFrame

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "AI 网页"
        win.level = HermesWindowLevel.artifact
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = false
        win.contentMinSize = NSSize(width: 480, height: 400)
        win.contentViewController = hosting
        hosting.view.autoresizingMask = [.width, .height]
        win.setContentSize(NSSize(width: 940, height: 720))
        win.center()
        window = win
    }

    private func showWindow() {
        guard let win = window else { return }
        if !win.isVisible { win.center() }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: 提示词 + 解析 + 落盘

    /// Artifact 生成提示词 —— 让 AI 产出完整、自包含、可直接渲染的精美 HTML。
    static func buildPrompt(title: String, markdown: String) -> String {
        """
        你是一名顶尖的网页设计师 + 资深前端工程师。请把下面这份文档内容，设计成一个**精美、现代、可直接在浏览器打开**的单文件 HTML 网页。

        ## 设计要求
        - 输出一个**完整、自包含**的 HTML 文档（从 <!DOCTYPE html> 到 </html>），不依赖任何本地文件。
        - 可以引入 Tailwind CSS CDN（<script src="https://cdn.tailwindcss.com"></script>）来获得精致排版；但**关键排版必须同时写一份内联 CSS 兜底**，确保即使 CDN 没加载成功，页面依然清晰好看、不塌。
        - 中文正文用优雅的无衬线字体栈（如 system-ui, "PingFang SC", "Microsoft YaHei", sans-serif），行距舒展、留白充足。
        - 现代高级的视觉语言：克制的配色、卡片化分区、清晰的视觉层级；顶部做一个有质感的标题区（主题 + 日期/副标题）。
        - 内容里若有要点 / 决策 / 待办 / 数据 / 时间线，用合适的视觉组件呈现（卡片、标签 chips、时间线、表格等），不要干巴巴堆文字。
        - 响应式布局，在窗口里看着舒服；优先做精致的浅色风格。
        - **只能重新组织和美化已有内容，绝不编造文档里没有的事实**。

        ## 输出格式（重要）
        - **只输出 HTML 代码本身**，不要任何解释、不要说明文字、不要寒暄。
        - 可以用 ```html 代码块包裹。

        ## 网页主题
        \(title.isEmpty ? "（未命名）" : title)

        ## 文档内容（Markdown）
        \(markdown)
        """
    }

    /// 从 AI 输出里抽出 HTML：剥 ```html 围栏 → 截到 <!DOCTYPE / <html> 开头。
    static func extractHTML(_ raw: String) -> String {
        var s = raw
        // 1) 剥代码围栏
        if let fence = s.range(of: "```html", options: .caseInsensitive) ?? s.range(of: "```") {
            let after = s[fence.upperBound...]
            if let end = after.range(of: "```") {
                s = String(after[..<end.lowerBound])
            } else {
                s = String(after)
            }
        }
        // 2) 截到文档真正开头（去掉前面可能的寒暄）
        if let r = s.range(of: "<!DOCTYPE", options: .caseInsensitive) ?? s.range(of: "<html", options: .caseInsensitive) {
            s = String(s[r.lowerBound...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
