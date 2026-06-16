import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 屏幕截图工具。基于 ScreenCaptureKit（macOS 12.3+ 推荐，14+ 唯一可用）。
/// 老的 CGWindowListCreateImage / CGDisplayCreateImage 在 macOS 15+ 已失效（返回 nil）。
enum ScreenCapture {

    enum CaptureResult {
        case success(Data)
        case needsPermission       // SCK 报权限错误
        case failed(String)        // 其他失败
    }

    /// 主动请求屏幕录制权限。首次会弹系统对话框，之后用户得自己去
    /// 系统设置 → 隐私与安全性 → 屏幕录制 里勾选并重启 app。
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 截当前主屏 —— 区分"无权限"vs"其他失败"。
    /// macOS 26 上 CGPreflightScreenCaptureAccess 对 ScreenCaptureKit 用户不准确
    /// （ad-hoc 签名换 CDHash 后会假返回 false），这里直接试 SCK，由它自己决定权限。
    static func captureMainScreenWithError() async -> CaptureResult {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // 拿不到 content 几乎一定是权限问题
            NSLog("[HermesPet] SCShareableContent 失败: \(error.localizedDescription)")
            return .needsPermission
        }

        let mainDisplayID = (NSScreen.main?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
                ?? content.displays.first else {
            return .failed("找不到可用的显示器")
        }

        let myBundleID = Bundle.main.bundleIdentifier
        let myWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == myBundleID
        }

        let filter = SCContentFilter(display: display, excludingWindows: myWindows)

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.capturesAudio = false

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                return .success(png)
            } else {
                return .failed("PNG 编码失败")
            }
        } catch {
            NSLog("[HermesPet] SCScreenshotManager 失败: \(error.localizedDescription)")
            let msg = error.localizedDescription
            if msg.lowercased().contains("permission")
                || msg.lowercased().contains("declined")
                || msg.lowercased().contains("entitlement") {
                return .needsPermission
            }
            return .failed(msg)
        }
    }

    /// 截鼠标当前所在屏 → 直接返回 CGImage（UserIntentRecorder 给 Vision OCR 用，省一次 PNG 编解码）
    /// 优先级：鼠标所在屏 > NSScreen.main > 屏幕数组第一个
    /// 失败返回 nil；权限缺失也直接 nil，OCR 这种静默场景不弹权限框（让聊天截图那条路径触发授权）
    static func captureMouseScreenAsCGImage() async -> CGImage? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return nil
        }

        // 找鼠标所在的 NSScreen → 转 displayID
        let mouseLoc = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) })
            ?? NSScreen.main
        let targetDisplayID: CGDirectDisplayID = {
            if let dict = mouseScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return dict
            }
            return CGMainDisplayID()
        }()
        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID })
                ?? content.displays.first else {
            return nil
        }

        // 排除自己的窗口（避免聊天窗 / 桌宠出现在截图里影响 OCR）
        let myBundleID = Bundle.main.bundleIdentifier
        let myWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == myBundleID }

        let filter = SCContentFilter(display: display, excludingWindows: myWindows)

        let scale = mouseScreen?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.capturesAudio = false

        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - 窗口共享（v1.6「AI 看屏幕」里程碑 0）

    /// 一个「可分享」的普通应用窗口的元信息。
    /// `Sendable`：只带值类型，图标在 UI 层按 `pid` 用 NSRunningApplication 现取（NSImage 非 Sendable）。
    struct ShareableWindow: Identifiable, Sendable {
        let id: CGWindowID
        let title: String        // 窗口标题；为空时回退成 app 名
        let appName: String
        let bundleID: String?
        let pid: pid_t
    }

    /// 列出当前所有「可分享」的普通应用窗口（给输入栏「+ → 分享窗口」菜单用）。
    /// 过滤掉：桌宠自己、非普通层级（菜单/状态栏/壁纸）、过小的浮窗、离屏窗口。
    /// 失败（一般=没屏幕录制权限）返回空数组——调用方据此引导授权。
    static func listWindows() async -> [ShareableWindow] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            NSLog("[HermesPet] listWindows 失败（多半没屏幕录制权限）: \(error.localizedDescription)")
            return []
        }

        let myBundleID = Bundle.main.bundleIdentifier
        return content.windows.compactMap { w -> ShareableWindow? in
            guard w.isOnScreen, w.windowLayer == 0 else { return nil }   // 只要普通窗口层
            guard let app = w.owningApplication else { return nil }
            if app.bundleIdentifier == myBundleID { return nil }          // 排除自己
            guard w.frame.width > 120, w.frame.height > 80 else { return nil }  // 过滤小浮窗
            let title = (w.title?.isEmpty == false) ? w.title! : app.applicationName
            return ShareableWindow(
                id: w.windowID,
                title: title,
                appName: app.applicationName,
                bundleID: app.bundleIdentifier,
                pid: app.processID
            )
        }
    }

    /// 截取指定窗口此刻的画面（单窗口，不含其它窗口/桌面）。
    /// 用 `SCContentFilter(desktopIndependentWindow:)`，所以即使目标窗口被别的窗口盖住也能截到它本身。
    /// 窗口已关闭/找不到 → `.failed`；没权限 → `.needsPermission`。
    static func captureWindow(id: CGWindowID) async -> CaptureResult {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            return .needsPermission
        }
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            return .failed("目标窗口已关闭或不可见")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                return .success(png)
            }
            return .failed("PNG 编码失败")
        } catch {
            NSLog("[HermesPet] captureWindow 失败: \(error.localizedDescription)")
            let msg = error.localizedDescription
            if msg.lowercased().contains("permission")
                || msg.lowercased().contains("declined")
                || msg.lowercased().contains("entitlement") {
                return .needsPermission
            }
            return .failed(msg)
        }
    }

    /// 截窗口 → 直接返回 `CGImage` + **窗口在屏幕上的 frame（点，左上角原点）**。
    /// 给「看屏定位」用：OCR 出归一化方框后，要靠这个 frame 映射成屏幕坐标喂给 `ScreenActuator`。
    /// 返回 CGImage 而非 PNG，省一次编解码（OCR 直接吃 CGImage）。失败 / 没权限 → nil。
    static func captureWindowImage(id: CGWindowID) async -> (image: CGImage, frame: CGRect)? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            return nil
        }
        guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return nil }
        return (cgImage, window.frame)
    }
}
