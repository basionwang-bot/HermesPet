import AppKit
import CryptoKit
import Vision

/// 用户意图采样器（v1.3 意图感知核心 —— Phase 1：静默采集）
///
/// 触发器（7 种事件触发，全部走同一节流）：
///   - 回车键（用户完成一段输入 / 提交）
///   - ⌘S（保存里程碑）
///   - ⌘C（用户认为这段内容重要）
///   - ⌘V（跨任务搬运）
///   - NSWorkspace app 切换（注意力转移）
///   - 窗口标题变化（任务粒度变化，**Phase 1 暂用 app 切换近似，未来用 AXObserver**）
///   - ⌘Space / ⌘⇧Space（Spotlight，在查工具）
///
/// 节流规则：同 app + window_title 在 5 分钟内只采 1 次。
/// 预估一天约 50-200 次采样。
///
/// 隐私分层：
///   - **硬黑名单**（不可关）：1Password / Bitwarden / 微信 / QQ —— 命中只记 app meta 不 OCR
///   - **软黑名单**（用户在设置里加）：自定义 bundle ID 列表，跟硬黑名单同等待遇
///   - 用户可以一键清空所有意图记录
///
/// 流程：trigger → 节流检查 → 截鼠标所在屏 → Vision OCR → 落库 `user_intents`
/// Phase 1 不接 AI，全程本地零网络。
///
/// Swift 6 并发：全局 NSEvent monitor + NSWorkspace observer 回调可能在后台线程，
/// class 用 `@unchecked Sendable` + NSLock 保护可变状态，回调里 hop 回 main 触发后续。
@MainActor
final class UserIntentRecorder {
    static let shared = UserIntentRecorder()

    // MARK: - 配置常量

    /// 同 app + window_title 节流秒数 —— 5min 内不重复采样
    static let throttleSeconds: TimeInterval = 300

    /// 硬黑名单：bundle ID 命中后只记 meta 不 OCR（不可关）
    private static let hardBlacklist: Set<String> = [
        "com.agilebits.onepassword7",    // 1Password 7
        "com.1password.1password",       // 1Password 8
        "com.bitwarden.desktop",         // Bitwarden
        "com.tencent.xinWeChat",         // 微信
        "com.tencent.qq",                // QQ
        "com.alipay.com.taobao.taobao",  // 支付宝 (老 bundle)
        "com.alipay.AlipayClient",       // 支付宝 (新 bundle)
    ]

    // MARK: - 状态

    private weak var viewModel: ChatViewModel?
    private var store: ActivityStore?
    private var keyMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var isRunning = false

    private init() {}

    // MARK: - 启停

    /// 启动采集。viewModel 用于读用户偏好（启用/触发器子集），store 落库。
    /// 多次调用 idempotent。
    func start(viewModel: ChatViewModel, store: ActivityStore) {
        guard !isRunning else { return }
        guard isEnabled else { return }  // 用户在设置里关了，不启动
        self.viewModel = viewModel
        self.store = store

        startKeyMonitor()
        startWorkspaceObserver()

        isRunning = true
        NSLog("[UserIntent] 采集启动")
    }

    func stop() {
        guard isRunning else { return }
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        isRunning = false
        NSLog("[UserIntent] 采集停止")
    }

