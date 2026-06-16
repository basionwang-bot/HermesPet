import Foundation

/// 对话历史持久化。
/// 新版多会话：所有 Conversation 一起存到 `~/.hermespet/conversations.json`。
/// 旧版单会话：`session.json` —— 首次启动会自动迁移到 conversations.json。
final class StorageManager: @unchecked Sendable {
    static let shared = StorageManager()

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var _lastLoadError: String?

    /// 最近一次 loadConversations 失败的人类可读原因（线程安全）。
    /// 调用方（ChatViewModel）在 init 后立即读 → set errorMessage 让用户看到。
    var lastLoadError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastLoadError
    }
    private func setLoadError(_ s: String?) {
        lock.lock(); _lastLoadError = s; lock.unlock()
    }

    private var storageDir: URL {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet")
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var conversationsFile: URL {
        storageDir.appendingPathComponent("conversations.json")
    }

    /// 图片持久化目录（Codex 生成 / 用户附加的图片落盘到这里）
    private var imagesDir: URL {
        let url = storageDir.appendingPathComponent("images")
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 把图片 Data 写入 `~/.hermespet/images/<groupID>-<index>.png`，返回绝对路径数组。
    /// groupID 默认是新的 UUID，调用方也可以传 message.id 让文件名跟消息对应。
    func persistImages(_ data: [Data], groupID: String = UUID().uuidString) -> [String] {
        guard !data.isEmpty else { return [] }
        var paths: [String] = []
        for (idx, png) in data.enumerated() {
            let filename = "\(groupID)-\(idx).png"
            let fileURL = imagesDir.appendingPathComponent(filename)
            do {
                try png.write(to: fileURL, options: .atomic)
                paths.append(fileURL.path)
            } catch {
                print("[Storage] 写图片失败: \(error.localizedDescription)")
            }
        }
        return paths
    }

    /// 兼容旧 API：persistImages(_:forMessage:)
    func persistImages(_ data: [Data], forMessage messageID: String) -> [String] {
        persistImages(data, groupID: messageID)
    }

    /// 删除指定路径列表的图片文件（清空对话 / 删除对话时调用）
    func deleteImageFiles(_ paths: [String]) {
        for p in paths {
            try? fileManager.removeItem(atPath: p)
        }
    }

    private var legacySessionFile: URL {
        storageDir.appendingPathComponent("session.json")
    }

    // MARK: - 旧版的 session.json schema（仅用于一次性迁移读取）

    private struct LegacyStoredConversation: Codable {
        let id: String
        let title: String
        let messages: [LegacyStoredMessage]
        let createdAt: Date
        let updatedAt: Date
    }

    private struct LegacyStoredMessage: Codable {
        let role: String
        let content: String
        let timestamp: Date
    }

    // MARK: - 多对话存读

    func saveConversations(_ conversations: [Conversation]) {
        // ⚠️ 加锁串行落盘：语音陪聊把存盘丢到后台线程（appendVoiceChatTurn 的 Task.detached），会与
        // 主线程的 saveConversations 并发；.atomic 只防单次写出半截损坏文件，挡不住两次并发写「后写
        // 覆盖先写」整段丢数据。用已有的 lock 串行化 encode+write。
        lock.lock()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(conversations)
            try data.write(to: conversationsFile, options: .atomic)
        } catch {
            print("[Storage] saveConversations 失败: \(error.localizedDescription)")
        }
        lock.unlock()
        // 顺手镜像进永久历史库（自带串行队列，放锁外）——满 8 个被挤掉的对话仍能在历史面板里找回
        ConversationHistoryStore.shared.mirror(conversations)
    }

    func loadConversations() -> [Conversation] {
        setLoadError(nil)

        // 优先读新版文件
        if fileManager.fileExists(atPath: conversationsFile.path) {
            do {
                let data = try Data(contentsOf: conversationsFile)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                // 启动加载跳过图片 Data 同步读取（images 目录可达几十 MB，会卡冷启动主线程）。
                // 图片由 ChatViewModel.hydrateImagesInBackground() 后台补水。
                decoder.userInfo[ChatMessage.lazyImagesKey] = true
                return sanitizeLoadedConversations(try decoder.decode([Conversation].self, from: data))
            } catch {
                // 把损坏文件改名备份，避免覆写丢失用户数据 + 让用户知道
                let stamp = Int(Date().timeIntervalSince1970)
                let backupURL = storageDir.appendingPathComponent("conversations.corrupt-\(stamp).json")
                let moved = (try? fileManager.moveItem(at: conversationsFile, to: backupURL)) != nil
                let backupName = moved ? backupURL.lastPathComponent : "(备份失败)"
                let reason = error.localizedDescription
                setLoadError("⚠️ 对话历史损坏，已备份到 \(backupName)。原因: \(reason)")
                print("[Storage] loadConversations 解码失败 → 备份到 \(backupName)。错误: \(error)")
            }
        }

        // 没有新版 —— 尝试从旧版 session.json 迁移
        if let migrated = migrateFromLegacySession() {
            saveConversations([migrated])
            return [migrated]
        }

        return []
    }

    /// 持久化文件里不应该恢复“正在流式输出”的瞬时状态。
    /// 如果 App 被 install.sh / 系统退出杀在半路，历史消息可能留下 isStreaming=true；
    /// 重启后没有对应子进程继续写它，会在 UI 里变成永远的 thinking dots。
    private func sanitizeLoadedConversations(_ conversations: [Conversation]) -> [Conversation] {
        conversations.map { conv in
            var fixed = conv
            fixed.isStreaming = false
            fixed.messages = fixed.messages.map { msg in
                var m = msg
                if m.isStreaming {
                    m.isStreaming = false
                    if m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        m.content = "(上次生成被中断)"
                    } else {
                        m.content += "\n\n_(上次生成被中断)_"
                    }
                }
                return m
            }
            return fixed
        }
    }

    /// 把旧版的 session.json 转成一个 Conversation
    private func migrateFromLegacySession() -> Conversation? {
        guard fileManager.fileExists(atPath: legacySessionFile.path),
              let data = try? Data(contentsOf: legacySessionFile),
              let legacy = try? JSONDecoder().decode(LegacyStoredConversation.self, from: data)
        else {
            return nil
        }
        let messages: [ChatMessage] = legacy.messages.compactMap { sm in
            guard let role = MessageRole(rawValue: sm.role) else { return nil }
            return ChatMessage(role: role, content: sm.content, timestamp: sm.timestamp)
        }
        return Conversation(
            id: legacy.id,
            title: legacy.title.isEmpty ? "对话 1" : legacy.title,
            messages: messages,
            createdAt: legacy.createdAt,
            updatedAt: legacy.updatedAt
        )
    }

    // MARK: - Utility

    func clearAll() {
        try? fileManager.removeItem(at: conversationsFile)
        try? fileManager.removeItem(at: legacySessionFile)
    }
}
