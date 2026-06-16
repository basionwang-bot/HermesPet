import AVFoundation
import Speech
import AppKit

/// AI 会议纪要 —— 长时录音 + 分段接力转录（Phase 2：麦克风 + 系统音频双路）。
///
/// 这是 WTF「会议纪要整理」workflow 的**输入管道**：把一场会录下来 → 落盘 →
/// 实时分段转成文字稿；文字稿之后交给 AI 整理成结构化纪要（议题 / 决议 / 待办），存进 AI 笔记。
///
/// **双路设计（Phase 2，2026-06-10）**：
/// - 麦克风路（AVAudioEngine tap）= 「我」说的话
/// - 系统音频路（`MeetingSystemAudioTap`，ScreenCaptureKit）= 「对方」的声音（腾讯会议/Zoom/飞书
///   里别人说话都从系统输出走）。转写走 macOS 26 的 SpeechAnalyzer（见 `MeetingLaneAnalyzer`
///   头注释——同进程双 SFSpeech 流式任务会互相饿死，麦克风路必须独占 SFSpeech）。
/// - 两路转写按时间窗合并成 `Entry` 列表；**只有系统路真出过声**才给文字稿加「【我】/【对方】」
///   标注（线下会议 = 纯麦克风 → 文字稿与 Phase 1 完全一致，无标注）。
/// - 系统路是**尽力而为**：没屏幕录制权限 / SCK 启动失败 → 自动降级纯麦克风，会议不受影响。
///
/// **为什么单独一个类、而不复用 VoiceInputController**：
/// - VoiceInputController 是 push-to-talk（按住几秒就松），单个识别 task 够用。
/// - 会议动辄几十分钟，SFSpeechRecognizer 单 task 约 1 分钟就会断 → 必须「分段接力」
///   （录一段转一段、自动起新 task 拼接），这是会议转录的核心，VoiceInputController 没有。
///
/// **隔离设计**（同 VoiceInputController，见 CLAUDE.md 决策 #5）：
/// 全类 nonisolated（@unchecked Sendable）。音频 tap / SCStream / 识别回调都在后台线程，
/// 若类是 @MainActor，内部 closure 被推断成 @MainActor 在后台执行就 SIGTRAP。
/// 可变状态一律 NSLock 保护，所有 public 方法线程安全。
final class MeetingRecorder: @unchecked Sendable {
    static let shared = MeetingRecorder()

    enum State: String { case idle, recording, finishing }

    /// 音频来源路：mic = 我（麦克风），system = 对方（系统播放的声音）
    enum Lane: String, Sendable { case mic, system }

    /// 一段已定稿的转写（一路音频在一个时间窗里说的话）。
    /// `text` 可被分段 AI 纠错替换；`raw` 永远是原始转写（笔记「原始转写」折叠区用）。
    private struct Entry {
        let id: UUID
        let lane: Lane
        var text: String
        var raw: String
        let at: Date          // 定稿时刻（回声抑制的时间窗判定用）
    }

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?       // 麦克风路（系统路用 SpeechAnalyzer，不共用）

    // NSLock 保护下面所有 mutable state
    private let lock = NSLock()
    private var _state: State = .idle
    private var _sessionID = UUID()                   // 每场会一个；异步起的系统路 / 残余 buffer 回调用它自检

    // 麦克风路。macOS 26+ 走 SpeechAnalyzer（与系统路各一个实例、可并发）；
    // SFSpeech 字段仅在 <26 或 analyzer 启动失败的回退路径使用。
    private var _micRequest: SFSpeechAudioBufferRecognitionRequest?
    private var _micTask: SFSpeechRecognitionTask?
    private var _micGeneration: Int = 0               // 每切一段 +1，防旧 task 残余回调污染新段
    private var _micCurrent: String = ""              // 当前段最新 partial / volatile
    private var _micAnalyzer: (any Sendable)?         // macOS 26+：MeetingLaneAnalyzer
    private var _micAnalyzerPending = false           // analyzer 启动中 → tap 先攒 prebuffer
    private var _micPreBuffers: [AVAudioPCMBuffer] = []   // attach 前攒的开头（防丢会议第一句）

    // 系统音频路（识别引擎 = MeetingLaneAnalyzer，存成 any Sendable 绕开
    // 「stored property 不能挂 @available」的限制，用处全在 #available(macOS 26) 块里 cast）
    private var _systemTap: MeetingSystemAudioTap?
    private var _sysAnalyzer: (any Sendable)?
    private var _sysCurrent: String = ""          // 系统路当前未定稿（volatile）文本

    // 已定稿的段（两路按时间窗顺序混排）
    private var _entries: [Entry] = []

    /// 豆包式分段实时纠错钩子：每切一段（约 50 秒）把「这段原文 + 前文上下文」交给外部
    /// （MeetingOverlayController 注入，走在线 AI 快速纠同音字/标点/专名）。返回纠好的文本则替换该段。
    /// nonisolated：录音类后台运行，回调内部自己 hop。失败/超时保留原文，绝不拖垮录音主流程。
    nonisolated(unsafe) var segmentRefiner: ((_ segment: String, _ context: String) async -> String?)?

