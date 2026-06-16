import CoreGraphics
import Vision

/// 公共 Vision OCR 工具 —— 把一张 CGImage 识别成文字。
///
/// 原本埋在 `UserIntentRecorder.performOCR`，现在抽出来供「圈选截图问 AI」和「意图记录」共用。
///
/// **性能策略**（沿用 v1.2.9 调优）：
/// - `.fast` 替代 `.accurate`：速度提升 2-5×
/// - `usesLanguageCorrection = false`：截屏 OCR 拼写矫正价值低，关掉省一半时间
/// - 输入图先 downsample 到长边 ≤ 1600pt：5K 屏全分辨率 OCR 太贵
///
/// **线程**：`VNImageRequestHandler.perform` 是 blocking IO，丢到后台 utility 队列跑，完成后 resume。
enum VisionOCR {

    /// 识别图中文字。中英混排（zh-Hans + en-US），按从上到下、从左到右排序后用换行拼接。
    /// 识别精度档位。
    /// - `.fast`：`.fast` 级别 + 关语言矫正 + 降采样到 1600px。为**后台意图快速扫描**优化
    ///   （只需判断屏幕有没有关键词），中文精度低，会把汉字识别成形近字/错字。
    /// - `.accurate`：`.accurate` 级别 + 开中文语言矫正 + 高分辨率（≤4096px）。为**用户主动圈选**
    ///   优化，要的是准确文字给用户/AI 看。慢一些（几百 ms），但中文质量大幅提升。
    enum Quality {
        case fast
        case accurate
    }

    /// 识别图中文字。中英混排（zh-Hans + en-US），按从上到下、从左到右排序后用换行拼接。
    /// 识别不到任何文字返回 nil。
    nonisolated static func recognizeText(in cgImage: CGImage, quality: Quality = .fast) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // accurate 保留高分辨率（≤4096，中文越清越准）；fast 缩到 1600 提速
                let maxEdge: CGFloat = (quality == .accurate) ? 4096 : 1600
                let processedImage = downsampleIfNeeded(cgImage, maxEdge: maxEdge) ?? cgImage

                let request = VNRecognizeTextRequest { (req, _) in
                    guard let results = req.results as? [VNRecognizedTextObservation] else {
                        cont.resume(returning: nil)
                        return
                    }
                    // 按 boundingBox 从上到下、从左到右排序（Y 原点在 image 底部）
                    let sorted = results.sorted { a, b in
                        if abs(a.boundingBox.origin.y - b.boundingBox.origin.y) > 0.02 {
                            return a.boundingBox.origin.y > b.boundingBox.origin.y
                        }
                        return a.boundingBox.origin.x < b.boundingBox.origin.x
                    }
                    let text = sorted
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    cont.resume(returning: text.isEmpty ? nil : text)
                }
                // 中文识别 macOS 13+ 支持，需要显式声明
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.recognitionLevel = (quality == .accurate) ? .accurate : .fast
                request.usesLanguageCorrection = (quality == .accurate)

                let handler = VNImageRequestHandler(cgImage: processedImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// 一段被识别出的文字 + 它在图中的归一化方框。
    /// `box`：Vision 原生归一化坐标 [0,1]、**原点在图片左下角**（调用方映射到屏幕时要翻 y）。
    struct TextBox: Sendable {
        let text: String
        let box: CGRect
    }

    /// 识别图中文字，**保留每段的方框坐标**（里程碑 2：要把文字对上屏幕位置）。
    /// 跟 `recognizeText` 同一套引擎，只是不把结果 join 成字符串、而是连方框一起返回。
    /// 默认 `.accurate`——定位要准，中文方框才贴合。
    nonisolated static func recognizeBoxes(in cgImage: CGImage, quality: Quality = .accurate) async -> [TextBox] {
        await withCheckedContinuation { (cont: CheckedContinuation<[TextBox], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let maxEdge: CGFloat = (quality == .accurate) ? 4096 : 1600
                let processedImage = downsampleIfNeeded(cgImage, maxEdge: maxEdge) ?? cgImage
                // 降采样不影响归一化方框（box 是 [0,1] 比例，与像素尺寸无关）

                let request = VNRecognizeTextRequest { (req, _) in
                    guard let results = req.results as? [VNRecognizedTextObservation] else {
                        cont.resume(returning: [])
                        return
                    }
                    let boxes: [TextBox] = results.compactMap { obs in
                        guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
                        return TextBox(text: s, box: obs.boundingBox)
                    }
                    cont.resume(returning: boxes)
                }
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.recognitionLevel = (quality == .accurate) ? .accurate : .fast
                request.usesLanguageCorrection = (quality == .accurate)

                let handler = VNImageRequestHandler(cgImage: processedImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
    }

    /// 把大图按比例缩到长边 ≤ maxEdge。已经够小（长边 < maxEdge）则 return nil 让调用方用原图。
    /// 用 CoreGraphics 重绘到小尺寸 context，速度 < 20ms。
    nonisolated static func downsampleIfNeeded(_ image: CGImage, maxEdge: CGFloat = 1600) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longSide = max(w, h)
        guard longSide > maxEdge else { return nil }

        let scale = maxEdge / longSide
        let newW = Int(w * scale)
        let newH = Int(h * scale)

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.bitmapInfo
        let bitsPerComponent = image.bitsPerComponent

        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }
}
