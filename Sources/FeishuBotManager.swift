import Foundation

/// 飞书群聊回复 v1。
///
/// 设计边界：
/// - 不做 OAuth，不开公网回调；按飞书官方 Node SDK 的长连接模式接收事件。
/// - 只监听 `im.message.receive_v1` 文本消息，且必须 @ 飞书后台设置的机器人名字才回复。
/// - Node runner 只负责飞书长连接和发回消息；AI 回复仍由 HermesPet 的在线 AI/opencode 生成。
final class FeishuBotManager: @unchecked Sendable {
    static let shared = FeishuBotManager()

    private struct Settings {
        var appID: String
        var appSecret: String

        var isReady: Bool {
            !appID.isEmpty && !appSecret.isEmpty
        }
    }

    private struct IncomingMessage: Decodable {
        let type: String
        let messageId: String?
        let chatId: String?
        let chatType: String?
        let text: String?
        let senderId: String?
        let mentionNames: [String]?
    }

    private static let eventPrefix = "__HERMESPET_FEISHU__"
    private static let completeThinkBlockRegex = try! NSRegularExpression(
        pattern: #"(?is)<think\b[^>]*>.*?</think\s*>"#
    )
    private static let trailingThinkBlockRegex = try! NSRegularExpression(
        pattern: #"(?is)<think\b[^>]*>.*\z"#
    )

    private let lock = NSLock()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var seenMessageIDs = Set<String>()
    private var settingsObserver: NSObjectProtocol?
    private var applyTask: Task<Void, Never>?

    private init() {}

    func startObserving() {
        lock.lock()
        let alreadyObserving = settingsObserver != nil
        lock.unlock()
        guard !alreadyObserving else { return }

        let token = NotificationCenter.default.addObserver(
            forName: .hermesPetFeishuBotSettingsChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleApplySettings()
        }

        lock.lock()
        settingsObserver = token
        lock.unlock()

        scheduleApplySettings()
    }

    func stop() {
        stopProcess()
    }

