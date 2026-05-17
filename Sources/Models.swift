import Foundation

// MARK: - Chat Models
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    var role: MessageRole
    var content: String
    /// 附加的图片（PNG 编码后的 Data）。内存中持有，重启后从 imagePaths 恢复
    var images: [Data]
    /// 图片在磁盘上的绝对路径（~/.hermespet/images/...）。
    /// 序列化进 JSON，重启后用这些路径恢复 images
    var imagePaths: [String]
    /// 用户拖入的文档绝对路径（保持用户真实路径，不复制）。
    /// 仅在 Claude / Codex 模式下使用 —— AI 用自己的 Read 工具按路径访问。
    /// 路径很短直接存进 JSON，重启后保留（但若用户删了文件 AI 读不到，由 AI 自己反馈）
    var documentPaths: [String]
    let timestamp: Date
    var isStreaming: Bool

    init(role: MessageRole,
         content: String,
         images: [Data] = [],
         imagePaths: [String] = [],
         documentPaths: [String] = [],
         isStreaming: Bool = false,
         timestamp: Date = Date()) {
        self.id = UUID().uuidString
        self.role = role
        self.content = content
        self.images = images
        self.imagePaths = imagePaths
        self.documentPaths = documentPaths
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }

    // CodingKeys：images（Data）不存（避免 JSON 爆大），imagePaths / documentPaths 存
    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, isStreaming, imagePaths, documentPaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.role = try c.decode(MessageRole.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.isStreaming = try c.decode(Bool.self, forKey: .isStreaming)
        self.imagePaths = (try? c.decode([String].self, forKey: .imagePaths)) ?? []
        self.documentPaths = (try? c.decode([String].self, forKey: .documentPaths)) ?? []
        // 从 imagePaths 还原 Data（启动时一次性 IO 不大）
        // 若图片文件已被外部删除（用户手动清 ~/.hermespet/images/、或 deleteImageFiles 漏调）
        // 会静默落空 → 至少 console 打个日志，方便事后追查
        var loaded: [Data] = []
        for path in self.imagePaths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                loaded.append(data)
            } else {
                print("[Models] 消息 \(self.id) 引用的图片已缺失: \(path)")
            }
        }
        self.images = loaded
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encode(imagePaths, forKey: .imagePaths)
        try c.encode(documentPaths, forKey: .documentPaths)
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case system

    var displayName: String {
        switch self {
        case .user: return "你"
        case .assistant: return "Hermes"
        case .system: return "System"
        }
    }
}

/// 多会话：一个 Conversation = 一组消息 + 一个标题 + 一个绑定的 AI mode。
/// 用户最多同时开 3 个，可在头部胶囊里切换。
/// **mode 绑定语义**：对话创建时锁定一个 mode（默认继承上一次用的 mode），
/// 一旦该对话发出过 user 消息，就再也不能改 mode —— 保证不同对话能用不同 CLI 并行不互相污染。
/// 对话类型 —— `.chat` 是普通聊天对话，`.canvas` 是画布工作区。
/// 同样存在 conversations 数组里、共享顶部胶囊条 / ⌘1-8 直达 / 多通道并发，
/// 但主区域 UI 由 ConversationKind 决定（CanvasView vs MessagesView）
enum ConversationKind: String, Codable {
    case chat
    case canvas
}

struct Conversation: Identifiable, Codable, Equatable {
    let id: String
    var title: String           // 默认 "对话 N"，发完第一条用户消息后自动取前 8 个字
    var messages: [ChatMessage]
    /// 该对话锁定的 AI 后端。创建时设置，发了第一条 user 消息后就锁死不可改
    var mode: AgentMode
    /// 对话类型（普通聊天 / 画布工作区）。canvas 时 `canvas` 字段有值
    var kind: ConversationKind
    /// 画布工作区数据 —— 仅 kind=.canvas 时有值。每个画布独立绑定一个 board
    var canvas: CanvasBoard?
    let createdAt: Date
    var updatedAt: Date
    /// 后台对话完成时设为 true，切到该对话时清除 —— 胶囊上显示红点
    var hasUnread: Bool
    /// 该对话当前是否正在等 AI 回复（每个对话独立，切换对话时输入栏状态跟着切换）。
    /// 仅内存态，不序列化（重启后所有 task 都没了，恢复成 false）
    var isStreaming: Bool

    /// 这个对话是否已经发过 user 消息 —— mode 锁死的判断依据
    var hasUserMessages: Bool {
        messages.contains { $0.role == .user }
    }

