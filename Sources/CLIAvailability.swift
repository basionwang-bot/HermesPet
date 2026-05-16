import Foundation

/// 检测 `claude` / `codex` CLI 是否安装在用户机器上。
///
/// 不能直接复用 ClaudeCodeClient.checkAvailable() 来做这件事 —— 那个用 hardcoded path
/// `/Users/mac01/.local/bin/claude` 跑 `--version`，在**别人电脑上 100% 失败**（路径不存在）。
/// 这里走 `command -v`（zsh -lic 加载 PATH）查可执行文件，并把找到的真实路径写回
/// UserDefaults，让真正发请求的 client 后续能用对的路径。
///
/// **为什么是 actor 而不是 final class + NSLock**：
/// Swift 6 严格并发模式禁止在 async context 调用 NSLock.lock/unlock，actor 是官方推荐替代。
///
/// **缓存策略**：5 分钟有效，避免每次切 mode 都启动子进程。用户装/卸 CLI 不会立即生效，
/// 但成本 < 收益（CLI 安装是低频操作）。
actor CLIAvailability {

    static let shared = CLIAvailability()

    private struct Entry {
        let isAvailable: Bool
        let resolvedPath: String?
        let shellPath: String?
        let checkedAt: Date
    }

    private let cacheTTL: TimeInterval = 5 * 60
    private var cache: [String: Entry] = [:]

    // MARK: - 对外接口（静态语法糖，省得调用方写 `await CLIAvailability.shared.xxx`）

    static func claudeAvailable() async -> Bool {
        await shared.isAvailable(command: "claude", userDefaultsKey: "claudeExecutablePath")
    }

    static func codexAvailable() async -> Bool {
        await shared.isAvailable(command: "codex", userDefaultsKey: "codexExecutablePath")
    }

    /// 强制清缓存 —— 用户在设置里点"重新检测"时调用
    static func invalidateCache() async {
        await shared.clearCache()
    }

    // MARK: - actor 内部实现

    private func clearCache() {
        cache.removeAll()
    }

    private func isAvailable(command: String, userDefaultsKey: String) async -> Bool {
        // 1) 读缓存
        if let entry = cache[command],
           Date().timeIntervalSince(entry.checkedAt) < cacheTTL {
            return entry.isAvailable
        }

        // 2) 实际跑一次检测（off-main，nonisolated 静态函数）
        let result: (Bool, String?, String?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let detected = Self.detectPath(for: command)
                continuation.resume(returning: detected)
            }
        }

        // 3) 回到 actor 内写缓存
        cache[command] = Entry(
            isAvailable: result.0,
            resolvedPath: result.1,
            shellPath: result.2,
            checkedAt: Date()
        )

        if let path = result.1, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: userDefaultsKey)
        }
        if let shellPath = result.2, !shellPath.isEmpty {
            UserDefaults.standard.set(shellPath, forKey: "cliLoginShellPATH")
        }
        return result.0
    }

    /// 用一个登录 shell 命令查可执行路径。
    /// 为什么不直接 `/usr/bin/which`：
    ///   - GUI app 的 PATH 不包含 ~/.local/bin、Homebrew brew --prefix、nvm/asdf 装的二进制
    ///   - 走 `zsh -lic 'command -v xxx'` 让 shell 加载用户 ~/.zshrc / ~/.zprofile，
    ///     才能拿到跟终端里一致的 PATH
    /// 失败/超时返回 (false, nil)，永远不抛错（这是个"探测"操作，不应该崩）
    private nonisolated static func detectPath(for command: String) -> (Bool, String?, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l = login shell（加载 ~/.zprofile）; -i = interactive（加载 ~/.zshrc）; -c = 跑命令
        //
        // 输出两段：
        //   1. `printf '__HERMESPET_PATH__%s\n' "$PATH"` —— 把 shell 真实 PATH 写出来，
        //      后面 lines.first(where: hasPrefix("__HERMESPET_PATH__")) 抽出来缓存到
        //      UserDefaults["cliLoginShellPATH"]，spawn 子进程时复用
        //   2. **用 `whence -p` 而非 `command -v` 拿可执行路径**：用户 .zshrc 里可能把
        //      claude 包成 shell function（例如注入 --dangerously-skip-permissions 的
        //      wrapper），此时 `command -v claude` 返回函数名 "claude" 而非路径，下面
        //      `hasPrefix("/")` 过滤会把结果丢掉 → 误判"未检测到"。
        //      `whence -p` 是 zsh 内建，强制走 PATH 解析二进制，忽略 function/alias/builtin。
        process.arguments = ["-lic", "printf '__HERMESPET_PATH__%s\\n' \"$PATH\"; whence -p \(command)"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (false, nil, nil)
        }

        // 2 秒兜底超时 —— 防止用户 .zshrc 里有死循环 / 同步网络请求把我们挂住
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return (false, nil, nil)
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let shellPath = lines
            .first(where: { $0.hasPrefix("__HERMESPET_PATH__") })
            .map { String($0.dropFirst("__HERMESPET_PATH__".count)) }

        // command -v 输出可能是 "claude: aliased to ..." 或纯路径；取最后一行的纯路径
        let path = lines
            .last(where: { $0.hasPrefix("/") })

        guard let resolved = path, !resolved.isEmpty,
              FileManager.default.isExecutableFile(atPath: resolved) else {
            return (false, nil, shellPath)
        }
        return (true, resolved, shellPath)
    }
}
