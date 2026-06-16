import AppKit
import SwiftUI
import CoreGraphics

/// 接管模式（v1.6「AI 看屏幕」里程碑 4）。
enum TakeoverMode {
    case manual   // 手动指挥：我发指令，AI 对锁定窗口执行
    case auto     // 自动盯防：AI 定时截图+OCR差分，检测到新消息自动分析并回复
}

/// 接管会话控制器 —— 让 HermesPet「时刻盯着」一个程序窗口，并在窗口上贴「正在接管」标识。
///
/// 体验目标（用户要求）：用户实实在在感觉到 HermesPet 在接管某个程序。所以：
/// - 贴在目标窗口顶部的浮动小标识（🦞 正在接管「X」· 模式 · 停止），窗口移动时跟随。
/// - 两种模式：手动指挥 / 自动盯防。
/// - 自动模式：差分省电（像素没变不 OCR）→ 变了才 OCR → 检测到**新增内容**→ 让用户当前选的 AI
///   生成回复 → 激活窗口 → 点输入区 → 打字 → 回车发出（用户已确认走全自动）。
///
/// 安全：始终可见的「停止」按钮 + 启动时**基线化**当前内容（绝不回复接管前就在的历史消息）+
/// 发出后把自己回复计入已见 & 冷却几拍，避免自问自答死循环。
@MainActor
final class ScreenTakeoverController: NSObject {
    static let shared = ScreenTakeoverController()

    private weak var viewModel: ChatViewModel?
    private(set) var isActive = false
    private var target: ScreenCapture.ShareableWindow?
    private var mode: TakeoverMode = .auto
    private var lastFrame: CGRect = .zero

    // 差分 / 新内容检测
    private var lastFingerprint: [UInt8] = []
    private var lastTextSignature: String = ""    // 上一拍整窗文字签名（"文字变没变"的判据）
    private var lastRepliedIncoming: String = ""  // 上次已回复过的"对方"消息（AI 据此判断有没有更新的）
    private var cooldownTicks = 0     // 发出回复后冷却，避免把自己的回复当新消息

    private var loopTask: Task<Void, Never>?
    private var positionTimer: Timer?               // 高频跟随目标窗口位置（拖动时标识同步移动）
    private var lastBadgeOrigin: CGPoint = CGPoint(x: -99999, y: -99999)

    // 浮窗标识
    private var badgeWindow: NSWindow?
    private let badgeState = TakeoverBadgeState()

    private let pollInterval: UInt64 = 3_000_000_000   // 3s

    // MARK: - 启动入口（菜单）

