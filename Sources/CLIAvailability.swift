import Foundation

/// 检测 `claude` / `codex` CLI 是否安装在用户机器上。
///
/// 三层兜底策略（按顺序尝试，任一成功即返回）：
///   1. zsh -lic 'command -v <cmd>'（加载用户 ~/.zshrc 拿真实 PATH）
///   2. bash -lic 'command -v <cmd>'（兼容默认 shell 改成 bash 的用户）
///   3. 扫常见安装目录（~/.local/bin、/opt/homebrew/bin、~/.bun/bin 等）
///
/// 不能直接复用 ClaudeCodeClient.checkAvailable() 来做这件事 —— 那个用 hardcoded path
/// `/Users/mac01/.local/bin/claude` 跑 `--version`，在**别人电脑上 100% 失败**（路径不存在）。
/// 这里把找到的真实路径写回 UserDefaults，让真正发请求的 client 后续能用对的路径。
///
/// **为什么是 actor 而不是 final class + NSLock**：
/// Swift 6 严格并发模式禁止在 async context 调用 NSLock.lock/unlock，actor 是官方推荐替代。
///
/// **缓存策略**（v1.3 优化）：
///   - 成功：缓存 5 分钟，避免每次切 mode 都启动子进程
///   - 失败：缓存 30 秒，让用户刚装完 CLI 后很快能被识别（之前 5 分钟太长）
///   - 设置面板"重新检测 CLI"按钮可立即清缓存
actor CLIAvailability {

    static let shared = CLIAvailability()

    private struct Entry {
        let isAvailable: Bool
        let resolvedPath: String?
        let shellPath: String?
        let checkedAt: Date
    }

    /// 成功结果缓存 5 分钟，失败结果只缓存 30 秒
    private let successTTL: TimeInterval = 5 * 60
    private let failureTTL: TimeInterval = 30
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
        // 1) 读缓存（成功 / 失败用不同 TTL）
        if let entry = cache[command] {
            let ttl = entry.isAvailable ? successTTL : failureTTL
            if Date().timeIntervalSince(entry.checkedAt) < ttl {
                return entry.isAvailable
            }
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

    /// 三层兜底：zsh shell → bash shell → 常见路径扫描。
    /// 任何一层成功就直接返回；全部失败才返回 (false, nil, nil)。
    /// 失败/超时永远不抛错（这是个"探测"操作，不应该崩）。
    private nonisolated static func detectPath(for command: String) -> (Bool, String?, String?) {
        // Layer 1: zsh login + interactive shell
        if let result = detectViaShell(shell: "/bin/zsh", command: command) {
            return result
        }
        // Layer 2: bash 兜底（用户默认 shell 改成 bash 的情况）
        if let result = detectViaShell(shell: "/bin/bash", command: command) {
            return result
        }
        // Layer 3: 直接扫常见安装路径
        if let path = scanCommonPaths(for: command) {
            return (true, path, nil)
        }
        return (false, nil, nil)
    }

    /// 用一个登录 shell 命令查可执行路径。
    /// 为什么不直接 `/usr/bin/which`：
    ///   - GUI app 的 PATH 不包含 ~/.local/bin、Homebrew brew --prefix、nvm/asdf 装的二进制
    ///   - 走 `<shell> -lic 'command -v xxx'` 让 shell 加载用户 ~/.zshrc / ~/.zprofile，
    ///     才能拿到跟终端里一致的 PATH
    /// 失败 / 超时返回 nil，让外层走下一层兜底。
    private nonisolated static func detectViaShell(shell: String, command: String) -> (Bool, String?, String?)? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l = login shell（加载 ~/.zprofile / ~/.bash_profile）;
        // -i = interactive（加载 ~/.zshrc / ~/.bashrc）;
        // -c = 跑后面这条命令。command -v 比 which 更标准也更快。
        process.arguments = ["-lic", "printf '__HERMESPET_PATH__%s\\n' \"$PATH\"; command -v \(command)"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // 4 秒兜底超时 —— 比之前 2s 宽松，给 nvm.sh 等慢启动 ~/.zshrc 留余地
        // 但仍然挡得住死循环
        let deadline = Date().addingTimeInterval(4.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
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
        let path = lines.last(where: { $0.hasPrefix("/") })

        guard let resolved = path, !resolved.isEmpty,
              FileManager.default.isExecutableFile(atPath: resolved) else {
            // shell 跑成了但没找到命令 —— 返回 shellPath 让 CLIProcessEnvironment 后续 spawn 时还能用上
            return (false, nil, shellPath)
        }
        return (true, resolved, shellPath)
    }

    /// 常见 CLI 工具安装路径兜底扫描。
    /// 当 shell 探测全失败时（用户用 fish/oh-my-posh/.zshrc 死循环超时等），直接到常见目录里找文件。
    /// 顺序按"流行度"排：homebrew → 用户 local → 包管理器 → node 生态。
    private nonisolated static func scanCommonPaths(for command: String) -> String? {
        let home = NSHomeDirectory()
        let candidates: [String] = [
            // Claude Code 官方安装目录（curl install 脚本默认）
            "\(home)/.local/bin/\(command)",
            // Homebrew on Apple Silicon
            "/opt/homebrew/bin/\(command)",
            // Homebrew on Intel
            "/usr/local/bin/\(command)",
            // bun 安装的 npm 包
            "\(home)/.bun/bin/\(command)",
            // Deno
            "\(home)/.deno/bin/\(command)",
            // npm -g 默认（用户改过 prefix）
            "\(home)/.npm-global/bin/\(command)",
            // volta（node 版本管理器）
            "\(home)/.volta/bin/\(command)",
            // cargo（万一有 Rust 实现）
            "\(home)/.cargo/bin/\(command)",
            // pnpm
            "\(home)/Library/pnpm/\(command)",
            // mise shims
            "\(home)/.local/share/mise/shims/\(command)",
            // asdf shims
            "\(home)/.asdf/shims/\(command)",
            "\(home)/.asdf/bin/\(command)"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // nvm：扫所有 node 版本的 bin 目录
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions {
                let candidate = "\(nvmRoot)/\(version)/bin/\(command)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        // fnm：同样扫所有 node 版本
        let fnmRoot = "\(home)/.local/share/fnm/node-versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnmRoot) {
            for version in versions {
                let candidate = "\(fnmRoot)/\(version)/installation/bin/\(command)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }
}
