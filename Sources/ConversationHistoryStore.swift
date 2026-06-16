import Foundation
import SQLite3
import NaturalLanguage

/// 永久对话历史库 —— 跟活动数据（activity.sqlite）**分开存、永不自动清理**。
///
/// 设计思路：
///   - **工作集** = `conversations.json` + ChatViewModel.conversations（≤ kMaxConversations 个）：
///     顶部胶囊能显示的、内存里活跃的那几个。
///   - **永久家** = 本库（history.sqlite）：用户**所有**聊过的对话的永久存档，没有上限。
///
/// 每次 `StorageManager.saveConversations` 都顺手把工作集镜像进来（唯一收口处挂钩，
/// 不用动 ChatViewModel 里 18 处存盘调用）。这样满 8 个被"挤掉"的对话只是从胶囊消失，
/// **数据仍在库里** → 历史面板可翻、可搜、可重新打开继续聊。
///
/// 线程：`@unchecked Sendable` + 后台串行队列，所有 SQLite 操作走这条队列，
/// 主线程（@MainActor 的 ChatViewModel）调 `mirror` 时只做轻量过滤 + 编码，写库 async 不阻塞。
final class ConversationHistoryStore: @unchecked Sendable {
    static let shared = ConversationHistoryStore()

    private var db: OpaquePointer?
    private let dbPath: String
    /// 串行队列：所有 SQLite 操作走这条，避免多线程并发访问同一个 handle
    private let queue: DispatchQueue
    /// 上次镜像的签名（id -> sig），用来跳过"没变化"的对话，避免重复写库
    private var lastMirroredSig: [String: String] = [:]
    private let sigLock = NSLock()

