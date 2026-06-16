import SwiftUI

/// 设置 → 桌宠 里的「养成卡」。
///
/// 第 0 步它有双重身份：
/// 1. **验证窗口** —— 让用户/开发者肉眼看到等级、经验、心情、累计战绩随干活增长（守决策 #11：
///    新增的 @Observable 状态必须有 UI 渲染；守决策 #22：用户能独立验证地基真的在跑）；
/// 2. **后续养成 UI 的落点** —— 第 1 步起的换形象、心情上脸入口都从这里长出来。
///
/// 读 `PetProgressStore.shared`（@Observable，数据变了自动重渲），样式对齐桌宠区其它卡片
/// （`.padding(12).background(Color.secondary.opacity(0.06)).cornerRadius(8)`）。
struct PetProgressCard: View {
    @State private var store = PetProgressStore.shared
    /// 昵称输入草稿（提交时才写回 store，避免每个字符都写盘）
    @State private var nicknameDraft: String = ""

    /// 暖色调（第 0 步先用固定色，第 1 步再跟当前形象主色走）
    private let tint = Color.pink

    var body: some View {
        let p = store.progress
        VStack(alignment: .leading, spacing: 10) {
            // —— 标题 ——
            Label(L("settings.pet.progress.title"), systemImage: "heart.circle.fill")
                .font(.system(size: 13, weight: .medium))
            Text(L("settings.pet.progress.caption"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // —— 形象 + 等级 + 心情 ——
            HStack(spacing: 8) {
                Text(L(p.currentForm.displayNameKey))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("settings.pet.progress.level", p.level))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.18))
                    .foregroundStyle(tint)
                    .clipShape(Capsule())

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: p.mood.symbolName)
                    Text(L(p.mood.displayNameKey))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            // —— 经验条 ——
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: store.levelProgressFraction)
                    .tint(tint)
                HStack {
                    Text(L("settings.pet.progress.exp"))
                    Spacer()
                    Text("\(p.exp) / \(store.expNeededForCurrentLevel)")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            // —— 昵称 ——
            HStack(spacing: 8) {
                Text(L("settings.pet.progress.nickname"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L(p.currentForm.displayNameKey), text: $nicknameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { store.rename(nicknameDraft) }
            }

            // —— 累计战绩 ——
            HStack(spacing: 16) {
                statItem(L("settings.pet.progress.stat.succeeded"), p.stats.tasksSucceeded)
                statItem(L("settings.pet.progress.stat.failed"), p.stats.tasksFailed)
                statItem(L("settings.pet.progress.stat.tools"), p.stats.toolsUsed)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
        .onAppear { nicknameDraft = p.petName }
    }

    private func statItem(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
