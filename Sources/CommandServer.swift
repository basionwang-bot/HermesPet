import Foundation
import Network
import Darwin

/// 手机端命令接收器（局域网）。
///
/// 和 `PermissionHookServer` 的区别：那个只接本机（`acceptLocalOnly = true`），
/// 这个要让【手机】在同一 WiFi 下连进来，所以**监听所有网卡**。收到手机派来的活
/// 就回调 `onCommand`，由 AppDelegate 交给 `ChatViewModel.sendMessage()` 真的让 AI 干。
///
/// 第一版：纯局域网明文 HTTP、无鉴权（仅家庭内网演示用）。
/// 上云那步会换成走云端中继 + 鉴权。HTTP 解析逻辑复制自 PermissionHookServer。
@MainActor
final class CommandServer {
    static let shared = CommandServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// 收到手机命令（已在主线程）。参数 (命令文本, 手机选的 AI mode rawValue)；返回这条活落在的对话 id。
    var onCommand: ((String, String?) -> String?)?

    /// 查询某对话的实时状态（消息 + 是否还在回复）。AppDelegate 提供，返回 JSON data。
    var stateProvider: ((String) -> Data?)?

    /// 列出所有「成果」（已生成网页）。AppDelegate 提供，返回 JSON data。
    var artifactsProvider: (() -> Data?)?
    /// 取某个成果的网页 HTML。参数 = artifact id；返回 HTML data（找不到返回 nil）。
    var artifactContentProvider: ((String) -> Data?)?

    /// 读最近一份「银月早报」。AppDelegate 提供，返回 JSON data。
    var briefingProvider: (() -> Data?)?
    /// 触发立即生成一份早报。AppDelegate 提供。
    var briefingGenerator: (() -> Void)?

    /// 列出当前所有未决权限请求（M3 远程拍板）。AppDelegate 提供，返回 {pending:[...]} 的 JSON data。
    var pendingPermissionsProvider: (() -> Data?)?
    /// 手机远程拍板回写：参数 (id, decision)，decision = once|always|reject。返回是否命中那条未决请求。
    var permissionDecider: ((String, String) -> Bool)?

    /// 列出内置工作流「技能卡」（M4）。AppDelegate 提供，返回 {workflows:[...]} 的 JSON data。
    var workflowsProvider: (() -> Data?)?
    /// 跑一个工作流：参数 (workflowID, input, mode?)，返回这次运行的 runId（找不到工作流返回 nil）。
    var workflowRunner: ((String, String, String?) -> String?)?
    /// 查某次运行的实时轨迹/进度（M4）。参数 = runId；返回该运行状态的 JSON data（找不到返回 nil）。
    var runStateProvider: ((String) -> Data?)?
    /// 工作流中途人工确认回写（M4）。参数 (runId, decision)，decision = allow|skip|abort。
    var runConfirmer: ((String, String) -> Void)?

    /// 连接专用队列 —— 跟 listener 的队列分开，发大图(1.7MB)不会卡死监听
    private let connectionQueue = DispatchQueue(label: "hermespet.commandserver.conn")

    // MARK: - 自愈（防止监听静默挂掉：Mac 睡眠/WiFi 切换后 NWListener 常进 failed 却没人管）
    private var configuredPort: UInt16 = 8765   // 记住要监听的端口，自愈时复用
    private var watchdog: Timer?                 // 看门狗：周期兜底自检
    private var restarting = false               // 防止重启重入
    private var listenerReady = false            // 监听当前是否健康（.ready）
    private var intentionalStop = false          // 是否主动 stop（主动停就不自愈）
    private var lastActionAt = Date.distantPast  // 上次启动/重启时刻，给 .ready 留宽限期

    private init() {}

    /// 启动。优先用固定端口（手机好记），被占就退随机端口。
    /// 内部会同时拉起看门狗，监听万一挂了能自动重启（Mac 睡眠/WiFi 切换后常见）。
    func start(preferredPort: UInt16 = 8765) throws {
        configuredPort = preferredPort
        intentionalStop = false
        try startListener()
        startWatchdog()
    }

