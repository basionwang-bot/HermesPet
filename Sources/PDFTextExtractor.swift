import Foundation
import PDFKit
import CoreGraphics

/// 把 PDF 抽成纯文本，供「在线 AI」(`.directAPI`) 内联进 prompt。
///
/// **为什么需要**：在线 AI 走 OpenAI 兼容模型（DeepSeek / Kimi / 智谱 等），这些模型
/// 读不了 PDF 二进制 file part —— 直接传 `{type:"file",mime:"application/pdf"}` 会被
/// opencode 报「file part media type not supported」或被模型忽略。Claude Code / Codex /
/// Hermes 有本机文件工具能自己 Read 解析 PDF，唯独在线 AI 没有，所以在客户端本地把
/// PDF 拆成纯文本再喂给模型。
///
/// **两条路径**：
/// - 有文字层（电子书 / 导出报告 / 网页存的 PDF）：逐页 `PDFPage.string` 拼接，秒出。
/// - 扫描版（拍照 / 扫描的合同，没有文字层）：逐页渲染成图片 → 复用 `VisionOCR` 识别。
///
/// **防爆 context**：文字截到 `maxChars`；OCR 最多跑 `maxOCRPages` 页（逐页 .accurate
/// 慢，几十页会拖很久），超出都标记 `truncated`。
///
/// **线程**：`nonisolated`，整个抽取在后台跑，不碰 @MainActor（PDFDocument / OCR 都是耗时 IO）。
enum PDFTextExtractor {

    /// 抽取结果。`text` 已截断到上限；`isEmpty` 表示连一个字都没抽到（加密 / 损坏 / 纯空白）。
    struct Result {
        let text: String
        let pageCount: Int
        let usedOCR: Bool      // 走了扫描版 OCR 路径
        let truncated: Bool    // 因字数 / 页数上限被截断
        let isEmpty: Bool      // 完全抽不出内容
    }

    /// 抽取 PDF 文本。`maxChars` 默认 6 万字（≈ 一本小册子 / 十几 k token），`maxOCRPages` 扫描版最多识别页数。
    nonisolated static func extract(
        from url: URL,
        maxChars: Int = 60_000,
        maxOCRPages: Int = 30
    ) async -> Result {
        guard let doc = PDFDocument(url: url) else {
            return Result(text: "", pageCount: 0, usedOCR: false, truncated: false, isEmpty: true)
        }
        let pageCount = doc.pageCount

        // 1. 先试文字层 —— 绝大多数 PDF 都有，秒出。
        var collected = ""
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let s = page.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected += s
                collected += "\n\n"
            }
            if collected.count >= maxChars { break }
        }
        let textLayer = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        // 抽到足量文字（≥ 20 字符，排除「只有页码 / 水印」这种伪文字层）→ 走文字版
        if textLayer.count >= 20 {
            let truncated = textLayer.count > maxChars
            return Result(
                text: String(textLayer.prefix(maxChars)),
                pageCount: pageCount,
                usedOCR: false,
                truncated: truncated,
                isEmpty: false
            )
        }

        // 2. 文字层几乎是空的 → 扫描版，逐页渲染 + OCR。
        var ocrText = ""
        let ocrPageLimit = min(pageCount, maxOCRPages)
        for i in 0..<ocrPageLimit {
            guard let page = doc.page(at: i),
                  let cg = renderPageToCGImage(page) else { continue }
            // 扫描件要给用户/AI 看，用 .accurate（中文精度高）
            if let recognized = await VisionOCR.recognizeText(in: cg, quality: .accurate),
               !recognized.isEmpty {
                ocrText += recognized
                ocrText += "\n\n"
            }
            if ocrText.count >= maxChars { break }
        }
        let ocr = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if ocr.isEmpty {
            // 扫描件也 OCR 不出东西（空白页 / 纯图无文字 / 加密）
            return Result(text: "", pageCount: pageCount, usedOCR: true, truncated: false, isEmpty: true)
        }
        let truncated = ocr.count > maxChars || pageCount > ocrPageLimit
        return Result(
            text: String(ocr.prefix(maxChars)),
            pageCount: pageCount,
            usedOCR: true,
            truncated: truncated,
            isEmpty: false
        )
    }

    /// 把 PDF 单页渲染成 CGImage 给 OCR 用。按 `scale` 倍率提清晰度（扫描件文字小，2x 更准）。
    /// 白底打底（PDF 透明区直接 OCR 会糊），坐标系按 PDF mediaBox 对齐。
    nonisolated private static func renderPageToCGImage(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0, width * height < 40_000_000 else { return nil }  // 超大页防内存爆

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 白底
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // CGContext 与 PDF 同为左下原点；缩放后按 mediaBox.origin 对齐（裁剪框非零偏移时也正确）
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)

        return ctx.makeImage()
    }
}
