import Foundation
#if canImport(SwiftTerm)
import SwiftTerm

/// tmux 工具层 —— 终端会话的「持久化底座」。
///
/// 用一个**私有 socket(`-L hermespet`)** 的 tmux 服务器管理所有会话：
///   - 会话活在 tmux 服务器进程里 → 手机断开/关 App，会话照样在（持久化）。
///   - 可以列出全部会话（手机端展示「电脑上开着的终端」）。
///   - 多客户端可同时 attach 同一会话 → 手机 + Mac(Ghostty/终端) 双向同步。
///
/// 开发期用机器上已装的 tmux；正式分发版会把 tmux 二进制打包进 App（用户零安装）。
enum Tmux {
    static let socket = "hermespet"

    /// 定位 tmux：优先 App 内打包，回退常见安装位置。
    static func binary() -> String? {
        if let p = Bundle.main.path(forResource: "tmux", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 给 tmux/子 shell 用的环境（补上 PATH，确保能找到 shell + 命令）。
    static func childEnv() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + extra
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// 同步跑一条 tmux 命令，返回 (exitCode, stdout)。
    @discardableResult
    static func run(_ args: [String]) -> (code: Int32, out: String) {
        guard let bin = binary() else { return (-1, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-L", socket] + args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        var envDict = ProcessInfo.processInfo.environment
        envDict["PATH"] = (envDict["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = envDict
        do { try p.run() } catch { return (-1, "") }
        p.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func hasSession(_ name: String) -> Bool {
        run(["has-session", "-t", name]).code == 0
    }

    /// 全局选项：鼠标模式(手机滚轮滚历史)、大历史、尺寸 manual(由手机显式 resize-window 决定,不被 Ghostty 影响)。
    static func configureServer() {
        _ = run(["set-option", "-g", "mouse", "on"])
        _ = run(["set-option", "-g", "history-limit", "10000"])
        _ = run(["set-option", "-g", "window-size", "manual"])
    }

    /// 确保会话存在（不存在则按给定大小创建一个 detached 的）。返回是否「这次新建的」。
    static func ensureSession(_ name: String, cols: Int, rows: Int) -> Bool {
        if hasSession(name) { return false }
        _ = run(["new-session", "-d", "-x", "\(max(1, cols))", "-y", "\(max(1, rows))", "-s", name])
        return true
    }

    /// 列出全部会话 → [{name, windows, attached}]
    static func listSessions() -> [[String: Any]] {
        let r = run(["list-sessions", "-F", "#{session_name}\t#{windows}\t#{session_attached}"])
        guard r.code == 0 else { return [] }
        var result: [[String: Any]] = []
        for line in r.out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 3, !f[0].isEmpty else { continue }
            result.append(["name": f[0],
                           "windows": Int(f[1]) ?? 1,
                           "attached": (Int(f[2]) ?? 0) > 0])
        }
        return result
    }

    /// 在用户的终端里打开并 attach 到会话：优先 Ghostty，否则系统「终端.app」。
    static func openOnMac(_ name: String) {
        guard let bin = binary() else { return }
        let ghostty = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        if FileManager.default.isExecutableFile(atPath: ghostty) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ghostty)
            p.arguments = ["-e", bin, "-L", socket, "attach", "-t", name]
            p.environment = ProcessInfo.processInfo.environment
            try? p.run()
            return
        }
        // 回退：系统「终端.app」
        let attach = "\(q(bin)) -L \(socket) attach -t \(q(name))"
        let script = "tell application \"Terminal\"\ndo script \"\(attach.replacingOccurrences(of: "\"", with: "\\\""))\"\nactivate\nend tell"
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        try? osa.run()
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// 远程终端 —— 手机通过云中转开/连一个 tmux 会话；HermesPet 在本机起一个 tmux 客户端(PTY)做桥接。
@MainActor
final class RemoteTerminalManager {
    static let shared = RemoteTerminalManager()
    private var sessions: [String: TerminalSession] = [:]   // termId -> 一个 tmux 客户端 PTY
    private init() {}

    var count: Int { sessions.count }

    /// 开一个终端：attach 到名为 sessionName 的 tmux 会话（不存在则建）。
    func open(termId: String, sessionName: String, cols: Int, rows: Int,
              onOutput: @escaping @Sendable (Data) -> Void,
              onExit: @escaping @Sendable (Int32) -> Void) {
        guard sessions[termId] == nil else { return }
        let name = sessionName.isEmpty ? "main" : sessionName

        // 确保会话存在；若是这次新建的，自动在 Mac 的终端里也打开它（双向同步 + 弹出）
        let isNew = Tmux.ensureSession(name, cols: cols, rows: rows)
        Tmux.configureServer()   // 鼠标滚动 + 尺寸按手机算（防排版乱）

        let s = TerminalSession(tmuxSession: name, cols: cols, rows: rows, onOutput: onOutput) { code in
            Task { @MainActor in
                RemoteTerminalManager.shared.sessions.removeValue(forKey: termId)
                onExit(code)
            }
        }
        sessions[termId] = s
        s.start()
        if isNew { Tmux.openOnMac(name) }
        NSLog("[RemoteTerm] 开终端 %@ → tmux「%@」%@，当前 %d 个客户端",
              termId, name, isNew ? "(新建+已在Mac弹出)" : "(已存在)", sessions.count)
    }

    func input(termId: String, data: Data) { sessions[termId]?.write(data) }
    func resize(termId: String, cols: Int, rows: Int) { sessions[termId]?.resize(cols: cols, rows: rows) }

    /// 关一个客户端 = detach（tmux 会话仍保活在服务器里 → 持久化）。
    func close(termId: String) {
        if let s = sessions.removeValue(forKey: termId) {
            s.stop()
            NSLog("[RemoteTerm] 关客户端 %@（会话仍保活），当前 %d 个", termId, sessions.count)
        }
    }

    func closeAll() {
        guard !sessions.isEmpty else { return }
        for (_, s) in sessions { s.stop() }
        NSLog("[RemoteTerm] 断线，detach 全部 %d 个客户端（tmux 会话保活）", sessions.count)
        sessions.removeAll()
    }
}

/// 单个 tmux 客户端会话：跑 `tmux attach`，把它的输出回传、把手机的键写进去。
/// 所有 fd/pid/source 只在内部 ioQueue 上访问，对外线程安全。
final class TerminalSession: @unchecked Sendable {
    private let ioQueue = DispatchQueue(label: "com.hermespet.term.io")

    private var pid: pid_t = -1
    private var masterFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    private var exited = false
    private var cols: Int
    private var rows: Int
    private let tmuxSession: String

    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(tmuxSession: String, cols: Int, rows: Int,
         onOutput: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) {
        self.tmuxSession = tmuxSession
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func start() { ioQueue.async { self._start() } }
    func write(_ data: Data) { ioQueue.async { self._write(data) } }
    func resize(cols: Int, rows: Int) { ioQueue.async { self._resize(cols: cols, rows: rows) } }
    func stop() { ioQueue.async { self._stop() } }

    // MARK: - 内部（都在 ioQueue）

    private func _start() {
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let env = Tmux.childEnv()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let exe: String
        let argv: [String]
        if let tmux = Tmux.binary() {
            exe = tmux
            argv = [tmux, "-L", Tmux.socket, "attach", "-t", tmuxSession]
        } else {
            // 回退：没有 tmux 就退化成普通登录 shell（不持久、不共享，但至少能用）
            let shell = Self.userShell()
            exe = shell
            argv = ["-" + ((shell as NSString).lastPathComponent)]
            NSLog("[RemoteTerm] ⚠️ 未找到 tmux，退化为普通 shell（无持久化/共享）")
        }

        guard let res = PseudoTerminalHelpers.fork(andExec: exe, args: argv, env: env,
                                                   currentDirectory: home, desiredWindowSize: &ws) else {
            NSLog("[RemoteTerm] fork 失败")
            onExit(-1)
            return
        }
        pid = res.pid
        masterFd = res.masterFd

        let fl = fcntl(masterFd, F_GETFL)
        _ = fcntl(masterFd, F_SETFL, fl | O_NONBLOCK)

        let rs = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: ioQueue)
        rs.setEventHandler { [weak self] in self?._drain() }
        readSource = rs
        rs.resume()

        let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        ps.setEventHandler { [weak self] in self?._handleExit() }
        procSource = ps
        ps.resume()
    }

    private func _drain() {
        guard masterFd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(masterFd, &buf, buf.count)
            if n > 0 {
                onOutput(Data(buf[0..<n]))
            } else if n == 0 {
                _handleExit(); return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                _handleExit(); return
            }
        }
    }

    private func _write(_ data: Data) {
        guard masterFd >= 0 else { return }
        let fd = masterFd
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, p, remaining)
                if n > 0 { p = p.advanced(by: n); remaining -= n }
                else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(2000); continue }
                else { break }
            }
        }
    }

    private func _resize(cols: Int, rows: Int) {
        guard masterFd >= 0 else { return }
        self.cols = max(1, cols); self.rows = max(1, rows)
        var ws = winsize(ws_row: UInt16(self.rows), ws_col: UInt16(self.cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterFd, windowSize: &ws)
        // window-size manual：显式把 tmux 窗口设成手机的尺寸，保证手机端精确对齐（不被 Ghostty 等其它客户端影响）
        _ = Tmux.run(["resize-window", "-t", tmuxSession, "-x", "\(self.cols)", "-y", "\(self.rows)"])
    }

    private func _stop() {
        // 杀掉的是 tmux 客户端进程 = detach；tmux 会话仍在服务器里保活
        if pid > 0 { kill(pid, SIGHUP) }
        _cleanup(exitCode: nil, fireExit: false)
    }

    private func _handleExit() {
        var code: Int32 = 0
        if pid > 0 {
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            if (status & 0x7f) == 0 { code = (status >> 8) & 0xff }
            else { code = 128 + (status & 0x7f) }
        }
        _cleanup(exitCode: code, fireExit: true)
    }

    private func _cleanup(exitCode: Int32?, fireExit: Bool) {
        if exited { return }
        exited = true
        readSource?.cancel(); readSource = nil
        procSource?.cancel(); procSource = nil
        if masterFd >= 0 { close(masterFd); masterFd = -1 }
        if pid > 0 { var st: Int32 = 0; waitpid(pid, &st, WNOHANG) }
        pid = -1
        if fireExit { onExit(exitCode ?? 0) }
    }

    static func userShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        return "/bin/zsh"
    }
}
#endif