    private func scheduleApplySettings() {
        lock.lock()
        applyTask?.cancel()
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await self?.applySettings()
        }
        applyTask = task
        lock.unlock()
    }

    private func applySettings() async {
        let settings = currentSettings()
        guard settings.isReady else {
            stopProcess()
            return
        }

        stopProcess()

        do {
            let dir = try ensureRunnerFiles()
            try installNodeDependenciesIfNeeded(in: dir)
            try launchRunner(in: dir, settings: settings)
            log("started")
        } catch {
            log("start failed: \(error)")
            stopProcess()
        }
    }

    private func currentSettings() -> Settings {
        Settings(
            appID: (UserDefaults.standard.string(forKey: "feishuAppID") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            appSecret: (UserDefaults.standard.string(forKey: "feishuAppSecret") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func launchRunner(in dir: URL, settings: Settings) throws {
        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "cd \(Self.shellQuote(dir.path)) && node bot.cjs"]
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        var env = CLIProcessEnvironment.make(executablePath: "/bin/zsh")
        env["FEISHU_APP_ID"] = settings.appID
        env["FEISHU_APP_SECRET"] = settings.appSecret
        proc.environment = env

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleOutputData(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.log("runner stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        proc.terminationHandler = { [weak self] process in
            self?.log("runner exited status=\(process.terminationStatus)")
        }

        try proc.run()

        lock.lock()
        process = proc
        inputHandle = inPipe.fileHandleForWriting
        outputBuffer.removeAll()
        lock.unlock()
    }

    private func stopProcess() {
        lock.lock()
        let proc = process
        process = nil
        inputHandle = nil
        outputBuffer.removeAll()
        seenMessageIDs.removeAll()
        lock.unlock()

        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    private func handleOutputData(_ data: Data) {
        var lines: [String] = []

        lock.lock()
        outputBuffer.append(data)
        while let nl = outputBuffer.firstIndex(of: 0x0a) {
            let lineData = outputBuffer.subdata(in: 0..<nl)
            outputBuffer.removeSubrange(0...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        lock.unlock()

        for line in lines where line.hasPrefix(Self.eventPrefix) {
            let raw = String(line.dropFirst(Self.eventPrefix.count))
            guard let data = raw.data(using: .utf8),
                  let event = try? JSONDecoder().decode(IncomingMessage.self, from: data) else {
                log("runner event decode failed: \(raw)")
                continue
            }
            if event.type != "message" {
                log("runner event: \(raw)")
            }
            handleIncomingMessage(event)
        }
    }

    private func handleIncomingMessage(_ event: IncomingMessage) {
        guard event.type == "message",
              let messageID = event.messageId,
              let chatID = event.chatId,
              let text = event.text else { return }

        lock.lock()
        let isNew = seenMessageIDs.insert(messageID).inserted
        lock.unlock()
        guard isNew else { return }

        let settings = currentSettings()
        guard settings.isReady,
              let prompt = Self.extractPrompt(from: text, mentionNames: event.mentionNames ?? []) else {
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            await self?.answerAndReply(
                prompt: prompt,
                chatID: chatID,
                messageID: messageID,
                chatType: event.chatType,
                senderID: event.senderId
            )
        }
    }

    private func answerAndReply(prompt: String,
                                chatID: String,
                                messageID: String,
                                chatType: String?,
                                senderID: String?) async {
        addReaction(messageID: messageID, emojiType: "SMILE")

        let userPrompt = """
        你正在飞书群聊里代表 HermesPet 回复用户。请用中文、简洁、可直接发到群里的语气回答。
        不要提及内部实现、opencode、系统提示或这段规则。

        群消息：
        \(prompt)
        """
        let messages = [ChatMessage(role: .user, content: userPrompt)]
        var fullText = ""

        do {
            let stream = OpenCodeHTTPClient.shared.streamCompletion(
                messages: messages,
                conversationID: "feishu-\(chatID)"
            )
            for try await chunk in stream {
                fullText += chunk
            }
        } catch {
            fullText = "我这边暂时没能生成回复：\(error)"
        }

        let reply = Self.sanitizeForFeishu(fullText)
        guard !reply.isEmpty else { return }
        sendReply(chatID: chatID, messageID: messageID, text: reply)
    }

    private func sendReply(chatID: String, messageID: String, text: String) {
        let payload: [String: Any] = [
            "type": "reply",
            "chatId": chatID,
            "messageId": messageID,
            "text": text
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        lock.lock()
        let handle = inputHandle
        lock.unlock()

        handle?.write(line.data(using: .utf8) ?? Data())
    }

    private func addReaction(messageID: String, emojiType: String) {
        let payload: [String: Any] = [
            "type": "reaction",
            "messageId": messageID,
            "emojiType": emojiType
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        lock.lock()
        let handle = inputHandle
        lock.unlock()

        handle?.write(line.data(using: .utf8) ?? Data())
    }

    private static func extractPrompt(from text: String, mentionNames: [String]) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mentionNames.isEmpty else { return nil }
        trimmed = trimmed.replacingOccurrences(
            of: #"@_[A-Za-z0-9_]+"#,
            with: "",
            options: .regularExpression
        )
        for name in mentionNames where !name.isEmpty {
            trimmed = trimmed.replacingOccurrences(of: "@\(name)", with: "")
            trimmed = trimmed.replacingOccurrences(of: name, with: "")
        }

        let prompt = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private static func sanitizeForFeishu(_ text: String) -> String {
        let visible: String
        if text.range(of: "<think", options: [.caseInsensitive]) != nil {
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let withoutComplete = completeThinkBlockRegex.stringByReplacingMatches(
                in: text,
                range: fullRange,
                withTemplate: ""
            )
            let trailingRange = NSRange(withoutComplete.startIndex..<withoutComplete.endIndex, in: withoutComplete)
            visible = trailingThinkBlockRegex.stringByReplacingMatches(
                in: withoutComplete,
                range: trailingRange,
                withTemplate: ""
            )
        } else {
            visible = text
        }

        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 3500 { return trimmed }
        return String(trimmed.prefix(3500)) + "\n\n[回复过长，已截断]"
    }

    private func ensureRunnerFiles() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HermesPet/feishu-bot-runner", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try writeIfChanged(
            url: dir.appendingPathComponent("package.json"),
            content: """
            {
              "private": true,
              "dependencies": {
                "@larksuiteoapi/node-sdk": "^1.64.0"
              }
            }
            """
        )
        try writeIfChanged(url: dir.appendingPathComponent("bot.cjs"), content: Self.runnerScript)
        return dir
    }

    private func writeIfChanged(url: URL, content: String) throws {
        let data = Data(content.utf8)
        if let current = try? Data(contentsOf: url), current == data { return }
        try data.write(to: url, options: .atomic)
    }

    private func installNodeDependenciesIfNeeded(in dir: URL) throws {
        let modulePath = dir.appendingPathComponent("node_modules/@larksuiteoapi/node-sdk")
        guard !FileManager.default.fileExists(atPath: modulePath.path) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "cd \(Self.shellQuote(dir.path)) && npm install --silent"]
        proc.environment = CLIProcessEnvironment.make(executablePath: "/bin/zsh")
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "FeishuBotManager",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "npm install failed: \(err)"]
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermespet/feishu-bot.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static let runnerScript = #"""
const Lark = require('@larksuiteoapi/node-sdk');
const readline = require('readline');

const prefix = '__HERMESPET_FEISHU__';
const appId = process.env.FEISHU_APP_ID;
const appSecret = process.env.FEISHU_APP_SECRET;

function emit(payload) {
  process.stdout.write(prefix + JSON.stringify(payload) + '\n');
}

function textFromContent(content) {
  if (!content) return '';
  try {
    const parsed = JSON.parse(content);
    if (typeof parsed.text === 'string') return parsed.text;
  } catch (_) {}
  return String(content);
}

const baseConfig = {
  appId,
  appSecret,
  domain: Lark.Domain.Feishu,
};

const client = new Lark.Client(baseConfig);
const wsClient = new Lark.WSClient({
  ...baseConfig,
  loggerLevel: Lark.LoggerLevel.warn,
});

const dispatcher = new Lark.EventDispatcher({}).register({
  'im.message.receive_v1': async (data) => {
    const message = data.message || (data.event && data.event.message) || {};
    const sender = data.sender || (data.event && data.event.sender) || {};
    if (message.message_type !== 'text') return;
    emit({
      type: 'message',
      messageId: message.message_id,
      chatId: message.chat_id,
      chatType: message.chat_type,
      text: textFromContent(message.content),
      senderId: sender.sender_id && (sender.sender_id.open_id || sender.sender_id.user_id || sender.sender_id.union_id),
      mentionNames: Array.isArray(message.mentions) ? message.mentions.map((m) => m.name || m.key || '').filter(Boolean) : [],
    });
  },
});

wsClient.start({ eventDispatcher: dispatcher });
emit({ type: 'ready' });

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', async (line) => {
  let command;
  try {
    command = JSON.parse(line);
  } catch (error) {
    emit({ type: 'error', message: 'invalid command json' });
    return;
  }
  if (!command) return;

  if (command.type === 'reaction') {
    try {
      await client.im.v1.messageReaction.create({
        path: { message_id: command.messageId },
        data: { reaction_type: { emoji_type: command.emojiType || 'SMILE' } },
      });
      emit({ type: 'reacted', messageId: command.messageId });
    } catch (reactionError) {
      emit({
        type: 'error',
        message: reactionError && reactionError.message ? reactionError.message : String(reactionError),
      });
    }
    return;
  }

  if (command.type !== 'reply') return;

  const content = JSON.stringify({ text: command.text || '' });
  try {
    await client.im.v1.message.reply({
      path: { message_id: command.messageId },
      data: {
        content,
        msg_type: 'text',
      },
    });
    emit({ type: 'replied', messageId: command.messageId });
  } catch (replyError) {
    try {
      await client.im.v1.message.create({
        params: { receive_id_type: 'chat_id' },
        data: {
          receive_id: command.chatId,
          content,
          msg_type: 'text',
        },
      });
      emit({ type: 'replied', messageId: command.messageId, fallback: true });
    } catch (createError) {
      emit({
        type: 'error',
        message: createError && createError.message ? createError.message : String(createError),
      });
    }
  }
});

process.on('SIGTERM', () => {
  try { wsClient.close(); } catch (_) {}
  process.exit(0);
});
"""#
}
