import AVFoundation
import Speech
import AppKit

/// 语音陪聊专用语音管线（独立于 push-to-talk 的 `VoiceInputController.shared`）。
///
/// 为什么要独立一套：
/// - **开 voice processing（系统 AEC 回声消除）**：speaking 时麦克风也开着，也不会把 AI 从扬声器
///   放出的声音录进来 → 支撑「AI 说话时用户开口即打断」。push-to-talk 不需要 AEC，所以两套分开。
/// - **发自定义通知** `HermesPetVoiceChatLevel` / `HermesPetVoiceChatPartial`，不发 push-to-talk
///   的 `HermesPetVoice*` → 彻底避开字幕条串扰。
/// - **engine 会话期间常开**；listening 轮挂 SFSpeech 识别，speaking 轮只读音量做 VAD（检测打断）。
///
/// **隔离（守 CLAUDE.md 决策 #5）**：`@unchecked Sendable` + NSLock。installTap / recognitionTask
/// 回调都在后台线程，本类 nonisolated，回调里只 `NotificationCenter.post`（线程安全）+ 锁保护可变状态。
final class VoiceChatMic: @unchecked Sendable {

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?

    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _task: SFSpeechRecognitionTask?
    private var _recognizing = false
    private var _engineRunning = false
    private var _currentText = ""

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
    }

    // MARK: - 权限

    func requestPermissions() async -> (Bool, String?) {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            return (false, "语音识别权限未授权，请到 系统设置 → 隐私与安全性 → 语音识别 中允许 HermesPet")
        }
        let micGranted: Bool = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        return micGranted
            ? (true, nil)
            : (false, "麦克风权限被拒绝，请到 系统设置 → 隐私与安全性 → 麦克风 中允许 HermesPet")
    }

    var isEngineRunning: Bool { lock.lock(); defer { lock.unlock() }; return _engineRunning }

    // MARK: - 引擎（会话常开 + AEC）

    @discardableResult
    func startEngine() -> Bool {
        lock.lock()
        if _engineRunning { lock.unlock(); return true }
        lock.unlock()

        guard let recognizer = recognizer, recognizer.isAvailable else { return false }

        let input = audioEngine.inputNode
        // ⚠️ 不开 voice processing（AEC）：实测在本机会把麦克风输入搞静音/改格式，
        // 导致 SFSpeech 连用户声音都识别不到。回到普通输入 → 回合制（speaking 不靠音量打断，改点击打断）。
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            // 后台音频线程：发音量通知（listening 静音检测 / speaking 打断 VAD 共用）
            let level = Self.computeLevel(buffer)
            NotificationCenter.default.post(
                name: .init("HermesPetVoiceChatLevel"), object: nil, userInfo: ["level": level]
            )
            // listening 轮才把 buffer 喂给识别
            self.lock.lock(); let req = self._request; self.lock.unlock()
            req?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            NSLog("[VoiceChatMic] audioEngine.start 失败: \(error)")
            return false
        }
        lock.lock(); _engineRunning = true; lock.unlock()
        return true
    }

    func stopEngine() {
        lock.lock()
        let running = _engineRunning
        let req = _request; let task = _task
        _engineRunning = false; _recognizing = false; _request = nil; _task = nil
        lock.unlock()

        req?.endAudio()
        task?.cancel()
        if running {
            audioEngine.inputNode.removeTap(onBus: 0)
            if audioEngine.isRunning { audioEngine.stop() }
        }
    }

    // MARK: - 识别（listening 轮）

    /// 开始识别本轮用户说话。engine 已常开，这里只建 request/task。
    func startRecognizing() {
        lock.lock()
        if _recognizing { lock.unlock(); return }
        _currentText = ""
        lock.unlock()

        guard let recognizer = recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.lock.lock(); self._currentText = text; self.lock.unlock()
                NotificationCenter.default.post(
                    name: .init("HermesPetVoiceChatPartial"), object: nil, userInfo: ["text": text]
                )
            }
        }
        lock.lock(); _request = request; _task = task; _recognizing = true; lock.unlock()
    }

    /// 结束本轮识别，返回最终识别文字。engine 保持常开。
    @discardableResult
    func stopRecognizing() -> String {
        lock.lock()
        let text = _currentText
        let req = _request; let task = _task
        _recognizing = false; _request = nil; _task = nil
        lock.unlock()
        req?.endAudio()
        task?.cancel()
        return text
    }

    // MARK: - 音量

    /// PCM buffer 音量峰值（0~1）。后台线程调用，static 不访问状态。
    private static func computeLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let ch = channelData.pointee
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { let v = ch[i]; sum += v * v }
        let rms = sqrtf(sum / Float(count))
        return min(max(rms * 6, 0), 1)
    }
}
