import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// 用户活动采集器 —— 持续监听用户在用什么 app / 窗口、键盘鼠标节奏。
/// 数据写到 `ActivityStore`，让 AI 能查询"用户最近在干什么"。
///
/// 采集源（按 macOS 权限难度递增）：
///   - `NSWorkspace.didActivateApplicationNotification` — 当前 active app（无权限）
///   - `NSEvent.addGlobalMonitorForEvents` — 全局键盘/鼠标计数（**Accessibility 权限**）
///   - `AXUIElementCopyAttributeValue` — focused window title（**Accessibility 权限**）
///   - `NSPasteboard.changeCount` — 剪贴板变化次数（无权限）
///
/// 会话切分规则（→ 关闭旧会话写盘 + 开新会话）：
///   1. active app 变化
///   2. 同 app 内 window title 变化
///   3. 30 秒无任何活动（键盘/鼠标/app/window 都没动）
///
/// 隐私：黑名单 app（密码管理器、钥匙串等）的 session 仅记 duration，
/// **不记** windowTitle / keyboardCount，避免敏感信息泄漏。
@MainActor
final class ActivityRecorder: NSObject {
    static let shared = ActivityRecorder()

    private let store: ActivityStore
    /// 默认敏感 app 黑名单 —— 这些 app 的 session 仅记 duration 占位
    private static let defaultExcludedBundleIDs: Set<String> = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlane",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.Safari.SafePaymentBrowsing",
    ]
    private var excludedBundleIDs: Set<String>

    /// 30 秒无任何活动就切新会话（避免一个 idle 的 app 累积虚假时长）
    private static let idleThresholdSeconds: TimeInterval = 30
    /// 每秒采样一次 active context（用 timer 触发）
    private static let sampleIntervalSeconds: TimeInterval = 1.0
    /// 每 5 分钟聚合一次当天 stats（让 AI 查询能拿到准实时的统计）
    private static let aggregateThrottleSeconds: TimeInterval = 5 * 60

    /// 是否在记录中（用户可在 settings 里暂停 / menu bar 一键暂停）
    private(set) var isRunning = false
    /// 缓存上次拿过 Accessibility 权限的检查结果，避免每次都跑 syscall
    private var hasAccessibilityPermission: Bool = false
    /// 是否拿到 Input Monitoring 权限（监听全局键盘事件需要，跟 Accessibility 是两个独立权限）
    private var hasInputMonitoringPermission: Bool = false

    /// 当前正在累积的会话块状态
    private struct SessionState {
        let id: String
        let appBundleID: String
        let appName: String
        var windowTitle: String?
        let startTime: Date
        var lastActivityTime: Date
        var keyboardCount: Int
        var mouseCount: Int
        var pasteboardCount: Int
        let isExcluded: Bool
    }
    private var current: SessionState?

    /// NSWorkspace observer / NSEvent monitor 的 token，stop 时要解绑
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var workspaceObserved = false
    private var sampleTimer: Timer?
    private var maintenanceTimer: Timer?

    private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    private var lastAggregateTime: Date = .distantPast

    init(store: ActivityStore = ActivityStore()) {
        self.store = store
        // 用户自定义黑名单（UserDefaults）合并默认黑名单
        let userExcluded = UserDefaults.standard.stringArray(forKey: "activityExcludedBundleIDs") ?? []
        self.excludedBundleIDs = Self.defaultExcludedBundleIDs.union(userExcluded)
        super.init()
    }

    // MARK: - 公开 API

    /// 启动采集。如果还没拿到 Accessibility 权限会**首次弹系统对话框**。
    /// 用户拒绝权限 → 降级为仅采集 active app（无 window title / 键盘 count）
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 检查 + 请求 Accessibility 权限（首次会弹系统对话框，给 window title 读取用）
        hasAccessibilityPermission = requestAccessibilityPermission()
        // Input Monitoring 是独立权限 —— 监听全局键盘事件需要它（跟 Accessibility 不是一回事）
        hasInputMonitoringPermission = requestInputMonitoringPermission()

        // 1) NSWorkspace 监听 active app 切换 / 启动 / 退出
        // 用经典 selector 模式 —— Swift 6 严格并发下，block 模式想把 Notification
        // 跨 actor 传过来会触发 SendingRisksDataRace 报错。selector 模式没这个问题。
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self,
                       selector: #selector(handleAppActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleAppLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleAppTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification,
                       object: nil)
        workspaceObserved = true

        // 2) 全局键盘/鼠标计数（仅数次数，不读 keyCode / characters / 坐标）
        // 必须有 Input Monitoring 权限，否则 NSEvent 静默忽略所有事件
        if hasInputMonitoringPermission {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.bumpKeyCount()
                }
            }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.bumpMouseCount()
                }
            }
        }

        // 3) 每秒采样一次：检测 window title 变化、剪贴板变化、idle 切分
        sampleTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleIntervalSeconds,
                                           repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // 当前 active app 立即开一个 session
        if let app = NSWorkspace.shared.frontmostApplication {
            startNewSession(for: app)
        }

        // 4) 启动后立即综合维护一次（prune 旧数据 + WAL checkpoint + 必要时 VACUUM）
        store.performMaintenance()

        // 5) 每 24h 重复一次维护 —— app 常驻几天的话需要持续清理避免 db 膨胀
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600,
                                                repeats: true) { [weak self] _ in
            self?.store.performMaintenance()
        }
    }

    /// 停止采集（暂停）。已在的 current session 会落盘。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        closeCurrentSession()
        if workspaceObserved {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            workspaceObserved = false
        }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        sampleTimer?.invalidate()
        sampleTimer = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
    }

    /// 用户在 settings / menu bar 切换"是否记录活动"
    func setRunning(_ running: Bool) {
        if running { start() } else { stop() }
        UserDefaults.standard.set(running, forKey: "activityRecordingEnabled")
    }

    /// 完全清空所有记录（用户在 settings 里点"清空"）
    func clearAll() {
        closeCurrentSession()
        store.clearAll()
    }

    /// 给 SettingsView / AI tool 暴露 store 查询接口
    var queryStore: ActivityStore { store }

    // MARK: - Workspace 事件处理

    @objc private func handleAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // 跳过自己 —— 没意义
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        startNewSession(for: app)
    }

    @objc private func handleAppLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        store.insertEvent(ActivityEvent(
            eventType: .appLaunch,
            appBundleID: app.bundleIdentifier,
            appName: app.localizedName
        ))
    }

    @objc private func handleAppTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        store.insertEvent(ActivityEvent(
            eventType: .appQuit,
            appBundleID: app.bundleIdentifier,
            appName: app.localizedName
        ))
    }

    // MARK: - 全局事件计数

    private func bumpKeyCount() {
        guard isRunning else { return }
        if current?.isExcluded == true { return }
        current?.keyboardCount += 1
        current?.lastActivityTime = Date()
    }

    private func bumpMouseCount() {
        guard isRunning else { return }
        if current?.isExcluded == true { return }
        current?.mouseCount += 1
        current?.lastActivityTime = Date()
    }

    // MARK: - 每秒心跳：检测 window title 变化、剪贴板变化、idle 切分

    private func tick() {
        guard isRunning else { return }

        // 1) 剪贴板：仅检测 changeCount 是否变化（**不读内容**），变了就 +1
        let pbCount = NSPasteboard.general.changeCount
        if pbCount != lastPasteboardChangeCount {
            lastPasteboardChangeCount = pbCount
            if current?.isExcluded == false {
                current?.pasteboardCount += 1
                current?.lastActivityTime = Date()
            }
        }

        // 2) window title 变化检测（仅非黑名单 + 有 AX 权限）
        if hasAccessibilityPermission, let cur = current, !cur.isExcluded,
           let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier == cur.appBundleID,
           app.processIdentifier > 0 {
            let newTitle = focusedWindowTitle(for: app.processIdentifier)
            if newTitle != cur.windowTitle {
                // window 切了 → 关旧 session 开新 session（同 app）
                closeCurrentSession()
                startNewSession(for: app, overrideTitle: newTitle)
                store.insertEvent(ActivityEvent(
                    eventType: .windowChange,
                    appBundleID: app.bundleIdentifier,
                    appName: app.localizedName,
                    windowTitle: newTitle
                ))
                return
            }
        }

        // 3) Idle 切分：30s 无任何活动 → 关闭当前 session
        if let cur = current,
           Date().timeIntervalSince(cur.lastActivityTime) > Self.idleThresholdSeconds {
            closeCurrentSession()
            // 不立即开新 session —— 等下一次活动（app 切换 / 键盘 / 鼠标）触发
        }

        // 4) Throttle 聚合：每 5 分钟把当天 sessions 卷成 app_usage_stats
        if Date().timeIntervalSince(lastAggregateTime) > Self.aggregateThrottleSeconds {
            lastAggregateTime = Date()
            store.aggregateDailyStats(for: Date())
        }
    }

    // MARK: - 会话生命周期

    private func startNewSession(for app: NSRunningApplication, overrideTitle: String? = nil) {
        guard let bundleID = app.bundleIdentifier else { return }
        // 同 app 同 window 不重新开 session
        if let cur = current,
           cur.appBundleID == bundleID,
           cur.windowTitle == (overrideTitle ?? cur.windowTitle) {
            return
        }
        closeCurrentSession()

        let isExcluded = excludedBundleIDs.contains(bundleID)
        let title: String? = {
            if isExcluded { return nil }   // 黑名单不记 window title
            if let overrideTitle { return overrideTitle }
            if hasAccessibilityPermission, app.processIdentifier > 0 {
                return focusedWindowTitle(for: app.processIdentifier)
            }
            return nil
        }()
        let now = Date()
        current = SessionState(
            id: UUID().uuidString,
            appBundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            windowTitle: title,
            startTime: now,
            lastActivityTime: now,
            keyboardCount: 0,
            mouseCount: 0,
            pasteboardCount: 0,
            isExcluded: isExcluded
        )
        store.insertEvent(ActivityEvent(
            eventType: .appActive,
            appBundleID: bundleID,
            appName: app.localizedName,
            windowTitle: title
        ))
    }

    private func closeCurrentSession() {
        guard let cur = current else { return }
        let endTime = Date()
        let duration = max(0, Int(endTime.timeIntervalSince(cur.startTime)))
        // 时长 < 1s 的丢掉，避免快速切窗的噪声
        if duration < 1 {
            current = nil
            return
        }
        let session = ActivitySession(
            id: cur.id,
            appBundleID: cur.appBundleID,
            appName: cur.appName,
            windowTitle: cur.isExcluded ? nil : cur.windowTitle,
            startTime: cur.startTime,
            endTime: endTime,
            durationSeconds: duration,
            keyboardEvents: cur.isExcluded ? 0 : cur.keyboardCount,
            mouseClicks: cur.isExcluded ? 0 : cur.mouseCount,
            pasteboardChanges: cur.isExcluded ? 0 : cur.pasteboardCount,
            isExcluded: cur.isExcluded
        )
        store.insertSession(session)
        current = nil
    }

    // MARK: - Accessibility 工具

    /// 检查 + 请求 Accessibility 权限。第一次调用会弹系统对话框。
    private func requestAccessibilityPermission() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let opts: NSDictionary = [promptKey: true]
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 检查 + 请求 Input Monitoring 权限。
    /// macOS 10.15+ 监听全局键盘事件（包括 NSEvent.addGlobalMonitorForEvents）必须有这个权限，
    /// 否则系统**静默忽略**所有事件 —— 不报错也不提示，键盘 count 永远是 0。
    /// IOHIDRequestAccess 第一次调用会弹系统对话框（前提：Info.plist 有 NSInputMonitoringUsageDescription）。
    private func requestInputMonitoringPermission() -> Bool {
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// 用 AX API 读 active app 的 focused window title
    private func focusedWindowTitle(for pid: pid_t) -> String? {
        let appElem = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let r1 = AXUIElementCopyAttributeValue(
            appElem, kAXFocusedWindowAttribute as CFString, &focusedWindow
        )
        guard r1 == .success, let win = focusedWindow else { return nil }
        var title: CFTypeRef?
        let r2 = AXUIElementCopyAttributeValue(
            win as! AXUIElement, kAXTitleAttribute as CFString, &title
        )
        guard r2 == .success else { return nil }
        return title as? String
    }
}