    // 落盘（保命）：转录中途挂了录音还在，可重转。麦克风 <id>.m4a / 系统音频 <id>-system.m4a
    private var _micFile: AVAudioFile?
    private var _micURL: URL?
    private var _sysFile: AVAudioFile?                // 拿到第一个 buffer 才知道格式 → 懒创建
    private var _sysURL: URL?
    private var _startedAt: Date?
    private var _levelTick: Int = 0                   // 音量通知降频计数（音量条只看麦克风路）

    // 分段接力定时器（独立串行队列，不依赖 runloop）
    private let segmentQueue = DispatchQueue(label: "com.basionwang.hermespet.meeting.segment")
    private var _segmentTimer: DispatchSourceTimer?
    private let segmentSeconds = 50               // 每 50 秒切一段（留余量避开 ~1 分钟硬限）

    // MARK: - 对外只读状态
    var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    var isRecording: Bool { state == .recording }

    var fullTranscript: String {
        lock.lock(); defer { lock.unlock() }
        return mergedLocked(raw: false)
    }

    /// 原始转写（未经 AI 纠错）—— 存进笔记的「原始转写」折叠区用这份，便于对照。
    var rawTranscript: String {
        lock.lock(); defer { lock.unlock() }
        return mergedLocked(raw: true)
    }

    /// 这场会（含刚 stop 完、下一场开始前）系统音频路是否真出过内容。
    /// Overlay 用它决定要不要跑「第二波完整重转」——双路会议的麦克风录音重转只有「我」一路，
    /// 重转替换反而会丢掉对方的话。
    var hasSystemAudioContent: Bool {
        lock.lock(); defer { lock.unlock() }
        return _entries.contains { $0.lane == .system } || !_sysCurrent.isEmpty
    }

    var elapsedSeconds: Int {
        lock.lock(); defer { lock.unlock() }
        guard let s = _startedAt, _state == .recording else { return 0 }
        return Int(Date().timeIntervalSince(s))
    }

