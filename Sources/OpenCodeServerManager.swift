import Foundation
import Security

/// **在线 AI 模式的运行时**：管理 bundled opencode 二进制的 headless `serve` 子进程。
///
/// 设计要点（见 TODO.md「P0-在线 AI 内核换代」）：
/// - App 启动时 `start()`，从 .app/Contents/Resources/opencode copy 到
///   `~/Library/Application Support/HermesPet/bin/opencode`（writable 副本，
///   后续 `opencode upgrade` 才能热替换二进制 —— .app bundle 内是只读的）
/// - 生成 32 字节 random password（Base64）做 Basic Auth，
///   持久化到 UserDefaults `opencodeServerPassword`
/// - spawn `opencode serve --port 0 --hostname 127.0.0.1`，
///   `--port 0` 让 opencode 自己挑一个空闲端口，避免冲突
/// - 监听子进程 stdout，等到 `listening on http://127.0.0.1:XXXX` 抓真实端口
/// - 健康检查 `/global/health` 拿到 `{healthy:true,version:...}` 才算 ready
/// - `applicationWillTerminate` 走 `SubprocessRegistry.shared.terminateAll()` 兜底
///
/// Swift 6 并发：标记 `@unchecked Sendable` —— stdout `readabilityHandler` 在后台线程
/// 回调，状态用 NSLock 保护（同 SubprocessRegistry / VoiceInputController 模式）。
final class OpenCodeServerManager: @unchecked Sendable {
    static let shared = OpenCodeServerManager()

    private let lock = NSLock()
    private var process: Process?
    private var _port: Int?
    private var _password: String?
    private var _ready: Bool = false
    private var _lastError: String?
    /// 在途 start() 的 Task 句柄（锁保护）。并发 start 复用同一个，避免重复 spawn opencode serve（决策 #15）
    private var startTask: Task<Void, Error>?

    private init() {}

    // MARK: - Public state

    /// `http://127.0.0.1:<port>`，server 没起来时为 nil
    var serverURL: URL? {
        lock.lock(); defer { lock.unlock() }
        guard let p = _port else { return nil }
        return URL(string: "http://127.0.0.1:\(p)")
    }

    /// Basic Auth password（用户名固定 `opencode`）
    var password: String? {
        lock.lock(); defer { lock.unlock() }
        return _password
    }

