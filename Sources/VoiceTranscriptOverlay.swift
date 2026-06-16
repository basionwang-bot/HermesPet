import AppKit
import SwiftUI

/// 按住 ⌘⇧V 时在灵动岛**下方**浮现的实时识别字幕条。
/// 用户能在按住期间确认"我说的对不对"，错了立即松手取消（HermesPetVoiceCancelled），
/// 不必等到松手才发现识别结果不对。
///
/// 实现：单独 NSWindow，level 跟灵动岛同 .statusBar，水平居中在带刘海的屏的顶部下方。
/// 监听 4 个通知：
///   - HermesPetVoiceStarted   → show，初始文字"正在听…"
///   - HermesPetVoicePartial   → 持续刷新文字
///   - HermesPetVoiceFinished  → hide
///   - HermesPetVoiceCancelled → hide
@MainActor
final class VoiceTranscriptOverlayController {
    static let shared = VoiceTranscriptOverlayController()

    private var window: NSWindow?
    private var hostingView: NSHostingController<VoiceTranscriptView>?
    private let viewState = TranscriptState()

    private init() {
        registerNotifications()
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .init("HermesPetVoiceStarted"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard !VoiceChatController.isSessionActive else { return }   // 陪聊用的是同一个 VoiceInputController，别让字幕条串扰冒出来
                self?.showOverlay(initialText: "正在听…")
            }
        }
        nc.addObserver(forName: .init("HermesPetVoicePartial"), object: nil, queue: .main) { [weak self] note in
            let text = (note.userInfo?["text"] as? String) ?? ""
            Task { @MainActor in
                guard !VoiceChatController.isSessionActive else { return }
                self?.updateText(text)
            }
        }
        nc.addObserver(forName: .init("HermesPetVoiceFinished"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard !VoiceChatController.isSessionActive else { return }
                self?.hideOverlay()
            }
        }
        nc.addObserver(forName: .init("HermesPetVoiceCancelled"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard !VoiceChatController.isSessionActive else { return }
                self?.hideOverlay()
            }
        }
    }

    // MARK: - Show / Hide / Update

    private func showOverlay(initialText: String) {
        if window == nil { createWindow() }
        viewState.text = initialText
        viewState.isVisible = true
        lastWidthBucket = -1   // 新一轮录音重置节流状态
        lastPositionAt = 0
        positionWindow()
        window?.orderFront(nil)
    }

    private func hideOverlay() {
        viewState.isVisible = false
        // 等淡出动画再 orderOut
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.viewState.isVisible == false {
                self?.window?.orderOut(nil)
                self?.viewState.text = ""
            }
        }
    }

    private func updateText(_ text: String) {
        let newText = text.isEmpty ? "正在听…" : text
        // SwiftUI 文本节点 diff —— 仅在内容确实变化时赋值，
        // 避免相同字符串触发无意义的 @Observable 通知
        if viewState.text != newText {
            viewState.text = newText
        }
        // **不要每次 partial 都 setFrame** —— SFSpeechRecognizer 一秒能发 20-30 次 partial，
        // 每次都同步 setFrame + display:true 会把主线程钉在 NSWindow.setFrameCommon /
        // SwiftUI flushTransactions，issue #3 "语音唤醒高占用"就是这条路径。
        // 改成按宽度等级（约每多 4 个字才扩一次窗口）+ 节流到 ≥120ms 一次。
        let widthBucket = (text.count + 3) / 4
        let now = CFAbsoluteTimeGetCurrent()
        if widthBucket != lastWidthBucket && now - lastPositionAt >= 0.12 {
            lastWidthBucket = widthBucket
            lastPositionAt = now
            positionWindow()
        }
    }

    /// 用于 updateText 节流：上次定位时的宽度等级 / 时间戳
    private var lastWidthBucket: Int = -1
    private var lastPositionAt: CFAbsoluteTime = 0

    // MARK: - Window

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.auxiliary   // 低于灵动岛 1 级，见 WindowLevels.swift
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true        // 不拦截鼠标 —— 用户能继续操作底下 app
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false

        // 决策 #1/#6 升级：裸 NSHostingView 即便 sizingOptions=[] 在 macOS 26 仍会经
        // updateAnimatedWindowSize 反推 setFrame（2026-06-11 00:09 崩溃实锤）；只有
        // NSHostingController + sizingOptions=[] 真正禁掉反推（照语音陪聊/迷你岛范本）
        let host = NSHostingController(rootView: VoiceTranscriptView(state: viewState))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        w.contentViewController = host
        host.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）
        w.setContentSize(NSSize(width: 320, height: 60))

        self.window = w
        self.hostingView = host
    }

    /// 把字幕窗放在带刘海的屏的顶部、灵动岛胶囊正下方约 18pt 处。
    /// 宽度根据当前文字长度估算，min 220、max 700，水平居中
    private func positionWindow() {
        guard let window = window else { return }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen = screen else { return }
        let screenFrame = screen.frame
        let safeArea = screen.safeAreaInsets
        let notchHeight: CGFloat = safeArea.top > 0 ? safeArea.top : 28

        // 估算文字宽度（粗略：每字 13pt + 左右 padding 32）
        let charCount = viewState.text.count
        let estimatedWidth: CGFloat = min(700, max(220, CGFloat(charCount) * 14 + 48))
        let windowHeight: CGFloat = 44

        // 灵动岛胶囊本体高度 ≈ notchHeight + idleDrop(4) ≈ notchHeight + 4
        // 字幕窗顶部距胶囊底部 18pt
        let topGap: CGFloat = 18
        let y = screenFrame.maxY - notchHeight - 4 - topGap - windowHeight
        let x = screenFrame.midX - estimatedWidth / 2

        window.setFrame(
            NSRect(x: x, y: y, width: estimatedWidth, height: windowHeight),
            display: true
        )
    }
}

// MARK: - View State

/// 字幕状态 —— Observable 让 SwiftUI View 跟着自动刷新
@Observable
@MainActor
final class TranscriptState {
    var text: String = ""
    var isVisible: Bool = false
}

// MARK: - SwiftUI 字幕条

struct VoiceTranscriptView: View {
    @Bindable var state: TranscriptState

    var body: some View {
        ZStack {
            if state.isVisible {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                    Text(state.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(.black.opacity(0.78))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 0)
        .animation(AnimTok.smooth, value: state.isVisible)
        // **不要 animate value: state.text** —— text 一秒变 20+ 次，每次都启一段动画
        // 会堆叠成永远跑不完的 transition 队列，主线程被 SwiftUI flushTransactions 钉住。
        // 文字节点本身换内容时让 SwiftUI 做 crossfade 默认就足够柔和。
    }
}
