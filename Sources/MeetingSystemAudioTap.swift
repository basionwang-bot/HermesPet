import Foundation
import AVFoundation
import ScreenCaptureKit

/// 会议纪要 Phase 2：系统音频采集（线上会议「对方的声音」）。
///
/// 用 ScreenCaptureKit 的音频流（`capturesAudio`）抓系统正在播放的声音 —— 腾讯会议 / Zoom /
/// 飞书里对方说话都从这条路出来。视频流压到最小（2×2 @ 1fps）且不挂 `.screen` output
/// （帧直接被丢弃），开销可忽略。
///
/// **权限**：走「屏幕录制」TCC（纯 TCC，无需 Hardened Runtime entitlement，见决策 #19）。
/// 项目截屏已用 SCK、多数用户已授权；没授权时 `start()` 抛错，由调用方降级成"只录麦克风"。
///
/// **隔离**（决策 #5）：SCStream 回调在我们提供的后台 sampleHandlerQueue 上，类必须
/// `@unchecked Sendable`、不能 @MainActor。buffer 通过 `@Sendable` 闭包转发给 MeetingRecorder
/// （后者自己 NSLock，全程不 hop 主线程）。
final class MeetingSystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var _stream: SCStream?
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let queue = DispatchQueue(label: "com.basionwang.hermespet.meeting.sysaudio")

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    /// 启动系统音频流。没屏幕录制权限 / 找不到显示器时抛错（调用方降级）。
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "HermesPet.Meeting", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到可用的显示器"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // 桌宠自己的提示音 / TTS 不混进会议稿
        config.sampleRate = 48_000
        config.channelCount = 1                     // 转写单声道足够，省一半数据
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lock.withLock { _stream = stream }   // async 上下文用 withLock（lock()/unlock() 标了 noasync）
    }

    func stop() async {
        let s = lock.withLock { () -> SCStream? in
            let s = _stream; _stream = nil; return s
        }
        guard let s else { return }
        try? await s.stopCapture()
    }

    // MARK: - SCStreamOutput（后台 queue 回调）

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 流被系统掐断（显示器拔出 / 权限被撤）：会议继续，只是退化成纯麦克风
        NSLog("[Meeting] 系统音频流中断: \(error.localizedDescription)")
        lock.lock(); _stream = nil; lock.unlock()
    }

    /// CMSampleBuffer → AVAudioPCMBuffer（喂 SFSpeechRecognizer / AVAudioFile）
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return pcm
    }
}
