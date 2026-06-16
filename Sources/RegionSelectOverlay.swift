import AppKit
import SwiftUI

/// 圈选截图控制器 —— 自建全屏 overlay 让用户拖框选区，返回裁好的 CGImage（取消则 nil）。
///
/// **为什么自建而不是系统 `screencapture -i`**：系统十字光标 UI 是 macOS 黑盒，无法注入光效。
/// 自建才能画 Apple Intelligence 彩色流光选框（圈选当下就有质感），素材复用 `IntelligenceGlowView.appleAIColors`。
///
/// **冻结截图方案**：先 SCK 截下鼠标所在屏冻结成静态图全屏铺底，用户在冻结图上拖框，
/// 松手直接裁冻结图 —— 不会把暗化遮罩 / 选框拍进去，也不用等"先收 overlay 再截屏"的时序。
///
/// **决策 #1 安全**：本 overlay 是独立 NSWindow，创建时一次性给 `screen.frame` 后**永不 setFrame**，
/// hosting view `sizingOptions = []`（决策 #6）禁掉反向 resize —— 跟灵动岛那个会崩的 setFrame 无关。
@MainActor
final class RegionCaptureController {
    static let shared = RegionCaptureController()

    private var window: RegionCaptureWindow?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var frozenImage: CGImage?
    /// 截屏所在屏的 point 尺寸 —— 用于把选区 point 坐标换算成 image 像素坐标
    private var screenPointSize: CGSize = .zero
    private var escMonitor: Any?

    private init() {}

    /// 起一次圈选。返回裁好的区域 CGImage；用户按 Esc / 点一下没拖 / 无屏幕权限 → 返回 nil。
    /// 调用方应在调用前把自己的窗口收起（避免被一起拍进冻结图）。
    func capture() async -> CGImage? {
        // 防重入：已经在圈选就忽略
        guard continuation == nil else { return nil }

        // 1) 截鼠标所在屏冻结。captureMouseScreenAsCGImage 已排除自家窗口；无权限时返回 nil
        guard let cg = await ScreenCapture.captureMouseScreenAsCGImage(),
              let screen = mouseScreen() else {
            return nil
        }
        screenPointSize = screen.frame.size
        frozenImage = cg

        return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            self.continuation = cont
            self.showOverlay(on: screen, frozen: cg)
        }
    }

    private func mouseScreen() -> NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(loc) }) ?? NSScreen.main
    }

    private func showOverlay(on screen: NSScreen, frozen: CGImage) {
        let w = RegionCaptureWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // 截屏遮罩级别 —— 盖过菜单栏 / 灵动岛 / 一切（跟系统截图工具同档）
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = false

        let nsImage = NSImage(cgImage: frozen, size: screen.frame.size)
        // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 反推约束崩（铁律 2026-06-14 升级：
        // 即便 borderless + 固定尺寸 + 永不 setFrame 也中，跟 Pin/系统状态卡同类）→ 转 NSHostingController。
        let host = NSHostingController(rootView: RegionCaptureView(
            background: nsImage,
            onComplete: { [weak self] rect in self?.finish(selectionPointRect: rect) },
            onCancel: { [weak self] in self?.finish(selectionPointRect: nil) }
        ))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }   // 决策 #6
        w.contentViewController = host
        host.view.autoresizingMask = [.width, .height]
        w.setContentSize(screen.frame.size)
        self.window = w

        // Esc 取消（local monitor，比 SwiftUI keyboardShortcut 在 borderless 窗口上更可靠）
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {   // kVK_Escape
                self?.finish(selectionPointRect: nil)
                return nil
            }
            return event
        }

        NSCursor.crosshair.push()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 收尾：拆 monitor / 还原光标 / 关窗 → 把选区 point 矩形换算成 image 像素并裁剪 → resume。
    private func finish(selectionPointRect: CGRect?) {
        guard let cont = continuation else { return }
        continuation = nil

        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        NSCursor.pop()
        window?.orderOut(nil)
        window = nil

        var result: CGImage? = nil
        if let rectPt = selectionPointRect,
           rectPt.width > 4, rectPt.height > 4,
           let cg = frozenImage,
           screenPointSize.width > 0, screenPointSize.height > 0 {
            // SwiftUI 坐标原点左上，CGImage.cropping 也按左上原点 —— 不需要翻 Y。
            // 选区 point → image 像素：乘 (像素宽/点宽)（≈ backingScaleFactor）
            let sx = CGFloat(cg.width) / screenPointSize.width
            let sy = CGFloat(cg.height) / screenPointSize.height
            let cropPx = CGRect(
                x: rectPt.minX * sx,
                y: rectPt.minY * sy,
                width: rectPt.width * sx,
                height: rectPt.height * sy
            ).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            if !cropPx.isEmpty {
                result = cg.cropping(to: cropPx)
            }
        }
        frozenImage = nil
        cont.resume(returning: result)
    }
}

