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
    private static let preferredDMGAssetMarker: String = {
        #if arch(arm64)
        return "AppleSilicon"
        #else
        return "Intel"
        #endif
    }()

    private var periodicTask: Task<Void, Never>?

    private init() {
        let info = Bundle.main.infoDictionary
        self.currentVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
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

        let urlString = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("HermesPet/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = L("update.error.httpStatus", code)
                return
            }
            try parseRelease(data: data)
        } catch {
            lastError = L("update.error.checkFailed", error.localizedDescription)
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

    private func parseRelease(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = L("update.error.parseNotJSON")
            return
        }
        guard let tag = json["tag_name"] as? String else {
            lastError = L("update.error.parseMissingTag")
            return
        }
        // GitHub tag 一般带 `v` 前缀（v1.3.0），剥掉再比对
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        self.latestVersion = version
        self.latestNotes = (json["body"] as? String) ?? ""

        // 从 assets 找当前架构对应的 .dmg；兼容旧版只有单个 DMG 的 release。
        if let assets = json["assets"] as? [[String: Any]] {
            let dmgAssets = assets.compactMap { asset -> (name: String, url: URL)? in
                if let name = asset["name"] as? String,
                   name.hasSuffix(".dmg"),
                   let urlStr = asset["browser_download_url"] as? String,
                   let url = URL(string: urlStr) {
                    return (name, url)
                }
                return nil
            }
            let selectedAsset = dmgAssets.first {
                $0.name.localizedCaseInsensitiveContains(Self.preferredDMGAssetMarker)
            } ?? dmgAssets.first
            self.latestDownloadURL = selectedAsset?.url
        }
        if latestDownloadURL == nil {
            lastError = L("update.error.noDMGAsset")
        }
    }

    // MARK: - 下载 + 引导安装

    /// 用户点「下载并安装」按钮调。
    /// 完成后会自动 `hdiutil attach` 挂载 DMG → `open` 让 Finder 弹出窗口让用户拖到 Applications
    func downloadAndInstall() async {
        guard let dlURL = latestDownloadURL else {
            lastError = L("update.error.missingDownloadURL")
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
                lastError = L("update.error.downloadHTTP", code)
                return
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            // 下载完成 → 全自动安装：挂载 → 替换 /Applications 旧版 → 卸载清理 → 重启新版
            await installFromDMG(dmgPath: destination.path)
        } catch {
            lastError = L("update.error.downloadFailed", error.localizedDescription)
        }
    }

    /// 全自动安装：挂载 DMG → 找到 .app → 写 helper 脚本 → 弹「立即重启」→ 退出让脚本接管替换+重启。
    /// 任一步不满足（挂载失败 / 找不到 .app / 目标目录不可写 / 脚本写入失败）→ 回退到打开 Finder 手动拖拽。
    private func installFromDMG(dmgPath: String) async {
        guard let volumePath = await Self.attachDMG(dmgPath: dmgPath) else {
            lastError = L("update.error.mountFailed")
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
        alert.messageText = L("update.ready.title", latestVersion ?? "")
        alert.informativeText = L("update.ready.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("update.button.restartNow"))
        alert.addButton(withTitle: L("update.button.later"))
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
            lastError = L("update.error.launchInstaller", error.localizedDescription)
        }
    }

    /// 弹一个 NSAlert 引导用户拖到 Applications
    private func postInstallHint(volumePath: String) {
        let alert = NSAlert()
        alert.messageText = L("update.manual.title")
        alert.informativeText = L("update.manual.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("update.button.gotIt"))
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

/// 持有 KVO observation 直到下载结束。observation 之前声明在 continuation 闭包里、闭包一退出就被释放
/// → KVO 注销 → 进度条永远停在 0。用 holder 把它挂到 download() 函数作用域（跨 await 存活），
/// 下载完成后 defer 里 invalidate。@unchecked Sendable 以便被 @Sendable 的 completion 闭包捕获。
private final class ProgressObservationHolder: @unchecked Sendable {
    private var obs: NSKeyValueObservation?
    func set(_ o: NSKeyValueObservation?) { obs = o }
    func invalidate() { obs?.invalidate(); obs = nil }
}

private extension URLSession {
    /// 自定义 download API 附带进度回调。Foundation 的原生 download(from:) 没有 progress hook。
    /// 用 dataTask + completion 简单封装；不做断点续传（更新场景文件小，没必要）
    func download(from url: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        let holder = ProgressObservationHolder()
        defer { holder.invalidate() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
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
            // 用 KVO 监听 fractionCompleted 转 callback；observation 存进 holder 保活到下载结束
            holder.set(task.progress.observe(\.fractionCompleted) { p, _ in
                progress(p.fractionCompleted)
            })
            task.resume()
        }
    }
}
