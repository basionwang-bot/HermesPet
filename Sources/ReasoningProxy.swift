import Foundation
import Network

/// 本地 SSE 过滤代理 —— 修 opencode v1.15.1 跟 reasoning_content 推理模型不兼容的根本问题。
///
/// **背景**：DeepSeek V4 / Kimi K2.x / OpenAI o1+ / 智谱思考链 等推理模型的 streaming chunk
/// 是 `{delta:{content:null, reasoning_content:"思考..."}}`（前 170+ chunk），末尾才出
/// `{delta:{content:"实际回答"}}`。opencode v1.15.1 用 `@ai-sdk/openai-compatible`，
/// 看 `content==null` 就跳过 chunk，结果 reasoning chain 太长把它"耗死" → text 没收到 → "(没有响应)"。
///
/// **架构**：HermesPet 启动时拉起本地 HTTP server (127.0.0.1:<random_port>)，
/// `OpenCodeConfigGenerator` 把 provider `baseURL` 改写成 `http://127.0.0.1:<port>/<provider>`。
/// opencode 调 `http://127.0.0.1:<port>/<provider>/chat/completions` → 本代理转发到真实 provider。
///
/// **核心 filter**：流式响应时逐行 SSE event 处理：
/// - 纯 reasoning chunk (`delta.content==null && delta.reasoning_content!=null`) → **整条丢弃**
/// - 有 content 的 chunk → **剥离 reasoning_content 字段**后透传
/// - `data: [DONE]` / 非 reasoning chunk → 原样透传
///
/// → opencode 看到的是纯净 OpenAI 标准 stream，100% 稳定。
final class ReasoningProxy: @unchecked Sendable {
    static let shared = ReasoningProxy()

    private let lock = NSLock()
    private var listener: NWListener?
    private var _port: Int = 0

    /// 各 provider 真实 baseURL（含 v1/v4 路径前缀）。
    /// 客户端来路：`/<providerID>/chat/completions` → 转发到 `<upstreamBase>/chat/completions`
    static let upstreamBaseURLs: [String: String] = [
        "deepseek": "https://api.deepseek.com/v1",
        "zhipu":    "https://open.bigmodel.cn/api/paas/v4",
        "moonshot": "https://api.moonshot.cn/v1",
        "minimax":  "https://api.minimaxi.com/v1",
        "openai":   "https://api.openai.com/v1"
    ]

    private init() {}

    // MARK: - Public state

    /// proxy 监听的真实端口（NWListener 让系统选空闲端口，启动后才确定）
    var port: Int {
        lock.lock(); defer { lock.unlock() }
        return _port
    }

    /// 给 OpenCodeConfigGenerator 用：`http://127.0.0.1:<port>`
    var baseURL: URL? {
        let p = port
        guard p > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(p)")
    }

    var isReady: Bool { port > 0 }

    // MARK: - Lifecycle

    /// 启动 proxy。AppDelegate.applicationDidFinishLaunching 调
    func start() {
        Self.fileLog("start() called")
        lock.lock()
        let alreadyRunning = listener != nil
        lock.unlock()
        guard !alreadyRunning else {
            Self.fileLog("start() noop: listener already exists")
            return
        }

        do {
            // 让系统在 ephemeral 范围内挑空闲端口
            let listener = try NWListener(using: NWParameters.tcp, on: .any)
            Self.fileLog("NWListener created")
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .setup:        Self.fileLog("listener state: setup")
                case .waiting(let err):  Self.fileLog("listener state: waiting err=\(err)")
                case .ready:
                    if let p = listener.port {
                        self.setPort(Int(p.rawValue))
                        Self.fileLog("listener state: READY on 127.0.0.1:\(p.rawValue)")
                    } else {
                        Self.fileLog("listener state: ready but no port?")
                    }
                case .failed(let err):
                    Self.fileLog("listener state: FAILED \(err)")
                    self.setPort(0)
                case .cancelled:    Self.fileLog("listener state: cancelled")
                @unknown default:   Self.fileLog("listener state: unknown")
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            Self.fileLog("listener.start() called")
            lock.lock(); self.listener = listener; lock.unlock()
        } catch {
            Self.fileLog("start() ERROR: \(error)")
        }
    }

