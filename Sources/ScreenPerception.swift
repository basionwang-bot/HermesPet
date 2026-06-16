import AppKit
import CoreGraphics

/// 屏幕感知层（v1.6「AI 看屏幕」里程碑 2）—— 把「眼睛」和「手」对齐。
///
/// 职责：看一个窗口 → 截图 → 本地 OCR → 产出每段文字 **+ 它在屏幕上的坐标**。
/// 有了屏幕坐标，AI 说「点『发送』」时，我们就能查到「发送」那段字的位置、直接喂给
/// `ScreenActuator.click(at:)` 真去点。这是「OCR 驱动操作」的核心一环（决策见 TODO 里程碑总览）。
///
/// 坐标系：输出的 `screenRect` 是**屏幕点坐标、左上角原点**（CGEvent 那套），可直接交给 `ScreenActuator`。
enum ScreenPerception {

    /// 屏幕上一段可识别的文字元素。
    struct TextElement: Sendable, Identifiable {
        let id: Int
        let text: String
        /// 屏幕坐标（点，左上角原点）—— 可直接喂 ScreenActuator
        let screenRect: CGRect
        /// 点击用的中心点
        var center: CGPoint { CGPoint(x: screenRect.midX, y: screenRect.midY) }
    }

    /// 看一个窗口：截图 → OCR → 每段文字 + 屏幕坐标。失败 / 没权限 / 没文字 → 空数组。
    static func readWindow(id: CGWindowID, quality: VisionOCR.Quality = .accurate) async -> [TextElement] {
        guard let shot = await ScreenCapture.captureWindowImage(id: id) else { return [] }
        return await mapAndOCR(image: shot.image, frame: shot.frame, quality: quality)
    }

    /// 已经有截图 + 窗口 frame 时直接 OCR + 映射（接管循环复用：差分判定已截过图，别重复截）。
    static func mapAndOCR(image: CGImage, frame: CGRect, quality: VisionOCR.Quality = .accurate) async -> [TextElement] {
        let boxes = await VisionOCR.recognizeBoxes(in: image, quality: quality)
        return mapToScreen(boxes, windowFrame: frame)
    }

    /// 把 OCR 的归一化方框（左下角原点）映射成屏幕坐标方框（左上角原点，点）。
    /// - Vision box：x/y/w/h ∈ [0,1]，y 从**底**往上算。
    /// - 目标：屏幕点坐标，y 从**顶**往下算，叠加窗口在屏幕上的 frame 原点。
    static func mapToScreen(_ boxes: [VisionOCR.TextBox], windowFrame frame: CGRect) -> [TextElement] {
        boxes.enumerated().map { idx, tb in
            let b = tb.box
            let sx = frame.minX + b.minX * frame.width
            // 翻 y：归一化方框顶边在 top-left 体系下 = 1 - box.maxY
            let sy = frame.minY + (1 - b.maxY) * frame.height
            let sw = b.width * frame.width
            let sh = b.height * frame.height
            return TextElement(
                id: idx,
                text: tb.text,
                screenRect: CGRect(x: sx, y: sy, width: sw, height: sh)
            )
        }
    }

    /// 在已知文字元素里找最匹配某个标签的那个（给「点击('发送')」这类高层动作用）。
    /// 先找完全相等，再找包含，最后找标签包含元素文字（短标签场景）。找不到返回 nil。
    static func findElement(matching label: String, in elements: [TextElement]) -> TextElement? {
        let target = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { return nil }
        if let exact = elements.first(where: { $0.text == target }) { return exact }
        if let contains = elements.first(where: { $0.text.contains(target) }) { return contains }
        return elements.first(where: { target.contains($0.text) })
    }
}
