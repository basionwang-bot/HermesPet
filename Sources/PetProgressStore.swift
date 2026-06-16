import Foundation
import SwiftUI

/// 宠物养成「中枢」—— 听信号 → 算经验 / 心情 / 升级 → 存档。
///
/// 这是养成系统的地基（第 0 步）。它**不碰渲染、不碰灵动岛、不碰 opencode**，只做三件事：
/// 1. 监听全局已有的活动通知（决策 #13 的 schema，聊天 / 舰队 / 工作流都在 post）；
/// 2. 把活动换算成经验 / 心情 / 等级，存进 `PetProgress`；
/// 3. 节流写盘到 UserDefaults。
///
/// 范式抄自 `ExecutionStateStore`（监听写法）+ `PetPaletteStore`（@Observable 单例 + 持久化）。
///
/// ⚠️ 守决策 #5：NotificationCenter `addObserver(queue:.main)` 的闭包是 Sendable，
/// 先在闭包里抽出 Sendable 值（Bool/String），再 `MainActor.assumeIsolated` 跳进 MainActor。
///
/// ⚠️ 它必须在 App 启动时就被创建（见 `HermesPetApp.applicationDidFinishLaunching` 里的
/// `_ = PetProgressStore.shared`），不能像 `ExecutionStateStore` 那样懒加载到聊天窗出现才创建，
/// 否则用户没开聊天窗时跑的舰队经验会丢。
@MainActor
@Observable
final class PetProgressStore {
    static let shared = PetProgressStore()

    /// 宠物成长档案 —— 被设置面板等 SwiftUI 视图直接读（@Observable 自动建立依赖）。
    private(set) var progress: PetProgress

    // MARK: - 私有

    private static let storageKey = "petProgress.v1"

    /// 本次任务周期内已从「工具调用」拿到的经验 —— 用来封顶，避免长任务 / 舰队刷爆经验。
    private var toolExpThisCycle = 0
    private let toolExpCapPerTask = 10

    /// 节流写盘的合并任务（高频的工具事件用，避免每个工具都写盘）。
    private var pendingSave: Task<Void, Never>?

    private init() {
        // 同步 load 一次，没有就用默认档案
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let p = try? JSONDecoder().decode(PetProgress.self, from: data) {
            self.progress = p
        } else {
            self.progress = PetLeveling.defaultProgress()
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: .init("HermesPetTaskStarted"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTaskStarted() }
        }
        nc.addObserver(forName: .init("HermesPetTaskFinished"), object: nil, queue: .main) { [weak self] note in
            let success = (note.userInfo?["success"] as? Bool) ?? false
            MainActor.assumeIsolated { self?.handleTaskFinished(success: success) }
        }
        nc.addObserver(forName: .init("HermesPetToolStarted"), object: nil, queue: .main) { [weak self] note in
            let name = note.userInfo?["name"] as? String
            MainActor.assumeIsolated { self?.handleToolStarted(name: name) }
        }
        nc.addObserver(forName: .init("HermesPetUserIdleChanged"), object: nil, queue: .main) { [weak self] note in
            let sleeping = (note.userInfo?["isSleeping"] as? Bool) ?? false
            MainActor.assumeIsolated { self?.handleIdleChanged(isSleeping: sleeping) }
        }
    }

    // MARK: - 事件处理

    private func handleTaskStarted() {
        // 新一轮任务开始：重置工具经验封顶计数 + 标记活跃。不算成长，不写盘。
        toolExpThisCycle = 0
        progress.lastActiveAt = Date()
    }

    private func handleTaskFinished(success: Bool) {
        progress.lastActiveAt = Date()
        if success {
            progress.stats.tasksSucceeded += 1
            progress.mood = Self.moodBumped(progress.mood, by: 1)   // 陪你打了胜仗，开心
            addExp(20)
        } else {
            progress.stats.tasksFailed += 1
            progress.mood = Self.moodBumped(progress.mood, by: -1)  // 出错了，有点沮丧
            addExp(5)                                               // 失败也陪着你了，给点安慰经验
        }
        saveNow()   // 任务完成是离散低频事件，立即落盘
    }

    private func handleToolStarted(name: String?) {
        guard name != nil else { return }
        progress.stats.toolsUsed += 1
        progress.lastActiveAt = Date()
        if toolExpThisCycle < toolExpCapPerTask {
            toolExpThisCycle += 1
            addExp(1)
        }
        scheduleSave()   // 工具事件高频，走节流合并
    }

    private func handleIdleChanged(isSleeping: Bool) {
        if isSleeping {
            // 3 分钟没理它 → 想你 / 累了
            progress.mood = Self.moodBumped(progress.mood, by: -1)
        } else {
            progress.lastActiveAt = Date()
            if progress.mood == .lonely {
                progress.mood = Self.moodBumped(progress.mood, by: 1)   // 见你回来，平复一点
            }
        }
        saveNow()
    }

    // MARK: - 经验 / 升级

    private func addExp(_ amount: Int) {
        guard amount > 0 else { return }
        progress.exp += amount
        progress.totalExp += amount
        checkLevelUp()
    }

    private func checkLevelUp() {
        var leveled = false
        while progress.exp >= PetLeveling.expNeeded(forLevel: progress.level) {
            progress.exp -= PetLeveling.expNeeded(forLevel: progress.level)
            progress.level += 1
            leveled = true
            // 解锁本等级新形象
            for form in PetForm.allCases
            where form.unlockLevel <= progress.level
                && !progress.unlockedFormIDs.contains(form.rawValue) {
                progress.unlockedFormIDs.append(form.rawValue)
            }
        }
        if leveled {
            saveNow()   // 升级是大事，立即落盘
            // 第 1 步会有视图监听这个通知放庆祝动画
            NotificationCenter.default.post(
                name: .init("HermesPetLevelUp"),
                object: nil,
                userInfo: ["level": progress.level]
            )
        }
    }

    /// 心情在档位上挪动（delta 正=变好 / 负=变差），夹在 [lonely, happy] 之间。
    private static func moodBumped(_ mood: PetMood, by delta: Int) -> PetMood {
        let order: [PetMood] = [.lonely, .tired, .neutral, .content, .happy]
        let idx = order.firstIndex(of: mood) ?? 2
        let newIdx = max(0, min(order.count - 1, idx + delta))
        return order[newIdx]
    }

    // MARK: - 持久化

    /// 节流写盘：1.5s 内的多次变更合并成一次写盘（高频工具事件用）。
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.pendingSave = nil
            self?.saveNow()
        }
    }

    /// 立即写盘（离散低频事件 / 升级 / 用户操作用）。
    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - 公开操作（设置面板用）

    /// 给宠物改昵称。
    func rename(_ name: String) {
        progress.petName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveNow()
    }

    /// 切换当前形象（必须已解锁）。返回是否成功。
    @discardableResult
    func selectForm(_ form: PetForm) -> Bool {
        guard progress.unlockedFormIDs.contains(form.rawValue) else { return false }
        progress.currentFormID = form.rawValue
        saveNow()
        return true
    }

    // MARK: - 给 UI 的派生值

    /// 当前等级升到下一级所需经验。
    var expNeededForCurrentLevel: Int {
        PetLeveling.expNeeded(forLevel: progress.level)
    }

    /// 本级经验进度（0...1），给经验条用。
    var levelProgressFraction: Double {
        let need = expNeededForCurrentLevel
        guard need > 0 else { return 0 }
        return min(1, Double(progress.exp) / Double(need))
    }
}