    /// 真正建立监听 —— 自愈重启时也复用这个
    private func startListener() throws {
        if listener != nil { return }
        lastActionAt = Date()   // 标记刚动过，给后面的 .ready 留宽限期，免得看门狗误杀
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 注意：不设 acceptLocalOnly —— 监听所有网卡，手机才能从局域网连进来

        let l: NWListener
        if let p = NWEndpoint.Port(rawValue: configuredPort),
           let made = try? NWListener(using: params, on: p) {
            l = made
        } else {
            l = try NWListener(using: params)   // 固定端口被占，退随机端口
        }
        self.listener = l

        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.connectionQueue)
            self.handleConnection(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = l.port?.rawValue {
                    Task { @MainActor in
                        self?.listenerReady = true
                        self?.port = p
                        self?.writeEndpointFile(port: p)
                        NSLog("[CommandServer] listening on 0.0.0.0:%d (LAN ip=%@)",
                              Int(p), CommandServer.localIPAddress() ?? "?")
                    }
                }
            case .failed(let err):
                NSLog("[CommandServer] failed: %@", "\(err)")
                Task { @MainActor in self?.scheduleRestart(reason: "failed") }
            case .waiting(let err):
                NSLog("[CommandServer] waiting: %@", "\(err)")
                Task { @MainActor in self?.listenerReady = false }
            case .cancelled:
                Task { @MainActor in self?.listenerReady = false }
            default: break
            }
        }
        l.start(queue: .main)
    }

    /// 监听报 failed → 延迟 2 秒重启（带防重入）
    private func scheduleRestart(reason: String) {
        listenerReady = false
        guard !intentionalStop, !restarting else { return }
        restarting = true
        NSLog("[CommandServer] 监听异常(%@)，2 秒后自动重启", reason)
        listener?.cancel()
        listener = nil
        port = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.restarting = false
            if !self.intentionalStop { try? self.startListener() }
        }
    }

    /// 看门狗：每 5 秒兜底自检 —— 监听不在线（且过了宽限期）就强制拉起来。
    /// 覆盖 stateUpdateHandler 没捕获到的各种"静默死亡"。
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.intentionalStop, !self.restarting else { return }
                // 刚启动/刚重启的 8 秒内不打扰，等它自己 ready
                guard Date().timeIntervalSince(self.lastActionAt) > 8 else { return }
                if self.listener == nil || !self.listenerReady {
                    NSLog("[CommandServer] watchdog: 监听不在线，重启")
                    self.listener?.cancel()
                    self.listener = nil
                    self.port = 0
                    try? self.startListener()
                }
            }
        }
    }

    func stop() {
        intentionalStop = true
        watchdog?.invalidate()
        watchdog = nil
        listener?.cancel()
        listener = nil
        listenerReady = false
        port = 0
    }

    /// 把"手机要连的地址"写到 ~/.hermespet/phone-endpoint.txt，方便查/填到手机里
    private func writeEndpointFile(port: UInt16) {
        let ip = CommandServer.localIPAddress() ?? "127.0.0.1"
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermespet")
        let url = dir.appendingPathComponent("phone-endpoint.txt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(ip):\(port)".data(using: .utf8)?.write(to: url)
    }

    // MARK: - 连接处理（并发模式照抄 PermissionHookServer：nonisolated + DataBuffer）

    nonisolated private func handleConnection(_ conn: NWConnection) {
        let buffer = DataBuffer()
        receiveLoop(conn: conn, buffer: buffer)
    }

    nonisolated private func receiveLoop(conn: NWConnection, buffer: DataBuffer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                buffer.append(data)
                if let request = Self.parseHTTPRequest(buffer.snapshot()),
                   Self.hasFullBody(request: request) {
                    self?.route(request, on: conn)
                    return
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self?.receiveLoop(conn: conn, buffer: buffer)
        }
    }

    /// 路由：不需要对话数据的端点(ping/image)在连接队列直接回；需要的(state/command)才切主线程
    nonisolated private func route(_ req: HTTPRequest, on conn: NWConnection) {
        let (path, query) = Self.splitPathQuery(req.path)
        switch (req.method, path) {
        case ("GET", "/ping"):
            Self.respond(conn: conn, status: 200,
                         body: "{\"ok\":true,\"app\":\"HermesPet\"}".data(using: .utf8)!)
        case ("GET", "/image"):
            let name = ((query["name"] ?? "") as NSString).lastPathComponent
            let fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermespet/images").appendingPathComponent(name)
            if !name.isEmpty, let data = try? Data(contentsOf: fileURL) {
                Self.respond(conn: conn, status: 200, body: data, contentType: "image/png")
            } else {
                Self.respond(conn: conn, status: 404, body: "{}".data(using: .utf8)!)
            }
        default:
            Task { @MainActor in self.handleRequest(req, on: conn) }
        }
    }

    /// 计算某个请求的响应（与「连接」无关的纯逻辑）。
    /// 局域网路径(handleRequest) 和 云中继路径(CloudRelayClient) 都复用它，
    /// 所以以后新增端点只要在这里加一处 case，两条路都自动支持。
    func produceResponse(method: String, rawPath: String, body: Data?) -> (status: Int, contentType: String, body: Data) {
        let (path, query) = Self.splitPathQuery(rawPath)
        let jsonType = "application/json"
        let badRequest: (Int, String, Data) = (400, jsonType, "{\"error\":\"bad request\"}".data(using: .utf8)!)

        switch (method, path) {
        // GET /ping —— 测连通
        case ("GET", "/ping"):
            return (200, jsonType, "{\"ok\":true,\"app\":\"HermesPet\"}".data(using: .utf8)!)

        // GET /term/sessions —— 列出 tmux 持久会话（手机端展示「电脑上开着的终端」）
        case ("GET", "/term/sessions"):
            #if canImport(SwiftTerm)
            let obj: [String: Any] = ["sessions": Tmux.listSessions()]
            let data = (try? JSONSerialization.data(withJSONObject: obj))
                ?? "{\"sessions\":[]}".data(using: .utf8)!
            return (200, jsonType, data)
            #else
            return (200, jsonType, "{\"sessions\":[]}".data(using: .utf8)!)
            #endif

        // POST /meeting/start —— 调试：直接启动会议录音管道（不开 UI，MeetingRecorder 全方法线程安全）
        // ?nosys=1 跳过系统音频路（麦克风单路对照实验）
        case ("POST", "/meeting/start"):
            let ok = MeetingRecorder.shared.start(systemLaneEnabled: query["nosys"] != "1")
            return (200, jsonType, "{\"ok\":\(ok ? "true" : "false")}".data(using: .utf8)!)

        // POST /meeting/stop —— 调试：异步收尾（stopAndFinalize 要等尾段冲刷，不能阻塞 MainActor）。
        // 终稿等收尾完从 GET /meeting/state 拿（entries 到下一场开始前一直在）。
        case ("POST", "/meeting/stop"):
            Task { _ = await MeetingRecorder.shared.stopAndFinalize() }
            return (200, jsonType, "{\"ok\":true,\"finalizing\":true}".data(using: .utf8)!)

        // GET /meeting/state —— 调试：录音管道实时状态
        case ("GET", "/meeting/state"):
            let r = MeetingRecorder.shared
            let obj: [String: Any] = [
                "state": r.state.rawValue,
                "elapsed": r.elapsedSeconds,
                "hasSystemAudio": r.hasSystemAudioContent,
                "transcript": r.fullTranscript,
                "errors": r.lastErrorsSnapshot,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? "{}".data(using: .utf8)!
            return (200, jsonType, data)

        // GET /state?id=xxx —— 某对话的实时状态（消息 + 是否还在回复）
        case ("GET", "/state"):
            let id = query["id"] ?? ""
            return (200, jsonType, stateProvider?(id) ?? "{}".data(using: .utf8)!)

        // GET /image?name=xxx —— 取图片（限 ~/.hermespet/images/，只取 basename 防穿越）
        case ("GET", "/image"):
            let name = ((query["name"] ?? "") as NSString).lastPathComponent
            let fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermespet/images").appendingPathComponent(name)
            if !name.isEmpty, let data = try? Data(contentsOf: fileURL) {
                return (200, "image/png", data)
            }
            return (404, jsonType, "{}".data(using: .utf8)!)

        // GET /artifacts —— 列出所有「成果」
        case ("GET", "/artifacts"):
            return (200, jsonType, artifactsProvider?() ?? "{\"artifacts\":[]}".data(using: .utf8)!)

        // GET /artifact?id=xxx —— 取某个成果的网页 HTML
        case ("GET", "/artifact"):
            let id = query["id"] ?? ""
            if !id.isEmpty, let data = artifactContentProvider?(id) {
                return (200, "text/html; charset=utf-8", data)
            }
            return (404, jsonType, "{}".data(using: .utf8)!)

        // GET /briefing/latest —— 最近一份「银月早报」
        case ("GET", "/briefing/latest"):
            return (200, jsonType, briefingProvider?() ?? "{\"hasBriefing\":false}".data(using: .utf8)!)

        // POST /briefing/generate —— 触发生成一份早报
        case ("POST", "/briefing/generate"):
            briefingGenerator?()
            return (200, jsonType, "{\"ok\":true,\"started\":true}".data(using: .utf8)!)

        // GET /permissions —— 列出未决权限请求
        case ("GET", "/permissions"):
            return (200, jsonType, pendingPermissionsProvider?() ?? "{\"pending\":[]}".data(using: .utf8)!)

        // POST /permission/decide { id, decision } —— 远程拍板
        case ("POST", "/permission/decide"):
            guard let body,
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = obj["id"] as? String,
                  let decision = obj["decision"] as? String, !id.isEmpty else {
                return badRequest
            }
            let ok = permissionDecider?(id, decision) ?? false
            return (200, jsonType, "{\"ok\":\(ok ? "true" : "false")}".data(using: .utf8)!)

        // GET /workflows —— 列出技能卡
        case ("GET", "/workflows"):
            return (200, jsonType, workflowsProvider?() ?? "{\"workflows\":[]}".data(using: .utf8)!)

        // POST /workflow/run { id, input, mode? } —— 跑一个工作流
        case ("POST", "/workflow/run"):
            guard let body,
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = obj["id"] as? String,
                  let input = obj["input"] as? String,
                  !id.isEmpty, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return badRequest
            }
            if let runId = workflowRunner?(id, input, obj["mode"] as? String) {
                let data = (try? JSONSerialization.data(withJSONObject: ["ok": true, "runId": runId]))
                    ?? "{\"ok\":true}".data(using: .utf8)!
                return (200, jsonType, data)
            }
            return (404, jsonType, "{\"ok\":false,\"error\":\"workflow not found\"}".data(using: .utf8)!)

        // GET /run?id=uuid —— 某次运行的轨迹/进度
        case ("GET", "/run"):
            let id = query["id"] ?? ""
            if !id.isEmpty, let data = runStateProvider?(id) {
                return (200, jsonType, data)
            }
            return (404, jsonType, "{}".data(using: .utf8)!)

        // POST /run/confirm { runId, decision } —— 工作流中途人工确认
        case ("POST", "/run/confirm"):
            guard let body,
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let runId = obj["runId"] as? String,
                  let decision = obj["decision"] as? String, !runId.isEmpty else {
                return badRequest
            }
            runConfirmer?(runId, decision)
            return (200, jsonType, "{\"ok\":true}".data(using: .utf8)!)

        // POST /command { text, mode? } —— 手机派来的活
        case ("POST", "/command"):
            guard let body,
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = obj["text"] as? String else {
                return badRequest
            }
            let convID = onCommand?(text, obj["mode"] as? String) ?? ""
            let data = (try? JSONSerialization.data(withJSONObject: ["ok": true, "conversationId": convID]))
                ?? "{\"ok\":true}".data(using: .utf8)!
            return (200, jsonType, data)

        default:
            return badRequest
        }
    }

    /// 局域网连接来的请求：算出响应 → 写回连接。
    private func handleRequest(_ req: HTTPRequest, on conn: NWConnection) {
        let (status, contentType, data) = produceResponse(method: req.method, rawPath: req.path, body: req.body)
        Self.respond(conn: conn, status: status, body: data, contentType: contentType)
    }

    /// 拆 "/state?id=abc&x=1" → ("/state", ["id":"abc","x":"1"])
    nonisolated private static func splitPathQuery(_ raw: String) -> (String, [String: String]) {
        guard let q = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let path = String(raw[..<q])
        let queryStr = String(raw[raw.index(after: q)...])
        var dict: [String: String] = [:]
        for pair in queryStr.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 { dict[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return (path, dict)
    }

    // MARK: - 最小 HTTP 解析（复制自 PermissionHookServer）

    struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk) }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    nonisolated private static func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return nil }
        let headerData = data.subdata(in: 0..<end.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }
        let bodyStart = end.upperBound
        let body = bodyStart < data.count ? data.subdata(in: bodyStart..<data.count) : nil
        return HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    nonisolated private static func hasFullBody(request: HTTPRequest) -> Bool {
        let expected = Int(request.headers["content-length"] ?? "0") ?? 0
        return (request.body?.count ?? 0) >= expected
    }

    nonisolated private static func respond(conn: NWConnection, status: Int, body: Data,
                                            contentType: String = "application/json") {
        let statusText = status == 200 ? "OK" : "Error"
        let headers = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var resp = headers.data(using: .utf8)!
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - 局域网 IP（取 en0 / en1 的 IPv4）

    nonisolated static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr else { continue }
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                                socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: host)
                }
            }
        }
        return address
    }
}
