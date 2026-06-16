import AppKit
import SwiftUI

/// 语音陪聊「会说话的脸/怪兽」—— 悬浮刘海下方、四角圆润的黑胶囊：左边在线 AI 小怪兽，右边它说的话。
/// 快捷键 ⌘⇧L 唤起，再按一次退出。
///
/// **守 CLAUDE.md 决策 #1**：独立 NSWindow，用 **NSHostingController + sizingOptions=[]**（照迷你岛/
/// 灵动岛），绝不动灵动岛本体。定位用 HermesIslandGeometry。
/// ⚠️ 为什么是 Controller 不是 View（2026-06-07 修腾讯会议全屏下呼出陪聊「卡死/崩溃」）：本窗口启动
///   reposition() setFrame + 内容持续动画（入场 transition / 流式文字 / 状态机），`NSHostingView` 即便
///   sizingOptions=[] 在 macOS 26 仍会经 `updateAnimatedWindowSize` 在 CA commit 反推 setFrame →
///   嵌套 layout → SIGABRT（崩）/ 反推风暴 100% CPU（卡死）；只有 `NSHostingController` 能真正禁掉。
///   配套：`VoiceChatRoot` 必须用**固定** `.frame(width:height:)`（不能 .infinity，否则 Controller 的
///   Auto Layout 首帧反推 updateConstraints 崩——这才是当初误判「固定窗口只能用 NSHostingView」的真因）。
///
/// **半双工打断（Phase B / AEC）**：用独立的 `VoiceChatMic`（开 voice processing 系统回声消除），
/// engine 会话期间常开 ——
///   listening：挂 SFSpeech 识别 + 静音检测（说完一轮 → 想 → 说）
///   speaking ：麦克风仍开，靠 AEC 消掉 AI 自己的声音，只检测**用户**音量；连续多帧超阈值 = 用户
///             开口插话 → `interrupt()` 停 TTS + 立刻转回听。
///
/// **隔离**：@MainActor，所有通知/Timer 回调 `MainActor.assumeIsolated`（回调都在主线程触发）。
@MainActor
final class VoiceChatController {

    static weak var shared: VoiceChatController?

    /// 陪聊会话是否激活 —— 给 VoiceTranscriptOverlay 判断（双保险；mic 已改用自定义通知本就不串扰）
    static var isSessionActive = false

    private weak var viewModel: ChatViewModel?

    private let window: NSWindow
    private let hosting: NSHostingController<VoiceChatRoot>
    private let state = VoiceChatState()
    private let mic = VoiceChatMic()

    // MARK: - 形态参数

    private let winW: CGFloat = 380   // 适当收窄
    private let winH: CGFloat = 178   // 两行文字（你右/AI左）+ 底部小横线的空间
    private let gapFromNotch: CGFloat = 0   // 距屏幕物理顶的偏移（0=顶到最上方，黑顶覆盖刘海连成一体）

    // MARK: - 会话状态

    private var active = false
    private var lastLoudTime = Date(timeIntervalSinceReferenceDate: 0)
    private var lastLevelPush = Date(timeIntervalSinceReferenceDate: 0)   // 节流波形音量写入（防 47Hz 高频写 @Observable 卡死）
    private var hasHeardSpeech = false
    private var silenceTimer: Timer?
    private var streamTask: Task<Void, Never>?
    /// 兜底看门狗：会话期间常开，定期让 TTS 拿系统真实状态对账，治「念完没回调 → 卡说不回听」。
    private var watchdogTimer: Timer?

    /// 静音多久算「说完了」（秒）/ 音量低于多少算静音
    private let silenceThreshold: TimeInterval = 1.2
    private let silenceLevel: Float = 0.08

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        win.level = HermesWindowLevel.dynamicIsland
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        // 接鼠标事件：底部小横线要能点（打开主聊天窗看完整对话）。
        // .nonactivatingPanel 保证点击不抢焦点；权限卡片窗口同款，有先例。
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        self.window = win