    /// 库文件位置 ~/.hermespet/history.sqlite
    static let defaultURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }()

    init(at url: URL = ConversationHistoryStore.defaultURL) {
        self.dbPath = url.path
        self.queue = DispatchQueue(label: "com.basionwang.hermespet.historystore", qos: .utility)
        queue.sync { self.openAndMigrate() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 对外的列表/搜索结果模型（只含元数据，列表展示用，不含全文）

    struct Summary: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let mode: AgentMode
        let kind: ConversationKind
        let createdAt: Date
        let updatedAt: Date
        let messageCount: Int
        /// 最后一条非空消息的截断预览（列表副标题用）
        let preview: String
        var starred: Bool         // 阶段2·加星（历史面板置顶）。var：支持点击后本地乐观翻转，UI 即时反馈
        var archived: Bool        // 阶段5·已归档（默认列表移走，收进折叠区）

        /// ForEach 专用复合 key：把 starred/archived 编进 id —— 加星/归档变化时 key 变，
        /// 强制 SwiftUI 重建该行（否则跨分组移动会复用旧视图，星标图标不刷新）。
        var rowKey: String { "\(id)|\(starred ? 1 : 0)|\(archived ? 1 : 0)" }
    }

    /// 知识图谱建图用：每个对话 + 它正文里最显著的实词（连线靠共享关键词，免费/本地/可解释）
    struct GraphRow: Sendable {
        let id: String
        let title: String
        let mode: AgentMode
        let updatedAt: Date
        let messageCount: Int
        let preview: String
        let keywords: [String]
        let openCount: Int        // 阶段1·回访次数（埋点收集，阶段2「显著度」用）
        let lastOpenedAt: Date?   // 最后一次打开（NULL → 还没单独打开过，阶段2 用 updatedAt 兜底）
        let starred: Bool         // 阶段2·人工加星（强制最高显著度）
    }

    // MARK: - 初始化 + Schema

    private func openAndMigrate() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            print("[HistoryStore] 打开 SQLite 失败：\(lastError())")
            return
        }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA temp_store = MEMORY")

        // 一行 = 一个对话的永久存档。
        //   - body / body_lower：所有消息正文拼起来（搜索用；body_lower 预先小写化方便英文大小写不敏感匹配，
        //     中文本身无大小写不受影响）。也是将来"知识图谱"算语义向量的原料。
        //   - full_json：完整 Conversation 的 JSON（重新打开时整段还原）
        exec("""
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                mode TEXT NOT NULL,
                kind TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                message_count INTEGER NOT NULL,
                preview TEXT,
                body TEXT NOT NULL,
                body_lower TEXT NOT NULL,
                title_lower TEXT NOT NULL,
                full_json TEXT NOT NULL,
                open_count INTEGER NOT NULL DEFAULT 0,
                last_opened_at REAL,
                starred INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_conv_updated ON conversations(updated_at)")
        // 阶段1·记回访：老库（建表时没这两列）补列。open_count 默认 0、last_opened_at 留 NULL
        // （读取时用 updated_at 兜底）。这是后续「显著度分级」的金标准信号——
        // 一次性琐事打开一次再不碰，重要的会反复回来。
        ensureColumn("conversations", "open_count", "open_count INTEGER NOT NULL DEFAULT 0")
        ensureColumn("conversations", "last_opened_at", "last_opened_at REAL")
        // 阶段2·加星：人工兜底，永远压过算法显著度（治"AI 识别不准"）
        ensureColumn("conversations", "starred", "starred INTEGER NOT NULL DEFAULT 0")
        // 阶段5·归档：超 N 天没碰且未加星的自动归档（默认视图移走、仍可搜可恢复、永不真删）
        ensureColumn("conversations", "archived", "archived INTEGER NOT NULL DEFAULT 0")
    }

    /// 表缺某列时 `ALTER TABLE ADD COLUMN` 补上（SQLite 无 `ADD COLUMN IF NOT EXISTS`，
    /// 先用 `PRAGMA table_info` 探，避免重复 ALTER 报错）。迁移幂等、可反复跑。
    private func ensureColumn(_ table: String, _ column: String, _ decl: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        var exists = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { exists = true; break }
            }
        }
        sqlite3_finalize(stmt)
        if !exists { exec("ALTER TABLE \(table) ADD COLUMN \(decl)") }
    }

    // MARK: - 镜像（写）

    /// 待写入的一行（全是基本类型，Sendable，安全跨线程传给后台队列）
    private struct Row: Sendable {
        let id: String
        let title: String
        let mode: String
        let kind: String
        let createdAt: Double
        let updatedAt: Double
        let messageCount: Int
        let preview: String
        let body: String
        let bodyLower: String
        let titleLower: String
        let json: String
    }

    /// 把当前工作集镜像进永久库。**非阻塞**（写库 async 到后台队列）。
    /// 只镜像：含 user 消息 + 非 streaming 的对话；用签名跳过没变化的。
    func mirror(_ conversations: [Conversation]) {
        var rows: [Row] = []
        sigLock.lock()
        for conv in conversations {
            // 正在流式输出的对话先不写（等它结束、isStreaming 翻 false 再镜像最终态）
            guard !conv.isStreaming else { continue }
            // 没发过用户消息的空对话不值得存档（如刚新建还没说话）
            guard conv.messages.contains(where: { $0.role == .user }) else { continue }

            let lastLen = conv.messages.last?.content.count ?? 0
            // 签名含 title —— 纯重命名（不改消息、不动 updatedAt）也能触发镜像，避免历史库标题滞后
            let sig = "\(conv.updatedAt.timeIntervalSince1970)-\(conv.messages.count)-\(lastLen)-\(conv.title)"
            if lastMirroredSig[conv.id] == sig { continue }

            guard let json = Self.encodeJSON(conv) else { continue }

            let body = conv.messages
                .filter { $0.role != .system && !$0.content.isEmpty }
                .map { $0.content }
                .joined(separator: "\n")
            let preview = Self.makePreview(conv)

            lastMirroredSig[conv.id] = sig
            rows.append(Row(
                id: conv.id,
                title: conv.title,
                mode: conv.mode.rawValue,
                kind: conv.kind.rawValue,
                createdAt: conv.createdAt.timeIntervalSince1970,
                updatedAt: conv.updatedAt.timeIntervalSince1970,
                messageCount: conv.messages.count,
                preview: preview,
                body: body,
                bodyLower: body.lowercased(),
                titleLower: conv.title.lowercased(),
                json: json
            ))
        }
        sigLock.unlock()

        guard !rows.isEmpty else { return }
        let finalRows = rows   // 复制成不可变值，安全跨线程传入 async 闭包
        queue.async { [weak self] in self?.upsert(finalRows) }
    }

    private func upsert(_ rows: [Row]) {
        guard let db else { return }
        exec("BEGIN")
        let sql = """
            INSERT INTO conversations
            (id, title, mode, kind, created_at, updated_at, message_count, preview, body, body_lower, title_lower, full_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title, mode=excluded.mode, kind=excluded.kind,
                updated_at=excluded.updated_at, message_count=excluded.message_count,
                preview=excluded.preview, body=excluded.body, body_lower=excluded.body_lower,
                title_lower=excluded.title_lower, full_json=excluded.full_json
        """
        for r in rows {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, r.id, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, r.title, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, r.mode, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, r.kind, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, r.createdAt)
            sqlite3_bind_double(stmt, 6, r.updatedAt)
            sqlite3_bind_int64(stmt, 7, Int64(r.messageCount))
            sqlite3_bind_text(stmt, 8, r.preview, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, r.body, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, r.bodyLower, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 11, r.titleLower, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 12, r.json, -1, Self.SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        exec("COMMIT")
    }

    // MARK: - 读：列表 / 搜索 / 还原 / 删除

    /// 归档范围：活跃（默认列表）/ 已归档（折叠区）/ 全部
    enum ArchiveScope: Sendable { case active, archived, all }

    /// 最近的对话。历史面板"按时间翻"用。
    /// - active：未归档；**加星置顶**（starred DESC），再按更新时间
    /// - archived：已归档（折叠区列出，可恢复）
    func recent(scope: ArchiveScope = .active, limit: Int = 500, offset: Int = 0) -> [Summary] {
        queue.sync {
            guard let db else { return [] }
            let filter: String
            switch scope {
            case .active: filter = "WHERE archived = 0"
            case .archived: filter = "WHERE archived = 1"
            case .all: filter = ""
            }
            let order = scope == .active ? "ORDER BY starred DESC, updated_at DESC" : "ORDER BY updated_at DESC"
            let sql = """
                SELECT id, title, mode, kind, created_at, updated_at, message_count, preview, starred, archived
                FROM conversations \(filter) \(order) LIMIT ? OFFSET ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            sqlite3_bind_int(stmt, 2, Int32(offset))
            return readSummaries(stmt)
        }
    }

    /// 智能关键词搜索（A1：本地分词，听得懂大白话）。
    ///
    /// 把整句用 `NLTokenizer` 拆成词、滤掉虚词/单字 → 多词子串检索（中文靠 LIKE，稳，
    /// 不踩 FTS5 中文分词坑）。这样"上次聊崩溃那个"也能搜到含"崩溃"的对话。
    /// 排序：标题命中词数 → 正文命中词数（命中越多越靠前）→ 更新时间倒序。
    /// 切不出实词（纯虚词 / 单字）就回退整串子串。
    func search(_ query: String, limit: Int = 100) -> [Summary] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let tokens = Self.contentTokens(raw)
        let terms = tokens.isEmpty ? [raw.lowercased()] : tokens
        return queue.sync {
            guard let db else { return [] }
            let n = terms.count
            // SQLite 编号参数 ?i 可重复引用：?1..?n 是各词的 LIKE 串，?(n+1) 是 limit
            let titleHits = (1...n)
                .map { "(CASE WHEN title_lower LIKE ?\($0) ESCAPE '\\' THEN 1 ELSE 0 END)" }
                .joined(separator: " + ")
            let matchCount = (1...n)
                .map { "(CASE WHEN title_lower LIKE ?\($0) ESCAPE '\\' OR body_lower LIKE ?\($0) ESCAPE '\\' THEN 1 ELSE 0 END)" }
                .joined(separator: " + ")
            let whereClause = (1...n)
                .map { "title_lower LIKE ?\($0) ESCAPE '\\' OR body_lower LIKE ?\($0) ESCAPE '\\'" }
                .joined(separator: " OR ")
            let limitIdx = n + 1
            let sql = """
                SELECT id, title, mode, kind, created_at, updated_at, message_count, preview, starred, archived,
                       (\(titleHits)) AS title_hits, (\(matchCount)) AS match_count
                FROM conversations
                WHERE \(whereClause)
                ORDER BY title_hits DESC, match_count DESC, updated_at DESC
                LIMIT ?\(limitIdx)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            for (i, term) in terms.enumerated() {
                let like = "%\(Self.escapeLike(term))%"
                sqlite3_bind_text(stmt, Int32(i + 1), like, -1, Self.SQLITE_TRANSIENT)
            }
            sqlite3_bind_int(stmt, Int32(limitIdx), Int32(limit))
            return readSummaries(stmt)   // 只读前 8 列，title_hits/match_count 仅供排序
        }
    }

    /// 把自然语言查询拆成"实词"。用 `NLTokenizer`（中文按词切、本地免费），
    /// 滤掉单字 + 常见虚词/泛指词；去重保序。切不出就返回空（调用方回退整串）。
    private static func contentTokens(_ query: String) -> [String] {
        let lower = query.lowercased()
        var seen = Set<String>()
        var result: [String] = []
        func add(_ t: String) {
            // 留 ≥2 字的实词（中文单字多为"的/了/在"等虚词；2 字才有检索价值），滤掉常见虚词
            guard t.count >= 2, !stopWords.contains(t), !seen.contains(t) else { return }
            seen.insert(t)
            result.append(t)
        }
        // ⚠️ 先按空白拆块再分词：否则 "SwiftUI 崩溃" 这种"拉丁+空格+短中文"，
        // NLTokenizer 会把空格后的中文整段切成单字（"崩"/"溃"）丢失。
        let chunks = lower.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for chunk in chunks {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = chunk
            var chunkTokens: [String] = []
            tokenizer.enumerateTokens(in: chunk.startIndex..<chunk.endIndex) { range, _ in
                let t = String(chunk[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 2, !stopWords.contains(t) { chunkTokens.append(t) }
                return true
            }
            if chunkTokens.isEmpty {
                // 分词没切出实词（短中文串被打成单字）→ 整块当一个词兜底
                add(chunk)
            } else {
                chunkTokens.forEach(add)
            }
        }
        return result
    }

    /// 常见虚词 / 泛指词 —— 搜索时滤掉，避免"那个 / 什么"之类噪声词把无关对话全捞出来
    private static let stopWords: Set<String> = [
        "这个", "那个", "什么", "怎么", "一下", "一个", "上次", "之前", "刚才", "那些", "这些",
        "可以", "怎样", "为什么", "的话", "然后", "就是", "但是", "因为", "所以", "我们", "你们", "他们",
        "the", "and", "for", "you", "that", "this", "with", "what", "how", "can", "about", "please", "find"
    ]

    /// 知识图谱建图（阶段3·呈现工作集）：先按**时间窗 + 加星**在 SQL 层筛候选，再按**预显著度**
    /// （新鲜度+深度+回访，加星=最高）截到 `maxCount`（默认 150 呈现上限），**只对入选的算关键词**
    /// （分词最贵，截断后再算才省）。返回 `(入选行, 时间窗内候选总数)`——总数 > 入选数即发生了截断。
    /// - sinceDays: 只看最近 N 天（加星的不受限、永远进）；nil = 全部。
    func allForGraph(maxCount: Int = 150, sinceDays: Int? = nil, maxKeywordsPerConv: Int = 12) -> (rows: [GraphRow], total: Int) {
        queue.sync {
            guard let db else { return ([], 0) }
            var sql = """
                SELECT id, title, mode, updated_at, message_count, body_lower, preview, open_count, last_opened_at, starred
                FROM conversations
            """
            var conds = ["archived = 0"]   // 阶段5·归档的不画进云图
            if let d = sinceDays {
                let cutoff = Date().timeIntervalSince1970 - Double(d) * 86400
                conds.append("(updated_at >= \(cutoff) OR starred = 1)")
            }
            sql += " WHERE " + conds.joined(separator: " AND ")
            sql += " ORDER BY updated_at DESC LIMIT 1200"   // 硬上限，防极端库一次性读爆内存
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ([], 0) }
            defer { sqlite3_finalize(stmt) }

            // 候选先不分词（分词最贵）；带 body 留给入选者；预显著度排序用于截断
            struct Cand {
                let id, title, mode, preview, body: String
                let updatedAt: Date; let messageCount, openCount: Int
                let lastOpened: Date?; let starred: Bool; let preSal: Double
            }
            var cands: [Cand] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                let mc = Int(sqlite3_column_int64(stmt, 4))
                let oc = Int(sqlite3_column_int64(stmt, 7))
                let starred = sqlite3_column_int64(stmt, 9) != 0
                let lastOpened = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
                // 预显著度：不含"是否成团"（聚类要先有关键词→鸡蛋问题；少这 0.16 分不影响截断排序）。
                // 加星 = 最大值 → 永远入选，不被上限挤掉。
                let preSal = starred
                    ? Double.greatestFiniteMagnitude
                    : NebulaLayout.salience(recency: NebulaLayout.recencyFactor(updatedAt),
                                            messageCount: mc, openCount: oc, inCluster: false)
                cands.append(Cand(
                    id: text(stmt, 0), title: text(stmt, 1), mode: text(stmt, 2),
                    preview: text(stmt, 6), body: String(text(stmt, 5).prefix(4000)),
                    updatedAt: updatedAt, messageCount: mc, openCount: oc,
                    lastOpened: lastOpened, starred: starred, preSal: preSal))
            }
            let total = cands.count
            cands.sort { $0.preSal > $1.preSal }     // 显著度高的留下
            let rows = cands.prefix(maxCount).map { c in
                GraphRow(
                    id: c.id, title: c.title,
                    mode: AgentMode(rawValue: c.mode) ?? .hermes,
                    updatedAt: c.updatedAt, messageCount: c.messageCount,
                    preview: c.preview,
                    keywords: Self.topKeywords(from: c.body, limit: maxKeywordsPerConv),   // 只对入选者分词
                    openCount: c.openCount, lastOpenedAt: c.lastOpened, starred: c.starred)
            }
            return (rows, total)
        }
    }

    /// 从一段正文里取最显著的实词（按出现频次 top-N）—— 图谱连线用。
    /// 复用 A1 的分词 + 停用词，加频次统计。
    static func topKeywords(from text: String, limit: Int) -> [String] {
        var freq: [String: Int] = [:]
        let chunks = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for chunk in chunks {
            let tk = NLTokenizer(unit: .word)
            tk.string = chunk
            var gotAny = false
            tk.enumerateTokens(in: chunk.startIndex..<chunk.endIndex) { range, _ in
                let t = String(chunk[range])
                if isGraphKeyword(t) { freq[t, default: 0] += 1; gotAny = true }
                return true
            }
            // 短中文串被切成单字 → 整块兜底（同 contentTokens 的处理）
            if !gotAny, chunk.count <= 8, isGraphKeyword(chunk) {
                freq[chunk, default: 0] += 1
            }
        }
        return freq.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    /// 图谱关键词的资格：≥2 字 + 含字母/汉字（滤掉 `##`/`**` 等纯符号）+ 不在停用词/噪声词表。
    private static func isGraphKeyword(_ t: String) -> Bool {
        t.count >= 2
            && t.contains(where: { $0.isLetter })
            && !stopWords.contains(t)
            && !graphNoiseWords.contains(t)
    }

    /// 图谱专用噪声词（不动搜索停用词）：markdown/路径/格式残渣 + 本 app 里太泛、连线没区分度的词。
    private static let graphNoiseWords: Set<String> = [
        "ai", "md", "http", "https", "www", "com", "json", "png", "jpg", "html", "css", "users", "app",
        "没有", "开始", "一直", "可能", "知道", "需要", "这种", "当中", "这样", "现在", "东西", "一种"
    ]

    /// 按 id 取出完整对话（重新打开时用）
    func load(id: String) -> Conversation? {
        queue.sync {
            guard let db else { return nil }
            let sql = "SELECT full_json FROM conversations WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, Self.SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let json = text(stmt, 0)
            return Self.decodeJSON(json)
        }
    }

    /// 阶段1·记回访：用户每次打开一个历史对话（历史面板 / 云图点开都走 `openFromHistory`）调一次，
    /// `open_count += 1` + 更新 `last_opened_at`。非阻塞（async 到后台队列）。
    /// 对话已在库才有效（来源都是从库列出来的，必然在库）；不在则 UPDATE 0 行、无害。
    func recordOpen(id: String) {
        let ts = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "UPDATE conversations SET open_count = open_count + 1, last_opened_at = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, id, -1, Self.SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    /// 阶段2·加星/取消加星。非阻塞。加星 = 人工把这条钉成最高显著度（云图里放大变亮 + ★ 角标，历史面板置顶）。
    /// **加星时若已归档则一并取消归档**（重新加星 = 重新重要，不该还躺在归档里）。
    func setStarred(id: String, _ starred: Bool) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "UPDATE conversations SET starred = ?, archived = CASE WHEN ? = 1 THEN 0 ELSE archived END WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, starred ? 1 : 0)
            sqlite3_bind_int(stmt, 2, starred ? 1 : 0)
            sqlite3_bind_text(stmt, 3, id, -1, Self.SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    /// 阶段5·手动归档 / 恢复一个对话（折叠区的"恢复"按钮、列表右键归档）。非阻塞。
    func setArchived(id: String, _ archived: Bool) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "UPDATE conversations SET archived = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, archived ? 1 : 0)
            sqlite3_bind_text(stmt, 2, id, -1, Self.SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    /// 阶段5·自动归档：超过 N 天没碰、且未加星、且还没归档的 → 标记归档。返回本次新归档条数。
    /// **加星的永不被自动归档**（人工优先级最高）；归档 ≠ 删除（仍可搜、可恢复、永不真删）。幂等可反复跑。
    @discardableResult
    func autoArchive(olderThanDays days: Int) -> Int {
        queue.sync {
            guard let db else { return 0 }
            let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
            let sql = "UPDATE conversations SET archived = 1 WHERE updated_at < ? AND starred = 0 AND archived = 0"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    /// 永久删除一个对话（用户在历史面板里主动删）
    func delete(id: String) {
        sigLock.lock(); lastMirroredSig[id] = nil; sigLock.unlock()
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "DELETE FROM conversations WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, Self.SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    /// 库里总共存了多少个对话
    func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM conversations", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - 行读取

    private func readSummaries(_ stmt: OpaquePointer?) -> [Summary] {
        var result: [Summary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(Summary(
                id: text(stmt, 0),
                title: text(stmt, 1),
                mode: AgentMode(rawValue: text(stmt, 2)) ?? .hermes,
                kind: ConversationKind(rawValue: text(stmt, 3)) ?? .chat,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                messageCount: Int(sqlite3_column_int64(stmt, 6)),
                preview: text(stmt, 7),
                starred: sqlite3_column_int64(stmt, 8) != 0,
                archived: sqlite3_column_int64(stmt, 9) != 0
            ))
        }
        return result
    }

    // MARK: - 工具

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    /// 最后一条非空消息的单行预览（≤ 100 字）
    private static func makePreview(_ conv: Conversation) -> String {
        let last = conv.messages.last { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let raw = (last?.content ?? "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.count > 100 ? String(raw.prefix(100)) + "…" : raw
    }

    /// LIKE 通配符转义（用户搜 "50%" 之类时别被当成通配符）
    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func encodeJSON(_ conv: Conversation) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(conv) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeJSON(_ json: String) -> Conversation? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Conversation.self, from: data)
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err {
                print("[HistoryStore] exec 失败 [\(sql.prefix(40))]: \(String(cString: err))")
                sqlite3_free(err)
            }
        }
    }

    private func lastError() -> String {
        guard let db, let cStr = sqlite3_errmsg(db) else { return "(unknown)" }
        return String(cString: cStr)
    }

    /// 绑定字符串必须用 SQLITE_TRANSIENT，否则 SQLite 不拷贝内容，Swift String 释放后读到野指针
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )
}
