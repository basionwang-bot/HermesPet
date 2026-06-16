import Foundation
import SwiftUI

/// 全局执行状态机：当前是否在跑、跑到哪一步、改了哪些文件。
/// 由 NotificationCenter 上现成的「灵动岛」schema 驱动（决策 #13），所以三个监听点
/// （灵动岛 PillView / 旧 PetHeaderStrip / 这里）会得到同一份数据。
///
/// 设计目的：让聊天窗里「正在工作的对话胶囊」能就地拉长展示状态，不用每个 tab 各自订阅。
@MainActor
@Observable
final class ExecutionStateStore {
    static let shared = ExecutionStateStore()

    // MARK: - 状态字段（被 SwiftUI 视图直接读）
    /// 是否正在执行任务（TaskStarted → true / TaskFinished → false）
    private(set) var isWorking: Bool = false

    /// 当前在跑的工具种类（Read / Write / Edit / Bash 等）。nil = 工具间隙或纯思考。
    private(set) var currentToolKind: ToolKind? = nil

    /// 当前工具参数（文件名 / 命令 等），已 shortenize
    private(set) var currentToolArg: String = ""

    /// 已开始的工具数 / 已完成的工具数 —— 用于 "M/N"
    private(set) var stepStarted: Int = 0
    private(set) var stepEnded: Int = 0

    /// 任务计时 (秒)。0 = 没在跑。
    private(set) var elapsedSeconds: Int = 0

    /// 任务结束后短暂展示「✓ 已改 N 文件」的状态。non-nil = 闪 2.5s 后自动 nil。
    private(set) var doneFlashFileCount: Int? = nil

    // MARK: - 私有
    private var taskStartTime: Date?
    private var elapsedTask: Task<Void, Never>?
    private var doneFlashTask: Task<Void, Never>?
    private var changedFilePaths: Set<String> = []

    private init() {
        let nc = NotificationCenter.default
        // Notification 自身不能跨 actor 传（@unchecked Sendable 在 Swift 6 严格模式被拒）。
        // 套路：在 .main queue 的闭包里**先抽出 Sendable 值**（String/Bool 等），再跨进 MainActor.assumeIsolated
        nc.addObserver(forName: .init("HermesPetTaskStarted"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTaskStarted()
            }
        }
        nc.addObserver(forName: .init("HermesPetToolStarted"), object: nil, queue: .main) { [weak self] note in
            let name = note.userInfo?["name"] as? String
            let arg = note.userInfo?["arg"] as? String
            let filePath = note.userInfo?["file_path"] as? String
            MainActor.assumeIsolated {
                self?.handleToolStarted(name: name, arg: arg, filePath: filePath)
            }
        }
        nc.addObserver(forName: .init("HermesPetToolEnded"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleToolEnded()
            }
        }
        nc.addObserver(forName: .init("HermesPetTaskFinished"), object: nil, queue: .main) { [weak self] note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            MainActor.assumeIsolated {
                self?.handleTaskFinished(success: success)
            }
        }
    }

    private func handleTaskStarted() {
        isWorking = true
        currentToolKind = nil
        currentToolArg = ""
        stepStarted = 0
        stepEnded = 0
        elapsedSeconds = 0
        changedFilePaths = []
        doneFlashFileCount = nil
        taskStartTime = Date()

        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self = self, let start = self.taskStartTime else { break }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func handleToolStarted(name: String?, arg: String?, filePath: String?) {
        guard let name = name else { return }
        stepStarted += 1
        currentToolKind = ToolKind.from(toolName: name)
        currentToolArg = arg ?? filePath ?? ""
        if let path = filePath,
           !path.isEmpty,
           ["Write", "Edit", "MultiEdit"].contains(name) {
            changedFilePaths.insert(path)
        }
    }

    private func handleToolEnded() {
        stepEnded += 1
    }

    private func handleTaskFinished(success: Bool) {
        isWorking = false
        currentToolKind = nil
        currentToolArg = ""
        elapsedTask?.cancel()
        elapsedTask = nil
        taskStartTime = nil

        if success && !changedFilePaths.isEmpty {
            doneFlashFileCount = changedFilePaths.count
            doneFlashTask?.cancel()
            doneFlashTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if !Task.isCancelled {
                    self?.doneFlashFileCount = nil
                }
            }
        }
        changedFilePaths = []
    }

    /// 当前工具参数的精简版（路径只保留 lastPathComponent，截到 24 字）
    var shortArg: String {
        let trimmed = currentToolArg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let last = (trimmed as NSString).lastPathComponent
        let candidate = last.isEmpty ? trimmed : last
        return candidate.count > 24 ? (String(candidate.prefix(22)) + "…") : candidate
    }

    /// "M/N" 进度文本（仅 ≥ 2 步时显示，单步任务省略避免噪音）
    var stepText: String? {
        guard stepStarted >= 2 else { return nil }
        return "\(min(stepEnded, stepStarted))/\(stepStarted)"
    }

    /// 计时文本（"3s" / "1m23s"）
    var elapsedText: String {
        let s = elapsedSeconds
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60)s"
    }
}
