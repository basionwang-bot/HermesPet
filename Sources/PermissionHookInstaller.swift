import Foundation

/// 把 HermesPet 的 permission hook 注入到 Claude / Codex 的全局配置文件，
/// 让 CLI 调用工具时通过 HTTP 回调到 HermesPet 内嵌的 PermissionHookServer。
///
/// **注入位置**：
/// - Claude: `~/.claude/settings.json` 的 `hooks.PreToolUse` 数组追加一个 type=http hook
/// - Codex: `~/.codex/config.toml` 的 `[[hooks.PermissionRequest.hooks]]` + bundled shell script
///
/// **幂等性**：所有 hook 配置都带 `hermespet=true` 标识字段，重复 install 时只追加一次。
/// uninstall 时按标识精确删除 HermesPet 加的那一条，不动用户其他 hook 配置
@MainActor
enum PermissionHookInstaller {

    /// 注入 hook 到 ~/.claude/settings.json。port 来自 PermissionHookServer。
    /// 失败不抛错（hook 是增值功能，配置写入失败不应阻塞 App 启动）
    static func installClaudeHook(port: UInt16) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        let fm = FileManager.default

        // 读现有 settings.json（可能不存在 / 空 / 损坏，都兜底）
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var preTool = (hooks["PreToolUse"] as? [[String: Any]]) ?? []

        // 检查是否已注入过（按 hermespet=true 标识幂等去重）
        preTool.removeAll { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["hermespet"] as? Bool) == true }
        }

        // 追加 HermesPet hook：matcher=".*" 拦截所有工具，type=http POST 到我们 server
        let hermesHook: [String: Any] = [
            "matcher": ".*",
            "hooks": [[
                "type": "http",
                "url": "http://127.0.0.1:\(port)/permission-hook",
                "timeout": 86400,   // 24h，等用户慢慢决策
                "hermespet": true   // 幂等标识
            ]]
        ]
        preTool.insert(hermesHook, at: 0)

        hooks["PreToolUse"] = preTool
        settings["hooks"] = hooks

        // 确保目录存在
        try? fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        guard let outData = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? outData.write(to: URL(fileURLWithPath: path), options: .atomic)
        NSLog("[PermissionHook] Claude hook installed to %@ (port=%d)", path, Int(port))
    }

    /// 从 ~/.claude/settings.json 撤销 hook（用户关掉 permissionUIEnabled 时调）
    static func uninstallClaudeHook() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var preTool = (hooks["PreToolUse"] as? [[String: Any]]) ?? []
        preTool.removeAll { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["hermespet"] as? Bool) == true }
        }

        if preTool.isEmpty {
            hooks.removeValue(forKey: "PreToolUse")
        } else {
            hooks["PreToolUse"] = preTool
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        if let outData = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? outData.write(to: URL(fileURLWithPath: path), options: .atomic)
            NSLog("[PermissionHook] Claude hook uninstalled")
        }
    }

    /// 注入 hook 到 ~/.codex/config.toml。
    /// Codex 不支持 type=http，必须用 shell script 中转 HTTP POST → 我们 server
    static func installCodexHook(port: UInt16) {
        let configDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        let scriptPath = (configDir as NSString).appendingPathComponent("hermespet-permission-hook.sh")
        let configPath = (configDir as NSString).appendingPathComponent("config.toml")
        let fm = FileManager.default

        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        // 写 shell script：读 stdin payload → curl POST 到我们 server → 输出响应到 stdout
        let script = """
        #!/bin/bash
        # HermesPet permission hook bridge (Codex)
        # 不要手改 —— 由 HermesPet App 启动时自动写入
        PAYLOAD=$(cat)
        curl -s -m 86400 -X POST -H 'Content-Type: application/json' \\
             -d "$PAYLOAD" "http://127.0.0.1:\(port)/permission-hook"
        """
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // 修改 config.toml：追加 [[hooks.PermissionRequest]] 段
        // 简单做法：用 marker 注释包围 HermesPet 块，幂等替换
        var existing = ""
        if let data = try? String(contentsOfFile: configPath, encoding: .utf8) {
            existing = data
        }

        // 去掉旧的 HermesPet 块
        let startMarker = "# === HermesPet permission hook (auto-managed) ==="
        let endMarker = "# === HermesPet end ==="
        if let startRange = existing.range(of: startMarker),
           let endRange = existing.range(of: endMarker),
           startRange.lowerBound < endRange.upperBound {
            existing.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }

        // 追加新块
        let block = """

        \(startMarker)
        [[hooks.PermissionRequest]]
        matcher = ".*"

        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = "\(scriptPath)"
        timeout = 86400
        \(endMarker)

        """
        existing += block

        try? existing.write(toFile: configPath, atomically: true, encoding: .utf8)
        NSLog("[PermissionHook] Codex hook installed to %@ (port=%d)", configPath, Int(port))
    }

    /// 从 ~/.codex/config.toml 撤销 HermesPet 块
    static func uninstallCodexHook() {
        let configPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml")
        guard var existing = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        let startMarker = "# === HermesPet permission hook (auto-managed) ==="
        let endMarker = "# === HermesPet end ==="
        if let startRange = existing.range(of: startMarker),
           let endRange = existing.range(of: endMarker),
           startRange.lowerBound < endRange.upperBound {
            existing.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            try? existing.write(toFile: configPath, atomically: true, encoding: .utf8)
            NSLog("[PermissionHook] Codex hook uninstalled")
        }
    }
}