    init(id: String = UUID().uuidString,
         title: String,
         messages: [ChatMessage] = [],
         mode: AgentMode = .hermes,
         kind: ConversationKind = .chat,
         canvas: CanvasBoard? = nil,
         hasUnread: Bool = false,
         isStreaming: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.mode = mode
        self.kind = kind
        self.canvas = canvas
        self.hasUnread = hasUnread
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // hasUnread / mode / kind / canvas 参与序列化；isStreaming 是内存态，重启后归 false
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, hasUnread, mode, kind, canvas
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.messages = try c.decode([ChatMessage].self, forKey: .messages)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.hasUnread = (try? c.decode(Bool.self, forKey: .hasUnread)) ?? false
        // 旧版 JSON 没有 mode 字段 —— 沿用全局 UserDefaults["agentMode"] 作为兜底
        if let raw = try? c.decode(String.self, forKey: .mode),
           let m = AgentMode(rawValue: raw) {
            self.mode = m
        } else {
            let legacy = UserDefaults.standard.string(forKey: "agentMode") ?? ""
            self.mode = AgentMode(rawValue: legacy) ?? .hermes
        }
        // 旧版 JSON 没有 kind 字段 —— 默认 .chat 保持兼容
        if let rawKind = try? c.decode(String.self, forKey: .kind),
           let k = ConversationKind(rawValue: rawKind) {
            self.kind = k
        } else {
            self.kind = .chat
        }
        self.canvas = try? c.decode(CanvasBoard.self, forKey: .canvas)
        self.isStreaming = false   // 内存态，启动恢复 false
    }
}

// MARK: - Canvas 数据模型

/// 一个画布工作区 —— 用户给一个主题（如"可口可乐"），AI 按模板批量生成
/// 一组带小标题的卡片（图 / 文混合），全部展示在一张画布上。
///
/// 画布作为 Conversation.canvas 字段持久化，跟普通聊天一起存在
/// `~/.hermespet/conversations.json`，图片复用现有 `~/.hermespet/images/` 机制
struct CanvasBoard: Codable, Equatable {
    /// 画布唯一 id
    let id: String
    /// 用户输入的主题（如"可口可乐"）
    var topic: String
    /// 用了哪个模板（"ecommerce" / "courseware" / ...）。"custom" 表示 AI 自由规划
    var templateID: String
    /// 用户上传的"真实产品参考图"绝对路径数组 —— Codex 生图时作为 vision 输入，
    /// 让 AI 看清产品真实细节再生成场景图，彻底解决"AI 凭想象瞎画"的还原度问题。
    /// 没传则 fall back 到从零生成（用 LLM 拼的英文 prompt）
    var referenceImagePaths: [String]
    /// AI 调研出的产品事实摘要 —— 在 plan 阶段把 topic 喂给 LLM 让它输出客观参数
    /// （容量 / 成分 / 价格档 / 规格 / 知名度），后续每张卡片的 prompt 都带上这些事实
    /// 让卖点是"0 糖 0 卡 容量 330ml"而不是"令人惊叹的口感"
    var researchSummary: String
    /// 卡片列表 —— UI 按 slot 顺序渲染
    var elements: [CanvasElement]
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         topic: String,
         templateID: String,
         referenceImagePaths: [String] = [],
         researchSummary: String = "",
         elements: [CanvasElement] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.topic = topic
        self.templateID = templateID
        self.referenceImagePaths = referenceImagePaths
        self.researchSummary = researchSummary
        self.elements = elements
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 旧版（没有这两个字段）的 JSON 反序列化兼容
    enum CodingKeys: String, CodingKey {
        case id, topic, templateID, referenceImagePaths, researchSummary, elements, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.topic = try c.decode(String.self, forKey: .topic)
        self.templateID = try c.decode(String.self, forKey: .templateID)
        self.referenceImagePaths = (try? c.decode([String].self, forKey: .referenceImagePaths)) ?? []
        self.researchSummary = (try? c.decode(String.self, forKey: .researchSummary)) ?? ""
        self.elements = try c.decode([CanvasElement].self, forKey: .elements)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// 画布里的单个卡片 —— 可能是图（heroImage / sceneImage）或文（title / sellingPoint / cta / text）
struct CanvasElement: Identifiable, Codable, Equatable {
    let id: String
    /// 卡片类型 —— 决定渲染方式 + 走哪个 client 生成
    var kind: CanvasElementKind
    /// 显示在卡片左上角的小标题（"产品主图" / "卖点 ①" / "使用场景：朋友聚会"）
    var caption: String
    /// 给 AI 的 prompt —— 由模板 + 用户主题拼成
    var prompt: String
    /// 文本类卡片的内容（kind 为 title/sellingPoint/cta/text 时用）
    var content: String
    /// 图片类卡片的图片磁盘路径（kind 为 *Image 时用）
    var imagePath: String?
    /// 渲染顺序（小的在前）
    var slot: Int
    /// 当前状态：pending / generating / done / failed
    var status: CanvasElementStatus
    /// 失败时的错误信息，给用户看
    var errorMessage: String?

