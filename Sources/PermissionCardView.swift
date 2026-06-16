import SwiftUI

/// Permission 决策卡片 —— 灵动岛展开后渲染的内容。
/// 参考 vibe-island 的设计：橙色 ⚠️ + 工具描述 + diff 预览（如有）+ 三档按钮（Deny / Allow / Allow always）。
///
/// **决策路由**：
/// 按钮回调通过 `onDecision` 闭包传出，调用方负责调 OpenCodeHTTPClient.replyPermission()
/// 然后让灵动岛收起卡片
struct PermissionCardView: View {
    let request: PermissionRequest
    let onDecision: (PermissionDecision) -> Void

    /// 鼠标 hover 在哪个按钮上 —— 用于按钮颜色微变
    @State private var hoveredButton: PermissionDecision?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            toolDescription
            if let diff = request.diffPreview {
                diffPreview(old: diff.oldText, new: diff.newText)
            } else if let primary = request.primaryArg {
                singleArgPreview(primary)
            }
            Spacer(minLength: 6)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - 头部：橙色 ⚠️ + "Permission Request"
    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(NSColor.systemOrange))
                .frame(width: 5, height: 5)
            Text("Permission Request")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(NSColor.systemOrange))
            Spacer()
        }
    }

    // MARK: - 工具描述：⚠️ 工具名
    /// 第一行 ⚠️ + 工具名（SF Pro Display Bold 17pt）。
    /// **第二行 primary arg 只在 Diff 模式显示** —— 让用户知道改的是哪个文件；
    /// 非 Diff 模式（WebFetch / Bash 等）由 singleArgPreview 承担主信息载体，避免重复
    private var toolDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(NSColor.systemOrange))
                Text(request.toolDisplayName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            // 仅 Diff 模式显示文件路径 —— 让 +- 行有上下文
            if request.diffPreview != nil, let arg = request.primaryArg {
                Text(arg)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 19)   // 跟工具名左对齐（避开 ⚠️ 图标宽度）
            }
        }
    }

    // MARK: - Diff 预览（Edit/Write 有 old_string + new_string 时）
    @ViewBuilder
    private func diffPreview(old: String?, new: String?) -> some View {
        let oldLines = (old ?? "").components(separatedBy: "\n")
        let newLines = (new ?? "").components(separatedBy: "\n")
        let plusCount = newLines.filter { !$0.isEmpty }.count
        let minusCount = oldLines.filter { !$0.isEmpty }.count

        VStack(alignment: .leading, spacing: 2) {
            // 老内容（删除）—— 红底
            ForEach(Array(oldLines.prefix(3).enumerated()), id: \.offset) { _, line in
                diffLine(prefix: "-", text: line, bg: Color.red.opacity(0.15), fg: Color.red.opacity(0.9))
            }
            if oldLines.count > 3 {
                Text(L("permission.diff.moreLines", oldLines.count - 3))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            // 新内容（添加）—— 绿底
            ForEach(Array(newLines.prefix(5).enumerated()), id: \.offset) { _, line in
                diffLine(prefix: "+", text: line, bg: Color.green.opacity(0.15), fg: Color.green.opacity(0.9))
            }
            if newLines.count > 5 {
                Text(L("permission.diff.moreLines", newLines.count - 5))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // 右下角统计
            HStack {
                Spacer()
                Text("+\(plusCount) -\(minusCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.25))
        )
    }

    private func diffLine(prefix: String, text: String, bg: Color, fg: Color) -> some View {
        HStack(spacing: 0) {
            Text(prefix)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(fg)
                .frame(width: 14, alignment: .center)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.vertical, 1)
        .background(bg)
    }

    // MARK: - 非 Edit 工具：单行主参数预览（Bash 命令 / Read 路径 / WebFetch URL）
    private func singleArgPreview(_ arg: String) -> some View {
        Text(arg)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(3)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.25))
            )
    }

    // MARK: - 按钮（横排，HIG 风格）：[拒绝] Spacer [总是允许] [允许]
    /// HIG 推荐 alert 按钮**横排在底部**，主操作（允许）放最右下角符合视线扫描终点。
    /// destructive（拒绝）放最左用 .systemGray 弱化避免抢注意力；总是允许用 .systemOrange 提示
    /// 危险性；允许用 .systemBlue 作为主 CTA。系统色自动适配 light/dark mode + 高对比度模式
    /// 三按钮等宽均分卡片宽度。HStack 内每个按钮 .frame(maxWidth: .infinity) 撑满分到的列宽，
    /// shortcut chip 用 fixedSize 不被压缩，主 label lineLimit(1) + minimumScaleFactor 兜底
    private var buttons: some View {
        HStack(spacing: 6) {
            decisionButton(.reject, label: "Deny", shortcut: "⌘N",
                           tint: Color(NSColor.systemGray))
            decisionButton(.always, label: "Always", shortcut: "",
                           tint: Color(NSColor.systemOrange))
            decisionButton(.once, label: "Allow", shortcut: "⌘Y",
                           tint: Color(NSColor.systemBlue))
        }
    }

    /// 等宽按钮（.frame(maxWidth: .infinity) 让 HStack 三按钮分到相同宽度）。
    /// label 用 lineLimit(1) + minimumScaleFactor 防止"Deny"被压成"D/e/n/y"竖排字符
    private func decisionButton(_ decision: PermissionDecision,
                                 label: String,
                                 shortcut: String,
                                 tint: Color) -> some View {
        Button {
            onDecision(decision)
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .fixedSize()
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(hoveredButton == decision ? 1.0 : 0.88))
            )
            .scaleEffect(hoveredButton == decision ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                hoveredButton = hovering ? decision : nil
            }
        }
    }
}
