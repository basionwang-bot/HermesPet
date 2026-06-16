import Foundation

/// 云中继客户端 —— 让家里这台 Mac「主动连出」到云服务器待命，
/// 这样手机在外网(4G/5G)也能通过云中转操控它（不再限同一 WiFi）。
///
/// 机制：用 WebSocket 长连接挂到中转的 `/agent`，收到中转转发来的请求后，
/// 复用 `CommandServer.produceResponse` 算出响应再原样回包。
/// 因为复用同一套处理逻辑，CommandServer 现有的所有端点都自动支持，无需逐个适配。
///
/// 配置来源（任一即可）：
///   1) 环境变量 HERMES_RELAY_URL + HERMES_RELAY_TOKEN（方便本地测试）
///   2) ~/.hermespet/cloud.json  形如 {"relayURL":"ws://1.2.3.4:8787","token":"<登录令牌>"}
@MainActor
final class CloudRelayClient {
    static let shared = CloudRelayClient()

    private lazy var session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var started = false
    private var intentionalStop = false
    private var reconnectDelay: TimeInterval = 1
    private var pingTimer: Timer?

    private(set) var isConnected = false

    private init() {}

    struct Config { let url: URL; let token: String }

    /// 读云中转配置（环境变量优先，再读 ~/.hermespet/cloud.json）。没配置返回 nil。
    private func loadConfig() -> Config? {
        let env = ProcessInfo.processInfo.environment
        if let u = env["HERMES_RELAY_URL"], let t = env["HERMES_RELAY_TOKEN"],
           let url = URL(string: u), !t.isEmpty {
            return Config(url: url, token: t)
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/cloud.json")
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let u = obj["relayURL"] as? String, let t = obj["token"] as? String,
           let url = URL(string: u), !t.isEmpty {
            return Config(url: url, token: t)
        }
        return nil
    }

    /// 启动（重复调用安全）。没配置时不报错、不重试 —— 用户在设置里配好后再调一次即可。
    func start() {
        guard !started else { return }
        started = true
        intentionalStop = false
        reconnectDelay = 1
        connect()
    }

    func stop() {
        intentionalStop = true
        started = false
        #if canImport(SwiftTerm)
        RemoteTerminalManager.shared.closeAll()
        #endif
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    /// 配置变了（比如刚登录账号、写了新的 cloud.json）→ 断开重连。
    func reload() {
        intentionalStop = false
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(); task = nil
        isConnected = false
        started = false
        reconnectDelay = 1
        start()
    }

    private func connect() {
        guard !intentionalStop else { return }
        guard let cfg = loadConfig() else {
            NSLog("[CloudRelay] 未配置云中转(~/.hermespet/cloud.json)，暂不连接")
            started = false   // 允许配好后再 start()
            return
        }

        // 把 token 拼到 /agent?token=... （url 可带或不带 /agent 路径）
        guard var comps = URLComponents(url: cfg.url, resolvingAgainstBaseURL: false) else {
            NSLog("[CloudRelay] 地址无法解析: %@", cfg.url.absoluteString)
            started = false; return
        }
        if !comps.path.hasSuffix("/agent") {
            // ⚠️ 带 host 的 URL，path 必须以 "/" 开头，否则 comps.url 会变 nil。
            let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
            comps.path = base + "/agent"     // 空路径 → "/agent"
        }
        comps.queryItems = [URLQueryItem(name: "token", value: cfg.token)]
        guard let wsURL = comps.url else {
            NSLog("[CloudRelay] 拼接地址失败 (path=%@)", comps.path)
            started = false; return
        }

        let task = session.webSocketTask(with: wsURL)
        self.task = task
        task.resume()
        NSLog("[CloudRelay] 连接中: %@", wsURL.absoluteString)
        receive()
        schedulePing()
    }

    /// 周期 ping 保活（URLSession 会自动回应中转发来的 ping，这里主动 ping 是为尽早发现断线）
    private func schedulePing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.task?.sendPing { _ in } }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    NSLog("[CloudRelay] 接收失败: %@", "\(err)")
                    self.isConnected = false
                    self.scheduleReconnect()
                case .success(let message):
                    self.reconnectDelay = 1     // 收到消息=连接健康，重置退避
                    self.isConnected = true
                    switch message {
                    case .string(let s): self.handleMessage(s)
                    case .data(let d): self.handleMessage(String(data: d, encoding: .utf8) ?? "")
                    @unknown default: break
                    }
                    self.receive()              // 继续收下一条
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !intentionalStop else { return }
        #if canImport(SwiftTerm)
        RemoteTerminalManager.shared.closeAll()   // 连接断了，远程终端都失联，清掉
        #endif
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(); task = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)   // 指数退避，最多 30s
        NSLog("[CloudRelay] %.0f 秒后重连", delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    /// 处理中转发来的一条消息：hello 忽略；req 则算响应回包。
    private func handleMessage(_ s: String) {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if type == "hello" {
            NSLog("[CloudRelay] 已挂载到云中转，待命中")
            return
        }

        // —— 远程终端通道：手机通过中转开/喂/调整/关一个真实 PTY ——
        #if canImport(SwiftTerm)
        switch type {
        case "term-open":
            let termId = obj["termId"] as? String ?? ""
            guard !termId.isEmpty else { return }
            let cols = (obj["cols"] as? Int) ?? 80
            let rows = (obj["rows"] as? Int) ?? 24
            let sessionName = (obj["tmux"] as? String) ?? "main"
            let out: @Sendable (Data) -> Void = { [weak self] d in
                Task { @MainActor in self?.sendTerm(type: "term-out", termId: termId, data: d) }
            }
            let exit: @Sendable (Int32) -> Void = { [weak self] code in
                Task { @MainActor in self?.sendTermExit(termId: termId, code: code) }
            }
            RemoteTerminalManager.shared.open(termId: termId, sessionName: sessionName,
                                              cols: cols, rows: rows, onOutput: out, onExit: exit)
            return
        case "term-in":
            if let termId = obj["termId"] as? String,
               let b64 = obj["dataB64"] as? String, let d = Data(base64Encoded: b64) {
                RemoteTerminalManager.shared.input(termId: termId, data: d)
            }
            return
        case "term-resize":
            if let termId = obj["termId"] as? String {
                let cols = (obj["cols"] as? Int) ?? 80
                let rows = (obj["rows"] as? Int) ?? 24
                RemoteTerminalManager.shared.resize(termId: termId, cols: cols, rows: rows)
            }
            return
        case "term-close":
            if let termId = obj["termId"] as? String {
                RemoteTerminalManager.shared.close(termId: termId)
            }
            return
        default:
            break
        }
        #endif

        guard type == "req", let reqId = obj["reqId"] as? String else { return }

        let method = obj["method"] as? String ?? "GET"
        let path = obj["path"] as? String ?? "/"
        var body: Data?
        if let b64 = obj["bodyB64"] as? String, !b64.isEmpty {
            body = Data(base64Encoded: b64)
        }

        // 复用本地同一套请求处理逻辑
        let (status, contentType, respData) = CommandServer.shared.produceResponse(
            method: method, rawPath: path, body: body)

        let resp: [String: Any] = [
            "type": "res",
            "reqId": reqId,
            "status": status,
            "contentType": contentType,
            "bodyB64": respData.base64EncodedString(),
        ]
        if let out = try? JSONSerialization.data(withJSONObject: resp),
           let str = String(data: out, encoding: .utf8) {
            task?.send(.string(str)) { err in
                if let err { NSLog("[CloudRelay] 回包失败: %@", "\(err)") }
            }
        }
    }

    // MARK: - 终端帧发送

    private func sendTerm(type: String, termId: String, data: Data) {
        sendJSON(["type": type, "termId": termId, "dataB64": data.base64EncodedString()])
    }
    private func sendTermExit(termId: String, code: Int32) {
        sendJSON(["type": "term-exit", "termId": termId, "code": Int(code)])
    }
    private func sendJSON(_ obj: [String: Any]) {
        guard let out = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: out, encoding: .utf8) else { return }
        task?.send(.string(s)) { err in
            if let err { NSLog("[CloudRelay] 终端帧发送失败: %@", "\(err)") }
        }
    }
}
