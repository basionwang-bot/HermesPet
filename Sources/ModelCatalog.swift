import Foundation

/// CLI 模式（Claude Code / Codex）可用模型清单的探测 + 缓存。
///
/// **策略**：先尝试 spawn CLI 拉 `--help` 输出，用正则抠模型 ID；
/// 抠不到（CLI 没暴露列表 / 进程超时 / 没装 CLI）→ 退回内置预设。
/// 两种来源合并去重，上游探测到的排前面。结果在 actor 内缓存到 invalidate() 调用为止。
///
/// **为什么用 actor**：探测要 spawn 子进程，UI 多次进设置面板别重复跑；
/// Swift 6 严格并发下 NSLock 在 async context 里不能用，actor 是唯一干净的方案。
actor ModelCatalog {
    static let shared = ModelCatalog()

    /// mode → 已确定的模型清单。invalidate 前一直复用，进设置面板秒出。
    private var cache: [AgentMode: [String]] = [:]

    /// 内置预设 —— 探测失败时的兜底，永远可用。
    /// 模型字符串以 2026-05 各家官方文档 + 知识截止前 CLAUDE.md 记录的旗舰为准；
    /// CLI 升级 / 新模型发布后可手动补充，或等 CLI `--help` 暴露列表后自动抓到。
    private static let presets: [AgentMode: [String]] = [
        .claudeCode: [
            // claude CLI 接受的官方别名，永远指向当家最强款，省心
            "sonnet", "opus", "haiku",
            // 完整 ID —— 用户想锁版本时用
            "claude-opus-4-7",
            "claude-sonnet-4-6",
            "claude-haiku-4-5-20251001"
        ],
        .codex: [
            // OpenAI 旗舰；codex CLI 接受官方 model ID 走 OpenAI API
            "gpt-5.4",
            "gpt-5.4-codex",
            "gpt-5.5",
            "gpt-5.4-mini"
        ]
    ]

    /// 获取 mode 的模型清单。`forceRefresh = true` 跳过缓存重新探测（"刷新"按钮用）
    func models(for mode: AgentMode, forceRefresh: Bool = false) async -> [String] {
        if !forceRefresh, let cached = cache[mode] { return cached }
        let upstream = await probeCLI(for: mode)
        let presets = Self.presets[mode] ?? []
        // 上游优先，预设兜底；保序去重
        var seen = Set<String>()
        var merged: [String] = []
        for item in upstream + presets where seen.insert(item).inserted {
            merged.append(item)
        }
        cache[mode] = merged
        return merged
    }

    /// 清空缓存 —— 用户改了 CLI 路径 / 装了新版本时调用
    func invalidate() {
        cache.removeAll()
    }

    // MARK: - 探测

    /// spawn `<cli> --help`，用正则从输出里抓模型 ID。抓不到 → []
    private func probeCLI(for mode: AgentMode) async -> [String] {
        let exe: String
        switch mode {
        case .claudeCode:
            exe = UserDefaults.standard.string(forKey: "claudeExecutablePath") ?? ""
        case .codex:
            exe = UserDefaults.standard.string(forKey: "codexExecutablePath") ?? ""
        default:
            return []
        }
        guard !exe.isEmpty, FileManager.default.isExecutableFile(atPath: exe) else { return [] }

        let output = await spawn(exe: exe, args: ["--help"], timeoutSeconds: 2.0)
        return extractModelIDs(from: output, mode: mode)
    }

    /// 异步 spawn，超时强杀。stdout + stderr 合并返回。失败 → 空串
    private func spawn(exe: String, args: [String], timeoutSeconds: Double) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: exe)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe

                do { try proc.run() } catch {
                    cont.resume(returning: "")
                    return
                }

                // 超时强杀 —— CLI 卡死也不能挂住设置面板
                let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: killer)

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()

                let text = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: text)
            }
        }
    }

    /// 从 `--help` 文本里抠模型 ID。CLI 不一定会列；列了就拿到，没列就空数组。
    /// 模式专用正则避免误抓（比如 codex 输出里别把 "gpt-3.5-turbo-example" 这种文档示例抓进来）
    private func extractModelIDs(from text: String, mode: AgentMode) -> [String] {
        let pattern: String
        switch mode {
        case .claudeCode:
            // claude-<family>-<version> 或带日期后缀 claude-haiku-4-5-20251001
            pattern = #"claude-[a-z]+-\d+(?:[-.]\d+)*(?:-\d{8})?"#
        case .codex:
            // gpt-5.4 / gpt-5.4-codex / o4-mini 等
            pattern = #"(?:gpt|o\d)[-.]?[a-zA-Z0-9.-]+[a-zA-Z0-9]"#
        default:
            return []
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var out: [String] = []
        for m in regex.matches(in: text, range: range) {
            if let r = Range(m.range, in: text) {
                let s = String(text[r])
                if seen.insert(s).inserted { out.append(s) }
            }
        }
        return out
    }
}
