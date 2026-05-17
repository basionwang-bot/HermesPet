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
        VStack(alignment: .leading, spacing: 8) {
            header
            toolDescription
            if let diff = request.diffPreview {
                diffPreview(old: diff.oldText, new: diff.newText)
            } else if let primary = request.primaryArg {
                singleArgPreview(primary)
            }
            // 固定 12pt 间距而不是 Spacer —— 避免没参数时按钮被推到底部留大空白
            Spacer().frame(height: 8)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - 头部：橙色 ⚠️ + "Permission Request"
    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
            Text("Permission Request")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.orange)
            Spacer()
        }
    }

    // MARK: - 工具描述：⚠️ Edit
    /// 窄宽度下分两行排：第一行 ⚠️ + 工具名，第二行单独显示参数（如文件路径）
    private var toolDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                Text(request.toolDisplayName)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
            }
            if let arg = request.primaryArg {
                Text(arg)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 17)   // 跟工具名左对齐（避开 ⚠️ 图标宽度）
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
                Text("    … +\(oldLines.count - 3) 行")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            // 新内容（添加）—— 绿底
            ForEach(Array(newLines.prefix(5).enumerated()), id: \.offset) { _, line in
                diffLine(prefix: "+", text: line, bg: Color.green.opacity(0.15), fg: Color.green.opacity(0.9))
            }
            if newLines.count > 5 {
                Text("    … +\(newLines.count - 5) 行")
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

    // MARK: - 按钮（竖排三个全宽按钮）：Allow（绿）/ Always（橙）/ Deny（红）
    /// 顺序按"最常用 → 危险"排：Allow 顶（首选，最易点）→ Always 中（持久决策）→ Deny 底
    /// 颜色语义：绿=安全确认，橙=持久强决策，红=拒绝
    private var buttons: some View {
        VStack(spacing: 7) {
            decisionButton(.once, label: "Allow", shortcut: "⌘Y",
                           tint: Color(red: 0.25, green: 0.72, blue: 0.38))   // 绿
            decisionButton(.always, label: "Always Allow", shortcut: "",
                           tint: Color(red: 0.95, green: 0.55, blue: 0.16))   // 橙
            decisionButton(.reject, label: "Deny", shortcut: "⌘N",
                           tint: Color(red: 0.86, green: 0.27, blue: 0.27))   // 红
        }
    }

    /// 全宽按钮：居中 label，右侧 shortcut chip。
    /// 用 ZStack + frame(maxWidth: .infinity) **强制 3 个按钮等宽**（无 shortcut 的不再缩水）
    private func decisionButton(_ decision: PermissionDecision,
                                 label: String,
                                 shortcut: String,
                                 tint: Color) -> some View {
        Button {
            onDecision(decision)
        } label: {
            ZStack {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                if !shortcut.isEmpty {
                    HStack {
                        Spacer()
                        Text(shortcut)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)   // ← 关键：强制按钮宽度撑满 VStack
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(hoveredButton == decision ? 1.0 : 0.88))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredButton = hovering ? decision : nil
        }
    }
}