/// 需要 canBecomeKey=true 才能收 Esc keyDown / 让 SwiftUI 手势聚焦
final class RegionCaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI 圈选视图

private struct RegionCaptureView: View {
    let background: NSImage
    let onComplete: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var selection: CGRect? = nil
    @State private var isDragging = false

    private var aiColors: [Color] { IntelligenceGlowView.appleAIColors }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 冻结的屏幕截图铺底（aspect 跟屏幕一致，resizable 填满不会变形）
                Image(nsImage: background)
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                // 暗化遮罩：全屏一个 rect + 选区一个 rect，even-odd 填充 → 选区被"挖空"提亮
                Canvas { ctx, size in
                    var path = Path()
                    path.addRect(CGRect(origin: .zero, size: size))
                    if let sel = selection {
                        path.addRect(sel)
                    }
                    ctx.fill(path, with: .color(.black.opacity(0.42)), style: FillStyle(eoFill: true))
                }

                // 选框：Apple Intelligence 彩色流光（外发光 + 锐边 + 内白边）
                if let sel = selection, sel.width > 1, sel.height > 1 {
                    selectionBorder(rect: sel)
                    sizeBadge(rect: sel, in: geo.size)
                }

                // 起手提示（还没拖时居中显示）
                if selection == nil {
                    hint
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        isDragging = true
                        selection = normalizedRect(
                            from: value.startLocation,
                            to: value.location,
                            in: geo.size
                        )
                    }
                    .onEnded { value in
                        let r = normalizedRect(
                            from: value.startLocation,
                            to: value.location,
                            in: geo.size
                        )
                        isDragging = false
                        // 拖出了有效大小 → 完成；只是点了一下（几乎没拖）→ 当取消
                        if r.width > 4, r.height > 4 {
                            onComplete(r)
                        } else {
                            onCancel()
                        }
                    }
            )
        }
        .ignoresSafeArea()
    }

    /// 两点构造矩形并 clamp 到屏幕范围内
    private func normalizedRect(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGRect {
        let minX = max(0, min(a.x, b.x))
        let minY = max(0, min(a.y, b.y))
        let maxX = min(size.width, max(a.x, b.x))
        let maxY = min(size.height, max(a.y, b.y))
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func selectionBorder(rect sel: CGRect) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 3.0) / 3.0) * 360
            let grad = AngularGradient(colors: aiColors, center: .center, angle: .degrees(angle))
            ZStack {
                // 外发光
                Rectangle()
                    .strokeBorder(grad, lineWidth: 3)
                    .blur(radius: 4)
                    .opacity(0.85)
                // 锐边
                Rectangle()
                    .strokeBorder(grad, lineWidth: 1.5)
                // 内白边（玻璃质感）
                Rectangle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 0.5)
            }
            .frame(width: sel.width, height: sel.height)
            .position(x: sel.midX, y: sel.midY)
        }
        .allowsHitTesting(false)
    }

    /// 选区尺寸徽章 —— 贴在选区左上角上方
    private func sizeBadge(rect sel: CGRect, in size: CGSize) -> some View {
        let label = "\(Int(sel.width)) × \(Int(sel.height))"
        // 默认放选区上方；太靠顶就放到选区内部上沿
        let badgeY = sel.minY > 24 ? sel.minY - 14 : sel.minY + 14
        return Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.6)))
            .position(x: min(max(sel.minX + 30, 40), size.width - 40), y: badgeY)
            .allowsHitTesting(false)
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "viewfinder")
                .font(.system(size: 13, weight: .medium))
            Text(L("region.hint"))
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.black.opacity(0.55))
                .overlay(
                    Capsule().strokeBorder(
                        AngularGradient(colors: aiColors, center: .center),
                        lineWidth: 1
                    )
                    .opacity(0.7)
                )
        )
        .allowsHitTesting(false)
    }
}
