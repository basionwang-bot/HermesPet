import Foundation

/// **OpenClaw 模式的本地运行时**：检测到用户机器装了 openclaw 就自动让它工作 ——
/// 启动 daemon（launchd 管的）+ 自动 enable chatCompletions HTTP endpoint + 读 token / port。
///
/// 设计要点（跟 HermesGatewayManager 的差异）：
/// - OpenClaw 是 npm 装的 + 自带 launchd service `ai.openclaw.gateway`。我们不直接 spawn 阻塞进程，
///   而是 invoke `openclaw daemon start`，service 由 launchd 后台跑（重启后自启）。
/// - **token / port 自动读取** 自 `~/.openclaw/openclaw.json`，用户**完全不用填表**。
/// - **chatCompletions endpoint 默认 disable**（OpenClaw 安全默认）—— 检测到没 enable 时
///   静默改 json 加 `gateway.http.endpoints.chatCompletions.enabled = true` + 重启 daemon。
///   用户拍板"静默改可以"（PR-A 决策点）。
///
/// 与 HermesGatewayManager 相同点：
/// - `@unchecked Sendable` + NSLock 防 Swift 6 隔离崩
/// - Status enum 给 SettingsView 显示状态卡片
/// - autoStartKey UserDefaults 让用户能关掉自动启动
final class OpenClawGatewayManager: @unchecked Sendable {
    static let shared = OpenClawGatewayManager()

    private let lock = NSLock()
    private var _ready: Bool = false
    private var _lastError: String?
    /// 已检测到的 openclaw binary 绝对路径，没装则为 nil
    private var _binaryPath: String?
    /// 从 ~/.openclaw/openclaw.json 读到的 Bearer token（auth.mode=token 时存在）
    private var _token: String?
    /// gateway 端口（默认 18789）
    private var _port: Int = 18789
    /// chatCompletions endpoint 是否已 enable
    private var _endpointEnabled: Bool = false

    /// 自动启动开关 UserDefaults key —— 用户可在设置关掉自动 daemon 拉起
    static let autoStartKey = "openclawGatewayAutoStart"

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

    /// 探测到的 openclaw 命令绝对路径，没装时 nil
    var binaryPath: String? {
        lock.lock(); defer { lock.unlock() }
        return _binaryPath
    }

    /// gateway baseURL（含 :port 不含 /v1，APIClient 拼 endpoint 用）
    var baseURL: String {
        lock.lock(); defer { lock.unlock() }
        return "http://localhost:\(_port)"
    }

    /// 当前 Bearer token（用于 APIClient 加 Authorization 头）
    var currentToken: String? {
        lock.lock(); defer { lock.unlock() }
        return _token
    }

