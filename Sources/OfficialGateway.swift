import Foundation

/// 预留：HermesPet「官方网关」后端槽（App 侧脚手架，尚未上线）。
///
/// 未来的商业形态 = 你运营一个 **OpenAI 兼容的计量网关**（批发买 token、加价转卖、按账号计量计费）。
/// 那个网关本质上就是 App 已经支持的「OpenAI 兼容 HTTP 后端」（同 Hermes / 在线 AI 的请求路径）。
///
/// 现在还没有服务器，所以这里只**预留配置槽**，故意**不接入任何真实可用的 AgentMode**（避免给用户一个点了没用的假选项）：
/// - 登录落地后，auth 流程把网关返回的 key 写进 `apiKey`，App 把 OpenAI 兼容 HTTP 路径指向 `baseURL` 即可。
/// - 账号 / 计量 / 计费体系全部在服务器侧实现（独立的 TS 后端项目）。
///
/// 配套身份槽见 `UserProfileStore.accountID`；反馈通道的可替换 endpoint 见 `FeedbackService`。
enum OfficialGateway {
    /// 计划中的官方网关地址（占位，**尚未上线**）。
    static let plannedBaseURL = "https://api.hermespet.app/v1"

    /// 登录后保存的网关访问 key（现在恒 nil）。
    static var apiKey: String? {
        get { UserDefaults.standard.string(forKey: "officialGatewayKey") }
        set {
            let d = UserDefaults.standard
            if let v = newValue, !v.isEmpty { d.set(v, forKey: "officialGatewayKey") }
            else { d.removeObject(forKey: "officialGatewayKey") }
        }
    }

    /// 网关地址（默认用计划地址，允许将来后台下发覆盖）。
    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "officialGatewayBaseURL") ?? plannedBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "officialGatewayBaseURL") }
    }

    /// 是否已配置好可用（拿到 key）—— 登录 + 计费上线后才会为 true。
    static var isConfigured: Bool { (apiKey?.isEmpty == false) }
}
