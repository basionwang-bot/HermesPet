import AppKit
import Foundation

/// 崩溃日志扫描 + 一键上报到 GitHub Issue。
///
/// **macOS crash log 现状**：app 崩溃后系统自动写到 `~/Library/Logs/DiagnosticReports/`
/// 文件名格式 `HermesPet-{date}-{pid}.ips`（macOS 11+ JSON 格式，老版本是 .crash 纯文本）。
/// 99% 用户**不知道这个目录存在**，更不会主动找 crash file 发给作者。
///
/// **本类做的事**：
/// 1. 扫描 `~/Library/Logs/DiagnosticReports/` 拿到所有 `HermesPet*.ips` / `*.crash`
/// 2. 按修改时间倒序
/// 3. 提取关键信息（version, OS, 崩溃线程, exception type）做摘要
/// 4. 用户点「上报」→ 把完整 crash log 复制到剪贴板 + 跳转 GitHub issue new 页面
///    （URL 预填 title + body 提示用户粘贴）
@MainActor
@Observable
final class CrashReporter {
    static let shared = CrashReporter()

    /// 最近一次崩溃记录（首次扫描后填）
    private(set) var latestCrash: CrashRecord?
    /// 所有崩溃记录，按时间倒序
    private(set) var allCrashes: [CrashRecord] = []
    /// 扫描中
    private(set) var isScanning = false

    private static let owner = "basionwang-bot"
    private static let repo = "HermesPet"

    private init() {}

    // MARK: - 扫描

    /// 扫描 ~/Library/Logs/DiagnosticReports/ 拿到 HermesPet 相关的 crash 文件
    /// 启动时调一次，用户进设置面板时也会再调一次保证数据新鲜
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let fm = FileManager.default
        let reportsDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? fm.contentsOfDirectory(atPath: reportsDir) else {
            self.allCrashes = []
            self.latestCrash = nil
            return
        }

        let hermesFiles = files.filter {
            ($0.hasPrefix("HermesPet") || $0.hasPrefix("Hermes 桌宠"))
                && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash"))
        }

        var records: [CrashRecord] = []
        for name in hermesFiles {
            let path = (reportsDir as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            let summary = parseSummary(path: path)
            records.append(CrashRecord(
                fileName: name,
                fullPath: path,
                date: mtime,
                appVersion: summary.appVersion,
                osVersion: summary.osVersion,
                exceptionType: summary.exceptionType,
                terminationReason: summary.terminationReason
            ))
        }
        records.sort { $0.date > $1.date }
        self.allCrashes = records
        self.latestCrash = records.first
    }

    /// 从 .ips 文件提取关键摘要。.ips 是 JSON Lines 格式：
    /// - 第一行：metadata JSON（app version / OS / 时间）
    /// - 第二行起：crash report 主体 JSON（exception / thread state / backtrace）
    private struct ParsedSummary {
        let appVersion: String
        let osVersion: String
        let exceptionType: String
        let terminationReason: String
    }

    private func parseSummary(path: String) -> ParsedSummary {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .utf8) else {
            return ParsedSummary(appVersion: "?", osVersion: "?", exceptionType: "?", terminationReason: "")
        }

