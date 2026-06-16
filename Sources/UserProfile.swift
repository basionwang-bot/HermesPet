import Foundation
import AppKit

/// 用户身份 / 资料的本地存储（App 侧脚手架，零服务器依赖）。
///
/// 现阶段全部本地：昵称 + 头像存本机；`accountID` / `email` 是为「未来登录 + 计费网关」预留的占位字段
/// （登录落地前恒 nil）。`deviceID` 是一个稳定的匿名设备标识，给「一键反馈」归类用 —— 不需要登录就能用。
///
/// 设计取向：登录与计费的真正逻辑在未来的网站 / 服务器侧（OpenAI 兼容计量网关，见 `OfficialGateway`），
/// 本类只是瘦客户端的身份槽。守决策 #5（@MainActor 单例）/ #11（每个 @Observable 字段都有 UI 渲染）。
@MainActor
@Observable
final class UserProfileStore {
    static let shared = UserProfileStore()

    // —— 本地资料（现在就能用）——
    /// 昵称。改用显式 setter 落盘（避免 @Observable 上叠 didSet 的边界问题）。
    private(set) var nickname: String
    /// 头像图片（裁成圆形显示）。落盘 ~/.hermespet/profile/avatar.png。
    private(set) var avatar: NSImage?

    // —— 账号（为登录 + 计费预留，登录前恒 nil）——
    private(set) var accountID: String?
    private(set) var email: String?

    /// 稳定的匿名设备标识。反馈 / 工单归类用，不绑定身份、不需要登录。
    let deviceID: String

    var isSignedIn: Bool { accountID != nil }

    /// 聊天气泡 / 资料卡显示名：有昵称用昵称，登录了用邮箱前缀，否则「我」。
    var displayName: String {
        let n = nickname.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        if let e = email, let at = e.firstIndex(of: "@") { return String(e[..<at]) }
        return L("account.defaultName")
    }

    /// 没头像时用的首字母（昵称首字 / 默认）。
    var initials: String {
        let n = displayName
        guard let first = n.first else { return "·" }
        if first.isASCII { return String(n.prefix(2)).uppercased() }
        return String(first)
    }

    private init() {
        let d = UserDefaults.standard
        nickname = d.string(forKey: Keys.nickname) ?? ""
        accountID = d.string(forKey: Keys.accountID)
        email = d.string(forKey: Keys.email)
        if let existing = d.string(forKey: Keys.deviceID) {
            deviceID = existing
        } else {
            let new = "dev_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
            d.set(String(new), forKey: Keys.deviceID)
            deviceID = String(new)
        }
        if let img = NSImage(contentsOf: Self.avatarURL) { avatar = img }
    }

    // MARK: 资料

    func setNickname(_ s: String) {
        nickname = s
        UserDefaults.standard.set(s, forKey: Keys.nickname)
    }

    /// 从用户选的图片文件设置头像（缩放到 256 存盘）。
    func setAvatar(from url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        setAvatar(image: img)
    }
    func setAvatar(image: NSImage) {
        let resized = Self.downscale(image, max: 256)
        avatar = resized
        if let png = Self.pngData(resized) {
            try? png.write(to: Self.avatarURL, options: .atomic)
        }
    }
    func clearAvatar() {
        avatar = nil
        try? FileManager.default.removeItem(at: Self.avatarURL)
    }

    // MARK: 账号（预留 setter，登录落地后由 auth 流程调用）

    func applyAccount(id: String?, email: String?) {
        let d = UserDefaults.standard
        accountID = id
        self.email = email
        if let id { d.set(id, forKey: Keys.accountID) } else { d.removeObject(forKey: Keys.accountID) }
        if let email { d.set(email, forKey: Keys.email) } else { d.removeObject(forKey: Keys.email) }
    }
    func signOut() { applyAccount(id: nil, email: nil) }

    // MARK: 文件 / 工具

    nonisolated static var profileDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var avatarURL: URL { profileDir.appendingPathComponent("avatar.png") }

    /// 给后台代码（反馈服务）读匿名设备 ID，不用 hop MainActor。
    nonisolated static func deviceIDValue() -> String {
        UserDefaults.standard.string(forKey: Keys.deviceID) ?? "dev_unknown"
    }

    private static func downscale(_ image: NSImage, max: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > max || size.height > max, size.width > 0, size.height > 0 else { return image }
        let scale = max / Swift.max(size.width, size.height)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private enum Keys {
        static let nickname = "userNickname"
        static let accountID = "userAccountID"
        static let email = "userAccountEmail"
        static let deviceID = "userDeviceID"
    }
}
