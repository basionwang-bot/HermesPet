import Foundation
import Security

/// **CodeSignVerifier** —— 启动时读取 app 自身的 codesign Team ID，判断是不是"原作者签名"。
///
/// 背景：用户反馈 HermesPet 开源后，有人冒充原作者把项目发出去自称作品。在关于页显示
/// 当前签名的 Team ID + 跟"原作者已知 Team ID" 对比，让用户能一眼识别是否官方版。
///
/// **三种结果**：
/// - `.officialSignature` —— Team ID 匹配 R34KL4X4D9（原作者 Apple Development 证书）
/// - `.adHocSignature` —— ad-hoc 签名（DMG 分发常见，没有 Team ID）—— 视为"开发版 / 非官方"
/// - `.thirdPartySignature(let teamID)` —— 其他 Team ID = 第三方重签 = 高度疑似盗版
/// - `.unsigned` —— 没有任何签名（极少见）
enum CodeSignVerifier {
    /// 原作者的 Apple Development Team ID（CLAUDE.md 决策 #4 / make-dmg.sh）
    static let officialTeamID = "R34KL4X4D9"

    /// 官方 GitHub 仓库 URL —— 让用户能跳过去验证
    static let officialRepoURL = "https://github.com/basionwang-bot/HermesPet"
    static let officialReleasesURL = "https://github.com/basionwang-bot/HermesPet/releases"

    enum Result: Equatable {
        case officialSignature
        case adHocSignature
        case thirdPartySignature(teamID: String)
        case unsigned
        case unknown(reason: String)

        /// UI 展示的简短标签
        var shortLabel: String {
            switch self {
            case .officialSignature:           return "✓ 原作者签名"
            case .adHocSignature:              return "ad-hoc 签名"
            case .thirdPartySignature:         return "⚠️ 第三方签名"
            case .unsigned:                    return "未签名"
            case .unknown:                     return "无法验证"
            }
        }

        /// 详细说明（关于页内显示）
        var detailText: String {
            switch self {
            case .officialSignature:
                return "Team ID：\(CodeSignVerifier.officialTeamID) · 这是原作者用 Apple Development 证书签名的官方版本。"
            case .adHocSignature:
                return "这是 ad-hoc 签名的 DMG 分发版本。如果你不是从官方 GitHub Releases 下载，请去官方仓库核对版本。"
            case .thirdPartySignature(let id):
                return "Team ID：\(id) · 这不是原作者的签名。可能是别人重新打包的版本，存在安全和合法性风险。建议去官方仓库下载正版。"
            case .unsigned:
                return "此 app 没有任何签名，强烈建议从官方 GitHub Releases 重新下载。"
            case .unknown(let reason):
                return "无法读取签名信息：\(reason)"
            }
        }

        /// 标识颜色（绿 / 橙 / 红 / 灰）
        var indicatorColorName: String {
            switch self {
            case .officialSignature: return "green"
            case .adHocSignature:    return "orange"
            case .thirdPartySignature, .unsigned: return "red"
            case .unknown:           return "gray"
            }
        }
    }

    /// 读取当前 app 的 codesign 信息并判定。
    /// 主线程或后台都能调（SecCode API 同步、安全）
    static func verify() -> Result {
        let bundleURL = Bundle.main.bundleURL as CFURL
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .unknown(reason: "SecStaticCodeCreateWithPath failed (\(createStatus))")
        }

        // 先确认签名有效（kSecCSDefaultFlags）
        let checkStatus = SecStaticCodeCheckValidity(code, [], nil)
        if checkStatus == errSecCSUnsigned {
            return .unsigned
        }
        // 其他错误：可能是签名损坏 / Gatekeeper 验证失败，但 Team ID 仍可能读到，继续
        // （不直接报 unsigned —— 让下面 SecCodeCopySigningInformation 拿数据）

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard infoStatus == errSecSuccess, let dict = info as? [String: Any] else {
            return .unknown(reason: "SecCodeCopySigningInformation failed (\(infoStatus))")
        }

        // teamid 字段：Apple Development / Distribution 证书都会有；ad-hoc 没有
        if let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String, !teamID.isEmpty {
            if teamID == officialTeamID {
                return .officialSignature
            } else {
                return .thirdPartySignature(teamID: teamID)
            }
        }

        // 没 teamID → 看 flags 是不是 ad-hoc
        // SecCodeSignatureFlags.adhoc = 0x2
        if let flags = dict[kSecCodeInfoFlags as String] as? UInt32 {
            if flags & 0x2 != 0 {
                return .adHocSignature
            }
        }

        // identifier 存在但没 teamid 且不是 adhoc —— 兜底当 unknown
        return .unknown(reason: "no team identifier")
    }
}