        // NSHostingController + sizingOptions=[]（照迷你岛）——真正禁掉 SwiftUI 反推 NSWindow.setFrame。
        // VoiceChatRoot 用固定 .frame(width:height:)，给 Auto Layout 确定尺寸，避免首帧反推崩（见类头注释）。
        let host = NSHostingController(rootView: VoiceChatRoot(state: state, width: winW, height: winH))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        win.contentViewController = host
        host.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）
        self.hosting = host

        Self.shared = self
        registerObservers()
    }

    func attach(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - 开 / 关（快捷键调）

    func toggle() {
        if active { stop() } else { start() }
    }

    func start() {
        guard !active else { return }
        Task { @MainActor in
            let (granted, errorMessage) = await mic.requestPermissions()
            guard granted else {
                NotificationCenter.default.post(
                    name: .init("HermesPetScreenshotAdded"), object: nil,
                    userInfo: ["text": errorMessage ?? "无法启动语音陪聊", "count": 0]
                )
                return
            }
            active = true
            Self.isSessionActive = true
            // 通知灵动岛/迷你胶囊淡出让位
            NotificationCenter.default.post(name: .init("HermesPetVoiceChatActive"), object: nil, userInfo: ["active": true])
            state.mode = viewModel?.agentMode ?? .hermes
            reposition()
            window.orderFront(nil)
            window.alphaValue = 1
            withAnimation(AnimTok.snappy) {
                state.active = true
                state.phase = .idle
            }
            guard mic.startEngine() else {
                NotificationCenter.default.post(
                    name: .init("HermesPetScreenshotAdded"), object: nil,
                    userInfo: ["text": "麦克风启动失败，请检查输入设备", "count": 0]
                )
                stop()
                return
            }
            // 注册「空格打断」：AI 说/想时按空格立刻停下来听你（陪聊期间临时拦空格，退出恢复）
            GlobalHotkey.shared.registerSpaceInterrupt {
                Task { @MainActor in VoiceChatController.shared?.handleSpaceInterrupt() }
            }
            // 卡拉OK进度：TTS 即将念到哪个词 → 只写两个 Int 驱动逐词高亮（词级 ~2-5Hz，低频安全）
            SpeechSynthesizer.shared.onSpeakRange = { [weak self] range, full in
                guard let self = self, self.active, self.state.phase == .speaking,
                      full == self.state.speakingText else { return }
                self.state.karaokeLo = range.location
                self.state.karaokeHi = range.location + range.length
            }
            beginListening()
            startWatchdog()
        }
    }

    func stop() {
        active = false
        Self.isSessionActive = false
        GlobalHotkey.shared.unregisterSpaceInterrupt()
        // 通知灵动岛/迷你胶囊淡回来
        NotificationCenter.default.post(name: .init("HermesPetVoiceChatActive"), object: nil, userInfo: ["active": false])
        stopSilenceTimer()
        stopWatchdog()
        streamTask?.cancel()
        streamTask = nil
        mic.stopEngine()
        SpeechSynthesizer.shared.onSpeakRange = nil   // 退出陪聊就摘掉卡拉OK回调
        SpeechSynthesizer.shared.stop()
        withAnimation(AnimTok.snappy) {
            state.active = false
            state.phase = .idle
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, !self.active else { return }
            self.window.alphaValue = 0
            self.window.orderOut(nil)
        }
    }

    // MARK: - 陪聊循环

    /// 进入「听」（engine 已常开，这里只挂识别）
    private func beginListening() {
        guard active else { return }
        guard !SpeechSynthesizer.shared.isSpeaking else { return }   // TTS 还在说就绝不开识别（防录到 AI 自己）
        state.transcript = ""
        // 回听后上一轮回复整段点亮（不再保留"当前词"主色高亮）
        if !state.speakingText.isEmpty {
            let len = (state.speakingText as NSString).length
            state.karaokeLo = len
            state.karaokeHi = len
        }
        lastLoudTime = Date()
        hasHeardSpeech = false
        withAnimation(AnimTok.snappy) { state.phase = .listening }
        mic.startRecognizing()
        startSilenceTimer()
    }

    /// 结束本轮听写 → 进入「想」
    private func endTurn() {
        stopSilenceTimer()
        let text = mic.stopRecognizing()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if active { beginListening() }
            return
        }
        think(trimmed)
    }

    /// 「想」+「说」：流式拿回复，整段念（不边收边念，避免句间空档误判 → 见 memory 回声修复）
    private func think(_ userText: String) {
        withAnimation(AnimTok.snappy) { state.phase = .thinking }
        state.reply = ""
        state.isReplyStreaming = true
        // 新一轮卡拉OK复位：想（流式）阶段整段暗色，开口后再逐词扫亮
        state.speakingText = ""
        state.karaokeLo = -1
        state.karaokeHi = 0

        guard let vm = viewModel else {
            state.isReplyStreaming = false
            if active { beginListening() }
            return
        }

        // 语音场景：① 提示 AI 容错语音识别的错别字 ② 要求简短口语化
        let voicePrompt = """
        [语音通话场景：你正在用语音和用户实时对话。
        - 用户这句话是语音识别自动转写的，可能有同音字、错别字或断句错误——请**结合上下文理解他的真实意图**，别被个别错字带偏；某个词明显识别错了就按最合理的意思去理解，不要纠结字面。
        - 回答像朋友面对面聊天那样自然口语、简短——通常一两句、最多不超过三句；不要用列表、标题、markdown、代码块或表情符号（这些会被语音读出来很奇怪）。]

        用户说：\(userText)
        """

        streamTask = Task { @MainActor in
            do {
                for try await chunk in vm.streamOneShotAsk(
                    prompt: voicePrompt,
                    recordToActivity: false,
                    sessionTag: "voice-chat"   // 固定 tag → directAPI 复用 session，多轮有上下文
                ) {
                    if Task.isCancelled { return }
                    state.reply += chunk
                }
                // 流式循环正常退出后再核对一次取消态：若期间被空格 interrupt() cancel 了，
                // 已经 beginListening 回到听，这里绝不能再 phase=speaking + speak()（会顶掉刚开始的听）。
                if Task.isCancelled {
                    state.isReplyStreaming = false
                    return
                }
                state.isReplyStreaming = false
                let toSpeak = state.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if toSpeak.isEmpty {
                    if active { beginListening() }
                } else {
                    withAnimation(AnimTok.snappy) { state.phase = .speaking }
                    state.speakingText = toSpeak              // 卡拉OK范围对应这段原文
                    SpeechSynthesizer.shared.speak(toSpeak)   // ① 先开口念（零延迟），念完由 TTSStateChanged 触发回到听
                    // 卡拉OK兜底：个别声音不回报念词进度 → 0.8s 没动静就整段点亮（别一直全暗）
                    let spokenSnapshot = toSpeak
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        guard let self = self, self.active, self.state.phase == .speaking,
                              self.state.speakingText == spokenSnapshot, self.state.karaokeLo < 0 else { return }
                        let len = (spokenSnapshot as NSString).length
                        self.state.karaokeLo = len
                        self.state.karaokeHi = len
                    }
                    // ② 再把这一轮（原始识别文字 + AI 回复，不含 voicePrompt 包装）存进当前对话的聊天记录。
                    //    纯后台旁路：append 在 speak 之后、写盘甩后台，对说话节奏零影响（见 appendVoiceChatTurn 铁律）。
                    vm.appendVoiceChatTurn(userText: userText, assistantText: toSpeak)
                }
            } catch {
                state.isReplyStreaming = false
                if active { beginListening() }
            }
        }
    }

    /// 打断：AI 说话时检测到用户开口 → 停 TTS + 取消流式 + 立刻转回听。
    private func interrupt() {
        streamTask?.cancel()
        streamTask = nil
        state.isReplyStreaming = false
        SpeechSynthesizer.shared.stop()   // 同步置 isSpeaking=false，下面 beginListening 的 guard 能过
        beginListening()
    }

    /// 空格被按下（陪聊会话期间）：AI 正在说/想 → 打断、转回听你；listening 时忽略。
    func handleSpaceInterrupt() {
        guard active else { return }
        if state.phase == .speaking || state.phase == .thinking {
            interrupt()
        }
    }

    // MARK: - 静音检测

    private func startSilenceTimer() {
        stopSilenceTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSilence() }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func stopSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private func checkSilence() {
        guard active, state.phase == .listening else { return }
        if hasHeardSpeech, Date().timeIntervalSince(lastLoudTime) > silenceThreshold {
            endTurn()
        }
    }

    // MARK: - 看门狗（兜底自愈：TTS didFinish 偶发不回调 → 卡「说」不回听 → 要按空格）

    /// 会话期间常开。每 0.25s 让 `SpeechSynthesizer` 拿**系统真实** synth 状态对账：若 TTS 实际已停
    /// 但「念完」通知因 didFinish 没回调而漏发，就在这里补发 → 走原本的延迟回听路径。
    /// 这是「有时要按空格才继续」的根因兜底——即便回调一次都不来，也能自动恢复回听。
    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        guard active else { return }
        SpeechSynthesizer.shared.reconcileSpeakingState()
    }

    // MARK: - 几何

    private func reposition() {
        guard let screen = HermesIslandGeometry.targetScreen() else { return }
        let cx = HermesIslandGeometry.islandCenterX(on: screen)
        // 黑块按真实灵动岛几何：视觉宽 = 刘海核心宽 + 80(idleExtraWidth)；视觉高 = 刘海高 + 18(drop)
        state.islandW = HermesIslandGeometry.islandCoreWidth(on: screen) + 80
        state.islandH = HermesIslandGeometry.islandCoreHeight(on: screen) + 18
        let topY = screen.frame.maxY - gapFromNotch   // 顶到屏幕物理最上方（黑块顶边直连屏幕边，玻璃挂在下面）
        let x = cx - winW / 2
        let y = topY - winH
        // 窗口尺寸自创建后恒定 → 只挪原点。setFrameOrigin 无 resize 路径，
        // 彻底排除与 SwiftUI 内容动画撞 CA commit 的可能（决策 #1/#6）
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - 通知监听

    private func registerObservers() {
        let nc = NotificationCenter.default

        // 实时识别文字（mic 专用通知，不串扰 push-to-talk 字幕条）
        nc.addObserver(forName: .init("HermesPetVoiceChatPartial"), object: nil, queue: .main) { [weak self] note in
            let text = note.userInfo?["text"] as? String
            MainActor.assumeIsolated {
                guard let self = self, self.active, self.state.phase == .listening, let text = text else { return }
                self.state.transcript = text
                self.lastLoudTime = Date()
                self.hasHeardSpeech = true
            }
        }

        // 实时音量：listening 做静音检测；speaking 做打断 VAD（AEC 已消 AI 声 → 高音量 = 用户插话）
        nc.addObserver(forName: .init("HermesPetVoiceChatLevel"), object: nil, queue: .main) { [weak self] note in
            let level = note.userInfo?["level"] as? Float
            MainActor.assumeIsolated {
                guard let self = self, self.active, let level = level else { return }
                switch self.state.phase {
                case .listening:
                    // 静音检测：每帧算（纯标量、不碰 UI，便宜）
                    if level > self.silenceLevel {
                        self.lastLoudTime = Date()
                        self.hasHeardSpeech = true
                    }
                    // 底部 Siri 波形音量。⚠️ 音频 tap ≈47Hz（bufferSize 1024 / 48kHz），若每帧写
                    // @Observable 会高频触发 SwiftUI 失效 + 玻璃/Canvas 重渲 → 主线程被打满**卡死**。
                    // 故：① 仅 listening 写（波形只有这相位用 level）② 节流到 ~15Hz。
                    let now = Date()
                    if now.timeIntervalSince(self.lastLevelPush) >= 0.066 {
                        self.lastLevelPush = now
                        let norm = min(1.0, max(0.0, (Double(level) - 0.04) / 0.36))
                        self.state.level = self.state.level * 0.5 + norm * 0.5
                    }
                // 回合制：speaking 时不靠音量打断（无 AEC，麦克风会录到 AI 自己的声音 → 会自打断）。
                // 打断改用「空格键」（见 start() 的 registerSpaceInterrupt），无回声风险。
                default:
                    // 非「听」：波形不用 level，归零一次即可（杜绝任何高频写 @Observable）
                    if self.state.level != 0 { self.state.level = 0 }
                }
            }
        }

        // TTS 念完 → 延迟开麦回到听（残响散 + 二次确认，防录 AI 尾音）
        nc.addObserver(forName: .init("HermesPetTTSStateChanged"), object: nil, queue: .main) { [weak self] note in
            let speaking = note.userInfo?["speaking"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self = self, self.active else { return }
                if !speaking, !self.state.isReplyStreaming {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        MainActor.assumeIsolated {
                            guard self.active, !self.state.isReplyStreaming,
                                  !SpeechSynthesizer.shared.isSpeaking else { return }
                            self.beginListening()
                        }
                    }
                }
            }
        }

        // 屏幕几何变化 → 重新定位
        nc.addObserver(forName: .init("HermesPetGeometry"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.active else { return }
                self.reposition()
            }
        }
    }
}