    /// health check 通过才会变 true
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return _ready
    }

    /// 最近一次 start 失败原因（UI 展示用）
    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }

    /// 用 URLRequest 时直接 setValue 的 Authorization header 值
    var authorizationHeader: String? {
        guard let pwd = password,
              let data = "opencode:\(pwd)".data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - Lifecycle

    /// 启动 opencode serve 子进程并等 ready。失败抛 `OpenCodeServerError`。
    /// 调用方应在 AppDelegate.applicationDidFinishLaunching 里 fire-and-forget：
    /// `Task { try? await OpenCodeServerManager.shared.start() }`
    func start() async throws {
        // 已经在跑就直接返回
        if isReady { return }
        // 去重 + 互斥：原子 get-or-insert 在途 start Task，并发只起一个 spawn，其余 await 复用，
        // 避免 restartForConfigChange 在首个 start 未完成（process 仍 nil、terminate 空杀）时并行 spawn 出第二个 opencode serve（决策 #15）
        let task = startTaskOrCreate {
            Task {
                defer { self.clearStartTask() }
                try await self.performStart()
            }
        }
        try await task.value
    }

    /// start() 的真正实现体（spawn + healthCheck + commitReady），由 start() 包成去重 Task 调用
    private func performStart() async throws {
        do {
            let binary = try prepareWritableBinary()
            let pwd = ensurePassword()
            // ⭐ 生成 opencode.json 前先等 ReasoningProxy 就绪（修推理泄漏的启动竞态）：
            // 否则 buildConfig 在 proxy 没拿到端口时会 fallback 成"直连 provider"，绕过 reasoning 过滤
            // → 智谱/DeepSeek 等推理模型的思考过程泄漏成正文。proxy 几十毫秒就 ready，等一下零感知。
            await ReasoningProxy.shared.waitUntilReady()
            // 关键：v1.3 走 HTTP API 路线，serve 必须能加载所有用户配的 provider。
            // 准备一个"全局 config dir"放完整 opencode.json，让 serve cwd 指向它
            let configDir = try prepareGlobalConfigDir()
            let (port, proc) = try await spawnAndWaitForReady(
                binary: binary,
                password: pwd,
                cwd: configDir
            )
            try await healthCheck(port: port, password: pwd)

            commitReady(process: proc, port: port, password: pwd)

            NotificationCenter.default.post(
                name: .init("HermesPetOpenCodeReady"),
                object: nil,
                userInfo: ["port": port]
            )
        } catch {
            let msg = (error as? OpenCodeServerError)?.localizedDescription ?? error.localizedDescription
            recordError(msg)
            throw error
        }
    }

    /// 用户在设置改了 provider / API Key → 重写 globalConfigDir 的 opencode.json，
    /// 同步重启 server 让新配置生效（PATCH /config 这条路 opencode 1.15.1 对部分字段不热加载，最稳的是 restart）
    func restartForConfigChange() async {
        // 先 await 在途 start 跑完（让其 commitReady 落下真实 process；不能 cancel——cancel 可能让 spawn 半途抛错留下真孤儿），
        // 再 terminate 杀掉它，最后用新配置重启。避免与未完成的首个 start 并行 spawn 出双进程（决策 #15）
        if let inFlight = currentStartTask() {
            _ = try? await inFlight.value
        }
        terminate()
        // 给 server 退出 + 端口释放一点时间
        try? await Task.sleep(nanoseconds: 200_000_000)
        try? await start()
    }

    /// 全局 config dir：`~/Library/Application Support/HermesPet/opencode-global/`，
    /// `opencode serve` cwd 指向这里 → server 启动时加载该 dir 的 opencode.json。
    /// 同一份 OpenCodeConfigGenerator.ensureConfig 复用，所有 provider 一次性注册到 server。
    private func prepareGlobalConfigDir() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        let dir = appSupport.appendingPathComponent("HermesPet/opencode-global", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenCodeConfigGenerator.ensureConfig(in: dir.path)
        return dir
    }

    // Swift 6 严格并发：NSLock 不能在 async 函数里直接 lock/unlock。
    // 把所有锁操作收敛到 sync helper，async 函数只调 helper。
    private func commitReady(process: Process, port: Int, password: String) {
        lock.lock()
        self.process = process
        self._port = port
        self._password = password
        self._ready = true
        self._lastError = nil
        lock.unlock()
    }

    // start Task 句柄的锁助手（同 commitReady 模式，锁操作收敛到 sync helper）。
    // make 起的 Task 体内首次访问 lock 都在 await 之后（锁外），不与本锁嵌套。
    private func startTaskOrCreate(_ make: () -> Task<Void, Error>) -> Task<Void, Error> {
        lock.lock(); defer { lock.unlock() }
        if let t = startTask { return t }
        let t = make()
        startTask = t
        return t
    }
    private func currentStartTask() -> Task<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        return startTask
    }
    private func clearStartTask() {
        lock.lock(); defer { lock.unlock() }
        startTask = nil
    }

    private func recordError(_ msg: String) {
        lock.lock()
        self._lastError = msg
        self._ready = false
        lock.unlock()
    }

    /// 终止 server 子进程。AppDelegate.applicationWillTerminate 调。
    /// 先 SIGTERM 让 opencode 优雅 cleanup（flush SQLite），半秒后还活着就 SIGKILL 兜底。
    /// 也要清理 grandchildren（opencode serve 内部会 fork worker，仅杀主进程不够）
    func terminate() {
        lock.lock()
        let p = self.process
        self.process = nil
        self._port = nil
        self._ready = false
        lock.unlock()

        guard let p, p.isRunning else { return }
        SubprocessRegistry.shared.unregister(p)
        let pid = p.processIdentifier

        // 1) SIGTERM 给 opencode 优雅退出的机会
        p.terminate()

        // 2) 半秒后还活着 → SIGKILL（同步等待，applicationWillTerminate 不应等太长）
        let deadline = Date().addingTimeInterval(0.5)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            kill(pid, SIGKILL)
        }

        // 3) 兜底：杀掉所有指向 bundled binary 的 opencode 子进程（grandchildren）。
        //    用 pgrep 路径精确匹配，避免误杀用户自装的 ~/.opencode/bin/opencode
        let bundledPath = "Application Support/HermesPet/bin/opencode"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", bundledPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Internal

    /// 把 bundled `.app/Contents/Resources/opencode` copy 到用户可写的
    /// `~/Library/Application Support/HermesPet/bin/opencode`。
    /// 后续 `opencode upgrade` 才能热替换这个文件（bundle 内是只读 mount）
    private func prepareWritableBinary() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        let binDir = appSupport.appendingPathComponent("HermesPet/bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let dest = binDir.appendingPathComponent("opencode")

        guard let bundled = Bundle.main.url(forResource: "opencode", withExtension: nil) else {
            throw OpenCodeServerError.bundledBinaryMissing
        }

        // bundled 比 writable 新（用户刚装新版本 HermesPet）→ 重新 copy
        let needsCopy: Bool = {
            guard fm.fileExists(atPath: dest.path) else { return true }
            let bundledAttrs = try? fm.attributesOfItem(atPath: bundled.path)
            let destAttrs = try? fm.attributesOfItem(atPath: dest.path)
            guard let bundledDate = bundledAttrs?[.modificationDate] as? Date,
                  let destDate = destAttrs?[.modificationDate] as? Date else { return true }
            return bundledDate > destDate
        }()

        if needsCopy {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: bundled, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755],
                                 ofItemAtPath: dest.path)
        }
        return dest
    }

    /// 拿 / 生成 32 字节 base64 password
    private func ensurePassword() -> String {
        let key = "opencodeServerPassword"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let pwd: String
        if status == errSecSuccess {
            pwd = Data(bytes).base64EncodedString()
        } else {
            // SecRandom 失败概率极低；退回 UUID×2 兜底
            pwd = "\(UUID().uuidString)\(UUID().uuidString)"
        }
        UserDefaults.standard.set(pwd, forKey: key)
        return pwd
    }

    /// spawn 子进程并等 stdout 给出端口（超时 10s）
    private func spawnAndWaitForReady(binary: URL, password: String, cwd: URL) async throws -> (port: Int, process: Process) {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["serve", "--port", "0", "--hostname", "127.0.0.1"]
        // 关键：cwd 指向准备好 opencode.json 的全局配置 dir，让 serve 启动时加载完整 provider 列表
        proc.currentDirectoryURL = cwd

        var env = CLIProcessEnvironment.make(executablePath: binary.path)
        env["OPENCODE_SERVER_PASSWORD"] = password
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        // 端口出现在 stdout：`opencode server listening on http://127.0.0.1:14098`
        let portBox = OneShotBox<Int>()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF 防护：opencode serve 启动后会关闭继承的 stdout 写端，读端此后永久处于
            // "可读(EOF)"状态。若不在此置 nil，dispatch source 会无限高频回调，每次
            // availableData 触发 fstat+read → 单核满载空转（曾导致整机 ~200% CPU）。
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let line = String(data: data, encoding: .utf8) else { return }
            if let port = Self.parsePort(from: line) {
                portBox.fulfill(.success(port))
            }
        }
        // stderr 持续 drain，避免缓冲区写满阻塞子进程；同样要做 EOF 防护
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        try proc.run()
        SubprocessRegistry.shared.register(proc)

        // 超时兜底
        Task.detached { @Sendable in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            portBox.fulfill(.failure(OpenCodeServerError.startupTimeout))
        }

        // 进程提前退出兜底（说明 binary 有问题或 OPENCODE_SERVER_PASSWORD 校验失败）
        proc.terminationHandler = { [portBox] _ in
            portBox.fulfill(.failure(OpenCodeServerError.processExitedEarly))
        }

        let port: Int = try await withCheckedThrowingContinuation { cont in
            portBox.attach(cont)
        }
        return (port, proc)
    }

    private func healthCheck(port: Int, password: String) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/global/health") else {
            throw OpenCodeServerError.healthCheckFailed
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        let creds = "opencode:\(password)".data(using: .utf8)?.base64EncodedString() ?? ""
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenCodeServerError.healthCheckFailed
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["healthy"] as? Bool == true else {
            throw OpenCodeServerError.healthCheckFailed
        }
    }

    /// "opencode server listening on http://127.0.0.1:14098" → 14098
    private static func parsePort(from line: String) -> Int? {
        let pattern = #"listening on http://127\.0\.0\.1:(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        guard let m = match, m.numberOfRanges >= 2 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }
}

