import Foundation
import Network

/// HermesPet 内嵌的本地 HTTP server，专门给 Claude Code / Codex CLI 的 permission hook 用。
///
/// **架构**：
/// - 启动时绑定 127.0.0.1 任意可用端口（保存到 UserDefaults `permissionHookPort`）
/// - Claude Code 通过 `~/.claude/settings.json` 的 `type: http` hook 配置 POST 过来
/// - Codex 通过 `~/.codex/config.toml` 的 `type: command` + 一个 shell script 中转 POST 过来
/// - 收到 POST /permission-hook → 转 PermissionRequest → 广播给 PermissionWindow → 等用户决策
/// - 用户决策回来后按 source（claude / codex）返回对应格式的 JSON 响应
///
/// **为什么不用 Swifter / Vapor**：避免引入大型 HTTP 依赖。
/// NWListener (Apple Network framework) 自己写最小 HTTP 1.1 解析器，~200 行能搞定 POST/响应
@MainActor
final class PermissionHookServer {

    static let shared = PermissionHookServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// pendingRequests[requestID] = continuation
    /// 收到 hook POST 时新建 continuation 挂起 HTTP 响应；用户决策后 resume
    private var pendingResponses: [String: (PermissionDecision, String?) -> Void] = [:]

    /// 与 pendingResponses 平行：保存每条未决请求的【真实数据】（工具名/参数/sessionID 等）
    /// 和它被问到的时刻。手机端「远程拍板」要靠这个把未决列表暴露出去（M3）。
    /// continuation 只是个闭包，序列化不了，所以另存一份结构化数据。
    private var pendingRequests: [String: (request: PermissionRequest, askedAt: Date)] = [:]

    private init() {}

    /// 启动 server。失败抛错（端口被占等罕见情况）
    func start() throws {
        if listener != nil { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true   // 只接受 localhost 连接

        let l = try NWListener(using: params)
        self.listener = l

        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = l.port?.rawValue {
                    Task { @MainActor in
                        self?.port = p
                        UserDefaults.standard.set(Int(p), forKey: "permissionHookPort")
                        NSLog("[PermissionHookServer] listening on 127.0.0.1:%d", Int(p))
                    }
                }
            case .failed(let err):
                NSLog("[PermissionHookServer] failed: %@", "\(err)")
            default: break
            }
        }
        l.start(queue: .main)