// MARK: - 状态

@MainActor
@Observable
final class VoiceChatState {
    var active = false                 // SwiftUI 显示开关（驱动入场/退场 transition）
    var phase: VoiceChatPhase = .idle
    var transcript = ""               // 用户说的（实时识别）
    var reply = ""                    // AI 说的（流式累积）
    var isReplyStreaming = false      // 回复流是否还在进行
    var mode: AgentMode = .hermes     // 当前 mode（决定主色）
    var level: Double = 0             // 实时音量 0..1（平滑）—— 底部 Siri 波形「在听」时跟着用户声音起伏
    // 卡拉OK逐词高亮（说话阶段）：TTS 即将念到 [karaokeLo, karaokeHi)（UTF-16 偏移，对应 speakingText）
    var speakingText = ""             // 正在念的整段文字（trim 后交给 TTS 的原文）
    var karaokeLo = -1                // 当前词起点；-1 = 还没开始念（整段保持暗色）
    var karaokeHi = 0                 // 当前词终点
    var islandW: CGFloat = 240        // 灵动岛视觉宽（刘海宽 + buffer）——黑块尺寸，reposition 时按真实几何更新
    var islandH: CGFloat = 54         // 灵动岛视觉高（刘海高 + drop）
}

enum VoiceChatPhase: Equatable {
    case idle, listening, thinking, speaking
}

