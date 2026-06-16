import Foundation
import Speech
import AVFoundation

/// 会议结束后的**完整离线重转写** —— 把录好的 m4a 全量转成文字（纪要/洞察都喂完整稿）。
///
/// **引擎选择（2026-06-01 重写）**：
/// - **macOS 26+：`SpeechAnalyzer` + `SpeechTranscriber`（新框架，WWDC 2025）** —— 专为长音频
///   （讲座/会议/多人对话）训练，**完全本地不上传**，比 Whisper Large V3 还快。中文 `zh-CN` 在
///   `supportedLocales` 里。这才是 iPhone「语音备忘录转文字」背后的引擎。**这是主路。**
/// - **macOS <26：旧 `SFSpeechRecognizer` buffer 分段** —— 兜底。它单次 ~1 分钟上限、要硬切段、
///   中文本地质量一般，**会丢内容**（用户实测一小时会议丢了大量句子），所以仅作老系统降级。
///
/// **本地优先、不上传**（用户定）：新引擎天生本地；旧路 `requiresOnDeviceRecognition = true`。
enum MeetingFileTranscriber {

    enum TranscribeError: Error {
        case recognizerUnavailable, audioRead, timeout, recognitionFailed(String), localeUnsupported
    }

    /// 对完整录音文件离线转写，返回完整文字。失败 throw（调用方回退实时稿）。
    static func transcribe(audioURL: URL,
                           progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        if #available(macOS 26.0, *) {
            do {
                return try await transcribeWithAnalyzer(audioURL: audioURL, progress: progress)
            } catch {
                NSLog("[FileTranscriber] 新引擎失败(\(error))，回退老 buffer 路")
                return try await transcribeLegacy(audioURL: audioURL, progress: progress)
            }
        }
        return try await transcribeLegacy(audioURL: audioURL, progress: progress)
    }

    // MARK: - 主路：SpeechAnalyzer 长音频全量转写（macOS 26+）

    @available(macOS 26.0, *)
    private static func transcribeWithAnalyzer(
        audioURL: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let file = try AVAudioFile(forReading: audioURL)
        let locale = Locale(identifier: "zh-CN")
        let want = locale.identifier(.bcp47)

        // 1) 确认 zh-CN 在支持列表（保险，理论上 macOS 26 都有）
        let supportedList = await SpeechTranscriber.supportedLocales
        guard supportedList.contains(where: { $0.identifier(.bcp47) == want }) else {
            NSLog("[FileTranscriber] zh-CN 不在 SpeechTranscriber.supportedLocales")
            throw TranscribeError.localeUnsupported
        }

        // 2) 显式选项：不要 volatile（只收最终结果，正合"等完整"），文字默认带标点
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])

        // 3) 模型没装就下（首次几百 MB，仅一次，之后本地直接用）
        let installedList = await SpeechTranscriber.installedLocales
        if !installedList.contains(where: { $0.identifier(.bcp47) == want }) {
            progress?("首次使用，正在下载中文语音模型（仅一次）…")
            NSLog("[FileTranscriber] zh-CN 模型未安装，开始下载…")
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
            NSLog("[FileTranscriber] zh-CN 模型安装完成")
        }

        // 4) 并发消费转写结果（边喂边出）
        let collector = Task { () -> String in
            var acc = ""
            for try await result in transcriber.results where result.isFinal {
                acc += String(result.text.characters)
                progress?(acc)
            }
            return acc
        }

        // 5) 把整段录音喂给 analyzer，喂完 finalize
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        let text = try await collector.value
        NSLog("[FileTranscriber] 新引擎完成：\(text.count) 字")
        guard !text.isEmpty else { throw TranscribeError.recognitionFailed("新引擎没转出内容") }
        return text
    }

    // MARK: - 兜底：SFSpeechRecognizer buffer 分段（macOS <26）

    /// 每段最多喂多少秒音频（避开苹果单 task ~1 分钟上限，取 45 留余量）。
    private static let segmentSeconds: Double = 45
    /// 单段识别超时（秒）—— 喂完 endAudio 后等 final 的最长容忍。
    private static let segmentTimeout: UInt64 = 60

    private static func transcribeLegacy(
        audioURL: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audioURL) }
        catch { throw TranscribeError.audioRead }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { throw TranscribeError.audioRead }

        let framesPerSegment = AVAudioFrameCount(sampleRate * segmentSeconds)
        let totalFrames = file.length
        guard totalFrames > 0 else { throw TranscribeError.audioRead }

        var merged = ""
        var failed = 0
        var segIndex = 0

        while file.framePosition < totalFrames {
            let remaining = totalFrames - file.framePosition
            let toRead = AVAudioFrameCount(min(Int64(framesPerSegment), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { break }
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                NSLog("[FileTranscriber] 段 \(segIndex) 读帧失败: \(error.localizedDescription)")
                break
            }
            if buffer.frameLength == 0 { break }

            NSLog("[FileTranscriber] 段 \(segIndex): 读入 \(buffer.frameLength) 帧，开始识别…")
            let text = (try? await recognizeBuffer(buffer)) ?? ""
            if text.isEmpty { failed += 1; NSLog("[FileTranscriber] 段 \(segIndex): ❌ 空") }
            else {
                merged += text
                NSLog("[FileTranscriber] 段 \(segIndex): ✅ \(text.count) 字")
                if let progress { progress(merged) }
            }
            segIndex += 1
        }

        NSLog("[FileTranscriber] 兜底完成：\(segIndex) 段，\(failed) 段失败，共 \(merged.count) 字")
        guard !merged.isEmpty else { throw TranscribeError.recognitionFailed("全部段都没转出内容") }
        return merged
    }

    /// buffer（AVAudioPCMBuffer 非 Sendable）不跨并发边界：本函数内同步 append + endAudio 后，
    /// 只 await continuation（continuation 只传 String）。超时用内部 DispatchQueue watchdog。
    private static func recognizeBuffer(_ buffer: AVAudioPCMBuffer) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw TranscribeError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // 决策 #5：识别回调 + 超时 asyncAfter 都在**后台**并发触发，且要去重 + cancel task。
        // 把这套状态收进一个 @unchecked Sendable 的小类（done/task/cont 全用 NSLock 保护），
        // 取代"本地函数 finishOnce + 裸 var done"——后者 Swift 6 无法标 @Sendable，会留并发隐患。
        final class FinishGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            private var task: SFSpeechRecognitionTask?
            private let cont: CheckedContinuation<String, Error>
            init(_ cont: CheckedContinuation<String, Error>) { self.cont = cont }
            func setTask(_ t: SFSpeechRecognitionTask?) { lock.lock(); task = t; lock.unlock() }
            func finish(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                task?.cancel()
                cont.resume(with: result)
            }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let g = FinishGuard(cont)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    g.finish(.failure(TranscribeError.recognitionFailed(error.localizedDescription)))
                    return
                }
                guard let result = result, result.isFinal else { return }
                g.finish(.success(result.bestTranscription.formattedString))
            }
            g.setTask(task)
            request.append(buffer)
            request.endAudio()
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(segmentTimeout)) {
                g.finish(.failure(TranscribeError.timeout))
            }
        }
    }
}
