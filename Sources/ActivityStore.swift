import Foundation
import SQLite3

/// 用户活动数据的持久化层 —— 直接用 SQLite3 C API（macOS 14 自带 sqlite3 ≥ 3.42）。
///
/// 三层存储：
///   - `activity_events`：原始事件，保留 48h 后自动 prune
///   - `activity_sessions`：聚合的会话块（"在 Xcode 写 PinCardOverlay 30 分钟"），保留 30 天
///   - `app_usage_stats`：每日聚合的使用频率统计（每个 app 总时长 / 会话数 / 按键数），永久保留
///
/// 所有写入用 prepared statement + transaction，最低成本。
/// 这个 class 全程在后台串行队列执行，**不要**带 @MainActor —— 主线程不能被磁盘 IO 阻塞。
final class ActivityStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let dbPath: String
    /// 串行队列：所有 SQLite 操作走这条队列，避免多线程并发访问 SQLite handle
    private let queue: DispatchQueue
    private let lock = NSLock()

    /// SQLite 数据库文件位置 ~/.hermespet/activity.sqlite
    static let defaultURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.sqlite")
    }()

    init(at url: URL = ActivityStore.defaultURL) {
        self.dbPath = url.path
        self.queue = DispatchQueue(label: "com.nousresearch.hermespet.activitystore", qos: .utility)
        queue.sync { self.openAndMigrate() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 初始化 + Schema 迁移

    private func openAndMigrate() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            print("[ActivityStore] 打开 SQLite 失败：\(lastError())")
            return
        }
        // 写性能优化：WAL 模式 + 同步 NORMAL（崩溃丢最近 1-2s 的数据可接受）
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA temp_store = MEMORY")

        // events: 原始事件
        exec("""
            CREATE TABLE IF NOT EXISTS activity_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                event_type TEXT NOT NULL,
                app_bundle_id TEXT,
                app_name TEXT,
                window_title TEXT,
                metadata TEXT
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_events_timestamp ON activity_events(timestamp)")

        // sessions: 聚合后的会话块
        exec("""
            CREATE TABLE IF NOT EXISTS activity_sessions (
                id TEXT PRIMARY KEY,
                app_bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL,
                window_title TEXT,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                duration_seconds INTEGER NOT NULL,
                keyboard_events INTEGER DEFAULT 0,
                mouse_clicks INTEGER DEFAULT 0,
                pasteboard_changes INTEGER DEFAULT 0,
                is_excluded INTEGER DEFAULT 0
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sessions_app ON activity_sessions(app_bundle_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_sessions_time ON activity_sessions(start_time, end_time)")

        // app_usage_stats: 每日聚合（每个 app 当天的总时长/会话数）
        exec("""
            CREATE TABLE IF NOT EXISTS app_usage_stats (
                date TEXT NOT NULL,
                app_bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL,
                total_seconds INTEGER NOT NULL,
                session_count INTEGER NOT NULL,
                keyboard_events INTEGER DEFAULT 0,
                mouse_clicks INTEGER DEFAULT 0,
                PRIMARY KEY (date, app_bundle_id)
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_stats_date ON app_usage_stats(date)")

        // user_questions: 用户跟 AI 说过的话（仅用户那一侧，不记 AI 回答）
        // 用来给早报 / AI 反向分析：用户最近关注什么、问了多少问题
        exec("""
            CREATE TABLE IF NOT EXISTS user_questions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id TEXT NOT NULL,
                mode TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL,
                char_count INTEGER NOT NULL,
                has_images INTEGER DEFAULT 0,
                has_documents INTEGER DEFAULT 0
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_uq_timestamp ON user_questions(timestamp)")
        exec("CREATE INDEX IF NOT EXISTS idx_uq_conversation ON user_questions(conversation_id)")

        // user_questions_fts: FTS5 全文检索虚拟表 —— 让 AI 能 MATCH 关键词搜索历史问题
        // external content 模式：内容存在 user_questions，FTS 只存倒排索引
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS user_questions_fts USING fts5(
                content,
                content='user_questions',
                content_rowid='id'
            )
        """)
        // triggers 自动同步 user_questions → user_questions_fts
        exec("""
            CREATE TRIGGER IF NOT EXISTS user_questions_ai AFTER INSERT ON user_questions BEGIN
                INSERT INTO user_questions_fts(rowid, content) VALUES (new.id, new.content);
            END
        """)
        exec("""
            CREATE TRIGGER IF NOT EXISTS user_questions_ad AFTER DELETE ON user_questions BEGIN
                INSERT INTO user_questions_fts(user_questions_fts, rowid, content)
                    VALUES('delete', old.id, old.content);
            END
        """)

        // user_intents: 屏幕意图采样（v1.3 用户意图感知功能）
        // 事件触发器（回车 / ⌘S / ⌘C / ⌘V / app 切换 / 窗口标题变化 / Spotlight）
        // 同 app+window_title 在 5min 内只采一次（去重靠 (app_bundle_id, window_title, timestamp) 节流）
        // 30 天后 ocr_text 字段移到 ocr_text_compressed（gzip BLOB），原文清空
        // 隐私敏感 app（1Password / 银行 / 微信私聊）命中 is_blacklisted=1，只记 meta 不存 ocr
        exec("""
            CREATE TABLE IF NOT EXISTS user_intents (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                trigger_type TEXT NOT NULL,
                app_bundle_id TEXT,
                app_name TEXT,
                window_title TEXT,
                safari_url TEXT,
                ocr_text TEXT,
                ocr_text_compressed BLOB,
                screen_hash TEXT,
                followed_up INTEGER DEFAULT 0,
                is_blacklisted INTEGER DEFAULT 0
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_intents_time ON user_intents(timestamp)")
        exec("CREATE INDEX IF NOT EXISTS idx_intents_app ON user_intents(app_bundle_id, window_title)")
        exec("CREATE INDEX IF NOT EXISTS idx_intents_hash ON user_intents(screen_hash)")
    }

    // MARK: - 写入

    /// 写一条原始事件（异步，不阻塞调用方）
    func insertEvent(_ event: ActivityEvent) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                INSERT INTO activity_events
                (timestamp, event_type, app_bundle_id, app_name, window_title, metadata)
                VALUES (?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, event.eventType.rawValue, -1, Self.SQLITE_TRANSIENT)
            self.bindOptionalText(stmt, 3, event.appBundleID)
            self.bindOptionalText(stmt, 4, event.appName)
            self.bindOptionalText(stmt, 5, event.windowTitle)
            self.bindOptionalText(stmt, 6, event.metadata)
            sqlite3_step(stmt)
        }
    }

    /// 写一条会话块（同步，因为通常在切换会话的关键时机调用，需保证落盘顺序）
    func insertSession(_ session: ActivitySession) {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                INSERT OR REPLACE INTO activity_sessions
                (id, app_bundle_id, app_name, window_title, start_time, end_time,
                 duration_seconds, keyboard_events, mouse_clicks, pasteboard_changes, is_excluded)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, session.id, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, session.appBundleID, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, session.appName, -1, Self.SQLITE_TRANSIENT)
            self.bindOptionalText(stmt, 4, session.windowTitle)
            sqlite3_bind_double(stmt, 5, session.startTime.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 6, session.endTime.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 7, Int64(session.durationSeconds))
            sqlite3_bind_int64(stmt, 8, Int64(session.keyboardEvents))
            sqlite3_bind_int64(stmt, 9, Int64(session.mouseClicks))
            sqlite3_bind_int64(stmt, 10, Int64(session.pasteboardChanges))
            sqlite3_bind_int(stmt, 11, session.isExcluded ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    /// 写一条用户问题（user 侧，不记 AI 回答）
    func insertUserQuestion(conversationID: String,
                            mode: String,
                            content: String,
                            hasImages: Bool,
                            hasDocuments: Bool,
                            timestamp: Date = Date()) {
        // 空内容不记（用户只发图片/文档时 content 可能为空，这种情况记一行带 has_images=1）
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !hasImages && !hasDocuments { return }
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                INSERT INTO user_questions
                (conversation_id, mode, content, timestamp, char_count, has_images, has_documents)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, conversationID, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, mode, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, trimmed, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, timestamp.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 5, Int64(trimmed.count))
            sqlite3_bind_int(stmt, 6, hasImages ? 1 : 0)
            sqlite3_bind_int(stmt, 7, hasDocuments ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    /// 最近 N 分钟内的用户问题（按时间倒序）
    func recentUserQuestions(withinMinutes minutes: Int, limit: Int = 50) -> [UserQuestion] {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return [] }
            let cutoff = Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970
            let sql = """
                SELECT id, conversation_id, mode, content, timestamp, char_count, has_images, has_documents
                FROM user_questions
                WHERE timestamp >= ?
                ORDER BY timestamp DESC
                LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            return self.readQuestions(stmt: stmt)
        }
    }

    /// 关键词全文检索（FTS5 MATCH 语法），按相关度排序
    func searchUserQuestions(matching query: String, limit: Int = 20) -> [UserQuestion] {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return [] }
            // FTS5 join 回主表拿全部字段
            let sql = """
                SELECT q.id, q.conversation_id, q.mode, q.content, q.timestamp,
                       q.char_count, q.has_images, q.has_documents
                FROM user_questions_fts fts
                JOIN user_questions q ON q.id = fts.rowid
                WHERE user_questions_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, query, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            return self.readQuestions(stmt: stmt)
        }
    }

    /// 指定日期的用户问题数（早报会用：你昨天问了 N 个问题）
    func userQuestionCount(for date: Date) -> Int {
        queue.sync {
            guard let db = self.db else { return 0 }
            let dayStart = Calendar.current.startOfDay(for: date)
            let dayEnd = dayStart.addingTimeInterval(86400)
            let sql = "SELECT COUNT(*) FROM user_questions WHERE timestamp >= ? AND timestamp < ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, dayStart.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, dayEnd.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - 用户意图采样（v1.3 意图感知功能）

    /// 写一条意图采样记录。OCR 文本可空（黑名单 app 只记 meta）。
    /// 节流由 UserIntentRecorder 在调用前判断（查 lastIntent 时间），这里不再去重。
    func insertUserIntent(_ intent: UserIntent) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                INSERT INTO user_intents
                (timestamp, trigger_type, app_bundle_id, app_name, window_title,
                 safari_url, ocr_text, screen_hash, is_blacklisted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, intent.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, intent.triggerType.rawValue, -1, Self.SQLITE_TRANSIENT)
            self.bindOptionalText(stmt, 3, intent.appBundleID)
            self.bindOptionalText(stmt, 4, intent.appName)
            self.bindOptionalText(stmt, 5, intent.windowTitle)
            self.bindOptionalText(stmt, 6, intent.safariURL)
            self.bindOptionalText(stmt, 7, intent.ocrText)
            self.bindOptionalText(stmt, 8, intent.screenHash)
            sqlite3_bind_int(stmt, 9, intent.isBlacklisted ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    /// 查最近 N 分钟内的所有意图记录（按时间倒序）
    func recentUserIntents(withinMinutes minutes: Int, limit: Int = 100) -> [UserIntent] {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return [] }
            let cutoff = Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970
            let sql = """
                SELECT id, timestamp, trigger_type, app_bundle_id, app_name, window_title,
                       safari_url, ocr_text, screen_hash, followed_up, is_blacklisted
                FROM user_intents
                WHERE timestamp >= ?
                ORDER BY timestamp DESC
                LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            return self.readIntents(stmt: stmt)
        }
    }

    /// Wave A3：当日（本地凌晨 0:00 至今）user_intents 总条数。
    /// 用 COUNT(*) 而非加载完整行避免大量 IO；灵动岛 hoverCard 的"今天 X 次" caption 直接读这个。
    func todayIntentCount() -> Int {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return 0 }
            // 本地凌晨 0:00 时间戳
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let sql = "SELECT COUNT(*) FROM user_intents WHERE timestamp >= ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, startOfDay)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// 查同一 app + window_title 最近一次采样时间 —— UserIntentRecorder 用它做 5min 节流
    func lastIntentTimestamp(appBundleID: String?, windowTitle: String?) -> Date? {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return nil }
            let sql = """
                SELECT timestamp FROM user_intents
                WHERE app_bundle_id IS ? AND window_title IS ?
                ORDER BY timestamp DESC LIMIT 1
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            self.bindOptionalText(stmt, 1, appBundleID)
            self.bindOptionalText(stmt, 2, windowTitle)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    /// 标记某条意图记录已被桌宠主动回应过（防止重复打扰）
    func markIntentFollowedUp(_ intentID: Int) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE user_intents SET followed_up = 1 WHERE id = ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(intentID))
            sqlite3_step(stmt)
        }
    }

    /// 把 30 天前的 ocr_text 字段 gzip 压缩到 ocr_text_compressed，原文清 NULL 省空间
    /// 真要分析时用 readIntentText 解压。每次 maintenance 调一次。
    func compressOldIntents(olderThanDays days: Int = 30) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

            // 找需要压缩的行（有 ocr_text 但还没压过 + 早于 cutoff）
            let selectSQL = """
                SELECT id, ocr_text FROM user_intents
                WHERE timestamp < ? AND ocr_text IS NOT NULL AND ocr_text_compressed IS NULL
                LIMIT 500
            """
            var selStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSQL, -1, &selStmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(selStmt) }
            sqlite3_bind_double(selStmt, 1, cutoff)

            var toCompress: [(id: Int, text: String)] = []
            while sqlite3_step(selStmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(selStmt, 0))
                if let text = self.textColumn(selStmt, 1) {
                    toCompress.append((id, text))
                }
            }
            guard !toCompress.isEmpty else { return }

            // 批量压缩 + 写回
            let updateSQL = "UPDATE user_intents SET ocr_text_compressed = ?, ocr_text = NULL WHERE id = ?"
            for (id, text) in toCompress {
                guard let data = text.data(using: .utf8),
                      let gz = try? (data as NSData).compressed(using: .zlib) else { continue }
                var upStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateSQL, -1, &upStmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_blob(upStmt, 1, gz.bytes, Int32(gz.length), Self.SQLITE_TRANSIENT)
                sqlite3_bind_int64(upStmt, 2, Int64(id))
                sqlite3_step(upStmt)
                sqlite3_finalize(upStmt)
            }
        }
    }

    /// 读取一条记录的 OCR 全文 —— 自动从 ocr_text 或 ocr_text_compressed 取
    func readIntentText(_ intentID: Int) -> String? {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return nil }
            let sql = "SELECT ocr_text, ocr_text_compressed FROM user_intents WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(intentID))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            if let txt = self.textColumn(stmt, 0) { return txt }
            // 压缩字段：BLOB → gunzip
            guard let blobPtr = sqlite3_column_blob(stmt, 1) else { return nil }
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))
            let data = Data(bytes: blobPtr, count: blobLen)
            guard let dec = try? (data as NSData).decompressed(using: .zlib) else { return nil }
            return String(data: dec as Data, encoding: .utf8)
        }
    }

    // MARK: - 每日聚合（把 sessions 卷成 app_usage_stats）

    /// 把指定日期的所有 sessions 聚合到 app_usage_stats（增量，旧统计 REPLACE）
    func aggregateDailyStats(for date: Date) {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let dayStart = Calendar.current.startOfDay(for: date)
            let dayEnd = dayStart.addingTimeInterval(86400)
            let dateStr = Self.dateFormatter.string(from: date)

            // 用 SQL 直接聚合
            let sql = """
                INSERT OR REPLACE INTO app_usage_stats
                (date, app_bundle_id, app_name, total_seconds, session_count, keyboard_events, mouse_clicks)
                SELECT
                    ?,
                    app_bundle_id,
                    app_name,
                    SUM(duration_seconds),
                    COUNT(*),
                    SUM(keyboard_events),
                    SUM(mouse_clicks)
                FROM activity_sessions
                WHERE start_time >= ? AND start_time < ? AND is_excluded = 0
                GROUP BY app_bundle_id
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, dateStr, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, dayStart.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, dayEnd.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    // MARK: - 查询（给 AI tool 用）

    /// 最近 N 分钟内的会话块（按时间倒序）
    func recentSessions(withinMinutes minutes: Int) -> [ActivitySession] {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return [] }
            let cutoff = Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970
            let sql = """
                SELECT id, app_bundle_id, app_name, window_title, start_time, end_time,
                       duration_seconds, keyboard_events, mouse_clicks, pasteboard_changes, is_excluded
                FROM activity_sessions
                WHERE end_time >= ?
                ORDER BY start_time DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            return self.readSessions(stmt: stmt)
        }
    }

    /// 指定日期的每个 app 使用统计（按总时长降序）
    func dailyStats(for date: Date) -> [AppDailyStat] {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return [] }
            let dateStr = Self.dateFormatter.string(from: date)
            let sql = """
                SELECT date, app_bundle_id, app_name, total_seconds, session_count, keyboard_events, mouse_clicks
                FROM app_usage_stats
                WHERE date = ?
                ORDER BY total_seconds DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, dateStr, -1, Self.SQLITE_TRANSIENT)
            return self.readDailyStats(stmt: stmt)
        }
    }

    /// 最近 N 天最常用的 N 个 app（按总时长降序）
    func topApps(days: Int, limit: Int) -> [AppDailyStat] {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return [] }
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let cutoffStr = Self.dateFormatter.string(from: cutoffDate)
            let sql = """
                SELECT 'aggregate' AS date, app_bundle_id,
                       MAX(app_name) AS app_name,
                       SUM(total_seconds) AS total_seconds,
                       SUM(session_count) AS session_count,
                       SUM(keyboard_events) AS keyboard_events,
                       SUM(mouse_clicks) AS mouse_clicks
                FROM app_usage_stats
                WHERE date >= ?
                GROUP BY app_bundle_id
                ORDER BY total_seconds DESC
                LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, cutoffStr, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            return self.readDailyStats(stmt: stmt)
        }
    }

    // MARK: - 清理

    /// 删除指定时间之前的原始事件（默认保留 48h）
    func pruneEvents(olderThan seconds: TimeInterval = 48 * 3600) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let cutoff = Date().addingTimeInterval(-seconds).timeIntervalSince1970
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM activity_events WHERE timestamp < ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
    }

    /// 删除指定时间之前的会话块（默认保留 30 天）
    func pruneSessions(olderThan seconds: TimeInterval = 30 * 86400) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let cutoff = Date().addingTimeInterval(-seconds).timeIntervalSince1970
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM activity_sessions WHERE end_time < ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
    }

    /// 清空所有记录（用户在设置里点"清空"）
    func clearAll() {
        queue.sync { [weak self] in
            self?.exec("DELETE FROM activity_events")
            self?.exec("DELETE FROM activity_sessions")
            self?.exec("DELETE FROM app_usage_stats")
            self?.exec("DELETE FROM user_questions")
            self?.exec("DELETE FROM user_intents")
            self?.exec("VACUUM")
        }
    }

    /// 清空意图记录（设置里"清空意图记录"按钮单独清这块）
    func clearUserIntents() {
        queue.sync { [weak self] in
            self?.exec("DELETE FROM user_intents")
        }
    }

    /// Wave E1：删单条意图记录（用户在"今日观察"列表点 × 触发）
    func deleteUserIntent(id: Int) {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = "DELETE FROM user_intents WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(id))
            _ = sqlite3_step(stmt)
        }
    }

    /// Wave E1：取最近 N 条意图记录（不限时间，给"今日观察"用 —— 调用方按 timestamp 过滤）。
    /// 跟 recentUserIntents 区别：那个按"最近 X 分钟"，这个按"最近 N 条"。
    func recentUserIntents(limit: Int) -> [UserIntent] {
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return [] }
            let sql = """
                SELECT id, timestamp, trigger_type, app_bundle_id, app_name, window_title,
                       safari_url, ocr_text, screen_hash, followed_up, is_blacklisted
                FROM user_intents
                ORDER BY timestamp DESC
                LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            return self.readIntents(stmt: stmt)
        }
    }

    /// 综合维护：定期清旧数据 + WAL checkpoint + 必要时 VACUUM。
    /// 启动时调一次 + 每 24h 调一次。各表保留策略（按数据价值差异化）：
    /// - events 48h（原始流水，量大价值低）
    /// - sessions 90 天（聚合块，AI 早报回顾用）
    /// - user_questions 90 天（用户跟 AI 说过的话，FTS 检索价值高）
    /// - app_usage_stats 365 天（每日聚合，体积小留久）
    /// 然后 WAL checkpoint(TRUNCATE) 把 WAL 文件清干净（不然能涨到几十 MB）。
    /// 最后如果数据库文件超过 sizeThresholdMB，跑一次 VACUUM 收缩（VACUUM 较慢
    /// 所以只在阈值之上才跑，平时靠 incremental autovacuum）
    func performMaintenance(sessionsRetentionDays: Int = 90,
                            userQuestionsRetentionDays: Int = 90,
                            userIntentsRetentionDays: Int = 180,
                            intentsCompressionDays: Int = 30,
                            statsRetentionDays: Int = 365,
                            sizeThresholdMB: Int = 50) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let now = Date().timeIntervalSince1970
            let sessionCutoff = now - Double(sessionsRetentionDays) * 86400
            let questionCutoff = now - Double(userQuestionsRetentionDays) * 86400
            let intentCutoff = now - Double(userIntentsRetentionDays) * 86400
            let statsCutoffDate: String = {
                let date = Date().addingTimeInterval(-Double(statsRetentionDays) * 86400)
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: date)
            }()
            let eventCutoff = now - 48 * 3600

            // 各表 prune
            self.deleteWhere(table: "activity_events", column: "timestamp", lessThan: eventCutoff)
            self.deleteWhere(table: "activity_sessions", column: "end_time", lessThan: sessionCutoff)
            self.deleteWhere(table: "user_questions", column: "timestamp", lessThan: questionCutoff)
            self.deleteWhere(table: "user_intents", column: "timestamp", lessThan: intentCutoff)
            // app_usage_stats 用 date 字段（TEXT 类型 yyyy-MM-dd），按字符串比较
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM app_usage_stats WHERE date < ?",
                                  -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (statsCutoffDate as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            // 30 天前的意图记录 OCR 文本压缩到 BLOB，原文清 NULL
            // 这里直接内联做（compressOldIntents 是 async 队列调用，避免嵌套 async 死锁）
            let compressCutoff = now - Double(intentsCompressionDays) * 86400
            let compressSelectSQL = """
                SELECT id, ocr_text FROM user_intents
                WHERE timestamp < ? AND ocr_text IS NOT NULL AND ocr_text_compressed IS NULL
                LIMIT 500
            """
            var compStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, compressSelectSQL, -1, &compStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(compStmt, 1, compressCutoff)
                var pending: [(id: Int, text: String)] = []
                while sqlite3_step(compStmt) == SQLITE_ROW {
                    let id = Int(sqlite3_column_int64(compStmt, 0))
                    if let text = self.textColumn(compStmt, 1) {
                        pending.append((id, text))
                    }
                }
                sqlite3_finalize(compStmt)
                for (id, text) in pending {
                    guard let data = text.data(using: .utf8),
                          let gz = try? (data as NSData).compressed(using: .zlib) else { continue }
                    var upStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, "UPDATE user_intents SET ocr_text_compressed = ?, ocr_text = NULL WHERE id = ?", -1, &upStmt, nil) == SQLITE_OK {
                        sqlite3_bind_blob(upStmt, 1, gz.bytes, Int32(gz.length), Self.SQLITE_TRANSIENT)
                        sqlite3_bind_int64(upStmt, 2, Int64(id))
                        sqlite3_step(upStmt)
                    }
                    sqlite3_finalize(upStmt)
                }
            } else {
                sqlite3_finalize(compStmt)
            }

            // WAL checkpoint(TRUNCATE)：把 WAL 文件清空（数据已合并回主 db）
            self.exec("PRAGMA wal_checkpoint(TRUNCATE)")

            // 容量阈值之上才 VACUUM（VACUUM 重写整个 db，几百 MB 时会慢，平时不必）
            if let attrs = try? FileManager.default.attributesOfItem(atPath: self.dbPath),
               let size = attrs[.size] as? Int64,
               size > Int64(sizeThresholdMB) * 1024 * 1024 {
                self.exec("VACUUM")
            }
        }
    }

    /// 内部辅助：按时间戳删 —— 替代散落的 pruneEvents/pruneSessions 重复代码
    private func deleteWhere(table: String, column: String, lessThan cutoff: TimeInterval) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM \(table) WHERE \(column) < ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }

    // MARK: - 私有辅助

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err {
                print("[ActivityStore] exec 失败 [\(sql.prefix(40))]: \(String(cString: err))")
                sqlite3_free(err)
            }
        }
    }

    private func lastError() -> String {
        guard let db, let cStr = sqlite3_errmsg(db) else { return "(unknown)" }
        return String(cString: cStr)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func readSessions(stmt: OpaquePointer?) -> [ActivitySession] {
        var out: [ActivitySession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ActivitySession(
                id: textColumn(stmt, 0) ?? UUID().uuidString,
                appBundleID: textColumn(stmt, 1) ?? "",
                appName: textColumn(stmt, 2) ?? "",
                windowTitle: textColumn(stmt, 3),
                startTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                endTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                durationSeconds: Int(sqlite3_column_int64(stmt, 6)),
                keyboardEvents: Int(sqlite3_column_int64(stmt, 7)),
                mouseClicks: Int(sqlite3_column_int64(stmt, 8)),
                pasteboardChanges: Int(sqlite3_column_int64(stmt, 9)),
                isExcluded: sqlite3_column_int(stmt, 10) != 0
            ))
        }
        return out
    }

    private func readIntents(stmt: OpaquePointer?) -> [UserIntent] {
        var out: [UserIntent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let triggerRaw = textColumn(stmt, 2) ?? ""
            out.append(UserIntent(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                triggerType: UserIntent.TriggerType(rawValue: triggerRaw) ?? .returnKey,
                appBundleID: textColumn(stmt, 3),
                appName: textColumn(stmt, 4),
                windowTitle: textColumn(stmt, 5),
                safariURL: textColumn(stmt, 6),
                ocrText: textColumn(stmt, 7),
                screenHash: textColumn(stmt, 8),
                isBlacklisted: sqlite3_column_int(stmt, 10) != 0,
                id: Int(sqlite3_column_int64(stmt, 0)),
                followedUp: sqlite3_column_int(stmt, 9) != 0
            ))
        }
        return out
    }

    private func readQuestions(stmt: OpaquePointer?) -> [UserQuestion] {
        var out: [UserQuestion] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(UserQuestion(
                id: Int(sqlite3_column_int64(stmt, 0)),
                conversationID: textColumn(stmt, 1) ?? "",
                mode: textColumn(stmt, 2) ?? "",
                content: textColumn(stmt, 3) ?? "",
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                charCount: Int(sqlite3_column_int64(stmt, 5)),
                hasImages: sqlite3_column_int(stmt, 6) != 0,
                hasDocuments: sqlite3_column_int(stmt, 7) != 0
            ))
        }
        return out
    }

    private func readDailyStats(stmt: OpaquePointer?) -> [AppDailyStat] {
        var out: [AppDailyStat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(AppDailyStat(
                date: textColumn(stmt, 0) ?? "",
                appBundleID: textColumn(stmt, 1) ?? "",
                appName: textColumn(stmt, 2) ?? "",
                totalSeconds: Int(sqlite3_column_int64(stmt, 3)),
                sessionCount: Int(sqlite3_column_int64(stmt, 4)),
                keyboardEvents: Int(sqlite3_column_int64(stmt, 5)),
                mouseClicks: Int(sqlite3_column_int64(stmt, 6))
            ))
        }
        return out
    }

    private func textColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    /// SQLite 绑定字符串时必须用 SQLITE_TRANSIENT，否则 SQLite 不会拷贝内容，
    /// Swift String 一释放就读到野指针。这是 SQLite C API 的常见坑。
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
}

// MARK: - 数据模型

/// 原始事件（写入 activity_events 表）
struct ActivityEvent {
    enum EventType: String {
        case appActive       = "app_active"
        case windowChange    = "window_change"
        case appLaunch       = "app_launch"
        case appQuit         = "app_quit"
        case pasteboardChange = "pasteboard_change"
    }
    let timestamp: Date
    let eventType: EventType
    let appBundleID: String?
    let appName: String?
    let windowTitle: String?
    let metadata: String?

    init(eventType: EventType,
         appBundleID: String? = nil,
         appName: String? = nil,
         windowTitle: String? = nil,
         metadata: String? = nil,
         timestamp: Date = Date()) {
        self.eventType = eventType
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.metadata = metadata
        self.timestamp = timestamp
    }
}

/// 会话块 —— 用户在某个 app + 某个窗口持续活动的一段时间
struct ActivitySession: Identifiable {
    let id: String
    let appBundleID: String
    let appName: String
    let windowTitle: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Int
    let keyboardEvents: Int
    let mouseClicks: Int
    let pasteboardChanges: Int
    /// 黑名单 app（密码/银行/隐私）—— 仅记 duration，不记 window_title 和 keyboard count
    let isExcluded: Bool
}

/// 每日 app 使用统计（永久保留）
struct AppDailyStat: Identifiable {
    var id: String { "\(date)-\(appBundleID)" }
    let date: String           // YYYY-MM-DD
    let appBundleID: String
    let appName: String
    let totalSeconds: Int
    let sessionCount: Int
    let keyboardEvents: Int
    let mouseClicks: Int
}

/// 用户跟 AI 说过的话 —— 仅用户那一侧，不存 AI 回答
struct UserQuestion: Identifiable {
    let id: Int
    let conversationID: String
    let mode: String              // "hermes" / "claude_code" / "codex"
    let content: String
    let timestamp: Date
    let charCount: Int
    let hasImages: Bool
    let hasDocuments: Bool
}

/// 用户意图采样记录（v1.3 意图感知）—— 每次事件触发器命中后存一条
struct UserIntent: Identifiable {
    /// 触发器类型 —— 决定了"这一刻为啥要采"
    enum TriggerType: String {
        /// 按下回车键（提交输入）—— 用户原始想法的核心触发器
        case returnKey      = "return"
        /// ⌘S 保存文件 —— 完成一段产出
        case saveShortcut   = "save"
        /// ⌘C 复制 —— 用户认为某段内容值得保留
        case copyShortcut   = "copy"
        /// ⌘V 粘贴 —— 用户在跨任务搬运内容
        case pasteShortcut  = "paste"
        /// NSWorkspace app 切换 —— 注意力转移
        case appSwitch      = "app_switch"
        /// 同一 app 窗口标题变化 —— 任务粒度变化（换文件/换 tab）
        case windowChange   = "window_change"
        /// ⌘Space / ⌘⇧Space —— 用户在查工具
        case spotlight      = "spotlight"
    }

    let id: Int
    let timestamp: Date
    let triggerType: TriggerType
    let appBundleID: String?
    let appName: String?
    let windowTitle: String?
    /// 仅 Safari 时取 URL（用 AppleScript / Accessibility 拿）
    let safariURL: String?
    /// 屏幕 OCR 全文 —— 30 天后移到压缩字段，这里读出来可能是 nil
    let ocrText: String?
    /// OCR 内容 sha256 前 16 位 —— Phase 2 模式识别用：相同 hash 多次出现 = "在重复某件事"
    let screenHash: String?
    /// 桌宠是否已经基于这条主动 follow up（防止重复打扰，Phase 3 用）
    let followedUp: Bool
    /// 是否命中隐私黑名单（命中时不存 ocr_text，只存 meta）
    let isBlacklisted: Bool

    init(timestamp: Date = Date(),
         triggerType: TriggerType,
         appBundleID: String?,
         appName: String?,
         windowTitle: String?,
         safariURL: String? = nil,
         ocrText: String?,
         screenHash: String?,
         isBlacklisted: Bool = false,
         id: Int = 0,
         followedUp: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.triggerType = triggerType
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.safariURL = safariURL
        self.ocrText = ocrText
        self.screenHash = screenHash
        self.followedUp = followedUp
        self.isBlacklisted = isBlacklisted
    }
}