// MARK: - SwiftUI Root

struct VoiceChatRoot: View {
    @Bindable var state: VoiceChatState
    /// 窗口固定尺寸 —— 外层用 `.frame(width:height:)` 给 NSHostingController 确定尺寸（不能 .infinity，见
    /// VoiceChatController 类头注释：否则 Auto Layout 首帧反推 updateConstraints 崩）。
    let width: CGFloat
    let height: CGFloat

    private var tint: Color { state.mode.railTint }

    private var statusText: String {
        switch state.phase {
        case .idle:      return "准备好啦"
        case .listening: return "在听…"
        case .thinking:  return "在想…"
        case .speaking:  return "在说"
        }
    }

    /// AI 行（左对齐）：想=流式回复（暗色先显示）；说=念稿（卡拉OK扫亮）；听=上一轮回复淡显
    private var aiText: String {
        switch state.phase {
        case .idle:      return "说点什么吧，我听着呢"
        case .listening: return state.reply
        case .thinking:  return state.reply.isEmpty ? "让我想想…" : state.reply
        case .speaking:  return state.speakingText.isEmpty ? state.reply : state.speakingText
        }
    }

    /// 你的话（右对齐）：听=实时识别流式；想/说=保留刚说的那句
    private var userText: String {
        if state.phase == .listening, state.transcript.isEmpty { return "你说，我听着呢…" }
        return state.transcript
    }

