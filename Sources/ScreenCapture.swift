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
}
