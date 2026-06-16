import Foundation

/// HermesPet 侧的云账号登录。
/// 登录/注册 → 拿令牌 → 写 ~/.hermespet/cloud.json → 让 CloudRelayClient 重连。
/// 手机用【同一账号】登录，就能在外网远程操控这台 Mac。
enum CloudAccount {
    /// 官方云中转地址。
    static let officialBase = "https://relay.hermespet.cc:8443"
    static let emailKey = "cloudAccountEmail"

    static var savedEmail: String { UserDefaults.standard.string(forKey: emailKey) ?? "" }

    /// 登录或注册。成功后写好 cloud.json 并重连，返回错误信息（nil = 成功）。注册需邀请码。
    @MainActor
    static func login(register: Bool, email: String, password: String, invite: String = "") async -> String? {
        let path = register ? "/auth/register" : "/auth/login"
        guard let url = URL(string: officialBase + path) else { return "服务器地址错误" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["email": email, "password": password]
        if register { payload["invite"] = invite }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let token = obj?["token"] as? String, !token.isEmpty else {
                return (obj?["error"] as? String) ?? "操作失败，请重试"
            }
            // http(s):// → ws(s):// 作为 WebSocket 地址
            let wsBase = officialBase
                .replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://", with: "ws://")
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermespet")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cloudJSON: [String: Any] = ["relayURL": wsBase, "token": token]
            let jsonData = try JSONSerialization.data(withJSONObject: cloudJSON, options: .prettyPrinted)
            try jsonData.write(to: dir.appendingPathComponent("cloud.json"))
            let savedE = (obj?["user"] as? [String: Any])?["email"] as? String ?? email
            UserDefaults.standard.set(savedE, forKey: emailKey)
            CloudRelayClient.shared.reload()   // 立刻按新令牌重连
            return nil
        } catch {
            return "连不上服务器，检查网络后重试"
        }
    }

    /// 断开：删 cloud.json、停掉云中继。
    @MainActor
    static func signOut() {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermespet/cloud.json")
        try? FileManager.default.removeItem(at: f)
        UserDefaults.standard.removeObject(forKey: emailKey)
        CloudRelayClient.shared.stop()
    }
}