    /// 卡拉OK着色：已念=亮白、正在念的词=mode 主色、未念=暗白。
    /// 想（流式）阶段 karaokeLo=-1 → 整段暗白（文字先到、开口后逐词扫亮——视听同步的感知来自这里）。
    private func karaokeStyled(_ text: String) -> AttributedString {
        let dim = Color.white.opacity(0.45)
        guard state.phase == .speaking, state.karaokeLo >= 0 else {
            var a = AttributedString(text)
            switch state.phase {
            case .idle:      a.foregroundColor = Color.white.opacity(0.7)
            case .listening: a.foregroundColor = Color.white.opacity(0.6)   // 上一轮回复淡显
            default:         a.foregroundColor = dim                        // 想：流式先显示，暗色
            }
            return a
        }
        // NSRange 是 UTF-16 偏移 → 用 NSString 切片，中文/emoji 不会切错位
        let ns = text as NSString
        let lo = max(0, min(state.karaokeLo, ns.length))
        let hi = max(lo, min(state.karaokeHi, ns.length))
        var spoken = AttributedString(ns.substring(to: lo))
        spoken.foregroundColor = Color.white
        var current = AttributedString(ns.substring(with: NSRange(location: lo, length: hi - lo)))
        current.foregroundColor = tint                                       // 正在念的词 = mode 主色
        var rest = AttributedString(ns.substring(from: hi))
        rest.foregroundColor = dim
        return spoken + current + rest
    }

