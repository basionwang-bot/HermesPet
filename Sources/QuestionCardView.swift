import SwiftUI

/// AI 主动问问题的卡片（opencode `question.asked` 事件 → 卡片）。
/// 跟 PermissionCardView 平行，复用 PermissionWindow 显示框架。
///
/// **跟 vibe-island Ask 模式对齐**：
/// - 青色头部（区分于 Permission 的橙色）
/// - 问题文本 + 选项列表
/// - 单选时点选项立即提交；多选时底部加"提交"按钮
/// - 右上角 ✕ 按钮 reject（也可用 ESC）
struct QuestionCardView: View {
    let request: QuestionRequest
    /// 用户选择回调。answers 是嵌套数组：外层每个 question 一个元素，
    /// 内层是该 question 选中的 label 数组（multiple=true 时可能多个）
    let onAnswer: ([[String]]) -> Void
    let onReject: () -> Void

    /// 每个 question 当前选中的 labels（按 questions 索引）
    @State private var selected: [Set<String>] = []
    @State private var hoveredOption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(Array(request.questions.enumerated()), id: \.offset) { idx, q in
                questionBlock(index: idx, info: q)
            }
            Spacer().frame(height: 8)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear {
            // 初始化 selected 数组结构跟 questions 对齐
            if selected.count != request.questions.count {
                selected = Array(repeating: Set<String>(), count: request.questions.count)
            }
        }
    }

    // MARK: - 头部
    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.cyan)
            Text("AI 想问你")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.cyan)
            Spacer()
            Button {
                onReject()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 单个 question 块
    @ViewBuilder
    private func questionBlock(index: Int, info: QuestionRequest.QuestionInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(info.options.enumerated()), id: \.offset) { optIdx, opt in
                optionRow(qIdx: index, optIdx: optIdx, option: opt,
                          multiple: info.multiple ?? false)
            }
        }
    }

    /// 单个 option 横排：[⌘N chip] label + description
    private func optionRow(qIdx: Int, optIdx: Int, option: QuestionRequest.QuestionOption, multiple: Bool) -> some View {
        let isSelected = selected.indices.contains(qIdx) && selected[qIdx].contains(option.label)
        let shortcutChip = "⌘\(optIdx + 1)"

        return Button {
            handleOptionTap(qIdx: qIdx, label: option.label, multiple: multiple)
        } label: {
            HStack(spacing: 8) {
                Text(shortcutChip)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cyan.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.cyan.opacity(0.18))
                    )
                Text(option.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.cyan)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.cyan.opacity(
                        isSelected ? 0.22 :
                        (hoveredOption == "\(qIdx)-\(option.label)" ? 0.10 : 0.06)
                    ))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredOption = hovering ? "\(qIdx)-\(option.label)" : nil
        }
    }

    // MARK: - 底部按钮（multiple=true 时显示"提交"按钮，否则隐藏）
    @ViewBuilder
    private var actions: some View {
        let needsSubmit = request.questions.contains(where: { ($0.multiple ?? false) })
        if needsSubmit {
            Button {
                submit()
            } label: {
                Text("提交")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.cyan.opacity(0.88))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isAllAnswered)
            .opacity(isAllAnswered ? 1.0 : 0.5)
        }
    }

    private var isAllAnswered: Bool {
        guard selected.count == request.questions.count else { return false }
        for set in selected where set.isEmpty { return false }
        return true
    }

    // MARK: - 选项点击处理
    private func handleOptionTap(qIdx: Int, label: String, multiple: Bool) {
        guard selected.indices.contains(qIdx) else { return }
        if multiple {
            if selected[qIdx].contains(label) {
                selected[qIdx].remove(label)
            } else {
                selected[qIdx].insert(label)
            }
        } else {
            // 单选：选完立即提交（如果只有一个 question 没全选会被 submit 兜底）
            selected[qIdx] = [label]
            // 如果所有 question 都答完了 → 立即提交
            if isAllAnswered {
                submit()
            }
        }
    }

    private func submit() {
        // 转换成 [[String]] 嵌套数组
        let answers: [[String]] = selected.map { Array($0) }
        onAnswer(answers)
    }
}
