import Foundation
import AVFoundation
import Speech

/// 单路音频的转写引擎（macOS 26+）：SpeechAnalyzer / SpeechTranscriber。
/// 麦克风路和系统音频路各开一个实例（SpeechAnalyzer 支持多实例并发，SFSpeech 不行）。
///
/// **为什么不用 SFSpeechRecognizer**：macOS 26.3 上一个进程**同时只有一个**流式
/// `SFSpeechAudioBufferRecognitionRequest` 能正常工作（2026-06-11 四轮实验实锤：
/// 双路不管端上/服务器怎么组合，先启动的麦克风路必被后启动的系统路"饿死"——
/// 音频电平正常却报 1110 No speech detected；单路对照同音量转写全正常）。
/// SpeechAnalyzer 是 macOS 26 的长音频转写新 API（备忘录/电话录音同款引擎），
/// 与 SFSpeech 不抢通道、无 1 分钟限制（不用 50s 切段接力）、精度明显更好，
/// 自带 volatile（实时变动）/ final（定稿）两级结果，天然对应字幕 + 封段。
///
/// **隔离**（决策 #5）：SCK buffer 从后台队列进来、结果流在 Task 里消费，
/// 类 `@unchecked Sendable` + NSLock，回调全是 `@Sendable` 闭包（MeetingRecorder 自己线程安全）。
@available(macOS 26.0, *)
final class MeetingLaneAnalyzer: @unchecked Sendable {

    private let lock = NSLock()
    private var _analyzer: SpeechAnalyzer?
    private var _transcriber: SpeechTranscriber?
    private var _input: AsyncStream<AnalyzerInput>.Continuation?
    private var _analyzerFormat: AVAudioFormat?
    private var _converter: AVAudioConverter?
    private var _resultsTask: Task<Void, Never>?

    private let onVolatile: @Sendable (String) -> Void   // 当前段实时变动文本（整段替换式）
    private let onFinal: @Sendable (String) -> Void      // 一段定稿（utterance 粒度）
    private let onError: @Sendable (String) -> Void
    /// 健康诊断信息（语言支持、analyzer 启动、首个 buffer 等）——**不是错误**。
    /// 审计 #10：原来这些走 onError → 被 MeetingRecorder 存进 `_lastErrors`，健康会也显示「最后错误」。
    /// 分流到 onStatus（默认丢弃，MeetingRecorder 接到 NSLog），不再污染错误快照。
    private let onStatus: @Sendable (String) -> Void

    init(onVolatile: @escaping @Sendable (String) -> Void,
         onFinal: @escaping @Sendable (String) -> Void,
         onError: @escaping @Sendable (String) -> Void,
         onStatus: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onVolatile = onVolatile
        self.onFinal = onFinal
        self.onError = onError
        self.onStatus = onStatus
    }

    /// 起引擎：建 transcriber → 确保中文模型资产已装 → 起 analyzer 输入流 → 消费结果流。
    /// 抛错 = 这台机器用不了（调用方降级纯麦克风）。
    private var _fedCount = 0
    private var _resultCount = 0

    func start() async throws {
        let locale = Locale(identifier: "zh-CN")
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier)
        let installed = await Set(SpeechTranscriber.installedLocales.map(\.identifier))
        let zhSupported = supported.contains(where: { $0.hasPrefix("zh") })
        let zhInstalled = installed.contains("zh-CN") || installed.contains("zh_CN")
        onStatus("zh supported=\(zhSupported) installed=\(zhInstalled) (all installed: \(installed.sorted().joined(separator: ",")))")
        // .fastResults：让 volatile 草稿尽快出字（默认节奏 2~4s 才冒一批，字幕观感慢）。
        // 只影响草稿首发质量（后续自动修正），final 定稿质量不变 → 没有真实代价，不做用户开关。
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        // 模型资产：系统听写用过一般已装好，没装就静默下载（本地小模型，几十 MB）
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: sequence)

        lock.withLock {   // async 上下文用 withLock（lock()/unlock() 标了 noasync）
            _analyzer = analyzer
            _transcriber = transcriber
            _input = continuation
            _analyzerFormat = format
        }

        // 结果流：volatile = 当前段在变（替换式更新字幕）；final = 这段定稿
        _resultsTask = Task.detached { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    self.lock.withLock { self._resultCount += 1 }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.onFinal(text)
                    } else {
                        self.onVolatile(text)
                    }
                }
                self?.onStatus("results loop ended normally")
            } catch {
                self?.onError("结果流中断: \(error.localizedDescription)")
            }
        }
        NSLog("[Meeting] 系统路 SpeechAnalyzer 已启动（格式: \(format?.description ?? "默认")）")
        onStatus("analyzer started, fmt=\(format.map { "\($0.sampleRate)Hz/\($0.channelCount)ch" } ?? "nil")")
    }

    /// SCK 后台队列回调：转换到 analyzer 要求的采样格式后入流。
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let input = _input
        let target = _analyzerFormat
        var converter = _converter
        _fedCount += 1
        let firstFeed = (_fedCount == 1)
        lock.unlock()
        guard let input else { return }
        if firstFeed { onStatus("first buffer in, fmt=\(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch") }

        guard let target, target != buffer.format else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            lock.lock(); _converter = converter; lock.unlock()
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: out))
    }

    func stop() async {
        let (input, analyzer, task) = lock.withLock {
            let t = (_input, _analyzer, _resultsTask)
            _input = nil
            _analyzer = nil
            _transcriber = nil
            _resultsTask = nil
            _converter = nil
            return t
        }

        input?.finish()
        if let analyzer {
            // finalize 会把没出完的 final 结果冲出来（用户"说完立刻点结束"的最后一句靠它保住）
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)   // 给结果流 0.3s 送达窗口
        task?.cancel()
    }
}