    var body: some View {
        ZStack {
            if state.active {
                capsule
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: width, height: height)
    }

    private var capsule: some View {
        ZStack {
            // 聆听态星云（docs/specs/listening-nebula.md）：整卡背景层 —— 中央星云、两端淡出。
            // 仅「在听」激活；其余相位 0.4s 淡出并停掉 TimelineView（零 CPU）。
            // 纯时间驱动 Canvas + 粒子状态在 class 里，不写视图状态 → 守决策 #21。
            // 用户调参（2026-06-10）：上下浮动收窄 —— 波幅 20→10、纵向发散 30→16（其余守规格默认）
            ListeningNebulaView(config: .init(waveAmplitude: 10, verticalSpread: 16),
                                isActive: state.phase == .listening)

            VStack(alignment: .leading, spacing: 0) {
                // 顶部黑岛区让开：内容从刘海黑块下方开始
                Spacer(minLength: 0).frame(height: max(state.islandH - 8, 0))

                // 弹性把文字往下推（文字位于卡片中下部，不再紧贴黑岛）
                Spacer(minLength: 0)

                // 文字：状态小字 + 你的话（右）/ AI 的话（左，流式+卡拉OK）
                VStack(alignment: .leading, spacing: 5) {
                    Text(statusText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.9))
                        .shadow(color: tint.opacity(0.6), radius: 4)        // 主色光晕

                    // 你说的（右对齐，实时识别流式）
                    if !userText.isEmpty {
                        Text(userText)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(state.phase == .listening ? 0.92 : 0.55))
                            .lineLimit(2)
                            .truncationMode(.head)   // 长句保最新尾部
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    // AI 说的（左对齐；想=流式暗色先显示，说=念到的词主色高亮逐词扫过）
                    if !aiText.isEmpty {
                        Text(karaokeStyled(aiText))
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(3)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .animation(.easeOut(duration: 0.18), value: state.karaokeHi)  // 高亮平滑扫过
                            .shadow(color: .white.opacity(0.3), radius: 4)
                    }
                }
                // 暗影：玻璃通透后浅/亮壁纸下也读得清（与上面的光晕叠加=发光又清晰）
                .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 0.5)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // 底部小横线：点一下打开主聊天窗（语音轮次实时存进当前对话，完整历史在那看）
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 44, height: 4)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle().inset(by: -10))   // 扩大点击热区
                    .onTapGesture {
                        NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
                    }
                    .padding(.bottom, 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .modifier(VoiceCapsuleGlass(tint: tint, islandW: state.islandW, islandH: state.islandH))
        .padding([.horizontal, .bottom], 4)   // 顶部不留边 → 黑顶 flush 顶到屏幕最上方接刘海
    }
}

