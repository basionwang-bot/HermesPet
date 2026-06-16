import SwiftUI

/// iOS 设置风格的可复用零件。统一设置面板的视觉语言：
/// - 彩色圆角图标贴片（iOS 设置最标志性的元素）
/// - 分组圆角卡片（inset-grouped）
/// - 分组小标题
/// 守决策 #11（纯视觉，无新状态）。light/dark 自适应用 `.primary.opacity` + 系统色。

/// 彩色圆角方形图标贴片（白色 SF Symbol on 彩色渐变底）。
struct SettingsIconTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * 0.54, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: color.opacity(0.25), radius: 1, y: 0.5)
    }
}

/// 分组圆角卡片容器（iOS inset-grouped 的一组）。可带分组小标题。
struct SettingsCard<Content: View>: View {
    var header: String? = nil
    var padding: CGFloat = 14
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
    }
}

/// 卡片内的一条带分隔线的行分隔（iOS 行间细线）。
struct SettingsRowDivider: View {
    var body: some View {
        Divider().opacity(0.4).padding(.vertical, 2)
    }
}
