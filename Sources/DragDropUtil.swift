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
    @MainActor
    static func handleProviders(
        _ providers: [NSItemProvider],
        onImage: @escaping @MainActor (Data) -> Void,
        onDocument: @escaping @MainActor (URL) -> Void
    ) -> Bool {
        var handled = false
        for provider in providers {
            // 直接是 NSImage（截图工具、浏览器拖图 等）—— 只能拿到 Data，没本地路径
            if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { item, _ in
                    if let img = item as? NSImage, let png = pngData(from: img) {
                        DispatchQueue.main.async { onImage(png) }
                    }
                }
                continue
            }
            // 文件 URL（Finder 拖文件）
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data,
                          let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    processFile(url, onImage: { png in
                        DispatchQueue.main.async { onImage(png) }
                    }, onDocument: { docURL in
                        DispatchQueue.main.async { onDocument(docURL) }
                    })
                }
            }
        }
        return handled
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
