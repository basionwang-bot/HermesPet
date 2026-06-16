import SwiftUI
import AppKit

/// 头像裁剪窗（iOS 那种圆形裁剪：拖动平移 + 捏合/滑块缩放 → 圆形预览 → 渲染成方图存盘）。
/// 用独立 NSWindow 弹出（设置在 popover 里，sheet 不稳；守决策 #1 用独立窗思路）。
/// 渲染走 `ImageRenderer`（macOS 13+），保证导出和预览所见一致。
@MainActor
final class AvatarCropController: NSObject {
    static let shared = AvatarCropController()
    private var window: NSWindow?
    private override init() { super.init() }

    func present(image: NSImage, onCrop: @escaping (NSImage) -> Void) {
        close()
        let view = AvatarCropView(
            image: image,
            onUse: { [weak self] cropped in onCrop(cropped); self?.close() },
            onCancel: { [weak self] in self?.close() }
        )
        // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 反推约束崩 → 转 NSHostingController。
        let hosting = NSHostingController(rootView: view)
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = L("settings.account.crop.title")
        win.level = .modalPanel
        win.isReleasedWhenClosed = false
        win.contentViewController = hosting
        hosting.view.autoresizingMask = [.width, .height]
        win.setContentSize(NSSize(width: 300, height: 400))
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil); window = nil }
}

struct AvatarCropView: View {
    let image: NSImage
    let onUse: (NSImage) -> Void
    let onCancel: () -> Void

    private let viewport: CGFloat = 240

    @State private var committedScale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var committedOffset: CGSize = .zero
    @GestureState private var dragT: CGSize = .zero

    private var scale: CGFloat { min(max(committedScale * pinch, 1), 5) }
    private var offset: CGSize {
        CGSize(width: committedOffset.width + dragT.width,
               height: committedOffset.height + dragT.height)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(L("settings.account.crop.hint"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            cropArea

            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $committedScale, in: 1...5)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: viewport)

            HStack {
                Button(L("settings.account.crop.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("settings.account.crop.use")) { render() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: viewport)
        }
        .padding(20)
        .frame(width: 280)
    }

    private var cropArea: some View {
        ZStack {
            Color.black.opacity(0.06)
            imageLayer
        }
        .frame(width: viewport, height: viewport)
        .clipped()
        .overlay(darkenOutsideCircle)
        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            MagnificationGesture()
                .updating($pinch) { v, s, _ in s = v }
                .onEnded { v in committedScale = min(max(committedScale * v, 1), 5) }
                .simultaneously(with:
                    DragGesture()
                        .updating($dragT) { v, s, _ in s = v.translation }
                        .onEnded { v in
                            committedOffset.width += v.translation.width
                            committedOffset.height += v.translation.height
                        }
                )
        )
    }

    private var imageLayer: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: viewport, height: viewport)
            .scaleEffect(scale)
            .offset(offset)
    }

    /// 圆形外暗化（iOS 裁剪那种焦点圈）
    private var darkenOutsideCircle: some View {
        Rectangle()
            .fill(Color.black.opacity(0.42))
            .mask(
                ZStack {
                    Rectangle()
                    Circle().blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            .allowsHitTesting(false)
    }

    /// 把当前平移/缩放的可见方区渲染成图片（与预览所见一致）。存的是方图，显示处再裁圆。
    @MainActor private func render() {
        let s = scale, o = offset
        let content = ZStack {
            Color.white
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: viewport, height: viewport)
                .scaleEffect(s)
                .offset(o)
        }
        .frame(width: viewport, height: viewport)
        .clipped()

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        onUse(renderer.nsImage ?? image)
    }
}