    init(kind: CanvasElementKind,
         caption: String,
         prompt: String,
         slot: Int,
         content: String = "",
         imagePath: String? = nil,
         status: CanvasElementStatus = .pending,
         errorMessage: String? = nil) {
        self.id = UUID().uuidString
        self.kind = kind
        self.caption = caption
        self.prompt = prompt
        self.slot = slot
        self.content = content
        self.imagePath = imagePath
        self.status = status
        self.errorMessage = errorMessage
    }
}

/// 画布卡片的类型 —— 决定走哪个 client 生成、UI 长什么样
enum CanvasElementKind: String, Codable, Hashable {
    case heroImage      // 产品主图（大图）
    case sceneImage     // 使用场景图（中图）
    case title          // 标题文案（粗体大字）
    case sellingPoint   // 卖点（icon + 标题 + 一行描述）
    case cta            // 行动号召（按钮风样式）
    case text           // 普通文本段落
}

/// 画布卡片的生成状态
enum CanvasElementStatus: String, Codable {
    case pending      // 还没开始（刚规划完，等排队）
    case generating   // 正在生成（UI 显示 skeleton 闪烁）
    case done         // 完成
    case failed       // 失败（点重试按钮）
}

/// 同时存在的对话数上限 —— 顶部胶囊条改成横向 ScrollView 后可以放更多。
/// 8 个是一个合理上限：⌘1~⌘8 直达快捷键够用、内存里同时跑 8 个对话历史 RAM 占用可控
let kMaxConversations = 8

/// 桌宠当前跟谁聊：
/// - **Hermes Gateway**：用户自托管的 OpenAI 兼容 API Server（localhost）
/// - **Direct API**：直连第三方服务商（DeepSeek / 智谱 / Kimi / MiniMax / OpenAI 等），只要 API Key 就能用 ——
///   给"没装任何 CLI 的朋友"分发场景做的"零依赖"档
/// - **Claude Code CLI** / **OpenAI Codex CLI**：本地子进程，能读写文件 / 跑命令 / 生图
enum AgentMode: String, Codable, CaseIterable, Identifiable {
    case hermes
    case directAPI  = "direct_api"
    case claudeCode = "claude_code"
    case codex      = "codex"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hermes:     return "Hermes"
        case .directAPI:  return "在线 AI"
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }

    var iconName: String {
        switch self {
        case .hermes:     return "sparkle"
        case .directAPI:  return "cloud.fill"
        case .claudeCode: return "terminal.fill"
        case .codex:      return "wand.and.stars"
        }
    }
}

// MARK: - API Models (OpenAI-compatible, 支持 multimodal)
struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [APIMessage]
    let stream: Bool
}

/// OpenAI 兼容 message：content 既可以是纯字符串，也可以是混合内容数组（文本 + 图片）
struct APIMessage: Codable {
    let role: String
    let content: APIMessageContent

    init(role: String, text: String, images: [Data] = []) {
        self.role = role
        if images.isEmpty {
            self.content = .text(text)
        } else {
            var parts: [APIContentPart] = []
            if !text.isEmpty {
                parts.append(.init(type: "text", text: text, image_url: nil))
            }
            for img in images {
                let b64 = img.base64EncodedString()
                parts.append(.init(
                    type: "image_url",
                    text: nil,
                    image_url: .init(url: "data:image/png;base64,\(b64)")
                ))
            }
            self.content = .parts(parts)
        }
    }
}

/// 混合 content：要么是单字符串，要么是 [text/image_url] 数组
enum APIMessageContent: Codable {
    case text(String)
    case parts([APIContentPart])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s):     try c.encode(s)
        case .parts(let arr):  try c.encode(arr)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .text(s)
        } else {
            self = .parts(try c.decode([APIContentPart].self))
        }
    }
}

struct APIContentPart: Codable {
    let type: String           // "text" / "image_url"
    let text: String?
    let image_url: ImageURL?

    struct ImageURL: Codable {
        let url: String        // "data:image/png;base64,..."
    }
}

struct ChatCompletionResponse: Codable {
    let id: String
    let choices: [Choice]
}

