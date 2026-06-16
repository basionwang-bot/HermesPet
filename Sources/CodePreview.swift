import SwiftUI
import AppKit
import PDFKit

/// 工作台预览区的轻量代码高亮 —— 正则着色（数字→关键字→字符串→注释，后者覆盖前者），
/// 无第三方依赖。颜色取中等明度，深/浅主题底色下都可读。
enum CodeHighlighter {
    private static let kKeyword = NSColor(calibratedRed: 0.69, green: 0.49, blue: 0.96, alpha: 1) // 紫
    private static let kString  = NSColor(calibratedRed: 0.40, green: 0.70, blue: 0.47, alpha: 1) // 绿
    private static let kNumber  = NSColor(calibratedRed: 0.87, green: 0.58, blue: 0.30, alpha: 1) // 橙

    /// 各语言常见关键字（纯字母，避免正则 \b 边界对符号失效）。
    private static func keywords(_ ext: String) -> [String] {
        let common = ["if","else","for","while","return","break","continue","switch","case","default",
                      "class","struct","enum","func","function","def","var","let","const","import","from",
                      "public","private","protected","static","new","true","false","null","nil","void",
                      "int","string","bool","float","double","this","super"]
        switch ext {
        case "swift":
            return common + ["guard","extension","protocol","self","init","deinit","weak","unowned",
                             "async","await","throws","throw","try","in","where","some","any","actor","lazy","mutating"]
        case "js","ts","tsx","jsx":
            return common + ["async","await","export","interface","type","extends","implements","yield",
                             "typeof","instanceof","undefined","NaN"]
        case "py":
            return common + ["elif","lambda","with","as","not","and","or","is","None","True","False",
                             "self","yield","global","pass","raise","except","finally","async","await"]
        case "go":
            return common + ["package","go","chan","defer","range","map","interface","select","fallthrough"]
        case "rs":
            return common + ["fn","mut","impl","trait","pub","use","mod","match","loop","unsafe","async","await","move","ref","Some","None","Ok","Err"]
        default:
            return common
        }
    }

    static func make(_ code: String, ext: String, theme: WorkbenchTheme) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor(theme.textPrimary)
        ])
        let len = (code as NSString).length
        func paint(_ pattern: String, _ color: NSColor, _ opts: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            re.enumerateMatches(in: code, range: NSRange(location: 0, length: len)) { m, _, _ in
                if let m { attr.addAttribute(.foregroundColor, value: color, range: m.range) }
            }
        }
        // 顺序很重要：后涂的覆盖先涂的（字符串覆盖里面的关键字/数字、注释覆盖一切）
        paint(#"\b\d+(\.\d+)?\b"#, kNumber)
        let kw = keywords(ext)
        if !kw.isEmpty {
            paint(#"\b(\#(kw.joined(separator: "|")))\b"#, kKeyword)
        }
        paint(#""[^"\n]*"|'[^'\n]*'"#, kString)               // 单/双引号字符串
        paint(#"//[^\n]*"#, NSColor(theme.textTertiary))       // 行注释 //
        paint(#"/\*[\s\S]*?\*/"#, NSColor(theme.textTertiary)) // 块注释 /* */
        if ["py","sh","rb","yaml","yml","toml"].contains(ext) {
            paint(#"#[^\n]*"#, NSColor(theme.textTertiary))     // # 注释（脚本/配置语言）
        }
        return attr
    }
}

/// 只读、可选中、可横向滚动的代码视图（NSTextView 对大文件性能好）。
struct CodeTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let background: Color

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 16, height: 16)
        tv.textContainer?.lineFragmentPadding = 0
        // 不自动换行 → 长代码行横向滚动
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.textStorage?.string != attributed.string || context.coordinator.lastLen != attributed.length {
            tv.textStorage?.setAttributedString(attributed)
            context.coordinator.lastLen = attributed.length
        }
        let bg = NSColor(background)
        tv.backgroundColor = bg
        scroll.backgroundColor = bg
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastLen = -1 }
}

/// 工作台 PDF 预览 —— PDFKit 原生渲染（翻页 / 缩放 / 选中复制），只换文件时重载（避免重置滚动）。
struct PDFKitView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true                 // 自适应宽度
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .clear
        if let url { v.document = PDFDocument(url: url); context.coordinator.lastURL = url }
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        guard context.coordinator.lastURL != url else { return }
        context.coordinator.lastURL = url
        v.document = url.flatMap { PDFDocument(url: $0) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastURL: URL? }
}