    // 调试：每路最近一次识别错误（/meeting/state 露出，unified log 在部分机器上读不到）
    private var _lastErrors: [String: String] = [:]
    var lastErrorsSnapshot: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return _lastErrors
    }

    private init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
    }

    // MARK: - 权限（麦克风 + 语音识别，同 VoiceInputController）
    // 屏幕录制权限不在这里预检（决策 #3：直接试 SCK 让它自己决定）；缺了系统路自动降级。
    func requestPermissions() async -> (Bool, String?) {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        switch speechStatus {
        case .authorized:
            let micGranted: Bool = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            return micGranted
                ? (true, nil)
                : (false, "麦克风权限被拒绝，请到 系统设置 → 隐私与安全性 → 麦克风 中允许 HermesPet")
        case .denied:
            return (false, "语音识别权限被拒绝，请到 系统设置 → 隐私与安全性 → 语音识别 中允许 HermesPet")
        case .restricted:
            return (false, "本设备禁止使用语音识别")
        case .notDetermined:
            return (false, "用户尚未授权")
        @unknown default:
            return (false, "未知权限状态")
        }
    }

    // MARK: - 开始
    /// `systemLaneEnabled: false` 仅供调试（/meeting/start?nosys=1 做麦克风单路对照实验）
    @discardableResult
    func start(systemLaneEnabled: Bool = true) -> Bool {
        lock.lock()
        if _state != .idle {
            NSLog("[Meeting] start 被跳过：state=\(_state.rawValue)（非 idle，可能上一场没正常收尾）")
            lock.unlock(); return true
        }
        lock.unlock()

        // 与 push-to-talk 互斥，避免两个 AVAudioEngine 抢同一输入设备崩溃
        if VoiceInputController.shared.isListening {
            NSLog("[Meeting] start 失败：push-to-talk 正在占用麦克风")
            postError("正在语音输入，请先松开说话键再开始会议录音")
            return false
        }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            NSLog("[Meeting] start 失败：SFSpeechRecognizer 不可用（recognizer=\(recognizer == nil ? "nil" : "有") available=\(recognizer?.isAvailable ?? false)）")
            postError("语音识别引擎不可用（可能在加载中文模型，请稍后再试）")
            return false
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // 无内置麦 / 外设刚断开 / 硬件未就绪时 format sampleRate==0，直接 installTap 会触发
        // CoreAudio 断言崩。此处尚未 mutate 状态，安全早退（同 VoiceInputController）。
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("[Meeting] start 失败：输入设备格式无效 sampleRate=\(format.sampleRate) ch=\(format.channelCount)")
            postError("音频输入设备不可用，请检查麦克风是否连接")
            return false
        }
        NSLog("[Meeting] start：输入格式 \(format.sampleRate)Hz/\(format.channelCount)ch")
        input.removeTap(onBus: 0)

        // 录音落盘（保命）：开一小时万一转录中途挂了，录音还在，可重转
        let id = UUID().uuidString
        let micURL = Self.meetingsDir().appendingPathComponent("\(id).m4a")
        let sysURL = Self.meetingsDir().appendingPathComponent("\(id)-system.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        let file = try? AVAudioFile(forWriting: micURL, settings: settings)

        // macOS 26+ 麦克风路走 SpeechAnalyzer；SFSpeech 仅 <26 / analyzer 失败回退用
        let useMicAnalyzer: Bool
        if #available(macOS 26.0, *) { useMicAnalyzer = true } else { useMicAnalyzer = false }
        let firstReq: SFSpeechAudioBufferRecognitionRequest? =
            useMicAnalyzer ? nil : Self.makeRequest(recognizer, onDevice: true)
        let gen = 1

        // tap 在后台高频回调：喂识别 + 落盘 + 算音量。不捕获 self，用 Self.shared 内部 lock
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let s = Self.shared
            s.lock.lock()
            let req = s._micRequest
            let analyzerObj = s._micAnalyzer
            let f = s._micFile
            if analyzerObj == nil, req == nil, s._micAnalyzerPending, s._micPreBuffers.count < 150 {
                s._micPreBuffers.append(buffer)   // analyzer 启动间隙先攒（~3s 上限），attach 后回灌
            }
            s._levelTick &+= 1
            let postLevel = (s._levelTick % 4 == 0)
            s.lock.unlock()
            if #available(macOS 26.0, *), let a = analyzerObj as? MeetingLaneAnalyzer {
                a.feed(buffer)
            } else {
                req?.append(buffer)
            }
            if let f = f { try? f.write(from: buffer) }   // 落盘失败不影响转录主流程
            if postLevel {
                let level = Self.computeLevel(buffer)
                NotificationCenter.default.post(name: .init("HermesPetMeetingLevel"),
                                                object: nil, userInfo: ["level": level])
            }
        }

        audioEngine.prepare()
        do { try audioEngine.start() }
        catch {
            input.removeTap(onBus: 0)
            NSLog("[Meeting] start 失败：AVAudioEngine.start 抛错 \(error)")
            postError("音频引擎启动失败: \(error.localizedDescription)")
            return false
        }
        NSLog("[Meeting] 录音已启动（落盘=\(file != nil ? "ok" : "失败")）")

        var firstTask: SFSpeechRecognitionTask?
        if let firstReq {
            firstTask = recognizer.recognitionTask(with: firstReq) { result, error in
                Self.shared.handleMicResult(result, error: error, generation: gen)
            }
        }

        let session = UUID()
        lock.lock()
        _state = .recording
        _sessionID = session
        _micRequest = firstReq
        _micTask = firstTask
        _micGeneration = gen
        _micCurrent = ""
        _micAnalyzer = nil
        _micAnalyzerPending = useMicAnalyzer
        _micPreBuffers = []
        _sysAnalyzer = nil
        _sysCurrent = ""
        _systemTap = nil
        _entries = []
        _micFile = file
        _micURL = (file != nil) ? micURL : nil
        _sysFile = nil
        _sysURL = sysURL
        _startedAt = Date()
        _levelTick = 0
        _lastErrors = [:]   // 每场会从零开始，别让上一场的残留误导调试
        lock.unlock()

        if useMicAnalyzer {
            Task.detached { await Self.shared.startMicLane(session: session) }
        }
        // 系统音频路异步起（SCShareableContent 要 await）；失败自动降级纯麦克风
        if systemLaneEnabled {
            Task.detached { await Self.shared.startSystemLane(session: session) }
        }

        // 50s 切段接力是 SFSpeech 的"1 分钟硬限"对策；analyzer 模式不需要
        // （analyzer 启动失败的回退路径里会补开，见 fallbackMicToSFSpeech）
        if !useMicAnalyzer { startSegmentTimer() }
        NotificationCenter.default.post(name: .init("HermesPetMeetingStarted"), object: nil)
        DispatchQueue.main.async { Haptic.tap(.alignment) }
        return true
    }

    // MARK: - 系统音频路（尽力而为，失败不影响会议）
    // macOS 26+ 走 SpeechAnalyzer；老系统直接跳过——同进程第二个 SFSpeech 流式任务
    // 会把麦克风路饿死（宁可少「对方」，不能哑「我」）。
    private func startSystemLane(session: UUID) async {
        guard #available(macOS 26.0, *) else {
            NSLog("[Meeting] macOS < 26 无 SpeechAnalyzer，本场只录麦克风")
            return
        }
        let analyzer = MeetingLaneAnalyzer(
            onVolatile: { text in Self.shared.laneVolatile(.system, text, session: session) },
            onFinal: { text in Self.shared.laneFinal(.system, text, session: session) },
            onError: { msg in Self.shared.noteLaneError("system", msg) },
            onStatus: { msg in NSLog("[Meeting] system 路状态: \(msg)") })   // 诊断走 NSLog，不进 _lastErrors（审计 #10）
        do { try await analyzer.start() }
        catch {
            NSLog("[Meeting] 系统路 SpeechAnalyzer 启动失败，本场只录麦克风: \(error)")
            noteLaneError("system", "SpeechAnalyzer 启动失败: \(error.localizedDescription)")
            return
        }
        let tap = MeetingSystemAudioTap { buffer in
            Self.shared.feedSystem(buffer, session: session)
        }
        do { try await tap.start() }
        catch {
            NSLog("[Meeting] 系统音频流启动失败（多半没屏幕录制权限），本场只录麦克风: \(error.localizedDescription)")
            postSystemLaneHintOnce()
            await analyzer.stop()
            return
        }

        // 起流期间会议可能已结束/换场 → attach 失败直接收掉
        if !attachSystemLane(tap: tap, analyzer: analyzer, session: session) {
            await tap.stop()
            await analyzer.stop()
        }
    }

    /// 系统路 attach 的同步部分（NSLock 不能在 async 函数体里直接 lock，抽成同步函数）
    private func attachSystemLane(tap: MeetingSystemAudioTap,
                                  analyzer: any Sendable, session: UUID) -> Bool {
        lock.lock()
        guard _state == .recording, _sessionID == session else { lock.unlock(); return false }
        _systemTap = tap
        _sysAnalyzer = analyzer
        lock.unlock()
        return true
    }

    private func noteLaneError(_ key: String, _ msg: String) {
        NSLog("[Meeting] \(key) 路: \(msg)")
        lock.lock(); _lastErrors[key] = msg; lock.unlock()
    }

    // MARK: - 麦克风路 SpeechAnalyzer（macOS 26+；启动失败回退 SFSpeech 接力，麦克风永远有产出）
    private func startMicLane(session: UUID) async {
        guard #available(macOS 26.0, *) else { return }
        let analyzer = MeetingLaneAnalyzer(
            onVolatile: { text in Self.shared.laneVolatile(.mic, text, session: session) },
            onFinal: { text in Self.shared.laneFinal(.mic, text, session: session) },
            onError: { msg in Self.shared.noteLaneError("mic", msg) },
            onStatus: { msg in NSLog("[Meeting] mic 路状态: \(msg)") })   // 诊断走 NSLog，不进 _lastErrors（审计 #10）
        do { try await analyzer.start() }
        catch {
            NSLog("[Meeting] 麦克风路 SpeechAnalyzer 启动失败，回退 SFSpeech: \(error)")
            noteLaneError("mic", "analyzer 启动失败，已回退 SFSpeech: \(error.localizedDescription)")
            fallbackMicToSFSpeech(session: session)
            return
        }
        if !attachMicAnalyzer(analyzer, session: session) {
            await analyzer.stop()
        }
    }

    private func attachMicAnalyzer(_ analyzer: any Sendable, session: UUID) -> Bool {
        lock.lock()
        guard _state == .recording, _sessionID == session else {
            _micAnalyzerPending = false
            _micPreBuffers = []
            lock.unlock()
            return false
        }
        _micAnalyzer = analyzer
        _micAnalyzerPending = false
        let pre = _micPreBuffers
        _micPreBuffers = []
        lock.unlock()
        if #available(macOS 26.0, *), let a = analyzer as? MeetingLaneAnalyzer {
            for b in pre { a.feed(b) }   // 回灌启动间隙攒下的开头，防"会议第一句"丢失
        }
        return true
    }

    /// analyzer 启动失败的回退：SFSpeech 接力（同 <26 老路径）。prebuffer 一并补喂。
    private func fallbackMicToSFSpeech(session: UUID) {
        guard let recognizer = recognizer else { return }
        lock.lock()
        guard _state == .recording, _sessionID == session else { lock.unlock(); return }
        _micAnalyzerPending = false
        let pre = _micPreBuffers
        _micPreBuffers = []
        let gen = _micGeneration &+ 1
        let req = Self.makeRequest(recognizer, onDevice: true)
        _micGeneration = gen
        _micRequest = req
        let task = recognizer.recognitionTask(with: req) { result, error in
            Self.shared.handleMicResult(result, error: error, generation: gen)
        }
        _micTask = task
        lock.unlock()
        for b in pre { req.append(b) }
        startSegmentTimer()
    }

    /// SCStream 后台回调：喂 analyzer + 落盘（文件按第一个 buffer 的真实格式懒创建）
    private func feedSystem(_ buffer: AVAudioPCMBuffer, session: UUID) {
        lock.lock()
        guard _state == .recording, _sessionID == session else { lock.unlock(); return }
        if _sysFile == nil, let url = _sysURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: buffer.format.channelCount,
            ]
            _sysFile = try? AVAudioFile(forWriting: url, settings: settings)
        }
        let f = _sysFile
        let analyzerObj = _sysAnalyzer
        lock.unlock()
        if #available(macOS 26.0, *), let a = analyzerObj as? MeetingLaneAnalyzer {
            a.feed(buffer)
        }
        if let f = f { try? f.write(from: buffer) }
    }

    /// 某路：当前段实时变动（volatile，整段替换式）。
    /// finishing 期间也收——stopAndFinalize 正在冲刷尾段，丢了"最后一句"就没了。
    private func laneVolatile(_ lane: Lane, _ text: String, session: UUID) {
        lock.lock()
        guard _state != .idle, _sessionID == session else { lock.unlock(); return }
        switch lane {
        case .mic: _micCurrent = text
        case .system: _sysCurrent = text
        }
        let full = mergedLocked(raw: false)
        lock.unlock()
        NotificationCenter.default.post(name: .init("HermesPetMeetingPartial"),
                                        object: nil, userInfo: ["text": full])
    }

    /// 某路：一段定稿（utterance 粒度，比 50s 时间窗细，对话交错更自然）。
    /// ⭐ 回声抑制：电脑**外放**时，对方的声音会被麦克风从空气里拾回来 → 同一句话
    /// 既是「对方」又被误标成「我」。无硬件 AEC（setVoiceProcessingEnabled 在本机会把
    /// 麦克风搞静音，语音陪聊踩过），改做**文本级判重**：时间窗内与系统路高度相似的
    /// 麦克风内容判为回声丢弃；反向（回声先定稿）由系统路定稿时回头清理。
    private func laneFinal(_ lane: Lane, _ text: String, session: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        guard _state != .idle, _sessionID == session else { lock.unlock(); return }
        switch lane {
        case .mic: _micCurrent = ""
        case .system: _sysCurrent = ""
        }
        guard !trimmed.isEmpty else {
            let full = mergedLocked(raw: false)
            lock.unlock()
            NotificationCenter.default.post(name: .init("HermesPetMeetingPartial"),
                                            object: nil, userInfo: ["text": full])
            return
        }
        // 纯标点/语气残渣（如孤零零一个"。"）不进卷
        if Self.normalizeForEcho(trimmed).isEmpty {
            let full = mergedLocked(raw: false)
            lock.unlock()
            NotificationCenter.default.post(name: .init("HermesPetMeetingPartial"),
                                            object: nil, userInfo: ["text": full])
            return
        }
        if lane == .mic, isMicEchoLocked(trimmed) {
            NSLog("[Meeting] 回声抑制：丢弃疑似外放回采的「我」段（\(trimmed.prefix(20))…）")
            let full = mergedLocked(raw: false)
            lock.unlock()
            NotificationCenter.default.post(name: .init("HermesPetMeetingPartial"),
                                            object: nil, userInfo: ["text": full])
            return
        }
        let contextBefore = String(mergedLocked(raw: false).suffix(200))
        let id = UUID()
        _entries.append(Entry(id: id, lane: lane, text: trimmed, raw: trimmed, at: Date()))
        if lane == .system {
            // 反向清理：回声常常比对方原声**更早**定稿（麦克风路引擎先到），
            // 此刻它已是「我」条目 → 对照刚到的对方原声，把近 25s 内的回声「我」删掉
            let cutoff = Date().addingTimeInterval(-25)
            let before = _entries.count
            _entries.removeAll { e in
                e.lane == .mic && e.at > cutoff && Self.isEchoPair(e.text, trimmed)
            }
            if _entries.count != before {
                NSLog("[Meeting] 回声抑制：对方原声到达，回头清掉 \(before - _entries.count) 条回声「我」")
            }
        }
        let full = mergedLocked(raw: false)
        lock.unlock()
        NotificationCenter.default.post(name: .init("HermesPetMeetingPartial"),
                                        object: nil, userInfo: ["text": full])
        scheduleRefine(entryID: id, text: trimmed, context: contextBefore)
    }

    /// 「我」的一段是否疑似外放回声。调用方必须已持锁。
    /// 对照：系统路当前 volatile + 近 25s 的系统路定稿条目。
    private func isMicEchoLocked(_ micText: String) -> Bool {
        if Self.isEchoPair(micText, _sysCurrent) { return true }
        let cutoff = Date().addingTimeInterval(-25)
        return _entries.contains { e in
            e.lane == .system && e.at > cutoff && Self.isEchoPair(micText, e.text)
        }
    }

    /// 两段文本是否「同一句话的两次转写」（回声判定）。
    /// 归一化（去标点空白）后：互为包含，或字符 bigram **重叠系数**（交集/较短者）≥ 0.7。
    /// 用重叠系数而不是 Dice——回声常是"半截 vs 完整"（两引擎定稿时机不同/被 stop 截断），
    /// Dice 会被长度差惩罚到阈值之下（实测 0.53 漏判），重叠系数只看"短的那段是否基本
    /// 包含在长的里面"，正是回声的形态；同音字差异（"回声/回身"）也吃得住。
    /// 短句（<6 字）不判，免得把双方都说的"好的""可以"误杀。
    static func isEchoPair(_ a: String, _ b: String) -> Bool {
        let na = normalizeForEcho(a), nb = normalizeForEcho(b)
        guard na.count >= 6, nb.count >= 6 else { return false }
        if na.contains(nb) || nb.contains(na) { return true }
        let ba = bigramSet(na), bb = bigramSet(nb)
        guard !ba.isEmpty, !bb.isEmpty else { return false }
        let overlap = Double(ba.intersection(bb).count) / Double(min(ba.count, bb.count))
        return overlap >= 0.7
    }

    private static func normalizeForEcho(_ s: String) -> String {
        String(s.unicodeScalars.filter { !$0.properties.isWhitespace
            && !CharacterSet.punctuationCharacters.contains($0)
            && !CharacterSet.symbols.contains($0) }.map(Character.init))
    }

    private static func bigramSet(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var set = Set<String>()
        for i in 0..<(chars.count - 1) { set.insert(String(chars[i...i+1])) }
        return set
    }

    /// 没屏幕录制权限的提示：每次 App 运行最多提示一次（线下会议用户不需要被反复打扰）
    nonisolated(unsafe) private static var didHintSystemLane = false   // hintLock 保护
    private static let hintLock = NSLock()
    private func postSystemLaneHintOnce() {
        Self.hintLock.lock()
        let already = Self.didHintSystemLane
        Self.didHintSystemLane = true
        Self.hintLock.unlock()
        guard !already else { return }
        postError("未获得屏幕录制权限，线上会议里对方的声音录不到（本场只记录你的麦克风）。可到 系统设置 → 隐私与安全性 → 屏幕录制 中允许 HermesPet")
    }

    // MARK: - 停止（async 版）：先让两路 analyzer finalize 冲出没落地的尾段，再封卷。
    /// SpeechAnalyzer 的 final 结果在 utterance 结束后约 1~2s 才送达——用户"说完立刻点结束"
    /// 若直接 stop() 会把最后一句丢掉。UI 路径（Overlay）一律走这个。
    func stopAndFinalize() async -> (transcript: String, audioPath: String?) {
        // 第一段（同步抽函数，NSLock 不能在 async 函数体直接 lock）：
        // 停输入，但**保留 sessionID**让迟到的 final 还能进卷
        guard let prep = prepStopForFinalize() else {
            return idleTranscriptSnapshot()
        }

        stopSegmentTimer()
        prep.micReq?.endAudio()
        prep.micTask?.cancel()
        stopAudioEngine()

        // 第二段（异步冲刷，封顶 5s 防引擎卡死拖住 UI）
        let tap = prep.tap
        let analyzers = prep.analyzers
        await Self.withTimeout(seconds: 5) {
            if let tap { await tap.stop() }
            if #available(macOS 26.0, *) {
                for obj in analyzers {
                    if let a = obj as? MeetingLaneAnalyzer { await a.stop() }
                }
            }
        }

        // 第三段：封卷（同步抽函数）
        let (finalText, audioPath) = sealAndFinish()
        NotificationCenter.default.post(name: .init("HermesPetMeetingFinished"), object: nil,
                                        userInfo: ["text": finalText, "audioPath": audioPath ?? ""])
        return (finalText, audioPath)
    }

    private struct StopPrep {
        let micReq: SFSpeechAudioBufferRecognitionRequest?
        let micTask: SFSpeechRecognitionTask?
        let tap: MeetingSystemAudioTap?
        let analyzers: [any Sendable]
    }

    /// 收尾第一段：标 finishing、摘输入端，保留 sessionID。非 recording 返回 nil。
    private func prepStopForFinalize() -> StopPrep? {
        lock.lock()
        guard _state == .recording else { lock.unlock(); return nil }
        _state = .finishing
        let prep = StopPrep(micReq: _micRequest, micTask: _micTask, tap: _systemTap,
                            analyzers: [_sysAnalyzer, _micAnalyzer].compactMap { $0 })
        _micRequest = nil; _micTask = nil
        _systemTap = nil
        _sysAnalyzer = nil
        _micAnalyzer = nil
        _micAnalyzerPending = false
        _micPreBuffers = []
        lock.unlock()
        return prep
    }

    private func idleTranscriptSnapshot() -> (String, String?) {
        lock.lock(); defer { lock.unlock() }
        return (mergedLocked(raw: false), _micURL?.path)
    }

    /// 收尾第三段：封卷 + 失效 session + 回 idle。
    private func sealAndFinish() -> (String, String?) {
        lock.lock()
        sealCurrentsLocked()
        _micGeneration &+= 1
        _sessionID = UUID()
        let finalText = mergedLocked(raw: false)
        let audioPath = _micURL?.path
        _micFile = nil
        _sysFile = nil
        _state = .idle
        lock.unlock()
        return (finalText, audioPath)
    }

    /// 给 async 操作加超时（操作和定时器赛跑，谁先到都收场）
    private static func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - 停止（同步版，不等尾段；仅退路/紧急场景用，UI 走 stopAndFinalize）
    @discardableResult
    func stop() -> (transcript: String, audioPath: String?) {
        lock.lock()
        guard _state == .recording else {
            let t = mergedLocked(raw: false)
            let p = _micURL?.path
            lock.unlock()
            return (t, p)
        }
        _state = .finishing
        sealCurrentsLocked()
        _micGeneration &+= 1   // 让任何残余回调失效
        _sessionID = UUID()    // 让迟到的系统路 attach / buffer / volatile / final 回调失效
        let micReq = _micRequest
        let micTask = _micTask
        let tap = _systemTap
        let sysAnalyzer = _sysAnalyzer
        let micAnalyzer = _micAnalyzer
        _micRequest = nil; _micTask = nil
        _systemTap = nil
        _sysAnalyzer = nil
        _micAnalyzer = nil
        _micAnalyzerPending = false
        _micPreBuffers = []
        let finalText = mergedLocked(raw: false)
        let audioPath = _micURL?.path
        lock.unlock()

        stopSegmentTimer()
        micReq?.endAudio()
        micTask?.cancel()
        stopAudioEngine()
        stopLanes(tap: tap, analyzers: [sysAnalyzer, micAnalyzer])
        closeAudioFiles()

        lock.lock(); _state = .idle; lock.unlock()
        NotificationCenter.default.post(name: .init("HermesPetMeetingFinished"), object: nil,
                                        userInfo: ["text": finalText, "audioPath": audioPath ?? ""])
        return (finalText, audioPath)
    }

    // MARK: - 取消（丢弃半截录音）
    func cancel() {
        lock.lock()
        guard _state == .recording else { lock.unlock(); return }
        _state = .finishing
        _micGeneration &+= 1
        _sessionID = UUID()
        let micReq = _micRequest
        let micTask = _micTask
        let tap = _systemTap
        let sysAnalyzer = _sysAnalyzer
        let micAnalyzer = _micAnalyzer
        let micURL = _micURL
        let sysURL = _sysURL
        _micRequest = nil; _micTask = nil
        _systemTap = nil
        _sysAnalyzer = nil
        _micAnalyzer = nil
        _micAnalyzerPending = false
        _micPreBuffers = []
        _entries = []
        _micCurrent = ""; _sysCurrent = ""
        _micFile = nil; _micURL = nil
        _sysFile = nil; _sysURL = nil
        lock.unlock()

        stopSegmentTimer()
        micReq?.endAudio()
        micTask?.cancel()
        stopAudioEngine()
        stopLanes(tap: tap, analyzers: [sysAnalyzer, micAnalyzer])
        if let url = micURL { try? FileManager.default.removeItem(at: url) }   // 删半截录音
        if let url = sysURL { try? FileManager.default.removeItem(at: url) }

        lock.lock(); _state = .idle; lock.unlock()
        NotificationCenter.default.post(name: .init("HermesPetMeetingCancelled"), object: nil)
    }

    // MARK: - 转写合并

    /// 两路 partial 各自封段进 _entries（按时间窗顺序：先我后对方）。调用方必须已持锁。
    private func sealCurrentsLocked() {
        if !_micCurrent.isEmpty {
            if !isMicEchoLocked(_micCurrent) {   // 封卷前最后一次回声判定
                _entries.append(Entry(id: UUID(), lane: .mic, text: _micCurrent, raw: _micCurrent, at: Date()))
            }
            _micCurrent = ""
        }
        if !_sysCurrent.isEmpty {
            _entries.append(Entry(id: UUID(), lane: .system, text: _sysCurrent, raw: _sysCurrent, at: Date()))
            _sysCurrent = ""
        }
    }

    /// 合并文字稿。调用方必须已持锁。
    /// 系统路从没出过声（线下会议）→ 与 Phase 1 完全一致：纯拼接、无标注；
    /// 双路都有 → 每段一行，前缀【我】/【对方】。
    private func mergedLocked(raw: Bool) -> String {
        let labeled = _entries.contains { $0.lane == .system } || !_sysCurrent.isEmpty
        if !labeled {
            return _entries.map { raw ? $0.raw : $0.text }.joined() + _micCurrent
        }
        var lines: [String] = _entries.map { e in
            let t = raw ? e.raw : e.text
            return (e.lane == .mic ? "【我】" : "【对方】") + t
        }
        // 「我」的 volatile 若疑似外放回声（和对方当前/近期内容高度相似），显示层先压掉
        // （定稿时 laneFinal 还会再判一次——这里只管字幕别闪重复）
        if !_micCurrent.isEmpty, !isMicEchoLocked(_micCurrent) {
            lines.append("【我】" + _micCurrent)
        }
        if !_sysCurrent.isEmpty { lines.append("【对方】" + _sysCurrent) }
        return lines.joined(separator: "\n")
    }

    // MARK: - 分段接力
    private func startSegmentTimer() {
        let timer = DispatchSource.makeTimerSource(queue: segmentQueue)
        timer.schedule(deadline: .now() + .seconds(segmentSeconds), repeating: .seconds(segmentSeconds))
        timer.setEventHandler { Self.shared.rotateSegment() }
        timer.resume()
        lock.lock(); _segmentTimer = timer; lock.unlock()
    }

    private func stopSegmentTimer() {
        lock.lock(); let t = _segmentTimer; _segmentTimer = nil; lock.unlock()
        t?.cancel()
    }

    /// 切段：把两路当前段并入 _entries、各起一个新 request/task 继续。旧 task 直接 cancel
    /// （放弃它最后一点修正，换来干净的段边界 + 避免旧回调污染新段）。
    /// 切段后触发**豆包式分段 AI 纠错**：刚定稿的段交给 segmentRefiner 纠一遍，按段 id 回写替换
    /// （Phase 1 的"字符偏移替换"已废——entries 化后按 id 定位，天然不怕重复语句/偏移漂移）。
    fileprivate func rotateSegment() {
        guard let recognizer = recognizer else { return }
        lock.lock()
        guard _state == .recording else { lock.unlock(); return }

        // 纠错上下文 = 封段前的全文末尾（够 AI 理解语境即可）
        let contextBefore = String(mergedLocked(raw: false).suffix(200))

        // 封段 + 登记纠错任务（entry.id 即纠错回写的定位句柄）
        var refineJobs: [(id: UUID, text: String)] = []
        if !_micCurrent.isEmpty {
            let id = UUID()
            _entries.append(Entry(id: id, lane: .mic, text: _micCurrent, raw: _micCurrent, at: Date()))
            refineJobs.append((id, _micCurrent))
            _micCurrent = ""
        }
        // （系统路不在这里封段——SpeechAnalyzer 的 final 结果自己封，粒度还更细）

        // 麦克风路接力
        let oldMicReq = _micRequest
        let oldMicTask = _micTask
        let micGen = _micGeneration &+ 1
        let newMicReq = Self.makeRequest(recognizer, onDevice: true)
        let newMicTask = recognizer.recognitionTask(with: newMicReq) { result, error in
            Self.shared.handleMicResult(result, error: error, generation: micGen)
        }
        _micGeneration = micGen
        _micRequest = newMicReq
        _micTask = newMicTask

        lock.unlock()

        oldMicReq?.endAudio()
        oldMicTask?.cancel()

        for job in refineJobs {
            scheduleRefine(entryID: job.id, text: job.text, context: contextBefore)
        }
    }

    /// 异步分段纠错（不阻塞录音），按段 id 回写。
    /// refiner 在 Task 内部从 nonisolated(unsafe) 属性现读——把同一个非 Sendable
    /// 闭包捕获进多个 detached Task 过不了 Swift 6 区域隔离检查。
    private func scheduleRefine(entryID: UUID, text: String, context: String) {
        guard segmentRefiner != nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return }
        Task.detached { [weak self] in
            guard let self, let refiner = self.segmentRefiner else { return }
            guard let refined = await refiner(trimmed, context) else { return }
            let cleaned = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned != trimmed else { return }
            self.applyRefinement(entryID: entryID, refined: cleaned)
        }
    }

    /// 把某段的纠错结果按段 id 回写。段还在就替换 text（raw 永远保留原文）。
    /// 录音中替换 → 立刻 broadcast 让字幕「跳变」成更准的版本（豆包式观感）。
    private func applyRefinement(entryID: UUID, refined: String) {
        lock.lock()
        guard let idx = _entries.firstIndex(where: { $0.id == entryID }) else { lock.unlock(); return }
        _entries[idx].text = refined
        let full = mergedLocked(raw: false)
        let recording = (_state == .recording)
        lock.unlock()
        if recording {
            NotificationCenter.default.post(name: .init("HermesPetMeetingPartial"),
                                            object: nil, userInfo: ["text": full])
        }
    }

    // MARK: - 麦克风路 SFSpeech 回调（仅 <26 / analyzer 回退路径；analyzer 模式走 laneVolatile/laneFinal）
    fileprivate func handleMicResult(_ result: SFSpeechRecognitionResult?, error: Error?,
                                     generation: Int) {
        if let error = error {
            // cancel 类错误在分段接力里是常态；但「识别服务拒绝/并发受限」类必须看见
            NSLog("[Meeting] mic 路识别回调 error(gen \(generation)): \(error)")
            lock.lock()
            _lastErrors["mic"] = "gen\(generation): \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)"
            lock.unlock()
        }
        guard let result = result else { return }
        let text = result.bestTranscription.formattedString
        lock.lock()
        guard generation == _micGeneration, _state == .recording else { lock.unlock(); return }
        _micCurrent = text
        let full = mergedLocked(raw: false)
        lock.unlock()
        NotificationCenter.default.post(name: .init("HermesPetMeetingPartial"),
                                        object: nil, userInfo: ["text": full])
    }

    /// 收掉两路（tap + 各 analyzer）。stop/cancel 共用；async 资源在 detached Task 里收。
    private func stopLanes(tap: MeetingSystemAudioTap?, analyzers: [(any Sendable)?]) {
        let objs = analyzers.compactMap { $0 }
        guard tap != nil || !objs.isEmpty else { return }
        Task.detached {
            if let tap { await tap.stop() }
            if #available(macOS 26.0, *) {
                for obj in objs {
                    if let a = obj as? MeetingLaneAnalyzer { await a.stop() }
                }
            }
        }
    }

    // MARK: - Private
    /// ⭐ 同进程**只能有一个** SFSpeech 流式任务（2026-06-11 四轮实验实锤：双路无论
    /// 端上/服务器怎么组合，先启动的必被后启动的"饿死"——音频电平正常却报 1110）。
    /// 所以本类只有麦克风一路用 SFSpeech（端上、隐私最优），系统路走 SpeechAnalyzer。
    private static func makeRequest(_ recognizer: SFSpeechRecognizer,
                                    onDevice: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.taskHint = .dictation
        if onDevice, recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        return r
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func closeAudioFiles() {
        lock.lock(); _micFile = nil; _sysFile = nil; lock.unlock()   // AVAudioFile 释放即落盘关闭
    }

    private func postError(_ message: String) {
        NotificationCenter.default.post(name: .init("HermesPetMeetingError"),
                                        object: nil, userInfo: ["message": message])
    }

    private static func meetingsDir() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 估算 PCM buffer 的音量峰值（0~1）。audio thread 调用，static + 不访问任何状态。
    private static func computeLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let ptr = channelData.pointee
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { let v = ptr[i]; sum += v * v }
        let rms = sqrtf(sum / Float(count))
        return min(max(rms * 6, 0), 1)
    }
}
