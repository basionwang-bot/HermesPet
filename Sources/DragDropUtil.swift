import AppKit
import UniformTypeIdentifiers

/// 拖入文件的统一处理工具。
/// 全聊天窗口的 onDrop 都走这里：
/// - 图片（PNG/JPG/HEIC 等）→ 调 onImage(Data)
/// - 其余文件（PDF / txt / md / 代码 / 任意类型）→ 调 onDocument(URL)，**只回传路径**
///
/// 文档不再读全文 —— Claude/Codex 模式下让 AI 用自己的 Read 工具按路径访问，速度更快、不占 context。
/// Hermes 模式（HTTP API）无法访问本地文件，由 ViewModel 拦截后弹错误提示。
enum DragDropUtil {

    /// SwiftUI .onDrop(of:) 用这个 UTType 列表 —— 故意只用最通用的两个，
    /// 加更多反而会让 macOS 拒绝某些拖入源（mail 附件、Finder 等）
    static let acceptedUTTypes: [UTType] = [.fileURL, .image]

    /// onDrop perform 直接调这个。返回 true 表示有 provider 被处理。
    ///
    /// ⚠️⚠️ 决策 #5 + 决策 #22（2026-06-02 反复踩崩后定论）：
    /// `NSItemProvider.loadObject/loadDataRepresentation` 的 completionHandler 在 **后台队列**
    /// （`com.apple.Foundation.NSItemProvider-callback-queue`）回调。崩溃链：
    /// `closure #2 → swift_task_isCurrentExecutor → dispatch_assert_queue_fail → SIGTRAP`。
    ///
    /// 真正的根因 = **回调参数 `onImage`/`onDocument` 的「类型」带 `@MainActor`**
    /// （mangled 里是 `...DataVYbScMYcc...` = `@Sendable @MainActor (Data)->Void`）。
    /// 只要参数类型是 @MainActor 闭包，后台闭包里**构造 `Task { @MainActor in onImage(...) }` 时**，
    /// 编译器就得插执行器断言来验证 MainActor 隔离 → 后台队列上断言失败 → 崩。
    /// 给闭包加 `@Sendable`、给函数加 `nonisolated`、把跳主线程换成 `Task { @MainActor in }`——
    /// **三种都试过，崩溃栈字节级不变**，因为它们都没动「参数类型仍是 @MainActor 闭包」这一点。
    ///
    /// ✅ 唯一稳妥修法（本版）：
    /// 1. **回调参数类型剥掉 `@MainActor`**，改成纯 `@Sendable (Data)->Void` / `@Sendable (URL)->Void`。
    ///    后台闭包捕获/调用它们时编译器不再插任何执行器断言。
    /// 2. 跳主线程用 **`DispatchQueue.main.async`**（GCD 派发，不带 actor 执行器断言），
    ///    **不用 `Task { @MainActor in }`**（它会插 isCurrentExecutor 检查）。
    /// 3. `@MainActor` 边界**上移到调用方**：onDrop 闭包本身在主线程，那里把
    ///    `viewModel.addPendingImage` 包成 `@Sendable` 转发器（内部 `DispatchQueue.main.async`）。
    nonisolated static func handleProviders(
        _ providers: [NSItemProvider],
        onImage: @escaping @Sendable (Data) -> Void,
        onDocument: @escaping @Sendable (URL) -> Void
    ) -> Bool {
        var handled = false
        for provider in providers {
            // 直接是 NSImage（截图工具、浏览器拖图 等）—— 只能拿到 Data，没本地路径
            if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { @Sendable item, _ in
                    guard let img = item as? NSImage, let png = pngData(from: img) else { return }
                    onImage(png)   // 参数已是 @Sendable 非隔离，后台调安全；主线程派发由 onImage 内部负责
                }
                continue
            }
            // 文件 URL（Finder 拖文件）
            // ⚠️⚠️ 决策 #22 终章（反汇编实锤）：**必须用 `loadObject(ofClass: URL.self)`，
            // 绝不能用 `loadDataRepresentation(forTypeIdentifier: fileURL)`**。
            // macOS 26 SDK 里 `loadDataRepresentation` 的 completionHandler 被标成 **@MainActor**，
            // 不管你给的闭包标 @Sendable、函数标 nonisolated，编译器都会把它钉成 @MainActor 闭包
            // → 后台队列回调时入口插的 `swift_task_isCurrentExecutor` 断言失败 → SIGTRAP（必崩）。
            // 反汇编对比：loadDataRepresentation 的 closure 体内有 isCurrentExecutor 指令；
            // `loadObject(ofClass:)`（NSImage / URL 都是）的 completionHandler 是纯 @Sendable，无该指令。
            // CanvasView.handleDrop 一直用 loadObject(URL.self)，从无此崩溃，正是佐证。
            else if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                    guard let url = url else { return }
                    processFile(url, onImage: onImage, onDocument: onDocument)
                }
            }
        }
        return handled
    }

    /// 把一个 @MainActor 回调包成「在任意线程都能安全调用」的 @Sendable 转发器：
    /// 内部用 `DispatchQueue.main.async`（纯 GCD 派发，**不带 actor 执行器断言**）跳主线程，
    /// 到主线程后再 `MainActor.assumeIsolated` 安全调原 @MainActor 闭包。
    /// 调用方在主线程（onDrop 闭包）调这个生成转发器，传给 handleProviders。
    @MainActor
    static func mainActorForwarder<T: Sendable>(
        _ body: @escaping @MainActor (T) -> Void
    ) -> @Sendable (T) -> Void {
        // body 是 @MainActor @Sendable 闭包，本身就是 Sendable，可直接进 @Sendable 转发器。
        // 内部 DispatchQueue.main.async（纯 GCD、无执行器断言）跳主线程，再 assumeIsolated 安全调用。
        return { value in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    body(value)
                }
            }
        }
    }

    /// 根据 URL 扩展名分流：
    /// - 图片扩展名 → 优先**保留原 Data 不转码**（PNG/JPG 直接读字节，体积一致）
    ///   仅 HEIC/WEBP 等模型不通用的格式才转 PNG（必要转码）
    /// - 其他所有文件 → 只回传 URL，让 AI 自己用 Read 工具去读
    nonisolated static func processFile(
        _ url: URL,
        onImage: @escaping @Sendable (Data) -> Void,
        onDocument: @escaping @Sendable (URL) -> Void
    ) {
        let ext = url.pathExtension.lowercased()

        // 模型原生支持的格式：直接读原 bytes，省去 NSImage decode + re-encode 的开销
        // （一张 200KB JPG 不转 PNG 还是 200KB，转完可能变 800KB+，base64 后体积翻 5 倍）
        let nativeImageExts: Set<String> = ["png", "jpg", "jpeg", "gif"]
        if nativeImageExts.contains(ext), let data = try? Data(contentsOf: url) {
            onImage(data)
            return
        }

        // 其他图片格式（HEIC/WEBP/BMP/TIFF）：模型一般不支持原生 → 必须转 PNG
        let convertibleImageExts: Set<String> = ["heic", "webp", "bmp", "tiff"]
        if convertibleImageExts.contains(ext), let img = NSImage(contentsOf: url), let png = pngData(from: img) {
            onImage(png)
            return
        }

        // 非图片：统一只回传路径，不再读内容
        onDocument(url)
    }

    nonisolated static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
