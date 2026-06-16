import SwiftUI

/// 灵动岛控制中心「Token 消耗」分区：本月/今日实付 + 各模型消耗条 + 近 14 天趋势 + 三种省钱明细。
/// 数据来自 `TokenUsageStore`（本地估算：token × 公开单价）。深色面板上，白字。
struct TokenConsumptionView: View {
    @Bindable private var store = TokenUsageStore.shared

    /// 金钱主色（薄荷绿，省钱/正向语义）
    private let accent = Color(red: 0.36, green: 0.82, blue: 0.58)

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            spendRow
            modelBreakdown
            trend
            Divider().overlay(Color.white.opacity(0.12))
            savings
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 300, alignment: .leading)
        .foregroundStyle(.white)
    }

    // MARK: 标题

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Text(L("island.tokens.title"))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(L("island.tokens.month"))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: 本月实付（大字）+ 今日（小字）

    private var spendRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(cny(store.monthPaidCNY))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(L("island.tokens.monthPaid"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(cny(store.todayPaidCNY))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                Text(L("island.tokens.today"))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: 各模型消耗条

    @ViewBuilder private var modelBreakdown: some View {
        let rows = Array(store.monthModelBreakdown().prefix(4))
        if rows.isEmpty {
            Text(L("island.tokens.empty"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            let maxTok = max(1, rows.map { $0.tokens }.max() ?? 1)
            VStack(spacing: 6) {
                ForEach(rows) { r in
                    modelRow(r, maxTokens: maxTok)
                }
            }
        }
    }

    private func modelRow(_ r: ModelUsageSummary, maxTokens: Int) -> some View {
        HStack(spacing: 7) {
            Text(r.model)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96, alignment: .leading)

            GeometryReader { geo in
                let frac = Double(r.tokens) / Double(maxTokens)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(r.subscriptionBacked ? Color.white.opacity(0.3) : accent)
                        .frame(width: max(4, geo.size.width * frac))
                }
            }
            .frame(height: 5)

            Text(r.subscriptionBacked ? L("island.tokens.sub") : cny(r.costCNY))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(r.subscriptionBacked ? accent.opacity(0.9) : .white.opacity(0.85))
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: 近 14 天用量趋势

    private var trend: some View {
        let days = store.last14DaysTokens()
        let maxTok = max(1, days.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, tok in
                    let frac = Double(tok) / Double(maxTok)
                    Capsule()
                        .fill(tok > 0 ? accent.opacity(0.75) : Color.white.opacity(0.1))
                        .frame(height: max(2, 22 * frac))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 22)
            Text(L("island.tokens.trend"))
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: 累计为你省下

    private var savings: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("🎁").font(.system(size: 10))
                Text(L("island.tokens.saved"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(cny(store.totalSavedCNY))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            }
            savingLine(L("island.tokens.saved.local"), cny(store.monthSavedLocalCNY))
            if store.monthSavedSubscriptionCNY > 0.005 {
                savingLine(L("island.tokens.saved.subscription"), cny(store.monthSavedSubscriptionCNY))
            }
            if store.monthSavedCacheCNY > 0.005 {
                savingLine(L("island.tokens.saved.cache"), cny(store.monthSavedCacheCNY))
            }
        }
    }

    private func savingLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text("·").foregroundStyle(.white.opacity(0.3))
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: 工具

    /// ¥ 两位小数；不足 1 分按 0 显示。
    private func cny(_ v: Double) -> String {
        String(format: "¥%.2f", max(0, v))
    }
}