        // 监听用户在 PermissionWindow 上的决策，回写到对应的 HTTP 响应。
        // NotificationCenter block observer 的闭包是 @Sendable，Swift 6 看不出 queue:.main
        // 等于 MainActor，所以显式包 Task @MainActor 桥过去。
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetPermissionDecisionMade"),
            object: nil, queue: .main
        ) { note in
            guard let requestID = note.userInfo?["requestID"] as? String,
                  let raw = note.userInfo?["decision"] as? String,
                  let decision = PermissionDecision(rawValue: raw) else { return }
            Task { @MainActor in
                Self.shared.dispatchDecision(requestID: requestID, decision: decision)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// 用户（本机卡片 或 手机远程）决策后，resume 那条挂起的 CLI HTTP 响应放行。
    /// 改成 @discardableResult + 返回是否命中，给手机端 /permission/decide 判 ok。
    @discardableResult
    func dispatchDecision(requestID: String, decision: PermissionDecision) -> Bool {
        pendingRequests.removeValue(forKey: requestID)   // 真实数据也一并清掉，未决列表立即更新
        guard let resume = pendingResponses.removeValue(forKey: requestID) else { return false }
        resume(decision, nil)
        // 同步通知本机卡片收起（手机远程拍板时本机卡片也得跟着关）
        NotificationCenter.default.post(
            name: .init("HermesPetPermissionReplied"),
            object: nil,
            userInfo: ["requestID": requestID]
        )
        return true
    }

    // MARK: - 给手机端「远程拍板」用的只读桥（M3）

    /// 列出当前所有未决权限请求（按问到时间升序）。CommandServer 的 /permissions 端点序列化它。
    /// 只读快照，不影响挂起的 CLI 请求。
    func pendingList() -> [(request: PermissionRequest, askedAt: Date)] {
        pendingRequests.values.sorted { $0.askedAt < $1.askedAt }
    }

    /// 手机远程拍板回写：等价于本机点了卡片按钮。命中返回 true。
    /// 走和本机一样的 dispatchDecision，触发 CLI 继续 + 本机卡片收起。
    @discardableResult
    func remoteDecide(requestID: String, decision: PermissionDecision) -> Bool {
        dispatchDecision(requestID: requestID, decision: decision)
    }

    // MARK: - 单连接处理
    //
    // NWConnection 的 receive 回调签名是 @Sendable + 在内部 dispatch queue 上跑，
    // Swift 6 不能假设它在 MainActor。所以这里走 nonisolated 路径：
    // - receiveLoop 标 nonisolated，可以被 @Sendable 闭包安全调
    // - 缓冲区用 DataBuffer (class + NSLock) 让 @Sendable 闭包能 capture mutable state
    // - 解析函数标 nonisolated（它们是纯函数，不需要 actor 上下文）
    // - 真正需要 @MainActor 的 handleRequest 用 Task @MainActor 桥过去

    nonisolated private func handleConnection(_ conn: NWConnection) {
        let buffer = DataBuffer()
        receiveLoop(conn: conn, buffer: buffer)
    }

    nonisolated private func receiveLoop(conn: NWConnection, buffer: DataBuffer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                buffer.append(data)
                // 检查是否收到完整 HTTP request（含 body）
                if let request = Self.parseHTTPRequest(buffer.snapshot()),
                   Self.hasFullBody(request: request) {
                    Task { @MainActor in
                        self?.handleRequest(request, on: conn)
                    }
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

    private func handleRequest(_ req: HTTPRequest, on conn: NWConnection) {
        // 只接 POST /permission-hook
        guard req.method == "POST",
              req.path == "/permission-hook",
              let bodyData = req.body else {
            Self.respond(conn: conn, status: 404, body: "{}".data(using: .utf8)!)
            return
        }

        // 解析 payload（兼容 Claude PreToolUse / Codex PermissionRequest 两种 source）
        guard let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            Self.respond(conn: conn, status: 400, body: "{\"error\":\"bad json\"}".data(using: .utf8)!)
            return
        }

        let source = HookSource.detect(payload: payload)
        let request = Self.buildPermissionRequest(payload: payload, source: source)

        // 广播给 PermissionWindow 显示卡片，挂起 HTTP 响应直到用户决策
        let reqID = request.id
        self.pendingResponses[reqID] = { [weak conn] decision, reason in
            guard let conn = conn else { return }
            let respBody = source.responseBody(decision: decision, reason: reason)
            Self.respond(conn: conn, status: 200, body: respBody)
        }
        // 同步登记结构化数据，供手机端 /permissions 列出（M3 远程拍板）
        self.pendingRequests[reqID] = (request: request, askedAt: Date())

        NotificationCenter.default.post(
            name: .init("HermesPetPermissionAsked"),
            object: nil,
            userInfo: ["request": request]
        )
    }

    /// 把 hook payload 转成 PermissionRequest 数据结构（复用现有 UI）
    /// Claude / Codex payload 字段名不同但语义对齐：tool_name + tool_input
    private static func buildPermissionRequest(payload: [String: Any], source: HookSource) -> PermissionRequest {
        let toolName = (payload["tool_name"] as? String) ?? "Unknown"
        let toolInput = (payload["tool_input"] as? [String: Any]) ?? [:]
        let sessionID = (payload["session_id"] as? String) ?? "ses_\(UUID().uuidString)"
        let id = "per_\(UUID().uuidString)"

        var metadata: [String: AnyCodable] = ["tool": .string(toolName)]
        for (k, v) in toolInput {
            metadata[k] = anyCodableFrom(v)
        }

        return PermissionRequest(
            id: id,
            sessionID: sessionID,
            permission: toolName.lowercased(),
            patterns: [],
            metadata: metadata,
            always: [],
            tool: nil
        )
    }

    private static func anyCodableFrom(_ v: Any) -> AnyCodable {
        if let s = v as? String { return .string(s) }
        if let b = v as? Bool { return .bool(b) }
        if let i = v as? Int { return .int(i) }
        if let d = v as? Double { return .double(d) }
        return .string("\(v)")
    }

    // MARK: - HTTP 解析（最小可用实现）

    struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    /// 简单的 thread-safe 字节缓冲，让 @Sendable closure 安全捕获并 mutate
    final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        func snapshot() -> Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    /// 返回 nil 表示数据还没收齐（header 都没收完）
    nonisolated private static func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let headerEndRange = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            return nil   // 还没收到 \r\n\r\n 分隔，header 没结束
        }
        let headerData = data.subdata(in: 0..<headerEndRange.lowerBound)
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

        let bodyStart = headerEndRange.upperBound
        let body = bodyStart < data.count ? data.subdata(in: bodyStart..<data.count) : nil

        return HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    /// 检查是否收到了完整 body（按 Content-Length 比对）
    nonisolated private static func hasFullBody(request: HTTPRequest) -> Bool {
        let expected = Int(request.headers["content-length"] ?? "0") ?? 0
        let actual = request.body?.count ?? 0
        return actual >= expected
    }

    nonisolated private static func respond(conn: NWConnection, status: Int, body: Data) {
        let statusText = status == 200 ? "OK" : "Error"
        let headers = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var resp = headers.data(using: .utf8)!
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - Hook source（Claude / Codex 两种协议）

/// hook 调用源，决定响应 JSON 格式（两家协议不同）
enum HookSource {
    case claude    // Claude Code PreToolUse: hookSpecificOutput.permissionDecision = "allow"|"deny"|"ask"
    case codex     // Codex PermissionRequest: hookSpecificOutput.decision.behavior = "allow"|"deny"
    case unknown

    /// 按 payload 里的 hook_event_name 判断
    static func detect(payload: [String: Any]) -> HookSource {
        let event = (payload["hook_event_name"] as? String) ?? ""
        switch event {
        case "PreToolUse":         return .claude
        case "PermissionRequest":  return .codex
        default:                   return .unknown
        }
    }

    /// 把用户决策 → 对应 CLI 协议的 JSON 响应
    func responseBody(decision: PermissionDecision, reason: String?) -> Data {
        let obj: [String: Any]
        switch self {
        case .claude:
            let perm: String
            switch decision {
            case .once, .always: perm = "allow"
            case .reject:        perm = "deny"
            }
            var inner: [String: Any] = [
                "hookEventName": "PreToolUse",
                "permissionDecision": perm
            ]
            if let r = reason { inner["permissionDecisionReason"] = r }
            obj = ["hookSpecificOutput": inner]
        case .codex:
            let behavior: String
            switch decision {
            case .once, .always: behavior = "allow"
            case .reject:        behavior = "deny"
            }
            var deci: [String: Any] = ["behavior": behavior]
            if let r = reason { deci["message"] = r }
            obj = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": deci
                ]
            ]
        case .unknown:
            // 兜底：返回空 → CLI 走默认行为
            obj = [:]
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