    /// 弹出窗口选择菜单（每个窗口下 自动盯 / 手动指挥 两个子项）。
    func presentStarterMenu(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        Task { @MainActor in
            let windows = await ScreenCapture.listWindows()
            let menu = NSMenu()
            if windows.isEmpty {
                let empty = NSMenuItem(title: "没找到可接管的窗口（需屏幕录制权限）", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            for w in windows {
                let item = NSMenuItem(title: w.title, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let autoItem = NSMenuItem(title: "🤖 自动盯（检测新消息自动回复）", action: #selector(startFromMenu(_:)), keyEquivalent: "")
                autoItem.target = self
                autoItem.representedObject = TakeoverChoice(window: w, mode: .auto)
                let manItem = NSMenuItem(title: "🎮 手动指挥（我发指令它执行）", action: #selector(startFromMenu(_:)), keyEquivalent: "")
                manItem.target = self
                manItem.representedObject = TakeoverChoice(window: w, mode: .manual)
                sub.addItem(autoItem)
                sub.addItem(manItem)
                item.submenu = sub
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func startFromMenu(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TakeoverChoice else { return }
        start(window: choice.window, mode: choice.mode)
    }

    // MARK: - 启停

    func start(window: ScreenCapture.ShareableWindow, mode: TakeoverMode) {
        guard ScreenActuator.ensureTrusted() else {
            postBubble("需要「辅助功能」权限，已弹出系统设置——允许后再试一次")
            return
        }
        stop()   // 先停掉上一个会话
        target = window
        self.mode = mode
        isActive = true
        lastFingerprint = []
        lastTextSignature = ""
        lastRepliedIncoming = ""
        cooldownTicks = 0
        lastBadgeOrigin = CGPoint(x: -99999, y: -99999)

        badgeState.title = window.title
        badgeState.mode = mode
        badgeState.status = (mode == .auto) ? "正在盯防…" : "待命中"
        badgeState.active = true
        showBadge()
        startPositionTimer()      // 高频跟随窗口（拖动同步移动）

        postBubble("🦞 已接管「\(window.title)」·\(mode == .auto ? "自动盯防" : "手动指挥")")
        loopTask = Task { @MainActor in await runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        positionTimer?.invalidate()
        positionTimer = nil
        if isActive { postBubble("已停止接管") }
        isActive = false
        target = nil
        badgeState.active = false
        hideBadge()
    }

    // MARK: - 主循环（位置跟随 + 自动盯防）

    private func runLoop() async {
        var firstScan = true
        while !Task.isCancelled, isActive, let target {
            // 截窗口（顺手拿 frame 给标识定位 + 自动操作用）
            guard let shot = await ScreenCapture.captureWindowImage(id: target.id) else {
                // 窗口可能关了
                badgeState.status = "窗口不可见"
                try? await Task.sleep(nanoseconds: pollInterval)
                continue
            }
            // 标识位置由 positionTimer 60fps 跟随，这里不再 reposition（避免两路 frame 抖动）

            if mode == .auto {
                await autoTick(shot: shot, firstScan: &firstScan)
            }

            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    /// 自动模式的一拍：差分 → OCR → 检测新内容 → 自动回复。
    private func autoTick(shot: (image: CGImage, frame: CGRect), firstScan: inout Bool) async {
        if cooldownTicks > 0 { cooldownTicks -= 1; return }

        // 1. 像素差分（便宜）——没变就不 OCR
        let fp = Self.fingerprint(shot.image)
        if !firstScan, !Self.differs(lastFingerprint, fp) {
            badgeState.status = "无变化"
            return
        }
        lastFingerprint = fp

        // 2. 整窗 OCR（认全部文字，不再激进过滤）
        badgeState.status = "看到变化，识别中…"
        let elements = await ScreenPerception.mapAndOCR(image: shot.image, frame: shot.frame)
        let f = shot.frame
        guard !elements.isEmpty else { badgeState.status = "正在盯防…"; return }

        // 顺手学用户自己发的消息（靠右气泡）当语气样本 —— 用得越久回复越像用户本人
        let mineTexts = elements
            .filter { Self.bubbleSide($0.screenRect, windowFrame: f) == .outgoing }
            .map { $0.text }
        ReplyStyleStore.shared.learn(mineTexts)

        // 3. 整窗文字签名 —— 把所有文字归一化排序拼起来，比"整窗文字变没变"。
        //    比之前逐行去抖鲁棒得多（不易漏、也不怕 OCR 顺序抖动）。
        let signature = elements
            .map { Self.normalizeLine($0.text) }
            .filter { $0.count >= 1 }
            .sorted()
            .joined(separator: "\u{1}")

        // 有序对话（按屏幕上→下，标好「对方/我」）—— 给 AI 当上下文 + 判断谁发的
        let transcript = elements
            .sorted { $0.screenRect.minY < $1.screenRect.minY }
            .compactMap { el -> String? in
                let t = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.count >= 1 else { return nil }
                switch Self.bubbleSide(el.screenRect, windowFrame: f) {
                case .incoming:  return "对方：\(t)"
                case .outgoing:  return "我：\(t)"
                case .ambiguous: return nil   // 时间戳/系统提示不进对话
                }
            }
            .suffix(24)
            .joined(separator: "\n")

        // 4. 首扫只记基线：记下当前文字签名 + 把当前最新对方消息当成"已回过"（绝不回历史）
        if firstScan {
            lastTextSignature = signature
            lastRepliedIncoming = Self.latestIncoming(elements, frame: f) ?? ""
            firstScan = false
            badgeState.status = "正在盯防…"
            return
        }

        // 5. 整窗文字没变 → 没有新东西，连 AI 都不用叫（像素动了但文字没动，如光标闪烁）
        if signature == lastTextSignature {
            badgeState.status = "正在盯防…"
            return
        }
        lastTextSignature = signature

        // 6. 文字变了 → 交给 AI 判断"对方有没有发来新的、还没回过的消息"，有就回
        guard let vm = viewModel else { return }
        badgeState.status = "有变化，AI 判断中…"

        let visionImages: [Data] = Self.modeCanSeeImages(vm)
            ? (Self.pngData(from: shot.image).map { [$0] } ?? [])
            : []
        let visionHint = visionImages.isEmpty
            ? ""
            : "（已附上聊天窗口截图，请以截图里的真实内容为准——下面文字是 OCR 提取的，可能有错别字/漏字。）\n"
        let styleBlock = ReplyStyleStore.shared.buildStyleBlock()
        let lastReplied = lastRepliedIncoming.isEmpty ? "（无，这是开始盯防后第一次判断）" : "「\(lastRepliedIncoming)」"

        let prompt = """
        你在帮用户盯一个聊天窗口，自动回复对方发来的新消息。
        \(visionHint)
        当前窗口里的对话（按时间上→下；"我"=用户本人，"对方"=别人）：
        \(transcript)

        你上一次已经回复过对方的消息是：\(lastReplied)

        先判断：对方有没有发来【新的、且你还没回复过】的消息？
        - 若没有（最新还是你已回过的、或最新是"我"自己发的、或只是系统提示/时间）→ 只输出四个字母：NONE
        - 若有 → 以用户本人身份回一句自然、简短、口语化的纯文本（一行不换行、≤50 字、无 markdown/代码/反引号），只输出回复正文本身。
        \(styleBlock.isEmpty ? "" : "\n" + styleBlock)
        """
        var reply = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, images: visionImages, recordToActivity: false) {
                reply += chunk
            }
        } catch {
            clearIslandStatus()
            badgeState.status = "AI 失败"
            return
        }
        // ⭐ 清掉 client 在读截图时留下的"正在读 IMG…"工具状态：
        //   接管是后台活、有自己的「正在接管」标识，本就不该占灵动岛；而 client 只发了 ToolStarted、
        //   不发 TaskFinished（那只在正常 sendMessage 流程发），灵动岛 currentTool 没人清会一直卡住。
        clearIslandStatus()

        let cleaned = Self.sanitizeForChat(reply)
        // AI 判断无需回复
        let compact = cleaned.replacingOccurrences(of: " ", with: "").uppercased()
        if cleaned.isEmpty || compact == "NONE" || compact.hasPrefix("NONE") {
            badgeState.status = "无对方新消息，继续盯防…"
            return
        }

        // 7. 自动发出：激活窗口 → 点输入区 → 打字 → 回车
        postBubble("📩 检测到对方新消息，回复中…")
        let sent = await sendReply(cleaned, windowFrame: shot.frame, pid: target?.pid)
        guard sent else {
            // ⚠️ 审计 #4/#12：目标 app 已退出/无法激活 → 根本没发出去。**不**推进 lastRepliedIncoming、
            // **不**谎报「已回复」，否则这条会被标记成已回复 → 永不重试，消息石沉大海。下一拍会再试。
            badgeState.status = "目标窗口不在前台，没发出，继续盯防…"
            postBubble("⚠️ 目标窗口不在，这条没发出去")
            return
        }
        // 记下"已回过对方的哪条" + 冷却 2 拍，避免把自己刚发的话当新消息
        lastRepliedIncoming = Self.latestIncoming(elements, frame: f) ?? lastRepliedIncoming
        cooldownTicks = 2
        badgeState.status = "已回复，继续盯防…"
        postBubble("✅ 已自动回复：\(cleaned.prefix(30))")
    }

    /// 模拟人手把回复打进聊天窗并发出（微信无发送键，回车即发）。
    /// 返回是否真把字打出去了。目标 app 已退出（`NSRunningApplication` 取不到）→ 返回 false，
    /// 否则会把回复打进**当前焦点 app**（很可能是 HermesPet 自己），还谎报成功。
    /// ⚠️ 仍无法 100% 确认文字落进了输入框——点的是固定坐标（0.5w / 0.92h），输入框若不在底部中央就会落空；
    /// 完整校验（OCR 回读输入框内容）留作后续，本次先堵住「app 都没了还谎报已回复」这条（审计 #4/#12）。
    private func sendReply(_ text: String, windowFrame frame: CGRect, pid: pid_t?) async -> Bool {
        if let pid {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }   // app 已退出
            app.activate(options: [])
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        // 点底部输入区（聊天类 app 输入框通常在窗口底部）
        let inputPt = CGPoint(x: frame.minX + frame.width * 0.5,
                              y: frame.minY + frame.height * 0.92)
        ScreenActuator.click(at: inputPt)
        try? await Task.sleep(nanoseconds: 150_000_000)
        ScreenActuator.typeText(text)
        try? await Task.sleep(nanoseconds: 150_000_000)
        ScreenActuator.pressReturn()
        return true
    }

    // MARK: - 手动指挥

    /// 标识上「发指令」按钮：弹输入框问目标 → 立刻对锁定窗口执行一步。
    func runManualCommand() {
        guard let vm = viewModel, let target else { return }
        let alert = NSAlert()
        alert.messageText = "对「\(target.title)」发指令"
        alert.informativeText = "你想让 AI 对这个窗口做什么？"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        tf.placeholderString = "例如：点开设置 / 回复对方一句你好"
        alert.accessoryView = tf
        alert.addButton(withTitle: "执行")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let goal = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        badgeState.status = "执行：\(goal.prefix(12))"
        Task { @MainActor in
            await ScreenAgent.runOnce(goal: goal, windowID: target.id, viewModel: vm) { [weak self] msg in
                self?.badgeState.status = String(msg.prefix(18))
                self?.postBubble(msg)
            }
            self.badgeState.status = "待命中"
        }
    }

    // MARK: - 浮窗标识

    private func showBadge() {
        if badgeWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 34),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: true
            )
            w.level = HermesWindowLevel.auxiliary
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.ignoresMouseEvents = false      // 标识上有「停止」「发指令」按钮，要收点击
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false

            // 决策 #1/#6 升级：裸 NSHostingView 即便 sizingOptions=[] 在 macOS 26 仍会经
        // updateAnimatedWindowSize 反推 setFrame（2026-06-11 00:09 崩溃实锤）；只有
        // NSHostingController + sizingOptions=[] 真正禁掉反推（照语音陪聊/迷你岛范本）
            let host = NSHostingController(rootView: TakeoverBadgeView(
                state: badgeState,
                onStop: { [weak self] in self?.stop() },
                onManualCommand: { [weak self] in self?.runManualCommand() }
            ))
            if #available(macOS 13.0, *) { host.sizingOptions = [] }
            w.contentViewController = host
            host.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）
            w.setContentSize(NSSize(width: 320, height: 34))
            badgeWindow = w
        }
        repositionBadge()
        badgeWindow?.orderFront(nil)
    }

    private func hideBadge() {
        badgeWindow?.orderOut(nil)
    }

    /// 把标识贴到目标窗口顶部中间（窗口 frame 是左上角原点，要翻成 Cocoa 左下角原点）。
    /// 位置没变时跳过 setFrame —— 窗口静止时近乎零开销，拖动时才真正移动。
    private func repositionBadge() {
        guard let w = badgeWindow, lastFrame != .zero else { return }
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
                             ?? NSScreen.main)?.frame.height ?? 0
        let badgeW: CGFloat = 320, badgeH: CGFloat = 34
        let originX = lastFrame.minX + (lastFrame.width - badgeW) / 2
        // 目标窗口顶边在 Cocoa 坐标里的 y
        let topEdgeCocoaY = primaryHeight - lastFrame.minY
        // 标识压在窗口顶部、略微下沉一点点（top 对齐窗口顶边再下移 2pt）
        let originY = topEdgeCocoaY - badgeH + 2
        let origin = CGPoint(x: originX, y: originY)
        if abs(origin.x - lastBadgeOrigin.x) < 0.5 && abs(origin.y - lastBadgeOrigin.y) < 0.5 { return }
        lastBadgeOrigin = origin
        w.setFrame(NSRect(x: originX, y: originY, width: badgeW, height: badgeH), display: true)
    }

    // MARK: - 高频跟随窗口位置（拖动时标识同步移动）

    private func startPositionTimer() {
        positionTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // Timer 回调在 main runloop 触发（我们已加到 .common 模式），hop 回 MainActor（决策 #5）
            MainActor.assumeIsolated { self?.followWindow() }
        }
        // ⭐ .common 含事件追踪模式 —— 用户拖动窗口期间也持续触发，标识才跟得住
        RunLoop.main.add(t, forMode: .common)
        positionTimer = t
    }

    private func followWindow() {
        guard isActive, let target else { return }
        if let bounds = Self.currentWindowBounds(id: target.id) {
            lastFrame = bounds
            repositionBadge()
        }
    }

    /// 用 `CGWindowListCopyWindowInfo` 读窗口实时 bounds（左上角原点，点）。
    /// 比 SCShareableContent 便宜得多，能 60fps 跑；窗口被关 / 隐藏返回 nil。
    nonisolated private static func currentWindowBounds(id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect),
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    // MARK: - 工具

    private func postBubble(_ text: String) {
        NotificationCenter.default.post(
            name: .init("HermesPetClawdBubble"),
            object: nil,
            userInfo: ["text": text, "duration": 3.0]
        )
    }

    /// 清掉灵动岛残留的工具状态（接管后台调 AI 时 client 会发 ToolStarted 却不发 TaskFinished）。
    /// 补发一个 success:false 的 TaskFinished，让 `currentTool` 复位、不卡在"正在读…"。
    private func clearIslandStatus() {
        NotificationCenter.default.post(
            name: .init("HermesPetTaskFinished"),
            object: nil,
            userInfo: ["success": false]
        )
    }

    // MARK: - 识图（让会看图的 AI 直接读截图，抗 OCR 错字）

    /// 当前选的 AI 能不能看图。Claude Code / Codex 原生支持；在线 AI/Hermes 按模型名启发式判断。
    @MainActor
    static func modeCanSeeImages(_ vm: ChatViewModel) -> Bool {
        switch vm.agentMode {
        case .claudeCode, .codex:
            return true
        case .directAPI, .hermes, .openclaw, .qwenCode:
            // 多模态模型名常见标记；纯文本模型（如 deepseek-chat）不含这些 → 走 OCR 文字回退
            let model = vm.directAPIModel.lowercased()
            let markers = ["vl", "vision", "4o", "4.1", "glm-4v", "glm-4.5v", "gpt-4", "claude", "gemini", "qwen-vl", "omni", "-v-", "kimi-latest"]
            return markers.contains { model.contains($0) }
        }
    }

    nonisolated static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 区分对方 / 自己的消息（靠气泡左右对齐判断）

    /// 聊天气泡归属：靠左=对方发的，靠右=自己发的，居中=系统提示/时间戳。
    enum BubbleSide { case incoming, outgoing, ambiguous }

    /// 按文字方框「贴左还是贴右」判断是谁发的（微信/iMessage/WhatsApp 等聊天 app 通用约定）。
    /// 比较「离窗口左边的间距」和「离右边的间距」：明显贴右=自己，明显贴左=对方，差不多=居中(系统/时间)。
    nonisolated private static func bubbleSide(_ rect: CGRect, windowFrame f: CGRect) -> BubbleSide {
        guard f.width > 0 else { return .ambiguous }
        let leftGap = rect.minX - f.minX
        let rightGap = f.maxX - rect.maxX
        let margin = f.width * 0.12   // 12% 容差，避开居中元素的误判
        if rightGap + margin < leftGap { return .outgoing }   // 贴右 → 自己
        if leftGap + margin < rightGap { return .incoming }   // 贴左 → 对方
        return .ambiguous                                      // 居中 → 系统提示/时间戳
    }

    // MARK: - 新消息去重（抗 OCR 漂移）

    /// 归一化一行文字：去掉所有空白 + 标点、转小写。让 OCR 的细微差异/标点漂移不被当成新行。
    nonisolated private static func normalizeLine(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(kept))
    }

    /// 当前画面里"对方"发的最新一条（最靠下的靠左气泡）—— 用作"已回过哪条"的基线/记录。
    nonisolated private static func latestIncoming(_ els: [ScreenPerception.TextElement], frame f: CGRect) -> String? {
        els.filter { bubbleSide($0.screenRect, windowFrame: f) == .incoming }
           .max(by: { $0.screenRect.minY < $1.screenRect.minY })?
           .text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 AI 回复净化成「适合发进聊天框的单行纯文本」。
    /// ⚠️ 关键：聊天类 app（微信）里**换行=发送**，所以必须把所有换行换成空格，
    /// 否则一条多行回复会被 `typeText` 逐字打进去时拆成多条消息发出去（用户实测踩到）。
    nonisolated private static func sanitizeForChat(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "```", with: " ")   // 去代码围栏
        t = t.replacingOccurrences(of: "`", with: "")        // 去行内反引号
        t = t.replacingOccurrences(of: "\r\n", with: " ")
        t = t.replacingOccurrences(of: "\n", with: " ")
        t = t.replacingOccurrences(of: "\r", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 200 { t = String(t.prefix(200)) }       // 兜底截断
        return t
    }

    /// 把 CGImage 渲染成小尺寸指纹（每像素 RGBA），给差分用。
    nonisolated private static func fingerprint(_ image: CGImage, side: Int = 24) -> [UInt8] {
        let w = side, h = side
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    /// 两个指纹是否有明显差异（采样 R 通道，差异像素超阈值即判定有变化）。
    nonisolated private static func differs(_ a: [UInt8], _ b: [UInt8], threshold: Int = 6) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var diff = 0
        var i = 0
        while i < a.count {
            if abs(Int(a[i]) - Int(b[i])) > 28 {
                diff += 1
                if diff > threshold { return true }
            }
            i += 4
        }
        return false
    }
}

/// 菜单项携带的选择（window + mode），作为 NSMenuItem.representedObject。
private final class TakeoverChoice {
    let window: ScreenCapture.ShareableWindow
    let mode: TakeoverMode
    init(window: ScreenCapture.ShareableWindow, mode: TakeoverMode) {
        self.window = window
        self.mode = mode
    }
}

// MARK: - 浮窗标识 UI

@MainActor
@Observable
final class TakeoverBadgeState {
    var title = ""
    var mode: TakeoverMode = .auto
    var status = "正在接管"
    var active = false
}

struct TakeoverBadgeView: View {
    @State var state: TakeoverBadgeState
    let onStop: () -> Void
    let onManualCommand: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)

            Text("🦞 接管「\(state.title)」")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(state.mode == .auto ? "自动" : "手动")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.white.opacity(0.18)))

            Text(state.status)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            Spacer(minLength: 4)

            if state.mode == .manual {
                Button(action: onManualCommand) {
                    Text("发指令").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }

            Button(action: onStop) {
                Text("停止").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule().fill(Color.black.opacity(0.84))
        )
        .overlay(
            Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5)
        )
        .padding(2)
        .onAppear { pulse = true }
    }
}
