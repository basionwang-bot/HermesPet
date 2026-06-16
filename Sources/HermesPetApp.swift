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
    /// 灵动岛「第三形态」菜单栏常驻迷你胶囊控制器（仅 DisplayMode.mini 时创建，替代大灵动岛）
    private var miniIslandController: MiniIslandController?
    /// 语音陪聊「会说话的脸」独立窗口控制器（⌘⇧L 唤起，守决策 #1 独立于灵动岛）
    private var voiceChatController: VoiceChatController?
    /// 任务回复摘要卡片控制器（v1.2.7-dev）—— 聊天窗关着时 task 完成 → 灵动岛下方弹摘要
    private var responseSummaryController: ResponseSummaryWindowController?
    /// 意图建议卡片控制器（v1.3 Phase 2）—— 识别到"重复 / 报错"等 pattern 时弹建议
    private var intentSuggestionController: IntentSuggestionWindowController?

    /// M4 工作流技能卡：手机发起的运行 runId → 实时 RunModel 的小注册表。
    /// 手机轮询 /run 时从这里取 RunModel 序列化进度；/run/confirm 找对应 RunModel 回写确认。
    /// 只留内存（重启即丢，符合"挂起等待类不依赖长连接"的设计；轨迹本身已落盘 WorkflowRunStore）。
    private var phoneRunModels: [String: RunModel] = [:]

    /// 菜单栏小怪兽图标（呼应 App 图标里的像素外星人）。
    /// 做成 template 图：菜单栏会自动按浅色/深色着色，且仍能被 contentTintColor 染成
    /// 绿/红/灰来表达连接状态。只画一次缓存复用（updateAll 轮询会反复取用）。
    private lazy var monsterMenuBarImage: NSImage = Self.makeMonsterMenuBarImage()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 头号崩溃定位：尽早安装异常捕获（swizzle reportException + 未捕获异常处理器），
        // 把 NSException 的 reason + 调用栈落盘，CrashReporter 上报时带上（见 ExceptionLogger 注释 + issues #25~#35）。
        ExceptionLogger.install()

        // 模型上下文窗口目录：加载本地缓存 + 异步刷新 models.dev（给 Context 进度条算真实窗口）
        ModelCatalog.shared.loadCachedAndRefresh()

        // 配置迁移：把老版本的 UserDefaults 字段升级到当前 schema。
        // 必须在任何读 UserDefaults 的代码（ChatViewModel / OpenCodeConfigGenerator 等）之前跑，
        // 否则它们会读到旧 key 拿不到值。同步执行（UserDefaults 操作极快，不阻塞启动）。
        SchemaMigrator.runMigrations()

        // 宠物养成中枢：App 启动即创建并常驻监听活动信号（不能懒加载到聊天窗出现才创建，
        // 否则没开聊天窗时跑的舰队经验会丢）。读自己的 UserDefaults，放在 SchemaMigrator 之后。
        _ = PetProgressStore.shared

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

        // ⭐ ReasoningProxy 必须**先于** opencode server 启动：本地 SSE 过滤代理，剥掉推理模型
        // （智谱 GLM / DeepSeek V4 / Kimi K2.x / OpenAI o1+）的 reasoning_content，避免思考过程泄漏成正文。
        // 监听随机端口，OpenCodeConfigGenerator 把所有 provider baseURL 改写到本代理。
        // ⚠️ 顺序关键：opencode server start 时会 `await proxy 就绪` 再生成 opencode.json；proxy 必须已在
        // 路上，否则 server 等不到端口 → 配置 fallback 成"直连 provider"绕过过滤 → 推理泄漏（曾经的「有时输出不好」）。
        ReasoningProxy.shared.start()

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

        // （ReasoningProxy.shared.start() 已提前到 opencode server 启动之前，见上方）

        // 在线 AI 服务商「远程预设清单」：启动后台拉一次公开仓 presets.json，合并进可选服务商列表。
        // 加新厂商（如小米 MiMo）= 改公开仓 JSON push 一下，用户当天就有，不用发版；拉不到则用内置兜底。
        Task.detached(priority: .utility) {
            await ProviderPresetRegistry.shared.refreshFromRemote()
        }

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
        setupWorkbenchCommandListener()

        // Dock 图标偏好（默认开，v1.3）—— showDockIcon 的 didSet 在 init 不触发，启动时显式应用一次
        NSApp.setActivationPolicy(vm.showDockIcon ? .regular : .accessory)

        // 聊天窗口（可拖拽调整大小）
        chatWindow = ChatWindowController(viewModel: vm)

        // 灵动岛胶囊 —— 形态三选一（决策 #1）
        // 第三形态 mini：不创建大灵动岛（连它的全局点击/hover 监听都不挂，避免空刘海误触），
        // 改用菜单栏常驻迷你胶囊 MiniIslandController。
        if DisplayMode.isMini {
            let mini = MiniIslandController()
            mini.onTapped = { [weak self] in
                if let vm = self?.viewModel, case .disconnected = vm.connectionStatus {
                    vm.checkConnection()
                }
                self?.toggleChatWindow()
            }
            mini.activate()
            self.miniIslandController = mini
        } else {
            let island = DynamicIslandController()
            island.show()
            island.onTapped = { [weak self] in
                // 会议录音收起态下点灵动岛 → 展开录音大窗（只展开，绝不停录），不开聊天
                if MeetingOverlayController.shared.isRecordingCollapsed {
                    MeetingOverlayController.shared.expandFromIsland()
                    return
                }
                // 错误态（连接断开）下点击灵动岛 → 顺便重新检测一次连接，再打开聊天
                if let vm = self?.viewModel,
                   case .disconnected = vm.connectionStatus {
                    vm.checkConnection()
                }
                self?.toggleChatWindow()
            }
            self.islandController = island
        }

        // Permission UI 独立窗口 —— 监听 NotificationCenter 自驱，独立于灵动岛 NSWindow
        self.permissionWindowController = PermissionWindowController()

        // 语音陪聊「会说话的脸」独立窗口（⌘⇧L 唤起）—— 悬浮刘海下方，独立于灵动岛本体
        self.voiceChatController = VoiceChatController()

        // 系统信息仪表盘独立窗口 —— hover 灵动岛时在刘海下方展开完整仪表盘（自驱，靠 static shared 持有）
        _ = SystemStatsPanelController()
        // 上次把系统监控卡片钉在桌面的话，原位置还原
        SystemStatsPinController.shared.restoreIfNeeded()

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

        // 手机命令接收器（局域网）：手机派来的活 → 真让 AI 干 + 桌宠冒泡
        CommandServer.shared.onCommand = { [weak vm] text, modeRaw in
            guard let vm else { return nil }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            // 切到手机选的那个 AI：mode 和当前对话不同才新建对话（用对 AI 又不让对话暴涨）
            if let raw = modeRaw, let target = AgentMode(rawValue: raw) {
                let cur = vm.conversations.first(where: { $0.id == vm.activeConversationID })
                if cur?.mode != target { _ = vm.newConversation(mode: target) }
            } else if vm.activeConversationID.isEmpty
                        || !vm.conversations.contains(where: { $0.id == vm.activeConversationID }) {
                _ = vm.newConversation(mode: nil)
            }
            // 桌宠冒泡，让"收到手机命令"肉眼可见
            NotificationCenter.default.post(
                name: .init("HermesPetClawdBubble"), object: nil,
                userInfo: ["text": "📱 手机说：\(clean)", "duration": 3.0])
            // 真的发起 AI 任务
            vm.inputText = clean
            vm.sendMessage()
            return vm.activeConversationID   // 告诉手机这条活落在哪个对话，便于回传结果
        }
        // 手机轮询某对话的实时状态：消息 + 是否还在回复
        CommandServer.shared.stateProvider = { [weak vm] id in
            guard let vm, let conv = vm.conversations.first(where: { $0.id == id }) else { return nil }
            let msgs: [[String: Any]] = conv.messages.map { m in
                ["role": m.role.rawValue,
                 "content": m.content,
                 "images": m.imagePaths.map { ($0 as NSString).lastPathComponent }]
            }
            let obj: [String: Any] = [
                "id": conv.id,
                "title": conv.title,
                "mode": conv.mode.rawValue,
                "isStreaming": conv.isStreaming,
                "messages": msgs
            ]
            return try? JSONSerialization.data(withJSONObject: obj)
        }
        // 手机查看「成果」：列出已生成网页 + 取某个网页的 HTML（ArtifactStore 是 @MainActor，这里在主线程调）
        CommandServer.shared.artifactsProvider = {
            let iso = ISO8601DateFormatter()
            let arr: [[String: Any]] = ArtifactStore.shared.records.map { r in
                var obj: [String: Any] = [
                    "id": r.id,
                    "title": r.title,
                    "createdAt": iso.string(from: r.createdAt),
                    "kind": "html"
                ]
                if let m = r.modeRaw { obj["modeRaw"] = m }
                return obj
            }
            return try? JSONSerialization.data(withJSONObject: ["artifacts": arr])
        }
        CommandServer.shared.artifactContentProvider = { id in
            guard let rec = ArtifactStore.shared.record(id: id) else { return nil }
            return try? Data(contentsOf: rec.fileURL)
        }
        // 手机拉最近一份「银月早报」：读 daily_journal 最新一行，把正文末尾的 ```docs 围栏拆出来。
        CommandServer.shared.briefingProvider = {
            guard let entry = ActivityRecorder.shared.queryStore.recentDailyJournals(limit: 1).first else {
                return "{\"hasBriefing\":false}".data(using: .utf8)!
            }
            // 把正文末尾的 ```docs ... ``` 围栏拆出来：body=去掉围栏的纯正文，docs=围栏里的文件名（取 basename）
            let (body, docNames) = Self.splitBriefingDocs(entry.summaryMarkdown)
            let iso = ISO8601DateFormatter()
            var obj: [String: Any] = [
                "hasBriefing": true,
                "date": entry.date,
                "markdown": body,
                "generatedAt": iso.string(from: entry.createdAt),
                "docs": docNames
            ]
            if let b = entry.backend { obj["backend"] = b }
            return try? JSONSerialization.data(withJSONObject: obj)
        }
        // 手机点「重新生成」：触发立即生成一份早报（异步流式，手机随后轮询 /briefing/latest）
        CommandServer.shared.briefingGenerator = { [weak vm] in
            guard let vm else { return }
            MorningBriefingService.shared.generateNow(viewModel: vm)
        }
        // M3 远程拍板：把 PermissionHookServer 的未决列表 + 决策回写架到面向手机的 CommandServer 上。
        // provider 序列化未决请求；decider 把手机的决策转成 PermissionDecision resume 那条挂起的 CLI 请求。
        CommandServer.shared.pendingPermissionsProvider = {
            Self.serializePendingPermissions()
        }
        CommandServer.shared.permissionDecider = { id, decisionRaw in
            guard let decision = PermissionDecision(rawValue: decisionRaw) else { return false }
            return PermissionHookServer.shared.remoteDecide(requestID: id, decision: decision)
        }
        // M4 工作流技能卡：把内置工作流 + harness 运行器架到手机端 CommandServer 上。
        // workflowsProvider 序列化 WorkflowRegistry.bundled；workflowRunner 新建 RunModel 后台跑 WorkflowRunner.run，
        // runId 先返回、状态后续靠 /run 轮询；runStateProvider 序列化那个 RunModel；runConfirmer 回写人工确认。
        CommandServer.shared.workflowsProvider = {
            Self.serializeWorkflows()
        }
        CommandServer.shared.workflowRunner = { [weak vm] id, input, modeRaw in
            guard let vm, let wf = WorkflowRegistry.shared.workflow(id: id) else { return nil }
            // mode：手机指定了用哪个 AI 就用那个，否则用 vm 当前/上次用的后端（守红线：调度由银月后台定）
            let backend = modeRaw.flatMap { AgentMode(rawValue: $0) } ?? vm.agentMode
            let material = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let stepRecords = wf.effectiveStages.map {
                WorkflowStepRecord(stepID: $0.id, title: $0.title, kind: $0.kind, status: "pending")
            }
            let run = WorkflowRun(id: UUID().uuidString,
                                  workflowID: wf.id, workflowName: wf.name,
                                  modeRaw: backend.rawValue, input: material,
                                  status: "running", steps: stepRecords,
                                  createdAt: Date(), updatedAt: Date())
            let model = RunModel(run: run, workflow: wf)
            WorkflowRunStore.shared.add(run)
            WorkflowTelemetry.recordRun(id: wf.id, mode: backend.rawValue)
            self.phoneRunModels[run.id] = model
            // async 跑 —— runId 立即返回，手机随后轮询 /run 看进度/产物
            Task { @MainActor in
                _ = await WorkflowRunner.run(workflow: wf, input: material, backend: backend, vm: vm, model: model)
            }
            return run.id
        }
        CommandServer.shared.runStateProvider = { [weak self] runId in
            guard let self, let model = self.phoneRunModels[runId] else { return nil }
            return Self.serializeRunState(model)
        }
        CommandServer.shared.runConfirmer = { [weak self] runId, decisionRaw in
            guard let self, let model = self.phoneRunModels[runId] else { return }
            switch decisionRaw {
            case "allow": model.resolveConfirm(.allow)
            case "skip":  model.resolveConfirm(.skip)
            case "abort": model.abort()
            default:      break
            }
        }
        do {
            try CommandServer.shared.start()
        } catch {
            NSLog("[CommandServer] start failed: %@", "\(error)")
        }

        // 云中继：若已配置(~/.hermespet/cloud.json 或环境变量)，主动连云中转，
        // 让手机在外网也能通过中转操控本机。未配置则自动跳过、不影响局域网直连。
        CloudRelayClient.shared.start()

        // 菜单栏图标：左键切换窗口，右键弹菜单（含"退出"）
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = monsterMenuBarImage
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        islandController?.setStatusItem(item)   // mini 模式无大灵动岛 → no-op
        statusItem = item

        // 快问浮窗 controller 绑定 ViewModel + 聊天窗，便于"转聊天窗"按钮联动
        QuickAskWindowController.shared.attach(viewModel: vm, chatWindow: chatWindow)

        // 语音陪聊绑定 ViewModel（陪聊请求复用 vm.streamOneShotAsk 跟随当前 mode）
        voiceChatController?.attach(viewModel: vm)

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
            },
            knowledgeGraph: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let vm = self?.viewModel else { return }
                    KnowledgeGraphOverlayController.shared.toggle(viewModel: vm)
                }
            },
            notes: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.toggleWritingMode()
                }
            },
            meeting: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.toggleMeetingRecorder()
                }
            },
            voiceChat: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.voiceChatController?.toggle()
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

        // 周期总结回顾（第二层）—— 距上次 ≥7 天 / 认识满 N 天里程碑时，6s 后生成一份
        PeriodicReviewService.shared.generateIfNeeded(viewModel: vm)

        // 新用户首次引导 —— 仅真·新用户弹（老用户静默跳过）
        maybeShowOnboarding(vm: vm)

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

        // 会议纪要结果窗「打开笔记」按钮 → 进写作模式（笔记列表顶部即刚存的纪要）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterWritingMode),
            name: .init("HermesPetEnterWritingMode"),
            object: nil
        )

        // 聊天窗 header「会议纪要」按钮 → 开始/结束录音（免得从菜单栏翻）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleMeeting),
            name: .init("HermesPetToggleMeeting"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivateWorkflow(_:)),
            name: .init("HermesPetActivateWorkflow"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenArena),
            name: .init("HermesPetOpenArena"),
            object: nil
        )
    }

    /// 设置里「打开竞技场」→ 用 vm 开竞技场窗口（需要 vm 跑工作流 + 裁判）。
    @objc private func handleOpenArena() {
        guard let vm = viewModel else { return }
        ArenaWindowController.shared.show(vm: vm)
    }

    @objc private func handleToggleMeeting() {
        toggleMeetingRecorder()
    }

    /// 陈列页点了某 workflow → 激活它 + 唤起聊天窗（关着就先开），让用户在输入栏喂内容。
    @objc private func handleActivateWorkflow(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? String, let vm = viewModel else { return }
        if ChatWindowController.shared?.isVisible != true { toggleChatWindow() }
        vm.activateWorkflow(id)
    }

    @objc private func handleEnterWritingMode() {
        guard let vm = viewModel else { return }
        if ChatWindowController.shared?.isVisible == true {
            vm.isWritingMode = true
        } else {
            toggleWritingMode()   // 没开聊天窗 → 先开再进写作模式
        }
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

        let openItem = NSMenuItem(title: L("app.menu.toggleChat"), action: #selector(toggleFromMenuBar), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let captureItem = NSMenuItem(title: L("app.menu.capture"), action: #selector(menuCaptureScreen), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let briefingItem = NSMenuItem(title: L("app.menu.briefing"), action: #selector(menuGenerateBriefing), keyEquivalent: "")
        briefingItem.target = self
        menu.addItem(briefingItem)

        let reviewItem = NSMenuItem(title: L("app.menu.review"), action: #selector(menuGeneratePeriodicReview), keyEquivalent: "")
        reviewItem.target = self
        menu.addItem(reviewItem)

        let onboardingItem = NSMenuItem(title: L("app.menu.onboarding"), action: #selector(menuShowOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let exportPinsItem = NSMenuItem(title: L("app.menu.exportPins"), action: #selector(menuExportPins), keyEquivalent: "")
        exportPinsItem.target = self
        exportPinsItem.isEnabled = !PinStore.shared.pins.isEmpty
        menu.addItem(exportPinsItem)

        let notesItem = NSMenuItem(title: L("notes.menu.openNotes"), action: #selector(menuOpenNotes), keyEquivalent: "")
        notesItem.target = self
        menu.addItem(notesItem)

        let meetingItem = NSMenuItem(title: L("app.menu.meeting"), action: #selector(menuMeeting), keyEquivalent: "")
        meetingItem.target = self
        menu.addItem(meetingItem)

        // 舰队工作流（实验）—— Clawd 当队长，把任务拆成多路子 Agent 并行干，再汇总
        let fleetItem = NSMenuItem(title: "🚀 舰队工作流（实验）", action: #selector(menuOpenFleet), keyEquivalent: "")
        fleetItem.target = self
        menu.addItem(fleetItem)

        // 工作台（实验）—— 刘海展开成全屏 AI 工作空间的视觉原型（双层主题 + AI 干活可视化）
        let workbenchItem = NSMenuItem(title: "🛠 工作台（实验）", action: #selector(menuOpenWorkbench), keyEquivalent: "")
        workbenchItem.target = self
        menu.addItem(workbenchItem)

        // 重新转写最近一段录音（用新 SpeechAnalyzer 引擎重跑全量转写 + 整理，验证效果）
        let reanalyzeItem = NSMenuItem(title: "🔁 重新转写最近的录音（新引擎）", action: #selector(menuReanalyzeRecording), keyEquivalent: "")
        reanalyzeItem.target = self
        menu.addItem(reanalyzeItem)

        // AI 看屏幕 / 接管窗口（v1.6，实验性功能——仅在设置→实验性 打开后才出现）
        if ExperimentalStore.shared.screenTakeoverEnabled {
            if ScreenTakeoverController.shared.isActive {
                let stopItem = NSMenuItem(title: "⏹ 停止接管", action: #selector(menuStopTakeover), keyEquivalent: "")
                stopItem.target = self
                menu.addItem(stopItem)
            } else {
                let takeoverItem = NSMenuItem(title: "🦞 接管一个窗口…", action: #selector(menuStartTakeover), keyEquivalent: "")
                takeoverItem.target = self
                menu.addItem(takeoverItem)
            }

            let styleItem = NSMenuItem(title: "✏️ 设置回复风格…", action: #selector(menuSetReplyStyle), keyEquivalent: "")
            styleItem.target = self
            menu.addItem(styleItem)
        }

        menu.addItem(.separator())

        // 检查更新：有新版时菜单项标题带🔵小圆点提示
        let checker = UpdateChecker.shared
        let updateTitle: String
        if checker.hasUpdate, let v = checker.latestVersion {
            updateTitle = L("app.menu.update.available", v)
        } else {
            updateTitle = L("app.menu.update.check", checker.currentVersion)
        }
        let updateItem = NSMenuItem(title: updateTitle, action: #selector(menuCheckUpdate), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("app.menu.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuCaptureScreen() {
        captureScreenAndAttach()
    }

    @objc private func menuOpenNotes() {
        toggleWritingMode()
    }

    @objc private func menuMeeting() {
        toggleMeetingRecorder()
    }

    @objc private func menuOpenFleet() {
        guard let vm = viewModel else { return }
        FleetTheaterController.shared.present(vm: vm)
    }

    @objc private func menuOpenWorkbench() {
        // 工作台 = 独立窗口（标准窗口层级，不盖 Dock、可移动缩放、与其他 app 并排）。
        // 刘海全屏 .workspace 那套（SystemStatsPanelController.presentWorkspace）保留作"沉浸版"退路。
        WorkbenchController.shared.present()
    }

    /// 工作台「指挥」监听：工作台 post 指令通知 → 用选定 mode 调 AI，把该 tab 文件夹注入为工作目录。
    /// 解耦（不让工作台持 vm 引用）；AI 干活的工具事件经 HermesPetToolStarted/Ended 通知自动回流工作台面板（决策 #13）。
    /// closure 走 NotificationCenter Sendable 上下文 → `MainActor.assumeIsolated` hop（决策 #5）。
    private func setupWorkbenchCommandListener() {
        NotificationCenter.default.addObserver(forName: .init("HermesPetWorkbenchCommand"), object: nil, queue: .main) { [weak self] note in
            // 决策 #5：先在 Sendable 上下文抽出 String 值，别把 task-isolated `note` 带进 assumeIsolated
            let info = note.userInfo
            guard let prompt = info?["prompt"] as? String,
                  let dir = info?["directory"] as? String,
                  let modeRaw = info?["mode"] as? String,
                  let tag = info?["sessionTag"] as? String else { return }
            let history = info?["history"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let self, let vm = self.viewModel, let mode = AgentMode(rawValue: modeRaw) else { return }
                self.runWorkbenchCommand(vm: vm, prompt: prompt, history: history, directory: dir, mode: mode, tag: tag)
            }
        }
    }

    private func runWorkbenchCommand(vm: ChatViewModel, prompt: String, history: String, directory: String, mode: AgentMode, tag: String) {
        // 重启后回灌的历史段落（只有磁盘恢复的 tab 首次发送才非空）
        let historySection = history.isEmpty ? "" : """

        以下是你和用户之前的对话记录（供你接上上下文，不要重复回答，也不要复述）：
        \(history)

        """
        let full = """
        你的工作目录是：\(directory)
        \(historySection)
        用户要求：\(prompt)

        请直接在上面这个目录里操作文件（读写都用该目录下的绝对路径），不要反问要不要做、直接动手。完成后用一两句话说明你做了什么。
        """
        NotificationCenter.default.post(name: .init("HermesPetTaskStarted"), object: nil)   // 全局：灵动岛进度
        // ⭐ 审计 #7：再发一条**带 tag 的**工作台专属 task 通知，让工作台只认发起命令的那个 tab。
        // 否则工作台监听全局 TaskStarted/Finished，舰队/工作流/早报等任何地方的 AI 活动都会冲乱它的 tab。
        NotificationCenter.default.post(name: .init("HermesPetWorkbenchTaskStarted"), object: nil, userInfo: ["tag": tag])
        Task { @MainActor in
            do {
                for try await chunk in vm.streamOneShotAsk(prompt: full, modeOverride: mode,
                                                           recordToActivity: false, injectMemory: false,
                                                           sessionTag: tag, workingDirectory: directory) {
                    // AI 流式吐的文字 → 按 tag 回流工作台右栏渲染（工具事件另走全局通知）
                    NotificationCenter.default.post(name: .init("HermesPetWorkbenchReply"), object: nil,
                                                    userInfo: ["tag": tag, "delta": chunk])
                }
                NotificationCenter.default.post(name: .init("HermesPetTaskFinished"), object: nil, userInfo: ["success": true])
                NotificationCenter.default.post(name: .init("HermesPetWorkbenchTaskFinished"), object: nil, userInfo: ["tag": tag, "success": true])
            } catch {
                // 失败原因也回流，让用户在右栏直接看到（否则面板瞬间回到「待命中」，错误被吞）
                NotificationCenter.default.post(name: .init("HermesPetWorkbenchReply"), object: nil,
                                                userInfo: ["tag": tag, "delta": "\n\n⚠️ 出错了：\(error.localizedDescription)"])
                NotificationCenter.default.post(name: .init("HermesPetTaskFinished"), object: nil, userInfo: ["success": false])
                NotificationCenter.default.post(name: .init("HermesPetWorkbenchTaskFinished"), object: nil, userInfo: ["tag": tag, "success": false])
            }
        }
    }

    @objc private func menuReanalyzeRecording() {
        guard let vm = viewModel else { return }
        MeetingOverlayController.shared.reanalyzeLatestRecording(viewModel: vm)
    }

    /// 会议纪要：⌘⇧M / 菜单触发。toggle —— 没在录→开始录音；录音中→结束并交给 AI 整理存笔记
    func toggleMeetingRecorder() {
        guard let vm = viewModel else { return }
        MeetingOverlayController.shared.toggle(viewModel: vm)
    }

    /// 切聊天窗的「写作模式」(三栏:文件侧栏 + 文档画布 + 对话)。聊天窗没开就先开再进。
    private func toggleWritingMode() {
        guard let vm = viewModel else { return }
        if ChatWindowController.shared?.isVisible == true {
            vm.isWritingMode.toggle()
        } else {
            toggleChatWindow()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)   // 等展开动画结束(isAnimating 清掉)再放大
                self?.viewModel?.isWritingMode = true
            }
        }
    }

    /// 🦞 接管一个窗口（弹窗口选择菜单 → 选自动盯防 / 手动指挥）。
    @objc private func menuStartTakeover() {
        guard let vm = viewModel else { return }
        ScreenTakeoverController.shared.presentStarterMenu(viewModel: vm)
    }

    @objc private func menuStopTakeover() {
        ScreenTakeoverController.shared.stop()
    }

    /// ✏️ 设置「回复风格说明」—— 注入自动回复 prompt，让回复更像用户本人。
    @objc private func menuSetReplyStyle() {
        let alert = NSAlert()
        alert.messageText = "设置回复风格"
        alert.informativeText = "用一两句话描述你说话的风格（自动回复会模仿）。\n例如：口语化、简短、爱用「哈哈」、少用句号、偶尔带 emoji。"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
        tf.stringValue = ReplyStyleStore.shared.styleDescription
        tf.placeholderString = "我说话的风格是…"
        tf.lineBreakMode = .byWordWrapping
        tf.usesSingleLineMode = false
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        alert.accessoryView = tf
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ReplyStyleStore.shared.styleDescription = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        NotificationCenter.default.post(
            name: .init("HermesPetClawdBubble"),
            object: nil,
            userInfo: ["text": "回复风格已保存 ✏️", "duration": 2.5]
        )
    }

    @objc private func menuGenerateBriefing() {
        guard let vm = viewModel else { return }
        MorningBriefingService.shared.generateNow(viewModel: vm)
    }

    @objc private func menuGeneratePeriodicReview() {
        guard let vm = viewModel else { return }
        PeriodicReviewService.shared.generateNow(viewModel: vm)
    }

    /// 手动唤出新手引导（老用户也能"重看引导"；新用户首启自动弹）
    @objc private func menuShowOnboarding() {
        guard let vm = viewModel else { return }
        vm.showOnboarding = true
        if chatWindow?.isVisible != true { toggleChatWindow() }
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
                    alert.messageText = L("app.alert.update.found.title", checker.latestVersion ?? "")
                    alert.informativeText = L("app.alert.update.found.message", checker.currentVersion)
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: L("app.alert.update.found.install"))
                    alert.addButton(withTitle: L("app.alert.update.found.later"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        await checker.downloadAndInstall()
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = L("app.alert.update.latest.title")
                    alert.informativeText = L("app.alert.update.latest.message", checker.currentVersion)
                    if let err = checker.lastError {
                        alert.informativeText = err
                        alert.alertStyle = .warning
                    }
                    alert.addButton(withTitle: L("app.alert.update.latest.ok"))
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

    /// 新用户首次引导：仅"真·新用户"显示（老用户静默标记跳过，不打扰）。
    /// 真·新用户 = 没配过任何后端 + 没有带消息的对话。判定为新用户就显示引导 + 自动把聊天窗弹一次。
    private func maybeShowOnboarding(vm: ChatViewModel) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "onboardingCompleted") else { return }

        let hasProvider = !((d.string(forKey: "directAPIProviderID") ?? "").isEmpty)
        let hasHermesKey = !((d.string(forKey: "apiKey") ?? "").isEmpty)
        let hasLegacyDirectKey = !((d.string(forKey: "directAPIKey") ?? "").isEmpty)
        // ⚠️ 新用户首启会自动建一个「只含 assistant 欢迎语」的默认对话（见 ChatViewModel.init 的
        // firstLaunch greeting），所以"聊过天 = 老用户"必须看**用户真正发过消息**(role == .user)，
        // 不能用 `!messages.isEmpty` —— 否则那条欢迎语本身就让 hasConversation=true，每个新装用户
        // 都被误判成老用户、引导永远不弹（v1.2.14 起的隐藏 bug，v1.2.15 修复）。
        let hasConversation = vm.conversations.contains { conv in
            conv.messages.contains { $0.role == .user }
        }
        if hasProvider || hasHermesKey || hasLegacyDirectKey || hasConversation {
            d.set(true, forKey: "onboardingCompleted")   // 老用户：静默跳过
            return
        }

        vm.showOnboarding = true
        // 自动把聊天窗弹出来一次（新用户大概率还不知道点胶囊能呼出）。延迟到灵动岛/桌宠都就位后。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.chatWindow?.isVisible != true else { return }
            self.toggleChatWindow()
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
                    userInfo: ["text": L("app.banner.voice.failed", errorMessage ?? L("app.banner.voice.cannotStart")), "count": 0]
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
                userInfo: ["text": L("app.banner.pin.none"), "count": 0]
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
        case .added:     msgText = L("app.banner.pin.added")
        case .duplicate: msgText = L("app.banner.pin.duplicate")
        case .full:      msgText = L("app.banner.pin.full")
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
            button.image = monsterMenuBarImage
            switch vm.connectionStatus {
            case .connected, .unknown:
                // 正常状态：不染色 → template 图自动按浅色/深色菜单栏切换黑白
                button.contentTintColor = nil
            case .disconnected:
                // 仅断开时染红做警示
                button.contentTintColor = .systemRed
            }
        }

        // Update Dynamic Island status — 直接 post 通知，大灵动岛（onReceive）和 mini 胶囊都监听这个。
        // 不再走 islandController?.updateStatus（mini 模式无大灵动岛会漏掉状态更新）。
        NotificationCenter.default.post(
            name: .init("HermesPetStatusChanged"),
            object: nil,
            userInfo: ["status": vm.connectionStatus]
        )
    }

    /// 把早报正文末尾的 ```docs 围栏拆出来。
    /// 返回：(去掉围栏的纯正文, 围栏里每条路径取 basename 得到的文件名数组)。
    /// 没有围栏时原样返回正文 + 空数组。
    private static func splitBriefingDocs(_ markdown: String) -> (body: String, docs: [String]) {
        let lines = markdown.components(separatedBy: "\n")
        // 从末尾往前找最后一个 ```docs 开围栏：它后面到结尾应是「路径行们 + 一个收尾 ```」
        guard let openIdx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```docs" }) else {
            return (markdown, [])
        }
        // 围栏内容 = openIdx 之后、直到收尾 ``` 之前的行（都是文件真实路径）
        var docNames: [String] = []
        var i = openIdx + 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "```" { break }   // 收尾围栏
            if !t.isEmpty { docNames.append((t as NSString).lastPathComponent) }
            i += 1
        }
        // 正文 = openIdx 之前的部分（去掉围栏块），顺手去掉尾部多余空行
        let bodyLines = Array(lines[0..<openIdx])
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, docNames)
    }

    // MARK: - 远程拍板（M3）：把一条未决权限请求序列化成手机端要的 JSON

    /// AnyCodable → 普通 JSON 值（手机端只需基本类型）
    private static func jsonValue(from v: AnyCodable) -> Any {
        switch v {
        case .string(let s): return s
        case .int(let i):    return i
        case .double(let d): return d
        case .bool(let b):   return b
        case .array(let a):  return a.map { Self.jsonValue(from: $0) }
        case .object(let o): return o.mapValues { Self.jsonValue(from: $0) }
        case .null:          return NSNull()
        }
    }

    /// 按工具名 + 参数把权限请求归类成紧迫度：
    /// - delete-danger：命令里含删除/rm/push/reset 等破坏性词
    /// - exec：跑命令类（Bash/Shell/Terminal/Execute）
    /// - write：写文件类（Write/Edit/Create/MultiEdit 等）
    /// - read：其余（Read/Glob/Grep/WebFetch…）兜底
    private static func classifyRisk(tool: String, primaryArg: String?) -> String {
        let t = tool.lowercased()
        let arg = (primaryArg ?? "").lowercased()
        // 危险词命中（不论什么工具，命令/参数里带破坏性动作就标红）
        let dangerWords = ["rm ", "rm -", "rmdir", "删除", "删 ", "git push", " push", "git reset",
                           "--force", "-f ", "drop ", "truncate", "format", "格式化", "mkfs",
                           "> /dev", "sudo rm", "killall", "shutdown", "reboot"]
        if dangerWords.contains(where: { arg.contains($0) }) { return "delete-danger" }
        // 跑命令类
        if ["bash", "shell", "terminal", "execute", "exec", "run", "command"].contains(where: { t.contains($0) }) {
            return "exec"
        }
        // 写文件类
        if ["write", "edit", "create", "multiedit", "apply", "patch"].contains(where: { t.contains($0) }) {
            return "write"
        }
        return "read"
    }

    /// 把 PermissionHookServer.pendingList() 序列化成 {pending:[{id,tool,summary,params,risk,conversationId,askedAt}]}
    private static func serializePendingPermissions() -> Data {
        let iso = ISO8601DateFormatter()
        let arr: [[String: Any]] = PermissionHookServer.shared.pendingList().map { entry in
            let req = entry.request
            let tool = req.toolDisplayName
            let primary = req.primaryArg
            // 参数：把 metadata 摊平成普通 JSON（去掉内部用的 "tool" 键，避免和 tool 字段重复）
            var params: [String: Any] = [:]
            for (k, v) in req.metadata where k != "tool" {
                params[k] = Self.jsonValue(from: v)
            }
            // summary：工具名 + 主参数，给手机卡一行话概括
            let summary: String
            if let p = primary, !p.isEmpty { summary = "\(tool)：\(p)" }
            else { summary = tool }
            return [
                "id": req.id,
                "tool": tool,
                "summary": summary,
                "params": params,
                "risk": Self.classifyRisk(tool: tool, primaryArg: primary),
                "conversationId": req.sessionID,
                "askedAt": iso.string(from: entry.askedAt)
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: ["pending": arr]))
            ?? "{\"pending\":[]}".data(using: .utf8)!
    }

    // MARK: - 工作流技能卡（M4）：序列化「内置工作流列表」+「某次运行实时进度」给手机

    /// 把 WorkflowRegistry.bundled 序列化成 {workflows:[{id,name,summary,icon,accent,category,inputHint,stageCount}]}。
    /// 字段对齐方案文档 4 节契约；stageCount=有效阶段数（单发=1，多阶段=N），手机据此决定流水线 / 单进度圈。
    private static func serializeWorkflows() -> Data {
        let arr: [[String: Any]] = WorkflowRegistry.shared.workflows.map { wf in
            return [
                "id": wf.id,
                "name": wf.name,
                "summary": wf.summary,
                "icon": wf.icon,
                "accent": wf.accent,
                "category": wf.category,
                "inputHint": wf.inputHint,
                "stageCount": wf.effectiveStages.count
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: ["workflows": arr]))
            ?? "{\"workflows\":[]}".data(using: .utf8)!
    }

    /// 把一个实时 RunModel 序列化成手机轮询 /run 要的进度 JSON：
    /// {runId,status,currentStep,statusLine,partialText,steps[{id,title,status}],
    ///  awaitingConfirm,pendingConfirmTitle,product?{kind,title,markdown,ref}}
    private static func serializeRunState(_ model: RunModel) -> Data {
        let run = model.run
        let steps: [[String: Any]] = run.steps.map { s in
            ["id": s.stepID, "title": s.title, "status": s.status]
        }
        var obj: [String: Any] = [
            "runId": run.id,
            "status": run.status,                          // running|awaitingConfirm|succeeded|failed|aborted
            "currentStep": model.currentStepIndex,
            "statusLine": model.statusLine,
            "partialText": model.partialText,
            "steps": steps,
            "awaitingConfirm": model.awaitingConfirm,
            "pendingConfirmTitle": model.pendingConfirmTitle
        ]
        // 产物：成稿完成（productMarkdown 有内容）才带上，手机用 MarkdownText 渲染
        let md = model.productMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !md.isEmpty {
            var product: [String: Any] = [
                "kind": model.workflow.outputRender,       // chat / artifact / note
                "title": run.workflowName,
                "markdown": md
            ]
            if let ref = run.productRef { product["ref"] = ref }
            obj["product"] = product
        }
        return (try? JSONSerialization.data(withJSONObject: obj))
            ?? "{}".data(using: .utf8)!
    }

    /// 用点阵画出 App 图标小怪兽的极简头像版（圆脑袋 + 两只小眼），返回 template NSImage。
    /// 8×7 网格，每格 2pt → 16×14pt，正好填满菜单栏图标高度，小尺寸下最清晰耐看。
    /// "1" = 实心像素，"0" = 透明（眼睛是挖空，菜单栏背景透出来）。
    /// 第 0 行在顶部（flipped:false 下 y 要翻转）。
    private static func makeMonsterMenuBarImage() -> NSImage {
        let rows = [
            "01111110",
            "11111111",
            "11011011",
            "11111111",
            "11111111",
            "11111111",
            "01111110",
        ]
        let cols = rows[0].count
        let lines = rows.count
        let cell: CGFloat = 2
        let size = NSSize(width: CGFloat(cols) * cell, height: CGFloat(lines) * cell)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for (r, line) in rows.enumerated() {
                let y = CGFloat(lines - 1 - r) * cell   // 第 0 行画在最上面
                for (c, ch) in line.enumerated() where ch == "1" {
                    let rect = NSRect(x: CGFloat(c) * cell, y: y, width: cell, height: cell)
                    NSBezierPath(rect: rect).fill()
                }
            }
            return true
        }
        image.isTemplate = true   // 关键：菜单栏自动适配明暗 + 支持 contentTintColor 染色
        return image
    }
}