    func stop() {
        lock.lock()
        let l = self.listener
        self.listener = nil
        self._port = 0
        lock.unlock()
        l?.cancel()
    }

    private func setPort(_ p: Int) {
        lock.lock(); _port = p; lock.unlock()
    }

    // MARK: - HTTP request handling

    private func handleConnection(_ conn: NWConnection) {
        Self.fileLog("incoming connection")
        conn.start(queue: .global(qos: .userInitiated))
        readHeaders(conn, accumulated: Data())
    }

    /// 累积读 TCP 字节直到看到 `\r\n\r\n`（HTTP header/body 分界）
    private func readHeaders(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if error != nil { conn.cancel(); return }
            guard let data, !data.isEmpty else {
                if isComplete { conn.cancel() }
                return
            }
            let buf = accumulated + data
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: 0..<range.lowerBound)
                let bodyStart = buf.subdata(in: range.upperBound..<buf.endIndex)
                self.parseAndForward(conn: conn, headerData: headerData, bodyAlreadyRead: bodyStart)
            } else if buf.count > 1_048_576 {
                // 防恶意客户端发巨大 header 卡爆内存
                self.sendError(conn, status: 431, message: "Headers too large")
            } else {
                self.readHeaders(conn, accumulated: buf)
            }
        }
    }

    private func parseAndForward(conn: NWConnection, headerData: Data, bodyAlreadyRead: Data) {
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            sendError(conn, status: 400, message: "Bad headers"); return
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(conn, status: 400, message: "No request line"); return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendError(conn, status: 400, message: "Bad request line"); return
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0

        if bodyAlreadyRead.count >= contentLength {
            let body = contentLength > 0 ? bodyAlreadyRead.subdata(in: 0..<contentLength) : Data()
            forwardRequest(conn: conn, method: method, path: path, headers: headers, body: body)
        } else {
            readBody(conn: conn, method: method, path: path, headers: headers, soFar: bodyAlreadyRead, total: contentLength)
        }
    }

    private func readBody(conn: NWConnection, method: String, path: String, headers: [String: String], soFar: Data, total: Int) {
        let needed = total - soFar.count
        conn.receive(minimumIncompleteLength: 1, maximumLength: max(needed, 1)) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            if error != nil { conn.cancel(); return }
            guard let data else { conn.cancel(); return }
            let newSoFar = soFar + data
            if newSoFar.count >= total {
                self.forwardRequest(conn: conn, method: method, path: path, headers: headers, body: newSoFar.subdata(in: 0..<total))
            } else {
                self.readBody(conn: conn, method: method, path: path, headers: headers, soFar: newSoFar, total: total)
            }
        }
    }

    /// 转发请求到真实 provider + filter stream 响应
    private func forwardRequest(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        Self.fileLog("request: \(method) \(path) body=\(body.count)B")
        // path 形如 /deepseek/chat/completions or /moonshot/models
        let pathTrim = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let pathParts = pathTrim.split(separator: "/", maxSplits: 1).map(String.init)
        guard pathParts.count == 2,
              let upstreamBase = Self.upstreamBaseURLs[pathParts[0]],
              let upstreamURL = URL(string: "\(upstreamBase)/\(pathParts[1])") else {
            Self.fileLog("request 404: bad path \(path)")
            sendError(conn, status: 404, message: "Unknown provider or path: \(path)")
            return
        }

        // **关键 fix（2026-05-16）**：Kimi K2.x / DeepSeek V4 等 thinking model 要求多轮对话
        // history 里的 assistant message（特别是 tool_calls 那条）必须含 `reasoning_content` 字段，
        // 缺了报 400 `thinking is enabled but reasoning_content is missing in assistant tool call message`。
        // 但 opencode 不存 reasoning_content（被我们过滤掉了）。
        // proxy 在转发请求时，**自动给 messages 里所有 assistant message 补 `reasoning_content: ""`**。
        // OpenAI 标准会忽略额外字段，不破坏 OpenAI/GLM 等不需要这字段的 provider
        let patchedBody = Self.patchAssistantReasoningContent(body)

        var req = URLRequest(url: upstreamURL)
        req.httpMethod = method
        if !patchedBody.isEmpty {
            req.httpBody = patchedBody
        }
        // 转发关键 headers，跳过 Host / Content-Length（URLSession 自动管）
        for (k, v) in headers where k != "host" && k != "content-length" && k != "connection" {
            req.setValue(v, forHTTPHeaderField: k)
        }
        // 强制 SSE Accept（防 OpenAI 兼容服务商默认返回 application/json 非流式）
        // 但只有 body 含 "stream":true 时才设置，避免破坏非流式请求
        // 简化处理：透传 client 设的 Accept

        Task.detached { [weak self] in
            await self?.proxyAndFilter(conn: conn, req: req)
        }
    }

    /// 用 URLSession 转发请求，把响应流逐行 filter 后写回 client
    private func proxyAndFilter(conn: NWConnection, req: URLRequest) async {
        Self.fileLog("proxy: forwarding to \(req.url?.absoluteString ?? "?")")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                Self.fileLog("proxy: response is not HTTPURLResponse")
                sendError(conn, status: 502, message: "Bad gateway"); return
            }
            Self.fileLog("proxy: upstream status=\(http.statusCode) content-type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "?")")

            // 1) 发响应起始行 + headers 给 client
            let statusText = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let upstreamContentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "text/event-stream")
            let isStream = upstreamContentType.contains("event-stream")

            var respHead = "HTTP/1.1 \(http.statusCode) \(statusText)\r\n"
            respHead += "Content-Type: \(upstreamContentType)\r\n"
            if isStream {
                respHead += "Cache-Control: no-cache\r\n"
                respHead += "Transfer-Encoding: chunked\r\n"
            }
            respHead += "Connection: close\r\n"
            respHead += "\r\n"
            await send(conn: conn, data: respHead.data(using: .utf8) ?? Data())

            // 2) 流式处理：逐行 read → filter → write
            if isStream {
                var chunksKept = 0
                var chunksDropped = 0
                for try await line in bytes.lines {
                    if let outLine = filterSSELine(line) {
                        // SSE event 之间用空行分隔
                        let chunk = "\(outLine)\r\n\r\n"
                        if let chunkData = chunk.data(using: .utf8) {
                            // HTTP chunked transfer encoding: "<hex-len>\r\n<data>\r\n"
                            let hexLen = String(chunkData.count, radix: 16)
                            let header = "\(hexLen)\r\n".data(using: .utf8) ?? Data()
                            let trailer = "\r\n".data(using: .utf8) ?? Data()
                            await send(conn: conn, data: header + chunkData + trailer)
                            chunksKept += 1
                        }
                    } else {
                        chunksDropped += 1
                    }
                }
                // 结束 chunked stream
                await send(conn: conn, data: Data("0\r\n\r\n".utf8))
                NSLog("[ReasoningProxy] %@ stream done: kept=%d dropped=%d",
                      req.url?.absoluteString ?? "?", chunksKept, chunksDropped)
            } else {
                // 非流式响应：直接全量读 + 透传
                var buf = Data()
                for try await byte in bytes {
                    buf.append(byte)
                }
                // 上游报错时把 body 记进诊断日志（关键！否则用户看到"(没有响应)"，
                // 但实际是 API 报错 model 名错 / token 超限 / 参数不对，我们什么都不知道）
                if http.statusCode >= 400, let bodyStr = String(data: buf, encoding: .utf8) {
                    Self.fileLog("upstream \(http.statusCode) body: \(bodyStr.prefix(600))")
                }
                await send(conn: conn, data: buf)
            }

            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
        } catch {
            NSLog("[ReasoningProxy] proxy error: %@", "\(error)")
            Self.fileLog("proxy: ERROR \(error.localizedDescription)")
            sendError(conn, status: 502, message: "Upstream error: \(error.localizedDescription)")
        }
    }

    /// 文件日志（绕开 macOS 26 对 NSLog 的压制）
    private static let logPath: String = {
        let home = NSHomeDirectory()
        let dir = "\(home)/.hermespet"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/reasoning-proxy.log"
    }()

    static func fileLog(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }

    /// 把字节写到 NWConnection，await 它发完
    private func send(conn: NWConnection, data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in
                cont.resume()
            })
        }
    }

    // MARK: - SSE filter（核心）

    /// 单行 SSE line filter：
    /// - 返回 `nil` → 整条 event 丢弃（推理 chunk）
    /// - 返回 String → 这一行原样 / 修改后透传
    ///
    /// SSE chunk JSON 结构示例（DeepSeek 推理阶段）：
    /// ```
    /// data: {"choices":[{"index":0,"delta":{"content":null,"reasoning_content":"思考"}}]}
    /// ```
    /// 上面这种 `content: null + reasoning_content 有值` → 整条丢弃
    ///
    /// 后期实际回答阶段：
    /// ```
    /// data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}
    /// ```
    /// → 剥离 reasoning_content（如有）后透传
    fileprivate func filterSSELine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空行：SSE 内部分隔符，让 forward 那侧统一加 \r\n\r\n 即可，这里跳过
        if trimmed.isEmpty { return nil }

        // 非 data 行（注释 / event: / id: / retry:）原样透传
        guard trimmed.hasPrefix("data: ") || trimmed.hasPrefix("data:") else {
            return trimmed
        }

        // [DONE] 标记
        if trimmed == "data: [DONE]" || trimmed == "data:[DONE]" {
            return trimmed
        }

        let jsonStr: String = {
            if trimmed.hasPrefix("data: ") { return String(trimmed.dropFirst(6)) }
            return String(trimmed.dropFirst(5))
        }()

        guard let jsonData = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return trimmed   // 不能 parse → 原样透传
        }

        // 改写 choices[0].delta，去掉 reasoning_content；如果 delta 是纯 reasoning 就丢整条
        guard var choices = obj["choices"] as? [[String: Any]], !choices.isEmpty,
              var firstChoice = choices.first,
              var delta = firstChoice["delta"] as? [String: Any] else {
            return trimmed
        }

        let contentStr = delta["content"] as? String     // "" 也算有 content；null 则为 nil
        let reasoningStr = delta["reasoning_content"] as? String

        // 纯 reasoning chunk（无 content 或 content 是 null + 有 reasoning_content）→ 丢弃
        let hasContent = (contentStr != nil)
        let hasReasoning = (reasoningStr != nil)
        let hasToolCalls = (delta["tool_calls"] != nil)
        let hasRole = (delta["role"] != nil)
        let hasFinishReason = (firstChoice["finish_reason"] as? String) != nil

        if !hasContent && hasReasoning && !hasToolCalls && !hasRole && !hasFinishReason {
            return nil
        }

        // 剥离 reasoning_content 字段（opencode 看不到推理过程），重新序列化
        delta.removeValue(forKey: "reasoning_content")
        firstChoice["delta"] = delta
        choices[0] = firstChoice
        var newObj = obj
        newObj["choices"] = choices

        guard let newData = try? JSONSerialization.data(withJSONObject: newObj, options: [.withoutEscapingSlashes]),
              let newJsonStr = String(data: newData, encoding: .utf8) else {
            return trimmed
        }
        return "data: \(newJsonStr)"
    }

    /// 修请求 body：给 messages 里所有 assistant message 补 `reasoning_content: ""`。
    /// 解决 Kimi K2.x / DeepSeek V4 等 thinking model 报 "reasoning_content is missing" 400。
    /// 字段不冲突时 OpenAI / GLM 会忽略这个字段，安全
    static func patchAssistantReasoningContent(_ body: Data) -> Data {
        guard !body.isEmpty,
              var obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var messages = obj["messages"] as? [[String: Any]] else {
            return body
        }

        var patched = false
        for i in 0..<messages.count {
            guard let role = messages[i]["role"] as? String, role == "assistant" else { continue }
            if messages[i]["reasoning_content"] == nil {
                messages[i]["reasoning_content"] = ""
                patched = true
            }
        }
        guard patched else { return body }

        obj["messages"] = messages
        guard let newData = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
            return body
        }
        fileLog("patched body: injected reasoning_content into assistant messages")
        return newData
    }

    private func sendError(_ conn: NWConnection, status: Int, message: String) {
        let body = message.data(using: .utf8) ?? Data()
        var resp = "HTTP/1.1 \(status) Error\r\n"
        resp += "Content-Type: text/plain; charset=utf-8\r\n"
        resp += "Content-Length: \(body.count)\r\n"
        resp += "Connection: close\r\n\r\n"
        var data = resp.data(using: .utf8) ?? Data()
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