// MARK: - 错误类型

enum OpenCodeServerError: LocalizedError {
    case bundledBinaryMissing
    case startupTimeout
    case processExitedEarly
    case healthCheckFailed

    var errorDescription: String? {
        switch self {
        case .bundledBinaryMissing:
            return "找不到内嵌的 opencode 二进制（HermesPet.app/Contents/Resources/opencode）"
        case .startupTimeout:
            return "opencode server 启动超时（10s 没监听端口）"
        case .processExitedEarly:
            return "opencode 子进程在 ready 之前就退出了"
        case .healthCheckFailed:
            return "opencode server 健康检查未通过"
        }
    }
}

// MARK: - OneShot Continuation Box

/// 解决 readabilityHandler 后台线程 fire 时可能早于 await 设置 continuation 的竞态：
/// 内部 buffer 第一个 result，等 continuation 进来时 resume。
/// 只能 fulfill 一次（second fulfill 静默忽略，避免 CheckedContinuation 重复 resume 崩溃）
final class OneShotBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var fired = false

    func fulfill(_ result: Result<T, Error>) {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            resume(c, result)
        } else {
            pending = result
            lock.unlock()
        }
    }

    func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let p = pending {
            pending = nil
            lock.unlock()
            resume(c, p)
        } else {
            continuation = c
            lock.unlock()
        }
    }

    private func resume(_ c: CheckedContinuation<T, Error>, _ result: Result<T, Error>) {
        switch result {
        case .success(let v): c.resume(returning: v)
        case .failure(let e): c.resume(throwing: e)
        }
    }
}
