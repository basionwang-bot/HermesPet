import Foundation

/// **Hermes 模式的本地运行时**：检测到用户机器装了 hermes 就自动 spawn `hermes gateway run` 子进程，
/// 让用户不用手动去终端起 gateway。
///
/// 设计要点：
/// - **不 bundle binary**：hermes 是个 Python 项目 + 695MB venv + hardcoded shebang，bundle 不现实。
///   仅在用户机器上已装 hermes 时启用（找 `~/.local/bin/hermes` / `which hermes`）。
/// - **端口冲突避让**：spawn 前先 ping `localhost:8642/health`，已经在跑（用户可能终端手动起了一个
///   或 launchd service）就跳过 spawn，直接 markReady，不去替换用户的实例。
/// - **生命周期**：注册到 SubprocessRegistry，App 退出时 SIGTERM。
/// - **stderr 监听**：抓启动失败原因（端口占用 / 配置错误 / license）。
///
/// 与 OpenCodeServerManager 的关键差别：
/// - opencode：bundle 二进制 + 随机端口 + Basic Auth
/// - hermes  ：不 bundle / 固定端口 8642 / 无独立鉴权（HermesPet 这边走 apiKey UserDefaults 即可）
///
/// Swift 6 并发：`@unchecked Sendable` + NSLock，跟 OpenCodeServerManager 同模式。
final class HermesGatewayManager: @unchecked Sendable {
    static let shared = HermesGatewayManager()

    private let lock = NSLock()
    private var process: Process?
    private var _ready: Bool = false
    private var _lastError: String?
    /// 已检测到的 hermes binary 绝对路径，没装则为 nil
    private var _binaryPath: String?
    /// 表示当前 server 不是我们 spawn 的（用户在外部已经起了，我们只是检测到）
    private var _externallyManaged: Bool = false

    /// 自动启动开关 UserDefaults key —— 用户可在设置关掉自动启动（避免与终端手起的 gateway 冲突）
    static let autoStartKey = "hermesGatewayAutoStart"

    private init() {}

