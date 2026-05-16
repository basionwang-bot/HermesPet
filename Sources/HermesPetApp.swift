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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        let vm = ChatViewModel()
        viewModel = vm

        // 聊天窗口（可拖拽调整大小）
        chatWindow = ChatWindowController(viewModel: vm)

        // 灵动岛胶囊
        let island = DynamicIslandController()
        // 注入 vm **先于** show()：替换 hostingView.rootView 会让 SwiftUI @State 全部重置（status/工具进度/shutter/...）
        // 要是先 show 再 attach，用户会看到 ~一帧的"初始 idle 状态"闪现 → 视觉抖动
        island.attach(viewModel: vm)
        island.show()
        island.onTapped = { [weak self] in
            // 错误态（连接断开）下点击灵动岛 → 顺便重新检测一次连接，再打开聊天
            if let vm = self?.viewModel,
               case .disconnected = vm.connectionStatus {
                vm.checkConnection()
            }
            self?.toggleChatWindow()
        }
        // 嵌入式聊天框右上角"展开主聊天窗"按钮 + embedded panel 空白处点击 → 开 ChatWindow（hover 模式）。
        // 走 hoverMode: true → 主聊天窗失焦 / 鼠标离开后自动收回，跟"hover 灵动岛 500ms 触发主窗"
        // 用同一套生命周期：用户从灵动岛/embedded 流来的窗口都是"暂时性的"，鼠标离开就该消失，
        // 跟 ⌘⇧H 主动呼出的"持久窗口"区分开（后者只有用户再次 ⌘⇧H / 点关闭才消失）
        island.onRequestFullChatWindow = { [weak self] in
            self?.toggleChatWindow(hoverMode: true)
        }
        self.islandController = island

        // 给聊天窗注入"灵动岛 frame 提供器" —— hover 模式下判断鼠标在 island + chat 连通区
        // 用 closure 而非直接持有 island 引用，避免 retain cycle
        chatWindow?.islandFrameProvider = { [weak island] in
            island?.pillWindow.frame
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

        // 任务完成后灵动岛下方弹出的「迷你回复预览卡片」
        // 仅 active 对话完成 + 聊天窗未显示 时才弹，避免跟后台 ConversationPill 呼吸光线重复透出
        MiniReplyCardController.shared.chatWindowIsVisible = { [weak self] in
            self?.chatWindow?.isVisible ?? false
        }
        MiniReplyCardController.shared.onOpenChat = { [weak self] in
            guard let self = self else { return }
            if self.chatWindow?.isVisible == true { return }
            self.toggleChatWindow()
        }

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

        // hover 灵动岛 500ms 后请求"主开 ChatWindow"（仅 hoverExpandMode == .chatWindow 时触发）。
        // mode 路由在 DynamicIslandPillView.handleHoverForExpand 完成；embedded mode 完全由 island 内部处理，
        // 不走这条通知（island 直接 setEmbeddedExpanded 改 panel frame，AppDelegate 不参与）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHoverExpandRequested(_:)),
            name: .init("HermesPetHoverExpandRequested"),
            object: nil
        )
    }

    /// App 退出前：杀掉所有还在跑的 Claude/Codex 子进程，避免僵尸进程
    func applicationWillTerminate(_ notification: Notification) {
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

    /// hover 灵动岛 500ms 后展开聊天窗（hoverMode=true）。
    /// 仅当 hoverExpandMode == .chatWindow 时此通知会被 PillView post —— 这里加 guard 防御未来误触
    @objc private func handleHoverExpandRequested(_ note: Notification) {
        // 防御：mode 不是 chatWindow 不应处理（PillView 内已分支，这里是双保险）
        guard viewModel?.hoverExpandMode == .chatWindow else { return }
        guard chatWindow?.isVisible != true else { return }
        if let vm = viewModel, case .disconnected = vm.connectionStatus {
            vm.checkConnection()
        }
        // 若 mini card 正悬浮，hover 展开聊天窗时立刻收掉 —— 避免双显示
        MiniReplyCardController.shared.hideIfVisible()
        let anchor: NSView? = islandController?.pillWindow.contentView ?? statusItem?.button
        chatWindow?.show(near: anchor, hoverMode: true)
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

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// 切换主聊天窗显示状态。
    /// - Parameter hoverMode: true → 主聊天窗失焦 / 鼠标离开自动收回（embedded / hover 灵动岛流的入口用）；
    ///   false（默认）→ 持久窗口，只有用户主动 ⌘⇧H / 点关闭才消失（⌘⇧H / 菜单栏 / Clawd 点击用）
    private func toggleChatWindow(hoverMode: Bool = false) {
        // 锚点优先用灵动岛胶囊（首次显示时定位用），其次菜单栏按钮
        let anchor: NSView? = islandController?.pillWindow.contentView ?? statusItem?.button
        // 若 mini card 正悬浮（任务完成后弹的预览），打开聊天窗时立刻收掉 —— 避免双显示
        if chatWindow?.isVisible == false {
            MiniReplyCardController.shared.hideIfVisible()
        }
        // 若灵动岛正处于嵌入式聊天形态，也收回 —— 主聊天窗弹出时不允许两个聊天界面并存
        islandController?.setEmbeddedExpanded(false)
        NotificationCenter.default.post(name: .init("HermesPetEmbeddedDismissed"), object: nil)
        // hoverMode 只在"开窗"时有意义；如果已显示走 hide()（不区分 mode）
        if chatWindow?.isVisible == true {
            chatWindow?.hide()
        } else {
            chatWindow?.show(near: anchor, hoverMode: hoverMode)
        }
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

    /// Cmd+Shift+J 全局热键调用：截当前屏幕并附加到聊天框。
    /// 不主动打开窗口 —— 灵动岛弹一个「截图已添加」通知，用户想看再点开。
    private func captureScreenAndAttach() {
        guard let vm = viewModel else { return }
        let chatWindow = self.chatWindow
        let wasVisible = chatWindow?.isVisible ?? false

        vm.captureScreenAndAttach { [weak chatWindow] hide in
            // 只在原本就开着的情况下才隐藏/恢复，否则全程不打扰
            guard wasVisible else { return }
            if hide {
                chatWindow?.hide()
            } else {
                let anchor: NSView? = self.islandController?.pillWindow.contentView ?? self.statusItem?.button
                chatWindow?.show(near: anchor)
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
