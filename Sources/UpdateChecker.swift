import AppKit
import Foundation

/// GitHub Release API 自动更新检查器。
///
/// **设计目标**：用户能知道有新版可用 + 一键引导安装，不上 Sparkle（避免 Developer ID 强依赖）。
///
/// 工作流：
/// 1. App 启动 60s 后 + 每 24h 自动 GET `https://api.github.com/repos/<owner>/<repo>/releases/latest`
/// 2. 对比 latest tag (`v1.3.0`) vs 当前 `CFBundleShortVersionString` (`1.3.0`)
/// 3. 有新版 → `hasUpdate = true`，触发 UI 通知（设置面板 + 菜单栏小红点）
/// 4. 用户点「下载并安装」→ 后台 download DMG 到 ~/Downloads → `hdiutil attach` 挂载
///    → `open <volumePath>` 让 Finder 弹出已挂载的 DMG 窗口 → 用户拖到 Applications
///
/// **403 韧性（issue #94）**：GitHub 未认证 API 限额 60 次/小时（全局 IP），易被耗尽。
/// 三层防御：① ETag 条件请求（304 不扣配额）② 本地缓存兜底（403 时用上次结果）
/// ③ 403/429 指数退避重试（最多 1 次，延迟 10s）
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    // MARK: - State (observable, UI 绑定)

    /// 当前安装版本（从 Info.plist 读）
    let currentVersion: String

    /// 远端最新版本（首次成功检查后填）
    private(set) var latestVersion: String?

    /// 最新版的 DMG 直链
    private(set) var latestDownloadURL: URL?

    /// 最新版的 Release Notes（GitHub release body markdown）
    private(set) var latestNotes: String = ""

    /// 上次检查时间，UI 显示用
    private(set) var lastCheckedAt: Date?

    /// 是否正在检查 / 下载
    private(set) var isChecking = false
    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0  // 0.0 ~ 1.0

    /// 最近一次错误（检查失败 / 下载失败）
    private(set) var lastError: String?

    /// 有新版可用（latest > current 且 download URL 有效）
    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        return UpdateChecker.compare(latest, isNewerThan: currentVersion) && latestDownloadURL != nil
    }

    // MARK: - 配置

    private static let owner = "basionwang-bot"
    private static let repo = "HermesPet"
    private static let checkInterval: TimeInterval = 24 * 60 * 60   // 24h
    /// 403/429 重试延迟（秒）—— 不激进，避免雪崩
    private static let retryDelay: TimeInterval = 10

    private var periodicTask: Task<Void, Never>?

    // MARK: - 缓存（issue #94：403 时用上次成功的结果兜底）

    /// 上次 GitHub API 返回的 ETag，用于条件请求（If-None-Match）。
    /// 304 Not Modified 不扣 Rate Limit 配额 —— 这是对抗 60 次/小时限制最有效的武器。
    private var cachedETag: String?
    /// 缓存目录：`~/Library/Caches/HermesPet/`（跟项目其他缓存共用，见 StorageManager）
    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("HermesPet", isDirectory: true)
    }
    private static var cacheFileURL: URL { cacheDir.appendingPathComponent("update-check-cache.json") }
    private static var etagFileURL: URL { cacheDir.appendingPathComponent("update-check-etag.txt") }

    private init() {
        let info = Bundle.main.infoDictionary
        self.currentVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        // 启动时加载上次缓存的 ETag（304 条件请求用）和检查结果（403 兜底用）
        loadCache()
    }

    // MARK: - 启动调度

    /// AppDelegate 启动时调一次。延迟 60s 首次检查（避免抢启动资源），之后每 24h 一次。
    func start() {
        periodicTask?.cancel()
        periodicTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await self?.check(silently: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.checkInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.check(silently: true)
            }
        }
    }

    /// 用户手动从设置面板点「检查更新」时调（silently=false → 即便没新版也通知）
    func check(silently: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer {
            isChecking = false
            lastCheckedAt = Date()
        }

        // 首次请求（带 ETag 条件请求，304 不扣配额）
        if await performCheckRequest(retryOnRateLimit: true) {
            saveCache()
        } else if lastError != nil {
            // 请求失败 → 尝试从缓存恢复（issue #94：403 时用上次结果兜底）
            if restoreFromCache() {
                // 缓存恢复成功，把错误降级为 info 级提示
                lastError = "\(lastError ?? "")（已使用上次缓存的检查结果）"
            }
        }

        if !silently, !hasUpdate {
            // 手动触发但没新版 → 弹个温和提示，让用户知道点击有反馈
            NotificationCenter.default.post(
                name: .init("HermesPetUpdateCheckResult"),
                object: nil,
                userInfo: ["hasUpdate": false]
            )
        }
        if hasUpdate {
            NotificationCenter.default.post(
                name: .init("HermesPetUpdateAvailable"),
                object: nil,
                userInfo: [
                    "version": latestVersion ?? "",
                    "silently": silently
                ]
            )
        }
    }

    /// 执行单次 GitHub API 请求（含 ETag 条件请求 + 403/429 重试）。
    /// 返回 true = 成功获取了有效结果（200 或 304 + 缓存）。
    private func performCheckRequest(retryOnRateLimit: Bool) async -> Bool {
        let urlString = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest"
        guard let url = URL(string: urlString) else { return false }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("HermesPet/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // ETag 条件请求：如果服务端资源没变，返回 304 不扣 Rate Limit
        if let etag = cachedETag {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastError = "网络错误：无法解析响应"
                return false
            }

            switch http.statusCode {
            case 200:
                // 成功 —— 保存 ETag + 解析结果
                if let newETag = http.value(forHTTPHeaderField: "ETag") {
                    cachedETag = newETag
                    saveETag()
                }
                do {
                    try parseRelease(data: data)
                    return lastError == nil
                } catch {
                    return false
                }

            case 304:
                // Not Modified —— 资源没变，用内存中的上次结果即可，不扣配额
                return latestVersion != nil

            case 403, 429:
                // Rate Limit 超限 —— 解析 X-RateLimit 头给用户有意义的提示
                let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining") ?? "?"
                let resetEpoch = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                let resetMsg: String
                if let epoch = resetEpoch, let ts = Double(epoch) {
                    let resetDate = Date(timeIntervalSince1970: ts)
                    let mins = Int(resetDate.timeIntervalSinceNow / 60) + 1
                    resetMsg = "约 \(max(mins, 1)) 分钟后恢复"
                } else {
                    resetMsg = "请稍后重试"
                }
                let rateLimitError = "GitHub API 请求超限（remaining=\(remaining)），\(resetMsg)"

                // 重试一次（指数退避）
                if retryOnRateLimit {
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                    lastError = nil
                    if await performCheckRequest(retryOnRateLimit: false) {
                        return true
                    }
                }
                lastError = rateLimitError
                return false

            default:
                lastError = "GitHub 返回 HTTP \(http.statusCode)"
                return false
            }
        } catch {
            lastError = "检查失败：\(error.localizedDescription)"
            return false
        }
    }

    private func parseRelease(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = "解析失败：响应不是 JSON 对象"
            return
        }
        guard let tag = json["tag_name"] as? String else {
            lastError = "解析失败：缺少 tag_name"
            return
        }
        // GitHub tag 一般带 `v` 前缀（v1.3.0），剥掉再比对
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        self.latestVersion = version
        self.latestNotes = (json["body"] as? String) ?? ""

        // 从 assets 找 .dmg 文件
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String,
                   name.hasSuffix(".dmg"),
                   let urlStr = asset["browser_download_url"] as? String,
                   let url = URL(string: urlStr) {
                    self.latestDownloadURL = url
                    break
                }
            }
        }
        if latestDownloadURL == nil {
            lastError = "未在 release 中找到 DMG 资产"
        }
    }

    // MARK: - 缓存持久化（issue #94：403 离线兜底）

    /// 把当前检查结果（latestVersion / latestDownloadURL / latestNotes）写到磁盘。
    /// 每次 200 成功解析后调用。
    private func saveCache() {
        guard let version = latestVersion else { return }
        let cache: [String: String] = [
            "version": version,
            "downloadURL": latestDownloadURL?.absoluteString ?? "",
            "notes": latestNotes
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cache) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheFileURL, options: .atomic)
    }

    /// 保存 ETag 到磁盘（跨启动持久化，避免每次冷启动都浪费一次 200 配额）
    private func saveETag() {
        guard let etag = cachedETag else { return }
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        try? etag.write(to: Self.etagFileURL, atomically: true, encoding: .utf8)
    }

    /// 启动时加载缓存的 ETag 和上次检查结果
    private func loadCache() {
        // 加载 ETag
        cachedETag = try? String(contentsOf: Self.etagFileURL, encoding: .utf8)
        // 加载上次检查结果（仅用于 403 兜底，不自动填充 UI —— 等首次 check 成功后再激活）
        guard let data = try? Data(contentsOf: Self.cacheFileURL),
              let cache = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let version = cache["version"] else { return }
        // 仅当缓存版本比当前版本新时才预填（避免显示过期信息）
        if UpdateChecker.compare(version, isNewerThan: currentVersion) {
            self.latestVersion = version
            if let urlStr = cache["downloadURL"], let url = URL(string: urlStr) {
                self.latestDownloadURL = url
            }
            self.latestNotes = cache["notes"] ?? ""
        }
    }

    /// API 请求失败后，尝试从磁盘缓存恢复结果。返回 true = 成功恢复。
    private func restoreFromCache() -> Bool {
        guard let data = try? Data(contentsOf: Self.cacheFileURL),
              let cache = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let version = cache["version"] else { return false }
        self.latestVersion = version
        if let urlStr = cache["downloadURL"], let url = URL(string: urlStr) {
            self.latestDownloadURL = url
        }
        self.latestNotes = cache["notes"] ?? ""
        return true
    }

    // MARK: - 下载 + 引导安装

    /// 用户点「下载并安装」按钮调。
    /// 完成后会自动 `hdiutil attach` 挂载 DMG → `open` 让 Finder 弹出窗口让用户拖到 Applications
    func downloadAndInstall() async {
        guard let dlURL = latestDownloadURL else {
            lastError = "下载链接缺失"
            return
        }
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        lastError = nil
        defer { isDownloading = false }

        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let fileName = dlURL.lastPathComponent.isEmpty
            ? "HermesPet-\(latestVersion ?? "latest").dmg"
            : dlURL.lastPathComponent
        let destination = downloadsDir.appendingPathComponent(fileName)

        // 已存在同名文件 → 删了重新下，避免老缓存覆盖新版
        try? FileManager.default.removeItem(at: destination)

        do {
            let progressHandler: @Sendable (Double) -> Void = { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            }
            let (tempURL, response) = try await URLSession.shared.download(from: dlURL, progress: progressHandler)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = "下载失败：HTTP \(code)"
                return
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            // 下载完成 → 全自动安装：挂载 → 替换 /Applications 旧版 → 卸载清理 → 重启新版
            await installFromDMG(dmgPath: destination.path)
        } catch {
            lastError = "下载失败：\(error.localizedDescription)"
        }
    }

    /// 全自动安装：挂载 DMG → 找到 .app → 写 helper 脚本 → 弹「立即重启」→ 退出让脚本接管替换+重启。
    /// 任一步不满足（挂载失败 / 找不到 .app / 目标目录不可写 / 脚本写入失败）→ 回退到打开 Finder 手动拖拽。
    private func installFromDMG(dmgPath: String) async {
        guard let volumePath = await Self.attachDMG(dmgPath: dmgPath) else {
            lastError = "DMG 挂载失败，无法自动安装"
            return
        }
        // 挂载卷里找 .app（优先与当前运行 app 同名）
        guard let newAppPath = findAppInVolume(volumePath) else {
            fallbackToManual(volumePath: volumePath)
            return
        }
        let oldAppPath = Bundle.main.bundlePath
        let parentDir = (oldAppPath as NSString).deletingLastPathComponent
        // 目标目录不可写（app 在只读位置 / 无权限）→ 回退手动拖拽
        guard FileManager.default.isWritableFile(atPath: parentDir) else {
            fallbackToManual(volumePath: volumePath)
            return
        }
        guard let scriptPath = writeInstallScript(
            oldApp: oldAppPath, newApp: newAppPath, volume: volumePath, dmg: dmgPath
        ) else {
            fallbackToManual(volumePath: volumePath)
            return
        }

        let alert = NSAlert()
        alert.messageText = "新版 v\(latestVersion ?? "") 已就绪"
        alert.informativeText = """
        点击「立即重启」自动完成安装。

        应用会先退出几秒，自动替换为新版后重新打开——你不用打开访达，也不用手动拖拽。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            launchInstaller(scriptPath: scriptPath)
            NSApp.terminate(nil)
        } else {
            // 用户选稍后：卸载挂载卷（DMG 与脚本留着，下次更新会覆盖）
            Self.detach(volumePath: volumePath)
        }
    }

    /// 回退路径：自动安装条件不满足时，打开 Finder 让用户手动拖拽（保留旧体验兜底）
    private func fallbackToManual(volumePath: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: volumePath))
        postInstallHint(volumePath: volumePath)
    }

    /// 后台 `hdiutil attach` 挂载 DMG，解析出 `/Volumes/...` 挂载路径。失败返回 nil。
    /// 挂载路径在每行末尾、tab 分隔，可能含空格（"Hermes 桌宠"），所以取 "/Volumes/" 起到行尾，
    /// 不能按空白切分（会把含空格的卷名截断）。
    private static func attachDMG(dmgPath: String) async -> String? {
        await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            proc.arguments = ["attach", dmgPath, "-nobrowse", "-noverify", "-noautoopen"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do { try proc.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") {
                if let range = line.range(of: "/Volumes/") {
                    return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }.value
    }

    /// `hdiutil detach` 卸载挂载卷（用户选"稍后"时清理）
    private static func detach(volumePath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", volumePath, "-quiet", "-force"]
        try? proc.run()
    }

    /// 挂载卷里找要安装的 .app：优先与当前运行 app 同名，否则第一个 .app
    private func findAppInVolume(_ volumePath: String) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: volumePath) else { return nil }
        let currentName = (Bundle.main.bundlePath as NSString).lastPathComponent
        if items.contains(currentName) {
            return (volumePath as NSString).appendingPathComponent(currentName)
        }
        if let appName = items.first(where: { $0.hasSuffix(".app") }) {
            return (volumePath as NSString).appendingPathComponent(appName)
        }
        return nil
    }

    /// 写一个「app 退出后接管」的安装脚本：等父进程退出 → ditto 替换 → 清 quarantine →
    /// 卸载 DMG + 删 DMG → 重开新版 → 自删。返回脚本路径；写入失败返回 nil。
    /// 注：路径用单引号包，app/DMG/卷路径均不含单引号，安全。
    private func writeInstallScript(oldApp: String, newApp: String, volume: String, dmg: String) -> String? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        OLD_APP='\(oldApp)'
        NEW_APP='\(newApp)'
        VOLUME='\(volume)'
        DMG='\(dmg)'
        PARENT_PID=\(pid)

        # 等父 app 退出（最多 ~12s）
        for i in $(seq 1 60); do
          kill -0 "$PARENT_PID" 2>/dev/null || break
          sleep 0.2
        done
        sleep 0.5

        # 安全替换：先 ditto 到同目录暂存（同卷 → mv 是原子 rename），成功后才删旧 + 改名。
        # ditto 中途失败时旧版原样保留，绝不出现"旧的删了新的没装上 → app 消失"。
        STAGING="${OLD_APP}.new"
        rm -rf "$STAGING"
        if /usr/bin/ditto "$NEW_APP" "$STAGING"; then
          rm -rf "$OLD_APP"
          mv "$STAGING" "$OLD_APP"
          /usr/bin/xattr -cr "$OLD_APP" 2>/dev/null || true
        else
          rm -rf "$STAGING"   # 替换失败，旧版不动，下面重开旧版兜底
        fi

        # 卸载 DMG + 删下载文件
        /usr/bin/hdiutil detach "$VOLUME" -quiet -force 2>/dev/null || true
        rm -f "$DMG"

        # 重新打开（替换成功 = 新版；失败则旧版兜底，用户至少不会丢 app）
        /usr/bin/open "$OLD_APP"

        # 自删脚本
        rm -f "$0"
        """
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let hpDir = dir.appendingPathComponent("HermesPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: hpDir, withIntermediateDirectories: true)
        let scriptURL = hpDir.appendingPathComponent("update-installer.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return nil
        }
    }

    /// 启动安装脚本并脱离本进程（nohup + 后台），这样本 app 退出后脚本仍继续跑。
    /// **刻意不注册到 SubprocessRegistry** —— 否则 NSApp.terminate 会把它一起 SIGTERM 掉。
    private func launchInstaller(scriptPath: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "nohup /bin/bash \"\(scriptPath)\" >/tmp/hermespet-update.log 2>&1 &"]
        do {
            try task.run()
            task.waitUntilExit()   // 外层 bash 后台化 nohup 子进程后立即退出
        } catch {
            lastError = "无法启动安装程序：\(error.localizedDescription)"
        }
    }

    /// 弹一个 NSAlert 引导用户拖到 Applications
    private func postInstallHint(volumePath: String) {
        let alert = NSAlert()
        alert.messageText = "新版已挂载，请拖入应用程序"
        alert.informativeText = """
        Finder 已经打开新版 DMG。请把里面的「Hermes 桌宠」拖到旁边的「应用程序」文件夹替换旧版即可。

        替换完成后退出当前版本（菜单栏右键 → 退出），重新打开新版本生效。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    // MARK: - 版本比较

    /// 语义版本比较：`1.3.0` > `1.2.5`，`1.3.1` > `1.3.0`
    /// 简单 dot 分割数字比较，遇到非数字段按字典序兜底
    static func compare(_ a: String, isNewerThan b: String) -> Bool {
        let aParts = a.split(separator: ".")
        let bParts = b.split(separator: ".")
        let len = max(aParts.count, bParts.count)
        for i in 0..<len {
            let ai = i < aParts.count ? Int(aParts[i]) ?? -1 : 0
            let bi = i < bParts.count ? Int(bParts[i]) ?? -1 : 0
            if ai != bi { return ai > bi }
        }
        return false
    }
}

// MARK: - URLSession.download with progress (custom helper)

private extension URLSession {
    /// 自定义 download API 附带进度回调。Foundation 的原生 download(from:) 没有 progress hook。
    /// 用 dataTask + completion 简单封装；不做断点续传（更新场景文件小，没必要）
    func download(from url: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            let task = self.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL, let response = response else {
                    continuation.resume(throwing: NSError(domain: "UpdateChecker", code: -1))
                    return
                }
                continuation.resume(returning: (tempURL, response))
            }
            // 用 KVO 监听 fractionCompleted 转 callback
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                progress(p.fractionCompleted)
            }
            // 给 task 一个 keepalive 引用，否则 observation 在 closure 退出时释放
            _ = observation
            task.resume()
        }
    }
}