    /// 状态摘要（设置面板 UI 展示用）
    enum Status: Equatable {
        case starting        // 正在 init / 拉起 daemon
        case running         // /health 200，可用
        case binaryMissing   // 用户没装 openclaw
        case configMissing   // 装了但没跑过 onboard（~/.openclaw/openclaw.json 不存在）
        case endpointDisabled // chatCompletions endpoint 关着且自动 enable 失败
        case failed(String)  // 启动失败
        case disabled        // 用户关掉了自动启动
    }

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        // 显式关掉
        if UserDefaults.standard.object(forKey: Self.autoStartKey) != nil,
           !UserDefaults.standard.bool(forKey: Self.autoStartKey) {
            return .disabled
        }
        if _ready { return .running }
        if let err = _lastError { return .failed(err) }
        if _binaryPath == nil { return .binaryMissing }
        if _token == nil { return .configMissing }
        if !_endpointEnabled { return .endpointDisabled }
        return .starting
    }

    // MARK: - Lifecycle

    /// 完整启动流程：探测 → 读配置 → 自动 enable endpoint → 启 daemon → ping ready。
    /// 调用方：AppDelegate.didFinishLaunching 里 `Task { await OpenClawGatewayManager.shared.startIfAvailable() }`
    func startIfAvailable() async {
        // 1. 自动启动开关
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.autoStartKey) != nil,
           !defaults.bool(forKey: Self.autoStartKey) {
            recordError(nil)
            return
        }

        // 2. 探测 binary
        guard let binary = locateOpenClawBinary() else {
            commitBinaryMissing()
            return
        }
        commitBinaryPath(binary)

        // 3. 读 ~/.openclaw/openclaw.json
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".openclaw/openclaw.json")
        guard let cfg = loadConfig(at: configURL) else {
            recordError("配置文件不存在或解析失败：\(configURL.path)。请先跑 `openclaw onboard --install-daemon`")
            return
        }

        // 4. 拿 token / port / endpoint enabled
        commitConfig(cfg)

        // 5. endpoint 没 enable → 自动改 + 重启
        if !cfg.endpointEnabled {
            if enableEndpointInConfig(at: configURL) {
                // 写盘成功，重启 daemon 让配置生效
                _ = runOpenClawCommand(binary: binary, args: ["daemon", "restart"])
                // 重启 1.5s 给 launchd 接管时间
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // 再读一次 config 确认 endpoint 已 enable
                if let cfg2 = loadConfig(at: configURL), cfg2.endpointEnabled {
                    commitConfig(cfg2)
                } else {
                    recordError("自动 enable chatCompletions endpoint 失败，请手动检查 ~/.openclaw/openclaw.json")
                    return
                }
            } else {
                recordError("写入 chatCompletions enabled 字段失败（权限问题？）")
                return
            }
        }

        // 6. ping /health → 通过就 ready
        if await pingHealth() {
            commitReady()
            broadcastReady()
            return
        }

        // 7. daemon 没跑 → invoke `openclaw daemon start` 让 launchd 接管
        _ = runOpenClawCommand(binary: binary, args: ["daemon", "start"])
        let ready = await waitForReady(timeoutSeconds: 12)
        if ready {
            commitReady()
            broadcastReady()
        } else {
            recordError("启动 12s 内未就绪（openclaw daemon start 没监听 :\(_port)）")
        }
    }

    /// OpenClaw daemon 由 launchd 管理，HermesPet 退出时**不主动停**它 —— 用户可能还在用。
    /// 仅为对称接口（HermesGatewayManager 有 terminate）保留 no-op
    func terminate() {
        // no-op：daemon 由 launchd 接管，HermesPet 退出不影响它
    }

    // MARK: - Internal

    /// 找 openclaw binary（homebrew / npm global / 用户 shell PATH）
    private func locateOpenClawBinary() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            "\(NSHomeDirectory())/.npm-global/bin/openclaw"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // 兜底走 zsh -l PATH
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", "which openclaw 2>/dev/null"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }

    /// 解析后的配置片段
    struct ParsedConfig {
        let token: String?
        let port: Int
        let endpointEnabled: Bool
    }

    /// 读 + 解析 ~/.openclaw/openclaw.json
    private func loadConfig(at url: URL) -> ParsedConfig? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = root["gateway"] as? [String: Any] else {
            return nil
        }
        let auth = gateway["auth"] as? [String: Any]
        let token = auth?["token"] as? String   // password mode 也可能有，但我们优先认 token
        let port = (gateway["port"] as? Int) ?? 18789
        let endpoints = (gateway["http"] as? [String: Any])?["endpoints"] as? [String: Any]
        let chatCompletions = endpoints?["chatCompletions"] as? [String: Any]
        let enabled = (chatCompletions?["enabled"] as? Bool) ?? false
        return ParsedConfig(token: token, port: port, endpointEnabled: enabled)
    }

    /// 把 chatCompletions.enabled = true 写回 json（原子写入：先写临时文件再 rename）
    private func enableEndpointInConfig(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        var gateway = (root["gateway"] as? [String: Any]) ?? [:]
        var http = (gateway["http"] as? [String: Any]) ?? [:]
        var endpoints = (http["endpoints"] as? [String: Any]) ?? [:]
        var chatCompletions = (endpoints["chatCompletions"] as? [String: Any]) ?? [:]
        chatCompletions["enabled"] = true
        endpoints["chatCompletions"] = chatCompletions
        http["endpoints"] = endpoints
        gateway["http"] = http
        root["gateway"] = gateway
        do {
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            // 原子写入：tmp 文件 + rename
            let tmpURL = url.appendingPathExtension("tmp")
            try out.write(to: tmpURL, options: .atomic)
            // 保留原权限（openclaw config 是 0600）
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            return true
        } catch {
            return false
        }
    }

    /// 异步 invoke `openclaw daemon start/restart`（不阻塞 HermesPet）
    @discardableResult
    private func runOpenClawCommand(binary: String, args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.environment = CLIProcessEnvironment.make(executablePath: binary)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    /// 同步取 port（async 函数不能用 NSLock，所以包一层同步 helper）
    private func currentPortSync() -> Int {
        lock.lock(); defer { lock.unlock() }
        return _port
    }

    /// ping /health → 200 = daemon 可用
    private func pingHealth() async -> Bool {
        let port = currentPortSync()
        guard let url = URL(string: "http://localhost:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// 轮询 ping 直到通 / 超时
    private func waitForReady(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if await pingHealth() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func broadcastReady() {
        NotificationCenter.default.post(
            name: .init("HermesPetOpenClawReady"),
            object: nil,
            userInfo: nil
        )
    }

    // MARK: - State commit helpers (lock 收敛)

    private func commitBinaryPath(_ path: String) {
        lock.lock(); self._binaryPath = path; lock.unlock()
    }

    private func commitBinaryMissing() {
        lock.lock()
        self._binaryPath = nil
        self._ready = false
        self._lastError = nil
        lock.unlock()
    }

    private func commitConfig(_ cfg: ParsedConfig) {
        lock.lock()
        self._token = cfg.token
        self._port = cfg.port
        self._endpointEnabled = cfg.endpointEnabled
        lock.unlock()
    }

    private func commitReady() {
        lock.lock()
        self._ready = true
        self._lastError = nil
        lock.unlock()
    }

    private func recordError(_ msg: String?) {
        lock.lock()
        self._lastError = msg
        self._ready = false
        lock.unlock()
    }
}