struct Choice: Codable {
    let index: Int
    let message: APIMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

struct StreamingChunk: Codable {
    let id: String?
    let choices: [StreamingChoice]?
}

struct StreamingChoice: Codable {
    let delta: Delta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

struct Delta: Codable {
    let content: String?
}

// MARK: - Permission System
// opencode v1.15.x permission ask 协议的客户端侧模型。
// 服务端 SSE 推 `permission.asked` 事件 → 我们解析成 PermissionRequest →
// 灵动岛展示卡片 → 用户决策 → POST /permission/{id}/reply { reply: once|always|reject }

/// 用户对 permission 请求的决策选项。
/// 对应 opencode 的 reply 字段三档枚举。
enum PermissionDecision: String, Codable {
    /// 仅本次允许 —— 下次同样的工具调用还会再次询问
    case once
    /// 永久允许此 pattern —— opencode 会把 pattern 加进 session 的 always 列表，
    /// 之后同样 pattern 自动放行不再 ask
    case always
    /// 拒绝 —— 工具调用直接报错给 AI，AI 通常会改用其他方式
    case reject
}

/// 一条等待用户决策的 permission 请求。来自 opencode SSE permission.asked 事件。
///
/// **字段对应**（来自 opencode OpenAPI spec）:
/// - id: "per_xxx" permission requestID（reply 时用这个）
/// - sessionID: "ses_xxx"
/// - permission: 权限类型（"read" / "write" / "edit" / "bash" / "webfetch" / ...）
/// - patterns: 匹配的 patterns（如 ["**/*.ts"]，always 模式会把这些加进白名单）
/// - metadata: 工具调用的实际参数（如 {"command": "rm -rf /"} / {"file_path": "...", "old_string": "..."}）
/// - always: 当前 session 已经 always 允许的 pattern 列表（UI 可显示作为参考）
/// - tool: 关联的工具调用元信息（messageID + callID，可用于关联气泡）
struct PermissionRequest: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let permission: String
    let patterns: [String]
    let metadata: [String: AnyCodable]
    let always: [String]
    let tool: ToolRef?

    struct ToolRef: Codable, Equatable, Sendable {
        let messageID: String
        let callID: String
    }

    /// 工具名（如 "Edit" / "Write" / "Bash"）—— UI 展示用。
    /// opencode metadata 里通常有 `tool` 字段，否则 fallback 到 permission 类型推断
    var toolDisplayName: String {
        if case .string(let s) = metadata["tool"] { return s }
        switch permission.lowercased() {
        case "read":     return "Read"
        case "write":    return "Write"
        case "edit":     return "Edit"
        case "bash":     return "Bash"
        case "webfetch": return "WebFetch"
        case "glob":     return "Glob"
        case "grep":     return "Grep"
        case "list":     return "List"
        default:         return permission.capitalized
        }
    }

    /// 工具操作的"主参数"（如 Edit/Write 的 file_path，Bash 的 command）—— UI 头部显示。
    /// 不同工具不同字段，按已知工具类型优先匹配
    var primaryArg: String? {
        if case .string(let s) = metadata["file_path"] { return s }
        if case .string(let s) = metadata["filePath"] { return s }
        if case .string(let s) = metadata["command"] { return s }
        if case .string(let s) = metadata["url"] { return s }
        if case .string(let s) = metadata["pattern"] { return s }
        if case .string(let s) = metadata["path"] { return s }
        return nil
    }

    /// Edit/Write 工具的 diff 预览（如果 metadata 里有 old_string + new_string）
    var diffPreview: (oldText: String?, newText: String?)? {
        var old: String? = nil
        var new: String? = nil
        if case .string(let s) = metadata["old_string"] { old = s }
        else if case .string(let s) = metadata["oldText"] { old = s }
        if case .string(let s) = metadata["new_string"] { new = s }
        else if case .string(let s) = metadata["newText"] { new = s }
        else if case .string(let s) = metadata["content"] { new = s }
        guard old != nil || new != nil else { return nil }
        return (old, new)
    }
}

/// AI 主动问问题的请求（opencode `question.asked` SSE 事件）。
/// 跟 PermissionRequest 平行，复用同一个 PermissionWindow 显示卡片
struct QuestionRequest: Identifiable, Codable, Equatable, Sendable {
    let id: String          // "que_xxx"
    let sessionID: String   // "ses_xxx"
    let questions: [QuestionInfo]
    let tool: PermissionRequest.ToolRef?

    struct QuestionInfo: Codable, Equatable, Sendable {
        let question: String
        let header: String
        let options: [QuestionOption]
        let multiple: Bool?
        let custom: Bool?
    }

    struct QuestionOption: Codable, Equatable, Sendable {
        let label: String
        let description: String
    }
}

/// 简单的 JSON 任意值容器 —— Codable 不直接支持 `[String: Any]`，
/// 这里用 enum 列出所有可能类型让 JSONDecoder 自动选。
/// 只需要 String / Bool / Double / Int / Array / Object 几种基本类型即可覆盖 opencode metadata
enum AnyCodable: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodable])
    case object([String: AnyCodable])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self)   { self = .bool(v) }
        else if let v = try? c.decode(Int.self)    { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AnyCodable].self) { self = .array(v) }
        else if let v = try? c.decode([String: AnyCodable].self) { self = .object(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - API Errors
enum APIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case cancelled
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无效的响应"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingError(let msg):
            return "数据解析失败: \(msg)"
        case .cancelled:
            return "请求已取消"
        case .emptyResponse:
            return "服务器未返回任何内容"
        }
    }
}
