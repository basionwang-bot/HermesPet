import AppKit
import ObjectiveC

/// 头号崩溃定位器。
///
/// 本 App 最常见的崩溃是「NSWindow 显示周期做约束更新时抛 NSException」（决策 #1/#6，
/// 见 issues #25/#27/#29/#30/#35，横跨 v1.2.8~v1.2.13、多种机型 / macOS 26.x）。
/// 但系统 `.ips` 崩溃日志**不带 NSException 的文字 reason**，导致只知道崩在 AppKit 布局层、
/// 不知道是哪个视图 / 哪条约束。
///
/// 本类在 AppKit `reportException:`（事件循环捕获异常的必经方法，就在崩溃栈
/// `_crashOnException` 的前一步）抛出的那一刻，把 `reason` + 含我们自己代码的
/// `callStackSymbols` 落盘到 `~/.hermespet/last_exception.log`，`CrashReporter` 上报时
/// 自动带上 → 下次崩溃即可精确指认是哪个窗口 / 视图。
///
/// 注意：本类只「观察并记录」，不吞异常 —— swizzle 里照常调用原始 `reportException:`，
/// 崩溃行为完全不变。
enum ExceptionLogger {

    /// 落盘路径：~/.hermespet/last_exception.log
    static var logPath: String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".hermespet")
        return (dir as NSString).appendingPathComponent("last_exception.log")
    }

    /// App 启动尽早调用。安装两道捕获：
    /// 1) swizzle `-[NSApplication reportException:]` —— 主事件循环里抛出的异常（含本 App 头号崩溃）
    /// 2) `NSSetUncaughtExceptionHandler` —— 兜底：未经事件循环、直达顶层的未捕获异常
    static func install() {
        swizzleReportException()
        NSSetUncaughtExceptionHandler { exc in
            ExceptionLogger.write(exc, source: "uncaught")
        }
    }

    private static func swizzleReportException() {
        let cls: AnyClass = NSApplication.self
        let sel = #selector(NSApplication.reportException(_:))
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let originalIMP = method_getImplementation(method)
        typealias OriginalFn = @convention(c) (AnyObject, Selector, NSException) -> Void
        let callOriginal = unsafeBitCast(originalIMP, to: OriginalFn.self)
        let block: @convention(block) (AnyObject, NSException) -> Void = { receiver, exc in
            ExceptionLogger.write(exc, source: "reportException")
            callOriginal(receiver, sel, exc)   // 保持原有崩溃 / 日志行为不变
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func write(_ exc: NSException, source: String) {
        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var s = "=== HermesPet 异常捕获 [\(source)] ===\n"
        s += "时间: \(ISO8601DateFormatter().string(from: Date()))\n"
        s += "版本: \(ver) (build \(build))\n"
        s += "name: \(exc.name.rawValue)\n"
        s += "reason: \(exc.reason ?? "(nil)")\n"
        if let ui = exc.userInfo, !ui.isEmpty {
            s += "userInfo: \(ui)\n"
        }
        s += "callStack:\n" + exc.callStackSymbols.joined(separator: "\n") + "\n"

        // 窗口快照：崩溃多发生在某个 NSHostingView 窗口布局时,把所有窗口的 类名/标题/frame/可见
        // 都记下来,好按 frame 比对出是哪个窗(报告只给尺寸不给名字)。
        s += "\nwindows:\n"
        for w in NSApplication.shared.windows {
            let f = w.frame
            let frameStr = "{{\(Int(f.origin.x)), \(Int(f.origin.y))}, {\(Int(f.size.width)), \(Int(f.size.height))}}"
            let ctrl = String(describing: type(of: w.contentViewController))
            s += "  \(type(of: w)) title=\"\(w.title)\" \(frameStr) vis=\(w.isVisible) ctrl=\(ctrl)\n"
        }

        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".hermespet")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? s.write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    /// 读取最近一次捕获的异常日志 + 其写入时间（用于跟崩溃时间做接近度判断）。
    static func readLastLog() -> (text: String, capturedAt: Date)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logPath),
              let text = try? String(contentsOfFile: logPath, encoding: .utf8),
              let attrs = try? fm.attributesOfItem(atPath: logPath),
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return (text, mtime)
    }
}
