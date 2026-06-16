import Foundation

/// 在 App 内「一键安装」CLI 后端 —— spawn 登录 shell 跑安装命令（npm / pip / brew 等），
/// 免去用户开终端手动粘贴。用 `zsh -lic` 加载用户 ~/.zprofile + ~/.zshrc，拿到跟终端一致的
/// PATH（nvm / homebrew / npm-global），让 npm 能找到、装到对的地方。
///
/// 边界（诚实）：npm 类安装依赖机器已有 Node.js（npm）；没有则返回 `.missingNpm` 让 UI 提示先装 Node。
/// 权限 / 网络等其它失败返回 `.failed`，UI 回退到"复制命令手动装"。不解决装后的登录（如 claude/codex
/// 的 OAuth）—— 那由各后端自己的认证流程或 HermesPet 的填 Key 完成。
enum CLIInstaller {
    enum InstallResult {
        case success
        case missingNpm
        case failed(String)
    }

    /// 跑一条安装命令（如 "npm install -g @qwen-code/qwen-code"）。最多等 5 分钟。
    static func run(command: String) async -> InstallResult {
        await withCheckedContinuation { (cont: CheckedContinuation<InstallResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // npm 类命令先确认 npm 在（没装 Node.js 时给清晰提示，而不是一堆 command not found）
                if command.contains("npm "), CLIAvailability.locateBinary(command: "npm") == nil {
                    cont.resume(returning: .missingNpm)
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lic", command]
                p.environment = ProcessInfo.processInfo.environment
                p.standardOutput = FileHandle.nullDevice   // 丢弃输出，避免管道写满死锁
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: .failed(error.localizedDescription))
                    return
                }
                // 轮询等待（带 5 分钟超时兜底，防网络卡死永远转圈）
                let deadline = Date().addingTimeInterval(300)
                while p.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.3)
                }
                if p.isRunning {
                    p.terminate()
                    cont.resume(returning: .failed("timeout"))
                    return
                }
                cont.resume(returning: p.terminationStatus == 0 ? .success : .failed("exit \(p.terminationStatus)"))
            }
        }
    }
}