    // MARK: - Public state

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return _ready
    }

    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }

    /// 探测到的 hermes 命令绝对路径，没装时返回 nil
    var binaryPath: String? {
        lock.lock(); defer { lock.unlock() }
        return _binaryPath
    }

    /// 当前 gateway 是 HermesPet spawn 的还是外部已存在的（影响 terminate 行为）
    var isExternallyManaged: Bool {
        lock.lock(); defer { lock.unlock() }
        return _externallyManaged
    }

    /// 状态摘要（设置面板 UI 展示用）
    enum Status: Equatable {
        case starting       // 正在 spawn
        case running        // 我们 spawn 的 gateway 已就绪
        case external       // 用户在外部已经起了一个
        case binaryMissing  // 用户没装 hermes
        case failed(String) // 启动失败
        case disabled       // 用户关掉了自动启动
    }

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        if !UserDefaults.standard.bool(forKey: Self.autoStartKey) &&
           UserDefaults.standard.object(forKey: Self.autoStartKey) != nil {
            // 显式关掉
            return .disabled
        }
        if _ready {
            return _externallyManaged ? .external : .running
        }
        if let err = _lastError { return .failed(err) }
        if _binaryPath == nil { return .binaryMissing }
        return .starting
    }

    // MARK: - Lifecycle

    /// 如果用户机器装了 hermes，则自动 spawn `hermes gateway run`；否则记 binaryMissing 直接返回。
    /// 调用方：AppDelegate.didFinishLaunching 里 `Task { await HermesGatewayManager.shared.startIfAvailable() }`
    func startIfAvailable() async {
        // 1. 自动启动开关（默认开启；显式 set false 才禁）
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.autoStartKey) != nil &&
           !defaults.bool(forKey: Self.autoStartKey) {
            recordError(nil)
            return
        }

        // 2. 探测 binary
        guard let binary = locateHermesBinary() else {
            commitBinaryMissing()
            return
        }
        commitBinaryPath(binary)

        // 3. 端口已被占用？已经有 gateway 在跑就跳过 spawn，让外部实例继续 serve
        if await pingExistingGateway() {
            commitExternal()
            NotificationCenter.default.post(
                name: .init("HermesPetGatewayReady"),
                object: nil,
                userInfo: ["externallyManaged": true]
            )
            return
        }

        // 4. spawn `hermes gateway run`
        do {
            let proc = try spawnGateway(binary: binary)
            // 给 hermes 一点时间起监听（Python boot ~2-3s）
            let ready = await waitForGatewayReady(timeoutSeconds: 15)
            if ready {
                commitReady(process: proc)
                NotificationCenter.default.post(
                    name: .init("HermesPetGatewayReady"),
                    object: nil,
                    userInfo: ["externallyManaged": false]
                )
            } else {
                // 超时 → 杀掉残留 + 记错误
                if proc.isRunning {
                    SubprocessRegistry.shared.unregister(proc)
                    proc.terminate()
                }
                recordError("启动 15s 内未就绪（hermes gateway run 没监听 :8642）")
            }
        } catch {
            recordError("启动失败：\(error.localizedDescription)")
        }
    }

    /// 终止我们 spawn 的 gateway 进程；外部管理的不动
    func terminate() {
        lock.lock()
        let p = self.process
        let external = self._externallyManaged
        self.process = nil
        self._ready = false
        lock.unlock()

        guard !external, let p, p.isRunning else { return }
        SubprocessRegistry.shared.unregister(p)
        let pid = p.processIdentifier
        p.terminate()

        let deadline = Date().addingTimeInterval(0.8)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning { kill(pid, SIGKILL) }
    }

    // MARK: - Internal

    /// 找 hermes binary。
    /// 旧版自己拼了一套弱探测（`zsh -l` 不加载 `.zshrc` + `waitUntilExit` 无超时 + 候选表漏 venv），
    /// 是"有时候检测不到"的病根之一。现统一复用 `CLIAvailability` 的健壮四层探测（带 `-lic` + 超时 + 脚印）。
    private func locateHermesBinary() -> String? {
        let fm = FileManager.default
        // 快路径：命中常见软链 / venv 本体就不必启 shell，省启动开销（venv 路径 clawd-on-desk 也查）
        let fast = [
            "\(NSHomeDirectory())/.hermes/hermes-agent/venv/bin/hermes",
            "\(NSHomeDirectory())/.local/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes"
        ]
        for path in fast where fm.isExecutableFile(atPath: path) {
            return path
        }
        // 慢路径兜底：CLIAvailability 健壮四层（zsh/bash -lic 加载 .zshrc + 全面路径扫描 + 脚印 + 超时）
        return CLIAvailability.locateBinary(command: "hermes")
    }

    /// ping `localhost:8642/health` —— 已经有 gateway 在跑（用户终端手起 / launchd service）
    private func pingExistingGateway() async -> Bool {
        guard let url = URL(string: "http://localhost:8642/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// spawn `hermes gateway run`，stderr 持续 drain（不阻塞），register 到 SubprocessRegistry
    private func spawnGateway(binary: String) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // run 子命令前台 serve；不加 --replace 避免误伤用户已有实例
        proc.arguments = ["gateway", "run"]
        proc.environment = CLIProcessEnvironment.make(executablePath: binary)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        // 持续 drain 避免缓冲区满，stderr 抓 last line 作为错误兜底
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            // EOF 防护：gateway run 启动后会关闭继承的 stdout 写端，读端此后永久处于
            // "可读(EOF)"状态。不置 nil 的话 dispatch source 会无限高频回调 → 单核满载空转
            // （与 OpenCodeServerManager 同一个坑，曾导致整机 ~200% CPU）
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {   // EOF：同样要置 nil，否则永久空转
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            // 抓最后非空一行存到 _lastError（仅当 process 还没 ready，避免覆盖正常运行日志）
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let lastErr = lines.last(where: { !$0.isEmpty }) {
                self?.maybeRecordTransientError(String(lastErr))
            }
        }

        try proc.run()
        SubprocessRegistry.shared.register(proc)
        return proc
    }

    /// 轮询 ping `localhost:8642/health` 直到通 / 超时
    private func waitForGatewayReady(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if await pingExistingGateway() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    // MARK: - State commit helpers (lock 收敛)

    private func commitBinaryPath(_ path: String) {
        lock.lock()
        self._binaryPath = path
        lock.unlock()
    }

    private func commitBinaryMissing() {
        lock.lock()
        self._binaryPath = nil
        self._ready = false
        self._lastError = nil
        lock.unlock()
    }

    private func commitReady(process: Process) {
        lock.lock()
        self.process = process
        self._ready = true
        self._lastError = nil
        self._externallyManaged = false
        lock.unlock()
    }

    private func commitExternal() {
        lock.lock()
        self.process = nil
        self._ready = true
        self._lastError = nil
        self._externallyManaged = true
        lock.unlock()
    }

    private func recordError(_ msg: String?) {
        lock.lock()
        self._lastError = msg
        self._ready = false
        lock.unlock()
    }

    /// stderr 抓到一行错误时调用；不覆盖已经 ready 后的运行日志
    private func maybeRecordTransientError(_ msg: String) {
        lock.lock()
        if !_ready { self._lastError = msg }
        lock.unlock()
    }
}