    /// 设置面板切换总开关时调用
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "userIntentEnabled")
        if enabled, let vm = viewModel, let store = store {
            start(viewModel: vm, store: store)
        } else if !enabled {
            stop()
        }
    }

    // MARK: - 用户偏好（AppStorage 风格）

    /// 总开关。默认 false —— 用户第一次进设置必须主动开启（隐私优先）
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "userIntentEnabled") }

    /// 用户加的软黑名单（bundle ID 列表）—— Wave E 改成 UserDefaults String 数组直存
    /// AppStorage 写入 / SettingsView 黑名单管理 UI 直接 set
    private var userBlacklist: Set<String> {
        let arr = UserDefaults.standard.array(forKey: "userIntentAppBlacklist") as? [String] ?? []
        return Set(arr)
    }

    /// 哪些 trigger 启用了（JSON 数组字符串）。默认全开
    private var enabledTriggers: Set<UserIntent.TriggerType> {
        guard let raw = UserDefaults.standard.string(forKey: "userIntentTriggers"),
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return Set(UserIntent.TriggerType.allCases)
        }
        return Set(arr.compactMap { UserIntent.TriggerType(rawValue: $0) })
    }

    // MARK: - 键盘监听

    private func startKeyMonitor() {
        // global monitor：app 在后台也能收到（不消费事件，纯被动观察）
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // global monitor 回调在 macOS 14+ 默认 main，但是 Sendable 闭包，
            // 显式 hop 一次更稳；@MainActor.assumeIsolated 在 main 上是 zero-cost
            MainActor.assumeIsolated {
                self?.handleKeyEvent(event)
            }
        }
    }

    /// keyCode 参考（USB HID 标准）：
    /// - 36: Return（主键盘回车）
    /// - 76: Enter（数字键盘回车）
    /// - 49: Space
    /// - 0: A, 1: S, 6: Z, 7: X, 8: C, 9: V, 14: E, 17: T ...
    private func handleKeyEvent(_ event: NSEvent) {
        // Wave B4：任何按键都告诉 budget "用户在打字"（用于"打字静默 10s 不打扰"判断）
        IntentFeedbackBudget.shared.noteKeyEvent()

        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let keyCode = event.keyCode

        let trigger: UserIntent.TriggerType? = {
            switch keyCode {
            case 36, 76:
                // 回车 —— 不带 cmd（带 cmd 是组合快捷键，过滤掉）
                return cmd ? nil : .returnKey
            case 1 where cmd && !shift:    return .saveShortcut    // ⌘S
            case 8 where cmd && !shift:    return .copyShortcut    // ⌘C
            case 9 where cmd && !shift:    return .pasteShortcut   // ⌘V
            case 49 where cmd:             return .spotlight       // ⌘Space / ⌘⇧Space
            default:                        return nil
            }
        }()
        guard let trigger else { return }
        guard enabledTriggers.contains(trigger) else { return }
        handleTrigger(trigger)
    }

    // MARK: - NSWorkspace 监听

    private func startWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTrigger(.appSwitch)
            }
        }
    }

    // MARK: - 触发处理

    /// 节流 + 黑名单检查 + OCR + 落库
    private func handleTrigger(_ trigger: UserIntent.TriggerType) {
        // 自家 app 触发的 trigger 直接跳过（用户在 HermesPet 聊天窗按回车我们不关心）
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        let bundleID = frontApp?.bundleIdentifier
        let appName = frontApp?.localizedName

        // Wave B1：⌘C 时额外短延迟（剪贴板异步同步要等一会儿）→ 检查内容像不像报错
        //          这条路径不依赖 OCR，反馈最快 < 200ms
        //          Wave D：把剪贴板原文当 nounSource 传给 IntentCopyWriter 挖具体名词
        if trigger == .copyShortcut {
            let triggerTime = Date()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)   // 等 NSPasteboard 同步
                if let rawText = Self.detectErrorTextInPasteboard() {
                    IntentInstantFeedback.shared.emit(
                        kind: .copiedError,
                        nounSource: rawText,
                        triggerAt: triggerTime
                    )
                }
            }
        }

        // Wave B2：切 app 时立即读 AX title 检查报错关键词（不走 OCR / 不依赖节流）
        //          AX 读 title 通常 < 50ms，反馈最快
        //          Wave D：按 title 关键词分类成不同 kind，文案由 IntentCopyWriter 按 mode 人设
        if trigger == .appSwitch {
            let triggerTime = Date()
            Task { @MainActor in
                if let title = AccessibilityReader.frontWindowTitle(),
                   let kind = Self.classifyWindowTitle(title) {
                    IntentInstantFeedback.shared.emit(
                        kind: kind,
                        nounSource: title,
                        triggerAt: triggerTime
                    )
                }
            }
        }

        // 异步走完全流程（窗口标题 / 截屏 / OCR 都是 async）
        Task { @MainActor in
            await self.captureAndStore(
                trigger: trigger,
                bundleID: bundleID,
                appName: appName
            )
        }
    }

    // MARK: - Wave B3: 屏幕当下关键词命中

    /// 检查 OCR 文本是否含报错关键词，且关键词上下文像是代码 / 报错语境。
    /// 命中返回关键词周围 200 字上下文（交给 IntentCopyWriter.extractNoun 挖名词）；
    /// 没命中或上下文太纯文字（提不出名词 hint） → 返回 nil
    nonisolated private static func extractScreenKeywordContext(text: String) -> String? {
        let lower = text.lowercased()
        let errorKw = ["error", "exception", "崩溃", "crash", "panic", "fatal", "报错"]
        guard let kw = errorKw.first(where: { lower.contains($0) }) else { return nil }

        // 取关键词上下 100 字上下文
        guard let range = lower.range(of: kw) else { return nil }
        let nsRange = NSRange(range, in: lower)
        let start = max(0, nsRange.location - 100)
        let end = min(text.count, nsRange.location + nsRange.length + 100)
        let nsText = text as NSString
        let context = nsText.substring(with: NSRange(location: start, length: end - start))

        // 上下文必须有"代码/标识符"线索，否则不算（防止纯叙述性文本如菜单 "Help / Report Error"）
        guard hasCodeLikeContext(context) else { return nil }
        return context
    }

    /// 启发式判断一段文本上下文像不像代码 —— 防止报错关键词命中纯叙述性文本。
    /// 规则：含引号 / 含文件扩展名 / 含 camelCase / 含 snake_case
    nonisolated private static func hasCodeLikeContext(_ text: String) -> Bool {
        if text.contains("`") || text.contains("\"") { return true }
        let exts = [".swift", ".py", ".js", ".ts", ".tsx", ".java", ".cpp",
                    ".rb", ".go", ".rs", ".kt", ".h", ".m"]
        let lower = text.lowercased()
        if exts.contains(where: { lower.contains($0) }) { return true }
        // camelCase / PascalCase
        var prev: Character? = nil
        for c in text {
            if let p = prev, p.isLowercase, c.isUppercase { return true }
            prev = c
        }
        // snake_case
        if text.contains("_") {
            let underscoreCount = text.filter { $0 == "_" }.count
            if underscoreCount >= 1 && underscoreCount <= 8 { return true }
        }
        return false
    }

    /// Wave D 重写：根据窗口标题分类成不同 IntentSignalKind，文案由 IntentCopyWriter 按 mode 决定。
    /// 不分大小写。返回 nil = 没看出信号。
    ///
    /// **注意**：之前有 windowTitleError 分支（error/fail/崩溃/exception 等子串匹配），
    /// 但子串匹配假阳性太多（ErrorHandler.swift / Email Failed / 错误报告菜单 等都会触发），
    /// 让桌宠在用户没看报错时也说"你在查报错"。已砍掉，真"看到报错"信号走：
    /// - copiedError：用户主动 Cmd+C 复制了报错文本（高置信，用户主动行为）
    /// - screenKeyword：OCR 命中 + hasCodeLikeContext 验证有代码语境（高置信，过滤纯叙述）
    ///
    /// 保留的三档都匹配站名/工具名而非泛词，置信度高。
    nonisolated private static func classifyWindowTitle(_ title: String) -> IntentSignalKind? {
        let lower = title.lowercased()
        // Stack Overflow（明确站名 → 用户在查问题）
        if lower.contains("stack overflow") || lower.contains("stackoverflow") {
            return .windowTitleStackOverflow
        }
        // 文档查阅（明确文档站域名）
        let docKw = ["mdn web docs", "developer.apple", "documentation",
                     "swift.org", "rust-lang", "python docs"]
        if docKw.contains(where: { lower.contains($0) }) {
            return .windowTitleDoc
        }
        // 调试 / 开发者工具（明确工具名）
        let debugKw = ["debugger", "breakpoint", "devtools", " — console"]
        if debugKw.contains(where: { lower.contains($0) }) {
            return .windowTitleDebug
        }
        return nil
    }

    // MARK: - Wave B1: 剪贴板报错文本启发式判定

    /// 检查 NSPasteboard 当前内容是否像 stack trace / error，命中返回简短摘要。
    /// 长度限制 30-2000 字避免误伤（太短可能是变量名，太长可能是日志文件）。
    /// nonisolated 让 Task 内调用不用 hop。
    nonisolated private static func detectErrorTextInPasteboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let length = text.count
        guard length >= 30, length <= 2000 else { return nil }

        let lower = text.lowercased()

        // 强信号：典型 stack trace 关键词（多行才算，单行容易误判）
        let stackKeywords: [String] = [
            "traceback", "stack trace", "    at ",
            "caused by:", "exception in thread"
        ]
        let hasStackKw = stackKeywords.contains { lower.contains($0) }

        // 文件路径风格：.swift: / .py: / .js: 等带行号
        let filePathExt: [String] = [
            ".swift:", ".py:", ".js:", ".ts:", ".tsx:", ".rb:", ".go:", ".rs:",
            ".java:", ".kt:", ".cpp:", ".c:", ".h:", ".m:", ".mm:"
        ]
        let hasFilePath = filePathExt.contains { lower.contains($0) }

        // error / exception 标题
        let errorPrefixes: [String] = [
            "error:", "exception:", "fatal:", "fatal error:", "panic:",
            "uncaught", "unhandled"
        ]
        let hasErrorTitle = errorPrefixes.contains { lower.contains($0) }

        let hasMultiLine = text.contains("\n")

        // 命中规则：
        // (1) 多行 + stack keyword 或 文件路径 → 几乎确定是 stack trace
        // (2) error 标题 + 文件路径 → 编译器/运行时报错
        // (3) 多行 + error 标题 → 较高置信
        if hasMultiLine && (hasStackKw || hasFilePath) { return text }
        if hasErrorTitle && hasFilePath { return text }
        if hasMultiLine && hasErrorTitle { return text }

        return nil
    }

    private func captureAndStore(trigger: UserIntent.TriggerType,
                                  bundleID: String?,
                                  appName: String?) async {
        // 1) 拿前台窗口标题（用 AccessibilityReader 已有的工具）
        let windowTitle = await frontWindowTitle()

        // 2) 节流：同 app + window_title 5min 内不再采样
        if let last = store?.lastIntentTimestamp(appBundleID: bundleID, windowTitle: windowTitle),
           Date().timeIntervalSince(last) < Self.throttleSeconds {
            return
        }

        // 3) 黑名单判断
        let isBlacklisted = bundleID.map { isBundleBlacklisted($0) } ?? false

        var ocrText: String? = nil
        var screenHash: String? = nil

        if !isBlacklisted {
            // 4) 截鼠标所在屏 → Vision OCR
            if let cgImage = await ScreenCapture.captureMouseScreenAsCGImage() {
                ocrText = await Self.performOCR(on: cgImage)
                if let text = ocrText, !text.isEmpty {
                    screenHash = Self.sha256Prefix(text)
                }
            }
        }

        // 5) 落库
        let intent = UserIntent(
            triggerType: trigger,
            appBundleID: bundleID,
            appName: appName,
            windowTitle: windowTitle,
            ocrText: ocrText,
            screenHash: screenHash,
            isBlacklisted: isBlacklisted
        )
        store?.insertUserIntent(intent)
        NSLog("[UserIntent] \(trigger.rawValue) @ \(appName ?? "?") · \(windowTitle ?? "?") · ocr=\(ocrText?.count ?? 0)字")

        // Wave B3：OCR 完成后立即查屏幕含不含报错关键词 + 上下文有具体名词
        //         命中 → 当下短临时反馈（不走 IntentPatternDetector 的卡片路径）
        //         Wave D：把命中关键词的上下文片段当 nounSource 传给 IntentCopyWriter
        if let text = ocrText, !text.isEmpty {
            if let context = Self.extractScreenKeywordContext(text: text) {
                IntentInstantFeedback.shared.emit(
                    kind: .screenKeyword,
                    nounSource: context,
                    triggerAt: Date()
                )
            }
        }

        // 6) Wave A 实时存在感：广播"我看到了"信号给桌宠 + 灵动岛做微反馈
        //    quietMode 时下游接收方自己跳过；这里不判断保持 recorder 单一职责
        //    携带 todayCount 让灵动岛 hoverCard 实时显示"今天 X 次"（A3）
        let todayCount = store?.todayIntentCount() ?? 0
        NotificationCenter.default.post(
            name: .init("HermesPetIntentRecorded"),
            object: nil,
            userInfo: [
                "trigger": trigger.rawValue,
                "appName": appName ?? "",
                "todayCount": todayCount
            ]
        )

        // 7) 触发 Phase 2 模式识别（IntentPatternDetector 命中后通过 closure 调灵动岛卡片）
        IntentPatternDetector.shared.evaluate(latestIntent: intent)
    }

    private func isBundleBlacklisted(_ bundleID: String) -> Bool {
        if Self.hardBlacklist.contains(bundleID) { return true }
        if userBlacklist.contains(bundleID) { return true }
        return false
    }

    /// 拿前台 app 当前活动窗口的标题。
    /// 用 AccessibilityReader 已有的 utility，没有权限就返回 nil。
    @MainActor
    private func frontWindowTitle() async -> String? {
        AccessibilityReader.frontWindowTitle()
    }

    // MARK: - Vision OCR

    /// 用 macOS Vision Framework 做 OCR（zh-Hans + en，fast 级别）。
    /// 后台线程跑（VNImageRequestHandler.perform 是 blocking IO），完成后 resume。
    ///
    /// **性能策略**（v1.2.9 优化）：
    /// - `.fast` 替代 `.accurate`：关键词检测场景不需要精准识别，速度提升 2-5×
    /// - `usesLanguageCorrection = false`：拼写矫正对截屏 OCR 价值低，关掉省一半时间
    /// - 输入图先 downsample 到 ≤ 1600pt 边长：5K 屏全分辨率 OCR 太贵，
    ///   缩到 1600pt 后大字号/正文都能识别，小字（< 12pt）虽然丢但对意图判定无关键损失
    ///
    /// 三项叠加后 OCR 速度提升 5-10×，主线程 Foundation→Swift dictionary bridging 同步减少。
    nonisolated private static func performOCR(on cgImage: CGImage) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                // 先 downsample 减少 ANE 处理量
                let processedImage = downsampleIfNeeded(cgImage) ?? cgImage

                let request = VNRecognizeTextRequest { (req, _) in
                    guard let results = req.results as? [VNRecognizedTextObservation] else {
                        cont.resume(returning: nil)
                        return
                    }
                    // 按 boundingBox 从上到下、从左到右排序（Y 原点在 image 底部）
                    let sorted = results.sorted { a, b in
                        if abs(a.boundingBox.origin.y - b.boundingBox.origin.y) > 0.02 {
                            return a.boundingBox.origin.y > b.boundingBox.origin.y
                        }
                        return a.boundingBox.origin.x < b.boundingBox.origin.x
                    }
                    let text = sorted
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    cont.resume(returning: text.isEmpty ? nil : text)
                }
                // 中文识别 macOS 13+ 支持，需要显式声明
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false

                let handler = VNImageRequestHandler(cgImage: processedImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    NSLog("[UserIntent] Vision OCR 失败: \(error.localizedDescription)")
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// 把全屏截图（5K = 5120×2880 等）按比例缩到长边 ≤ 1600pt。
    /// CGImage 已经够小（长边 < 1600）则直接 return nil 让调用方用原图。
    /// 用 CoreGraphics 重绘到小尺寸 context，速度 < 20ms。
    nonisolated private static func downsampleIfNeeded(_ image: CGImage) -> CGImage? {
        let maxEdge: CGFloat = 1600
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longSide = max(w, h)
        guard longSide > maxEdge else { return nil }

        let scale = maxEdge / longSide
        let newW = Int(w * scale)
        let newH = Int(h * scale)

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.bitmapInfo
        let bitsPerComponent = image.bitsPerComponent

        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    /// SHA256 前 16 位 hex —— 用于 Phase 2 重复屏幕检测
    nonisolated private static func sha256Prefix(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}

extension UserIntent.TriggerType: CaseIterable {
    public static let allCases: [UserIntent.TriggerType] = [
        .returnKey, .saveShortcut, .copyShortcut, .pasteShortcut,
        .appSwitch, .windowChange, .spotlight
    ]

    /// 设置面板里给用户看的中文短名
    var displayName: String {
        switch self {
        case .returnKey:     return "按回车"
        case .saveShortcut:  return "⌘S 保存"
        case .copyShortcut:  return "⌘C 复制"
        case .pasteShortcut: return "⌘V 粘贴"
        case .appSwitch:     return "切换应用"
        case .windowChange:  return "切换窗口"
        case .spotlight:     return "⌘Space 唤起"
        }
    }
}
