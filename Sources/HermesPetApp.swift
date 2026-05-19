import SwiftUI
import AppKit

@main
struct HermesPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var chatWindow: ChatWindowController?
    private var viewModel: ChatViewModel?
    private var islandController: DynamicIslandController?
    /// Permission UI 独立窗口控制器（v1.3+，监听 NotificationCenter 自驱）
    private var permissionWindowController: PermissionWindowController?
    /// 任务回复摘要卡片控制器（v1.2.7-dev）—— 聊天窗关着时 task 完成 → 灵动岛下方弹摘要
    private var responseSummaryController: ResponseSummaryWindowController?
    /// 意图建议卡片控制器（v1.3 Phase 2）—— 识别到"重复 / 报错"等 pattern 时弹建议
    private var intentSuggestionController: IntentSuggestionWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 配置迁移：把老版本的 UserDefaults 字段升级到当前 schema。
        // 必须在任何读 UserDefaults 的代码（ChatViewModel / OpenCodeConfigGenerator 等）之前跑，
        // 否则它们会读到旧 key 拿不到值。同步执行（UserDefaults 操作极快，不阻塞启动）。
        SchemaMigrator.runMigrations()

        // 启动后立即异步预热 CLI 探测 —— 用 zsh -lic 走用户真实 PATH 找 claude / codex，
        // 找到的路径写入 UserDefaults，让后续 ClaudeCodeClient / CodexClient 的 spawn 用对路径。
        // 这一步对"对方装好了 CLI 但 App 还以为没装"的场景至关重要：之前用硬编码
        // /Users/mac01/.local/bin/claude 在别人电脑上 100% 失败
        Task.detached(priority: .utility) {
            _ = await CLIAvailability.claudeAvailable()
            _ = await CLIAvailability.codexAvailable()
            // 探测完成后回到主线程让 connectionStatus 用最新路径再检一次
            await MainActor.run { [weak self] in
                self?.viewModel?.checkConnection()
            }
        }

        // 在线 AI 模式的引擎：启动 bundled opencode 的 headless server。
        // App 启动就拉起（用户决策，TODO.md「P0-在线 AI 内核换代」Phase 1）。
        // 失败不阻塞 App 启动 —— 设置面板会展示 lastError 让用户诊断，
        // 后续 OpenCodeClient 请求时如果发现 isReady=false 会尝试重启
        Task.detached(priority: .utility) {
            do {
                try await OpenCodeServerManager.shared.start()
                NSLog("[OpenCode] server ready at %@",
                      OpenCodeServerManager.shared.serverURL?.absoluteString ?? "?")
            } catch {
                NSLog("[OpenCode] server start failed: %@", "\(error)")
            }
        }

        // Hermes 模式的本地运行时：检测用户机器上是否装了 hermes，装了就自动 spawn
        // `hermes gateway run` 子进程，免去用户打开终端启服务的麻烦。没装则什么都不做（设置面板会显示
        // "未找到 hermes 命令"提示用户）。8642 端口已被占用（用户终端手起 / launchd service）会自动避让。
        Task.detached(priority: .utility) {
            await HermesGatewayManager.shared.startIfAvailable()
            await MainActor.run { [weak self] in
                // U5: gateway ready → 自动启用 .hermes mode（除非用户曾经手动关过）
                let status = HermesGatewayManager.shared.status
                if case .running = status {
                    EnabledModesStore.shared.autoEnableIfNotExplicitlyDisabled(.hermes)
                } else if case .external = status {
                    EnabledModesStore.shared.autoEnableIfNotExplicitlyDisabled(.hermes)
                }
                self?.viewModel?.checkConnection()
            }
        }

        // OpenClaw 模式的本地运行时：检测用户机器是否装了 openclaw（npm 全局装）。
        // 装了就自动读 ~/.openclaw/openclaw.json 拿 token / port，自动 enable chatCompletions endpoint
        // （OpenClaw 安全默认 disable，HermesPet 静默改 config + 重启 daemon），然后拉起 daemon。
        // 没装则什么都不做（设置面板会显示"未装 openclaw 命令"+ 一键安装命令复制按钮）。
        Task.detached(priority: .utility) {
            await OpenClawGatewayManager.shared.startIfAvailable()
            await MainActor.run { [weak self] in
                // U5: daemon ready → 自动启用 .openclaw mode（除非用户曾经手动关过）
                if case .running = OpenClawGatewayManager.shared.status {
                    EnabledModesStore.shared.autoEnableIfNotExplicitlyDisabled(.openclaw)
                }
                self?.viewModel?.checkConnection()
            }
        }

        // U5: Claude Code / Codex CLI 自动探测 —— 装了就自动启用对应 mode
        Task.detached(priority: .utility) {
            let hasClaude = await CLIAvailability.claudeAvailable()
            let hasCodex  = await CLIAvailability.codexAvailable()
            await MainActor.run {
                if hasClaude { EnabledModesStore.shared.autoEnableIfNotExplicitlyDisabled(.claudeCode) }
                if hasCodex  { EnabledModesStore.shared.autoEnableIfNotExplicitlyDisabled(.codex) }
            }
        }

        // ReasoningProxy：本地 SSE 过滤代理，修 opencode 对 reasoning_content 字段不兼容。
        // 让 DeepSeek V4 / Kimi K2.x / OpenAI o1+ 等推理模型也能在 opencode 下稳定工作。
        // 监听随机端口，OpenCodeConfigGenerator 启动后把所有 provider baseURL 改写到 proxy
        ReasoningProxy.shared.start()

        // 自动更新检查：启动 60s 后调一次 GitHub Release API，之后每 24h 一次。
        // 有新版 → 设置面板「关于」区 + 菜单栏出 🔵 提示，用户点击一键下载 + 引导挂载
        UpdateChecker.shared.start()

        // Dock 图标显隐 —— Info.plist 默认 LSUIElement=true 不占 Dock。
        // 用户在设置里开「显示 Dock 图标」时，runtime 切到 .regular policy 显示
        if UserDefaults.standard.bool(forKey: "showDockIcon") {
            NSApp.setActivationPolicy(.regular)
        }

        let vm = ChatViewModel()
        viewModel = vm

        // 聊天窗口（可拖拽调整大小）
        chatWindow = ChatWindowController(viewModel: vm)

        // 灵动岛胶囊
        let island = DynamicIslandController()
        island.show()
        island.onTapped = { [weak self] in
            // 错误态（连接断开）下点击灵动岛 → 顺便重新检测一次连接，再打开聊天
            if let vm = self?.viewModel,
               case .disconnected = vm.connectionStatus {
                vm.checkConnection()
            }
            self?.toggleChatWindow()
        }
        self.islandController = island

        // Permission UI 独立窗口 —— 监听 NotificationCenter 自驱，独立于灵动岛 NSWindow
        self.permissionWindowController = PermissionWindowController()

        // 任务回复摘要卡片 —— 监听 HermesPetResponseReady 自驱（v1.2.7-dev）
        self.responseSummaryController = ResponseSummaryWindowController()

        // Permission hook server + Claude / Codex CLI hook 安装。
        // 不论 permissionUIEnabled 开关如何，server 都启动（端口固定后才能写 hook 配置）
        // 由 ChatViewModel.permissionUIEnabled didSet 控制是否真注入 hook 到 ~/.claude/settings.json
        do {
            try PermissionHookServer.shared.start()
            // 如果用户上次启用着，立即注入 hook（用户开关同步在 ChatViewModel didSet）
            if UserDefaults.standard.bool(forKey: "permissionUIEnabled") {
                let port = PermissionHookServer.shared.port
                if port > 0 {
                    PermissionHookInstaller.installClaudeHook(port: port)
                    PermissionHookInstaller.installCodexHook(port: port)
                } else {
                    // server start 异步绑定端口，延迟到下一个 runloop 再写
                    DispatchQueue.main.async {
                        let p = PermissionHookServer.shared.port
                        if p > 0 {
                            PermissionHookInstaller.installClaudeHook(port: p)
                            PermissionHookInstaller.installCodexHook(port: p)
                        }
                    }
                }
            }
        } catch {
            NSLog("[PermissionHookServer] start failed: %@", "\(error)")
        }

        // 菜单栏图标：左键切换窗口，右键弹菜单（含"退出"）
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Hermes 桌宠")
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        island.setStatusItem(item)
        statusItem = item

        // 快问浮窗 controller 绑定 ViewModel + 聊天窗，便于"转聊天窗"按钮联动
        QuickAskWindowController.shared.attach(viewModel: vm, chatWindow: chatWindow)

        // 全局快捷键：
        //   Cmd+Shift+H      → 切换聊天窗口
        //   Cmd+Shift+J      → 截屏并附加
        //   Cmd+Shift+V      → 按住说话（push-to-talk），松开自动发送
        //   Cmd+Shift+Space  → Spotlight 风快问浮窗
        //   Cmd+Shift+P      → Pin 当前对话最新 AI 回答到桌面
        GlobalHotkey.shared.register(
            toggle: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.toggleChatWindow()
                }
            },
            capture: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.captureScreenAndAttach()
                }
            },
            voiceDown: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.startVoiceInput()
                }
            },
            voiceUp: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.stopVoiceInputAndSend()
                }
            },
            quickAsk: {
                Task { @MainActor in
                    QuickAskWindowController.shared.toggle()
                }
            },
            pinLastAnswer: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.pinLastAssistantAnswer()
                }
            }
        )

        startPolling()

        // 启动时主动请求一次屏幕录制权限：第一次启动会弹系统申请框；
        // 已经允许就什么都不做。这样用户不必"按了热键发现没反应才知道要权限"
        _ = ScreenCapture.requestScreenRecordingPermission()

        // 触发字幕窗 controller 初始化（init 时自己注册 Voice 通知，不需要 AppDelegate 后续维护）
        _ = VoiceTranscriptOverlayController.shared

        // Clawd 头顶情绪气泡 controller —— 同样在 init 注册通知
        _ = ClawdBubbleOverlayController.shared

        // 灵动岛下方选项菜单 —— AI 输出编号列表时弹出，让用户从灵动岛位置直接选
        _ = ChoiceMenuOverlayController.shared

        // 桌面 Pin 卡片 —— 启动时恢复已持久化的 pin 到屏幕右上角
        // 双击 pin → 转新对话（注入 ChatViewModel 入口）
        PinCardController.shared.onOpenInChat = { [weak vm] pin in
            vm?.openPinAsConversation(pin: pin)
        }
        PinCardController.shared.bootstrap()

        // 全局鼠标跟踪 —— Clawd 的眼睛跟着鼠标看
        MouseTrackingController.shared.start()

        // 系统 idle 检测 —— 3min 无活动 → 灵动岛圆点 dim + 飘 z + Clawd 漫步触发
        IdleStateTracker.shared.start()

        // Clawd 桌面漫步彩蛋 —— Claude 模式 + idle + 启用 → 沿菜单栏下方往返散步
        ClawdWalkController.shared.start(viewModel: vm)

        // 用户活动记录 —— 持续记录用户在用什么 app / 窗口、键盘节奏，让 AI 能"看见"用户做什么。
        // 默认开启（首次会弹 Accessibility 权限框，用户可在设置里关）。
        // UserDefaults 没值时默认 true；用户主动关过就保持关闭
        let activityEnabled = (UserDefaults.standard.object(forKey: "activityRecordingEnabled") as? Bool) ?? true
        if activityEnabled {
            ActivityRecorder.shared.start()
        }

        // v1.3 意图感知 —— 按回车 / ⌘S / ⌘C / ⌘V / app 切换 / spotlight 时静默采样屏幕 OCR
        // 默认 false（隐私优先），用户在设置里主动开启。共享 ActivityRecorder 的 SQLite handle
        UserIntentRecorder.shared.start(viewModel: vm, store: ActivityRecorder.shared.queryStore)

        // Phase 2 反向唤醒：detector attach + 灵动岛建议卡片 window + 路由管理
        IntentPatternDetector.shared.attach(store: ActivityRecorder.shared.queryStore)
        intentSuggestionController = IntentSuggestionWindowController()
        IntentNotificationManager.shared.start(
            viewModel: vm,
            store: ActivityRecorder.shared.queryStore
        )

        // 每日早报 —— 检查今天有没有生成过，没有就在 3s 后用 morningBriefingBackend 生成一份
        MorningBriefingService.shared.generateIfNeeded(viewModel: vm)

        // 监听任务完成 → 播放清脆"叮~"音效
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTaskFinishedSound(_:)),
            name: .init("HermesPetTaskFinished"),
            object: nil
        )

        // Clawd 桌面漫步上点击 → 打开聊天窗口
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenChatRequested(_:)),
            name: .init("HermesPetOpenChatRequested"),
            object: nil
        )
    }

    /// App 退出前：杀掉所有还在跑的 Claude/Codex 子进程，避免僵尸进程
    func applicationWillTerminate(_ notification: Notification) {
        // 先关 ReasoningProxy（OpenCodeServerManager 之前关，让正在 forward 的请求有机会收尾）
        ReasoningProxy.shared.stop()
        // 优雅 terminate opencode server（让它有机会 flush SQLite）
        OpenCodeServerManager.shared.terminate()
        // 我们 spawn 的 hermes gateway 也一起停（外部管理的会自动跳过，详见 HermesGatewayManager.terminate()）
        HermesGatewayManager.shared.terminate()
        let count = SubprocessRegistry.shared.runningCount
        if count > 0 {
            print("[Lifecycle] 退出时清理 \(count) 个未结束的子进程")
        }
        SubprocessRegistry.shared.terminateAll()
        // 让 ActivityRecorder 把当前会话落盘
        ActivityRecorder.shared.stop()
    }

    /// Clawd 桌面漫步上单击 / 双击都会触发此通知，统一回到打开聊天窗口
    @objc private func handleOpenChatRequested(_ note: Notification) {
        // 如果当前没在 chat 窗口（比如断连状态），同时检查一次连接
        if let vm = viewModel, case .disconnected = vm.connectionStatus {
            vm.checkConnection()
        }
        // 已显示则不重复打开（toggle 会反向收起），只在隐藏时才呼出
        if chatWindow?.isVisible == true { return }
        toggleChatWindow()
    }

    /// AI 回复完成时的音效反馈（跟按住语音的 "duang" 区分）
    @objc private func handleTaskFinishedSound(_ note: Notification) {
        let success = (note.userInfo?["success"] as? Bool) ?? false
        guard success else { return }   // 失败/取消静默，避免烦人
        let soundName = UserDefaults.standard.string(forKey: "voiceFinishSound") ?? "Glass"
        guard !soundName.isEmpty else { return }
        NSSound(named: soundName)?.play()
    }

    @objc func toggleFromMenuBar() {
        toggleChatWindow()
    }

    /// 菜单栏图标的点击分发：
    /// - 左键 / 单击：切换聊天窗口（保留原有快捷行为）
    /// - 右键 / Control+左键：弹出菜单（截屏、退出 等）
    @objc func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            toggleChatWindow()
            return
        }
        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRightClick {
            showStatusMenu()
        } else {
            toggleChatWindow()
        }
    }

    /// 在菜单栏图标下方弹出菜单（用完即清，避免左键也被劫持）
    private func showStatusMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "打开 / 关闭聊天", action: #selector(toggleFromMenuBar), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let captureItem = NSMenuItem(title: "截屏并附加", action: #selector(menuCaptureScreen), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let briefingItem = NSMenuItem(title: "📰 立即生成今日早报", action: #selector(menuGenerateBriefing), keyEquivalent: "")
        briefingItem.target = self
        menu.addItem(briefingItem)

        let exportPinsItem = NSMenuItem(title: "📌 导出全部 Pin 为 Markdown", action: #selector(menuExportPins), keyEquivalent: "")
        exportPinsItem.target = self
        exportPinsItem.isEnabled = !PinStore.shared.pins.isEmpty
        menu.addItem(exportPinsItem)

        menu.addItem(.separator())

        // 检查更新：有新版时菜单项标题带🔵小圆点提示
        let checker = UpdateChecker.shared
        let updateTitle: String
        if checker.hasUpdate, let v = checker.latestVersion {
            updateTitle = "🔵 有新版 v\(v) · 点击查看"
        } else {
            updateTitle = "检查更新（当前 v\(checker.currentVersion)）"
        }
        let updateItem = NSMenuItem(title: updateTitle, action: #selector(menuCheckUpdate), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Hermes 桌宠", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuCaptureScreen() {
        captureScreenAndAttach()
    }

    @objc private func menuGenerateBriefing() {
        guard let vm = viewModel else { return }
        MorningBriefingService.shared.generateNow(viewModel: vm)
    }

    @objc private func menuExportPins() {
        PinCardController.shared.exportAllPinsToMarkdown()
    }

    /// 菜单栏「检查更新」点击：
    /// - 有新版 → 直接调 downloadAndInstall 一键流程
    /// - 没新版 / 没检查过 → 触发 silently=false 检查，结果通过 alert 反馈
    @objc private func menuCheckUpdate() {
        let checker = UpdateChecker.shared
        if checker.hasUpdate {
            Task { @MainActor in await checker.downloadAndInstall() }
        } else {
            Task { @MainActor in
                await checker.check(silently: false)
                if checker.hasUpdate {
                    // 检查后发现有新版 → 直接弹窗确认是否下载
                    let alert = NSAlert()
                    alert.messageText = "发现新版 v\(checker.latestVersion ?? "")"
                    alert.informativeText = "当前 v\(checker.currentVersion)。要现在下载并安装吗？"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "下载并安装")
                    alert.addButton(withTitle: "稍后")
                    if alert.runModal() == .alertFirstButtonReturn {
                        await checker.downloadAndInstall()
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "已是最新版本"
                    alert.informativeText = "当前 v\(checker.currentVersion) 是最新的 🎉"
                    if let err = checker.lastError {
                        alert.informativeText = err
                        alert.alertStyle = .warning
                    }
                    alert.addButton(withTitle: "好的")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func toggleChatWindow() {
        // 锚点优先用灵动岛胶囊（首次显示时定位用），其次菜单栏按钮
        let anchor: NSView? = islandController?.pillWindow.contentView ?? statusItem?.button
        chatWindow?.toggle(near: anchor)
    }

    // MARK: - 语音输入（push-to-talk）

    /// Cmd+Shift+V 按下：请求权限后启动录音。第一次按会弹麦克风 / 语音识别权限框。
    private func startVoiceInput() {
        // 防抖：如果已经在听写，忽略重复按下
        guard !VoiceInputController.shared.isListening else { return }

        Task { @MainActor in
            let (granted, errorMessage) = await VoiceInputController.shared.requestPermissions()
            if granted {
                // Apple Intelligence 风格光环 + duang 音效，显示在录音前
                IntelligenceOverlayController.shared.show()
                _ = VoiceInputController.shared.startListening()
            } else {
                NotificationCenter.default.post(
                    name: .init("HermesPetScreenshotAdded"),
                    object: nil,
                    userInfo: ["text": "⚠️ \(errorMessage ?? "无法启用语音")", "count": 0]
                )
            }
        }
    }

    /// Cmd+Shift+V 松开：停止录音，把最终识别文字交给 ViewModel 自动发送
    private func stopVoiceInputAndSend() {
        guard VoiceInputController.shared.isListening else { return }
        IntelligenceOverlayController.shared.hide()
        let text = VoiceInputController.shared.stopListening()
        viewModel?.submitVoiceInput(text)
    }

    /// Cmd+Shift+P 全局热键调用：把当前对话**最后一条 assistant 消息**钉到桌面。
    /// 找不到（对话还没回复 / 仍在流式生成）→ 通过截图通知通道弹灵动岛提示
    private func pinLastAssistantAnswer() {
        guard let vm = viewModel else { return }
        let active = vm.conversations.first(where: { $0.id == vm.activeConversationID })

        // 找最后一条 assistant + 非流式 + content 不空的消息
        let target = active?.messages
            .reversed()
            .first(where: { $0.role == .assistant && !$0.isStreaming && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        guard let msg = target, let conv = active else {
            NotificationCenter.default.post(
                name: .init("HermesPetScreenshotAdded"),
                object: nil,
                userInfo: ["text": "⚠️ 还没有可 Pin 的回答", "count": 0]
            )
            return
        }

        let result = PinCardController.pin(
            content: msg.content,
            mode: conv.mode,
            conversationID: conv.id,
            messageID: msg.id
        )
        let msgText: String
        switch result {
        case .added:     msgText = "📌 已 Pin 到桌面"
        case .duplicate: msgText = "已经 Pin 过这条了"
        case .full:      msgText = "⚠️ Pin 已达上限 8 张"
        }
        NotificationCenter.default.post(
            name: .init("HermesPetScreenshotAdded"),
            object: nil,
            userInfo: ["text": msgText, "count": 0]
        )
    }

    /// Cmd+Shift+J 全局热键调用：截当前屏幕并附加到聊天框。
    /// 不主动打开窗口 —— 灵动岛弹一个「截图已添加」通知，用户想看再点开。
    private func captureScreenAndAttach() {
        guard let vm = viewModel else { return }
        let chatWindow = self.chatWindow
        let wasVisible = chatWindow?.isVisible ?? false

        vm.captureScreenAndAttach { [weak chatWindow] hide, done in
            // 只在原本就开着的情况下才隐藏/恢复，否则全程不打扰
            guard wasVisible else { done(); return }
            if hide {
                // hide 是 0.22s 退出动画，必须等动画 completion 才能截图
                chatWindow?.hide { done() }
            } else {
                let anchor: NSView? = self.islandController?.pillWindow.contentView ?? self.statusItem?.button
                chatWindow?.show(near: anchor)
                done()   // 恢复不需要等
            }
        }
    }

    // MARK: - Polling

    private var iconTimer: Timer?

    private func startPolling() {
        updateAll()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAll()
            }
        }
    }

    private func updateAll() {
        guard let vm = viewModel else { return }

        // Update menu bar icon color
        if let button = statusItem?.button {
            switch vm.connectionStatus {
            case .connected:
                button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Hermes — 已连接")
                button.contentTintColor = .systemGreen
            case .disconnected:
                button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Hermes — 已断开")
                button.contentTintColor = .systemRed
            case .unknown:
                button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Hermes 桌宠")
                button.contentTintColor = .tertiaryLabelColor
            }
        }

        // Update Dynamic Island status — posted via notification
        islandController?.updateStatus(vm.connectionStatus)
    }
}
