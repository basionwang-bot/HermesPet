import AVFoundation
import Speech
import AppKit

/// 录音 + 语音识别（push-to-talk 用）。
///
/// **隔离设计**：本类完全 nonisolated（@unchecked Sendable）。
/// 原因：系统 API（SFSpeechRecognizer、AVAudioNode.installTap、SFSpeechRecognitionTask）
/// 的回调都在后台线程触发。如果类是 @MainActor，编译器把内部 closure 推断为 @MainActor，
/// 在后台线程执行就 SIGTRAP。
///
/// 可变状态用 NSLock 保护。所有 public 方法都线程安全。
final class VoiceInputController: @unchecked Sendable {
    static let shared = VoiceInputController()

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?

    // NSLock 保护下面的 mutable state
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _task: SFSpeechRecognitionTask?
    private var _isListening: Bool = false
    private var _currentTranscript: String = ""

    var isListening: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isListening
    }

    var currentTranscript: String {
        lock.lock(); defer { lock.unlock() }
        return _currentTranscript
    }

    private init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer()
    }

    // MARK: - 权限

    /// 请求语音识别 + 麦克风权限。返回 (是否全部授权, 错误描述)。
    func requestPermissions() async -> (Bool, String?) {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        switch speechStatus {
        case .authorized:
            let micGranted: Bool = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
            if micGranted {
                return (true, nil)
            } else {
                return (false, "麦克风权限被拒绝，请到 系统设置 → 隐私与安全性 → 麦克风 中允许 HermesPet")
            }
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

    // MARK: - 录音 + 识别

    @discardableResult
    func startListening() -> Bool {
        lock.lock()
        if _isListening {
            lock.unlock()
            return true
        }
        lock.unlock()

        guard let recognizer = recognizer, recognizer.isAvailable else {
            postError("语音识别引擎不可用（可能在加载中文模型，请稍后再试）")
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // 无内置麦 / 外设刚断开 / 硬件未就绪时 format 为 sampleRate==0 的无效格式，
        // 直接 installTap 会触发 CoreAudio 断言 NSException 崩。此处尚未 mutate 状态/启动引擎，安全早退。
        guard format.sampleRate > 0, format.channelCount > 0 else {
            postError("音频输入设备不可用，请检查麦克风是否连接")
            return false
        }
        input.removeTap(onBus: 0)

        // audio tap closure 在后台线程跑。不要捕获 self，
        // 只引用局部 sendable 变量（request 引用、Self 类型）
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            let level = Self.computeLevel(buffer)
            NotificationCenter.default.post(
                name: .init("HermesPetVoiceLevel"),
                object: nil,
                userInfo: ["level": level]
            )
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            postError("音频引擎启动失败: \(error.localizedDescription)")
            return false
        }

        // recognitionTask 回调也在后台线程。捕获 lock 引用（class，sendable）
        // 不捕获 self，通过 Self.shared 内部 lock 直接 mutate
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                Self.shared.updateTranscript(text)
                NotificationCenter.default.post(
                    name: .init("HermesPetVoicePartial"),
                    object: nil,
                    userInfo: ["text": text]
                )
            }
            if error != nil {
                Self.shared.handleRecognitionError()
            }
        }

        lock.lock()
        _request = request
        _task = task
        _isListening = true
        _currentTranscript = ""
        lock.unlock()

        NotificationCenter.default.post(name: .init("HermesPetVoiceStarted"), object: nil)
        // trackpad 轻震：让用户知道"已经在录了"，按住 ⌘⇧V 不需要盯灵动岛
        DispatchQueue.main.async { Haptic.tap(.alignment) }
        return true
    }

    @discardableResult
    func stopListening() -> String {
        lock.lock()
        guard _isListening else {
            let t = _currentTranscript
            lock.unlock()
            return t
        }
        let req = _request
        _isListening = false
        let finalText = _currentTranscript
        _task = nil
        _request = nil
        lock.unlock()

        req?.endAudio()
        stopAudioEngine()

        NotificationCenter.default.post(
            name: .init("HermesPetVoiceFinished"),
            object: nil,
            userInfo: ["text": finalText]
        )
        return finalText
    }

    func cancelListening() {
        lock.lock()
        guard _isListening else { lock.unlock(); return }
        let t = _task
        _isListening = false
        _currentTranscript = ""
        _task = nil
        _request = nil
        lock.unlock()

        t?.cancel()
        stopAudioEngine()
        NotificationCenter.default.post(name: .init("HermesPetVoiceCancelled"), object: nil)
    }

    // MARK: - 内部 mutation（线程安全，给后台回调用）

    fileprivate func updateTranscript(_ text: String) {
        lock.lock()
        _currentTranscript = text
        lock.unlock()
    }

    fileprivate func handleRecognitionError() {
        stopAudioEngine()
    }

    // MARK: - Private

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func postError(_ message: String) {
        NotificationCenter.default.post(
            name: .init("HermesPetVoiceError"),
            object: nil,
            userInfo: ["message": message]
        )
    }

    /// 估算 PCM buffer 的音量峰值（0~1）。audio thread 调用，static + 不访问任何状态。
    private static func computeLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelDataValue = channelData.pointee
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let v = channelDataValue[i]
            sum += v * v
        }
        let rms = sqrtf(sum / Float(count))
        let normalized = min(max(rms * 6, 0), 1)
        return normalized
    }
}
