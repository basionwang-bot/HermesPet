import Foundation

/// 检测 `claude` / `codex` CLI 是否安装在用户机器上。
///
/// 四层兜底策略（按顺序尝试，任一成功即返回）：
///   1. zsh -lic 'command -v <cmd>'（加载用户 ~/.zshrc 拿真实 PATH）
///   2. bash -lic 'command -v <cmd>'（兼容默认 shell 改成 bash 的用户）
///   3. 扫常见安装目录（~/.local/bin、/opt/homebrew/bin、~/.bun/bin 等）
///   4. **脚印探测**（借鉴 clawd-on-desk）—— 按 agent 自己的固定安装布局定位可执行文件：
///      - Claude：`~/.local/share/claude/versions/<最新版本号>`（版本号命名的二进制本体；
///        `~/.local/bin/claude` 只是软链到它，软链坏/缺时 Layer 3 抓瞎，这里直接到版本目录捞）
///      - Codex：`/Applications/Codex.app/Contents/Resources/codex`（随 Codex.app 一起装的 CLI，
///        用户没把它加进 PATH 时前三层全漏，但 app bundle 路径是固定可靠的脚印）
///      解决"明明装了却被判没装"——GUI app 的 PATH 抓不到这些位置，但脚印固定可靠。
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

    static func qwenAvailable() async -> Bool {
        await shared.isAvailable(command: "qwen", userDefaultsKey: "qwenExecutablePath")
    }

    /// 强制清缓存 —— 用户在设置里点"重新检测"时调用
    static func invalidateCache() async {
        await shared.clearCache()
    }

    /// 通用 binary 定位 —— 给 `HermesGatewayManager` / `OpenClawGatewayManager` 复用，
    /// 让 hermes / openclaw 也享受跟 claude / codex 同款的健壮四层探测：
    ///   1) zsh -lic + 2) bash -lic（**加载 `~/.zshrc`**，旧版那俩管理器只用 `-l` 会漏掉
    ///      nvm / bun / pnpm / npm-global 这些装在 `.zshrc` 里的 PATH —— openclaw 是 npm CLI 最常中招）
    ///   3) 全面扫常见目录（含 nvm / bun / pnpm / volta / asdf / mise / fnm）
    ///   4) 脚印兜底（hermes venv 本体 / codex app bundle 等）
    /// 全程带 4s 超时（旧版 `waitUntilExit()` **无超时**，登录 shell 偶发卡顿就"这一次检测不到、下次又好"）。
    ///
    /// **同步阻塞**（内部跑登录 shell 子进程），调用方应在后台 Task / detached 里调，别卡主线程。
    /// 不写 UserDefaults、不走 actor 缓存（hermes/openclaw 只在启动 + 手动重检时调，频率低）。
    nonisolated static func locateBinary(command: String) -> String? {
        let (found, path, _) = detectPath(for: command)
        return found ? path : nil
    }

    // MARK: - actor 内部实现

    private func clearCache() {
        cache.removeAll()
    }

    private func isAvailable(command: String, userDefaultsKey: String) async -> Bool {
        // 0) 手动指定路径优先（issue #23）—— 用户在设置面板手填的路径，只要可执行就直接用，
        //    不经过自动探测。这是自动探测失败时的兜底，也是高级用户强制指定的入口。
        let manualKey = userDefaultsKey + "Manual"
        if let manual = UserDefaults.standard.string(forKey: manualKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty {
            if FileManager.default.isExecutableFile(atPath: manual) {
                UserDefaults.standard.set(manual, forKey: userDefaultsKey)  // 写解析路径供 spawn 读
                return true
            }
            // 手填了但路径不可执行 → 不直接判失败，继续走下面的自动探测兜底
        }

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
        // shell 跑通但没找到命令时，detectViaShell 返回 (false, nil, shellPath)。
        // 此时**不能直接 return**（否则会跳过后面的路径扫描），但要把拿到的 shellPath 留着，
        // 给 CLIProcessEnvironment 后续 spawn 用。
        var bestShellPath: String?

        // Layer 1: zsh login + interactive shell
        if let result = detectViaShell(shell: "/bin/zsh", command: command) {
            if result.0 { return result }                  // 找到了 → 直接用
            bestShellPath = bestShellPath ?? result.2       // 没找到但拿到了 PATH → 留着继续兜底
        }
        // Layer 2: bash 兜底（用户默认 shell 改成 bash 的情况）
        if let result = detectViaShell(shell: "/bin/bash", command: command) {
            if result.0 { return result }
            bestShellPath = bestShellPath ?? result.2
        }
        // Layer 3: 直接扫常见安装路径（/usr/local/bin、/opt/homebrew/bin、~/.local/bin 等）。
        // ⚠️ 关键修复（issue #23）：登录 shell 跑通但 PATH 里没有该命令（如用户的 claude 在
        // /usr/local/bin 但没加进 .zshrc 的 PATH）时，必须落到这一层扫描；以前 detectViaShell
        // 返回的 (false, nil, shellPath) 被当成"有结果"直接 return，导致这一层永远不执行。
        if let path = scanCommonPaths(for: command) {
            return (true, path, bestShellPath)
        }
        // Layer 4: 脚印探测（借鉴 clawd-on-desk）。按 agent 自己的固定安装布局定位可执行文件，
        // 兜住前三层全漏的真实场景：Claude 软链坏掉只剩 versions/ 版本目录、Codex 只装了
        // Codex.app 没把 codex 加进 PATH 等。这些路径固定可靠，是"明明装了却说没装"的最后救命稻草。
        if let path = scanFootprintPaths(for: command) {
            return (true, path, bestShellPath)
        }
        return (false, nil, bestShellPath)
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

    /// 脚印探测（Layer 4，借鉴 clawd-on-desk 的"看 agent 自己的安装脚印而非 PATH"思路）。
    /// 前三层全失败时调用：按每个 agent 自己**固定且可靠**的安装布局直接定位可执行文件。
    /// 这些位置故意不放进 `scanCommonPaths`——它们是 agent 专属布局，不是通用 bin 目录。
    private nonisolated static func scanFootprintPaths(for command: String) -> String? {
        let home = NSHomeDirectory()
        let fm = FileManager.default

        switch command {
        case "claude":
            // Claude Code 原生安装器布局：
            //   ~/.local/bin/claude  →（软链）→  ~/.local/share/claude/versions/<版本号>
            // 每个 versions/<版本号> 都是独立的 Mach-O 可执行本体。软链被删/损坏时 Layer 3
            // 的 ~/.local/bin/claude 会失败，这里直接进版本目录挑**最新版本号**那个可执行文件。
            let versionsDir = "\(home)/.local/share/claude/versions"
            if let entries = try? fm.contentsOfDirectory(atPath: versionsDir) {
                let executables = entries
                    .map { (name: $0, path: "\(versionsDir)/\($0)") }
                    .filter { fm.isExecutableFile(atPath: $0.path) }
                // 按语义化版本号降序，取最新的那个（2.1.150 > 2.1.148 > 2.1.9）
                if let newest = executables.max(by: { versionLess($0.name, $1.name) }) {
                    return newest.path
                }
            }

        case "codex":
            // Codex CLI 常随 Codex.app 一起安装在 app bundle 内，用户没把它加进 PATH 时前三层全漏。
            // app bundle 路径固定可靠，作为脚印兜底。
            let candidates = [
                "/Applications/Codex.app/Contents/Resources/codex",
                "\(home)/Applications/Codex.app/Contents/Resources/codex",
                "\(home)/.codex/bin/codex"
            ]
            for path in candidates where fm.isExecutableFile(atPath: path) {
                return path
            }

        case "hermes":
            // Hermes 是 Python 项目，官方装法把可执行放在 venv 里、再软链到 ~/.local/bin/hermes。
            // 软链没建/被删时 ~/.local/bin/hermes 失效，直接到 venv 本体捞（clawd-on-desk 也查这个脚印）。
            let venvBin = "\(home)/.hermes/hermes-agent/venv/bin/hermes"
            if fm.isExecutableFile(atPath: venvBin) { return venvBin }

        default:
            break
        }

        return nil
    }

    /// 语义化版本号比较：`a < b` 时返回 true。按点分段逐段比数字，缺段补 0。
    /// 用于在 Claude 的 versions/ 目录里挑出最新版本（纯字符串比会把 "2.1.9" 误判为大于 "2.1.10"）。
    private nonisolated static func versionLess(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(pa.count, pb.count)
        for i in 0..<count {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va < vb }
        }
        return false
    }
}