/// 语音陪聊胶囊背景：**灵动岛形状的黑块**（圆角矩形、刘海周围那块）—— 顶边**实黑直连屏幕边缘**（不渐变）、
/// 侧边和下边**模糊扩散**渐隐到 **iOS 26 通透液态玻璃**。黑块按真实灵动岛几何 islandW × islandH。
/// 关键技巧：黑块往上多留一截 + 上移，把**模糊的顶边推到屏幕外被裁掉** → 顶部就是实黑、直连物理屏幕边。
/// macOS 26 走原生 `.glassEffect(.clear)`（Apple 自己算的玻璃，真通透）；老系统退回 behind-window 磨砂兜底。
/// behind-window 实现 `BehindWindowGlass` 在 `GlassSurface.swift`（语音陪聊 + 钉住卡共用）。
private struct VoiceCapsuleGlass: ViewModifier {
    let tint: Color
    let islandW: CGFloat
    let islandH: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        // 收归灵动岛后的形状：**上半贴屏幕顶边（顶角直角）、下半圆润矩形**——像从刘海长出来。
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 32, bottomTrailing: 32, topTrailing: 0),
            style: .continuous)

        // 灵动岛形状黑块：往上多留 24pt、整体上移 24pt → 模糊的**顶边被屏幕边缘裁掉**，顶部实黑直连屏幕边；
        // 侧边 + 下边照常模糊扩散（blur 14）渐隐进玻璃。只盖刘海周围那块，不是全宽。
        let topBleed: CGFloat = 24
        let islandBlob = UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 0, bottomLeading: 20, bottomTrailing: 20, topTrailing: 0),
                style: .continuous)
            .fill(Color.black)
            .frame(width: islandW, height: islandH + topBleed)   // 顶部多留一截给裁切
            .blur(radius: 14)                                    // 侧/下边缘柔化扩散
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(y: -topBleed)                                // 上移：模糊顶边推出屏幕外被裁 → 顶部实黑直连屏幕边

        if reduceTransparency {
            // 辅助功能「减弱透明度」：近实色黑底，不通透
            return AnyView(content
                .background(shape.fill(Color.black.opacity(0.92)))
                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 2))
        }
        if #available(macOS 26.0, *) {
            return AnyView(content
                .background {
                    ZStack {
                        Color.clear.glassEffect(.clear, in: shape).opacity(0.6)   // iOS 26 通透玻璃（更透）
                        islandBlob                                                 // 灵动岛形状黑块（顶实黑、侧下扩散）
                    }
                    .clipShape(shape)                                              // 黑块模糊别溢出胶囊轮廓
                }
                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 2))
        }
        // 老系统(<26)兜底：behind-window 磨砂 + 灵动岛形状黑块
        return AnyView(content
            .background {
                ZStack {
                    BehindWindowGlass().clipShape(shape)
                    islandBlob
                }
                .clipShape(shape)
            }
            .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 2))
    }
}
