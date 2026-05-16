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
struct Conversation: Identifiable, Codable, Equatable {
    let id: String
    var title: String           // 默认 "对话 N"，发完第一条用户消息后自动取前 8 个字
    var messages: [ChatMessage]
    /// 该对话锁定的 AI 后端。创建时设置，发了第一条 user 消息后就锁死不可改
    var mode: AgentMode
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
         hasUnread: Bool = false,
         isStreaming: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.mode = mode
        self.hasUnread = hasUnread
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // hasUnread / mode 参与序列化；isStreaming 是内存态，重启后归 false
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, hasUnread, mode
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
        // 这样老用户升级后，已有对话还是按他原本在用的那个 mode 继续
        if let raw = try? c.decode(String.self, forKey: .mode),
           let m = AgentMode(rawValue: raw) {
            self.mode = m
        } else {
            let legacy = UserDefaults.standard.string(forKey: "agentMode") ?? ""
            self.mode = AgentMode(rawValue: legacy) ?? .hermes
        }
        self.isStreaming = false   // 内存态，启动恢复 false
    }
}

/// 同时存在的对话数上限 —— 顶部胶囊条改成横向 ScrollView 后可以放更多。
/// 8 个是一个合理上限：⌘1~⌘8 直达快捷键够用、内存里同时跑 8 个对话历史 RAM 占用可控
let kMaxConversations = 8

/// 桌宠当前跟谁聊：
/// - **Hermes Gateway**：用户自托管的 OpenAI 兼容 API Server（localhost）
/// - **Direct API**：直连第三方服务商（DeepSeek / 智谱 / Kimi / OpenAI 等），只要 API Key 就能用 ——
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

// MARK: - Hover Expand 三态

/// 鼠标悬停灵动岛 500ms 后的展开行为。三选一：
/// - `off`：不动，hover 仅保留 hoverCard 预览（默认 —— 最保守、零侵入）
/// - `embedded`：灵动岛胶囊本身扩展成"上平下圆"的迷你聊天框（融进刘海），
///   含最近 1-2 条对话 + 输入框 + 发送。**不开第二个窗口**，视觉上从刘海长出来
/// - `chatWindow`：自动展开主聊天窗（NSWindow，原 PR3 行为）。鼠标离开 / Esc / 失焦收回
enum HoverExpandMode: String, Codable, CaseIterable, Identifiable {
    case off
    case embedded
    case chatWindow = "chat_window"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:        return "不动"
        case .embedded:   return "嵌入式聊天框"
        case .chatWindow: return "展开主聊天窗"
        }
    }

    var detail: String {
        switch self {
        case .off:        return "仅显示预览"
        case .embedded:   return "刘海长出迷你聊天卡，融进顶部"
        case .chatWindow: return "弹出 420×580 完整对话窗口"
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
