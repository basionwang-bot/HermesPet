import Foundation
import AppKit

/// 一键反馈 / 报 bug —— App 侧脚手架。
///
/// 「可替换 endpoint」：`feedbackEndpoint`（UserDefaults，默认空）。
/// - 配了 endpoint（未来你的服务器）→ POST JSON，bug 直达服务器，你后台直接读。
/// - 没配（现在还没服务器）→ 回退到现有零后端方案：结构化正文复制到剪贴板 + 打开 GitHub issue 页。
///
/// payload 带：匿名 deviceID + accountID（登录后才有）+ 版本 / 系统 + 用户描述 + 可选诊断上下文。
/// 守决策 #5：@MainActor，网络调用用 async/await 不跨线程回调。
@MainActor
enum FeedbackService {
    enum Outcome { case sentToServer, openedGitHub, failed(String) }

    /// 可替换的反馈 endpoint。服务器上线后在这里（或设置里）填上即可让 bug 直达后台。
    static var endpoint: URL? {
        guard let s = UserDefaults.standard.string(forKey: "feedbackEndpoint"),
              !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(string: s)
    }

    /// 提交一条反馈。`kind`："bug" / "idea"。`context` 为可选诊断信息（版本/崩溃/最近对话）。
    static func submit(kind: String, message: String, context: String?) async -> Outcome {
        let payload = buildPayload(kind: kind, message: message, context: context)
        if let url = endpoint {
            return await post(payload, to: url)
        } else {
            openGitHub(payload: payload)
            return .openedGitHub
        }
    }

    // MARK: payload

    private static func buildPayload(kind: String, message: String, context: String?) -> [String: Any] {
        var p: [String: Any] = [
            "kind": kind,
            "message": message,
            "deviceID": UserProfileStore.deviceIDValue(),
            "appVersion": appVersion(),
            "os": osVersion(),
            "locale": LocaleManager.currentLanguage().rawValue,
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        if let acc = UserDefaults.standard.string(forKey: "userAccountID") { p["accountID"] = acc }
        if let c = context, !c.isEmpty { p["context"] = String(c.prefix(8000)) }
        return p
    }

    private static func post(_ payload: [String: Any], to url: URL) async -> Outcome {
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            req.timeoutInterval = 15
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failed("HTTP \(http.statusCode)")
            }
            return .sentToServer
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: GitHub 回退（沿用 CrashReporter 的零后端思路）

    private static func openGitHub(payload: [String: Any]) {
        let kind = payload["kind"] as? String ?? "feedback"
        let msg = payload["message"] as? String ?? ""
        var body = "## \(kind == "bug" ? "Bug 反馈" : "想法 / 建议")\n\n"
        body += (msg.isEmpty ? "（请在这里描述）" : msg) + "\n\n---\n"
        body += "- App: v\(appVersion())\n- OS: \(osVersion())\n- device: \(UserProfileStore.deviceIDValue())\n"
        if let c = payload["context"] as? String, !c.isEmpty {
            body += "\n<details><summary>诊断上下文</summary>\n\n```\n\(String(c.prefix(4000)))\n```\n</details>\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)

        let title = (kind == "bug" ? "Bug: " : "Idea: ") + String(msg.prefix(50))
        let urlStr = "https://github.com/basionwang-bot/HermesPet/issues/new?title=" +
            (title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
    }

    // MARK: env

    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