        // .ips 是 JSON Lines。第一行是 metadata
        let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        guard let firstLine = lines.first,
              let firstData = String(firstLine).data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: firstData) as? [String: Any] else {
            // 老版 .crash 纯文本 fallback：grep 几行
            return parseLegacyCrash(text: raw)
        }

        let appVersion = (meta["app_version"] as? String)
            ?? (meta["bundleVersion"] as? String)
            ?? "?"
        let osVersion = (meta["os_version"] as? String) ?? "?"

        var exception = "?"
        var termination = ""
        if lines.count > 1,
           let body = String(lines[1]).data(using: .utf8),
           let bodyJson = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let exc = bodyJson["exception"] as? [String: Any] {
                exception = (exc["type"] as? String) ?? "?"
                if let signal = exc["signal"] as? String { exception += " (\(signal))" }
                if let subtype = exc["subtype"] as? String { exception += " · \(subtype)" }
            }
            if let term = bodyJson["termination"] as? [String: Any] {
                termination = ((term["indicator"] as? String) ?? "")
                if let by = term["byProc"] as? String { termination += " by \(by)" }
            }
        }
        return ParsedSummary(
            appVersion: appVersion,
            osVersion: osVersion,
            exceptionType: exception,
            terminationReason: termination
        )
    }

    /// macOS 10 时代的 .crash 纯文本格式 fallback。grep 几个关键字
    private func parseLegacyCrash(text: String) -> ParsedSummary {
        var version = "?"
        var os = "?"
        var exc = "?"
        for line in text.split(separator: "\n").prefix(40) {
            let s = String(line)
            if s.hasPrefix("Version:") {
                version = s.replacingOccurrences(of: "Version:", with: "").trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("OS Version:") {
                os = s.replacingOccurrences(of: "OS Version:", with: "").trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("Exception Type:") {
                exc = s.replacingOccurrences(of: "Exception Type:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return ParsedSummary(appVersion: version, osVersion: os, exceptionType: exc, terminationReason: "")
    }

    // MARK: - 上报

    /// 把指定 crash record 的完整 log 复制到剪贴板 + 跳转 GitHub issue new
    /// **流程**：
    /// 1. 读完整 crash log
    /// 2. 拼 issue body 模板（环境信息 + 占位提示"以下崩溃日志已自动复制到剪贴板"）
    /// 3. 完整日志 + body 模板都写到剪贴板（用户去 GitHub 粘贴一次性带走）
    /// 4. NSWorkspace 打开 issue new URL（title 预填）
    func reportToGitHub(_ record: CrashRecord) {
        guard let content = try? String(contentsOfFile: record.fullPath, encoding: .utf8) else {
            // 文件读不到，至少把摘要发出去
            openIssueWithFallbackBody(record: record)
            return
        }

        let envHeader = """
        ## 环境信息
        - App 版本：\(record.appVersion)
        - OS：\(record.osVersion)
        - 崩溃时间：\(formatDate(record.date))
        - Exception：\(record.exceptionType)
        \(record.terminationReason.isEmpty ? "" : "- 终止原因：\(record.terminationReason)")

        ## 操作步骤
        <!-- 请补充：崩溃前你在做什么？例如「按住 ⌘⇧V 录音时」「切换 AgentMode 到 Codex 时」 -->

        ## 完整崩溃日志
        <details>
        <summary>点击展开（已自动复制到剪贴板，可直接粘贴这里）</summary>

        ```
        \(content)
        ```
        </details>
        """

        // 写到剪贴板
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(envHeader, forType: .string)

        // 打开 GitHub issue new 页，预填 title（body 因 URL 长度限制不能塞完整 log，靠剪贴板带）
        let title = "Crash: \(record.exceptionType) on v\(record.appVersion)"
        let urlString = "https://github.com/\(Self.owner)/\(Self.repo)/issues/new" +
            "?title=\(title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" +
            "&body=" + ("**崩溃日志已复制到剪贴板，请按 ⌘V 粘贴到下方** —— 我会尽快定位修复 🙏\n\n"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        // 弹个确认 alert，让用户知道发生了什么
        let alert = NSAlert()
        alert.messageText = "崩溃日志已复制到剪贴板"
        alert.informativeText = "GitHub issue 页已在浏览器打开。粘贴（⌘V）到 body 里，描述一下崩溃前你在做什么，然后提交即可。\n\n感谢反馈 🙏"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    /// crash 文件读取失败的兜底 —— 只发摘要，没完整 log
    private func openIssueWithFallbackBody(record: CrashRecord) {
        let body = """
        ## 环境信息
        - App 版本：\(record.appVersion)
        - OS：\(record.osVersion)
        - 崩溃时间：\(formatDate(record.date))
        - Exception：\(record.exceptionType)

        ⚠️ 完整崩溃日志读取失败（文件路径：\(record.fullPath)）

        ## 操作步骤
        <!-- 请描述崩溃前的操作 -->
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)
        let title = "Crash: \(record.exceptionType) on v\(record.appVersion)"
        let urlString = "https://github.com/\(Self.owner)/\(Self.repo)/issues/new" +
            "?title=\(title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    /// 用户没崩过也想反馈普通 bug —— 直接打开空白 issue
    func openBlankIssue() {
        let urlString = "https://github.com/\(Self.owner)/\(Self.repo)/issues/new"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    /// 在 Finder 里选中崩溃日志文件，方便用户自己看 / 拖到微信 QQ 发给朋友
    func revealInFinder(_ record: CrashRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.fullPath)])
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

/// 单个崩溃记录
struct CrashRecord: Identifiable, Hashable {
    var id: String { fullPath }
    let fileName: String
    let fullPath: String
    let date: Date
    let appVersion: String
    let osVersion: String
    let exceptionType: String
    let terminationReason: String
}
