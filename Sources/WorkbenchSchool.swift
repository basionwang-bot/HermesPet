import SwiftUI
import AppKit

/// 工作台「AI 学校」栏 —— 把 AgentForge（`agent-school/课程地图.md`）的 132 门课按学院陈列出来，
/// 用户挑一门点「让 AI 学这门课」→ 新建上学 tab 用 Claude Code 真去上那门课、沉淀技能卡。
///
/// 视觉跟工作台一致（专业克制 + 双层主题），全读 `theme`。守决策 #21（ScrollView 不被 GeometryReader 包）。
struct WorkbenchSchoolView: View {
    let theme: WorkbenchTheme
    var onEnroll: (Course) -> Void

    @State private var detail: Course?
    @State private var cloning = false
    @State private var cloneError: String?
    @State private var copied = false
    private var store: SkillLibraryStore { SkillLibraryStore.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.hairline).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                                   startPoint: .top, endPoint: .bottom))
        .onAppear { if store.academies.isEmpty { store.refreshCourses() } }
        .sheet(item: $detail) { c in CourseDetailSheet(course: c, theme: theme) { onEnroll(c) } }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.accent.opacity(0.15)).frame(width: 42, height: 42)
                Image(systemName: "graduationcap.fill").font(.system(size: 19)).foregroundStyle(theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 学校 · AgentForge").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.textPrimary)
                Text("让你的 AI 去上课、学会真本事 —— 挑一门，点「学这门课」")
                    .font(.system(size: 11.5)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if SkillLibrary.repoExists, store.courseCount > 0 {
                statPill("\(store.courseCount)", "门课", "books.vertical.fill")
                statPill("\(store.graduatedCount)", "已掌握", "checkmark.seal.fill")
                Button { store.refreshCourses(); store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .frame(width: 30, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface1))
                }
                .buttonStyle(.plain).help("重新扫描课程")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func statPill(_ num: String, _ label: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(theme.accent)
            Text(num).font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textPrimary)
            Text(label).font(.system(size: 10.5)).foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(theme.surface1))
        .overlay(Capsule().strokeBorder(theme.panelStroke, lineWidth: 1))
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !SkillLibrary.repoExists {
            noRepoState
        } else if store.academies.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取课程地图…").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(store.academies) { academySection($0) }
                }
                .padding(18)
            }
        }
    }

    private func academySection(_ academy: Academy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(academy.title).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary)
                Text(academy.tagline).font(.system(size: 11)).foregroundStyle(theme.textTertiary).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(academy.courses.count) 门").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(theme.surface1))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 248), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(academy.courses) { courseCard($0) }
            }
        }
    }

    private func courseCard(_ course: Course) -> some View {
        Button { detail = course } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(course.id)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(Capsule().fill(theme.accent.opacity(0.14)))
                    Text(course.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "graduationcap").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                }
                Text(course.summary).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.panelStroke, lineWidth: 1))
            .shadow(color: theme.cardShadow, radius: theme.cardShadowRadius, y: 1)
        }
        .buttonStyle(.plain)
        .help("点开看这门课 → 让 AI 去学")
    }

    private var noRepoState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(theme.accent.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "graduationcap.fill").font(.system(size: 30)).foregroundStyle(theme.accent)
            }
            Text("先把课程库装到本地").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary)
            Text("AI 学校的课程来自公开课程库 AgentForge。\n点下面一键装好，这里就会列出全部课程供 AI 上学。")
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).lineSpacing(2)

            if cloning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在克隆课程库到 ~/agent-forge …").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 10) {
                    Button { cloneRepo() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 13))
                            Text("一键装好课程库").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent))
                    }
                    .buttonStyle(.plain).help("git clone 到 ~/agent-forge（需本机已装 git）")

                    Button { NSWorkspace.shared.open(SkillLibrary.repoWebURL) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "safari").font(.system(size: 13))
                            Text("在 GitHub 查看").font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surface1))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.panelStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }

            if let err = cloneError {
                Text(err).font(.system(size: 11)).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }

            // 手动命令（带真实地址，可复制）
            HStack(spacing: 8) {
                Text("git clone \(SkillLibrary.repoCloneURL) ~/agent-forge")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("git clone \(SkillLibrary.repoCloneURL) ~/agent-forge", forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10)).foregroundStyle(copied ? .green : theme.textSecondary)
                }
                .buttonStyle(.plain).help("复制克隆命令")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface1))
            .padding(.top, 2)

            Text("装好后也可以在 设置 → 用 agentForgePath 指向别处的克隆")
                .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// 一键克隆课程库 → 成功后刷新课程目录（content 会自动切到课程列表）。
    private func cloneRepo() {
        cloning = true; cloneError = nil; copied = false
        Task {
            let err = await Task.detached { SkillLibrary.cloneRepo() }.value
            cloning = false
            if let err {
                cloneError = err
            } else {
                store.refreshCourses()
                store.refresh()
            }
        }
    }
}

// MARK: - 课程详情弹窗（读课程正文渲染；底部「让 AI 学这门课」）

private struct CourseDetailSheet: View {
    let course: Course
    let theme: WorkbenchTheme
    var onEnroll: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var body_: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text(course.id)
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                Text(course.name).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary).lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(theme.textTertiary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            Rectangle().fill(theme.hairline).frame(height: 1)

            ScrollView {
                Group {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 40)
                    } else if let b = body_, !b.isEmpty {
                        MarkdownTextView(content: b, tint: theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(course.summary).font(.system(size: 13)).foregroundStyle(theme.textPrimary)
                            Text("（这门课的详细讲义没在本地找到，但 AI 上课时会自己去 agent-school/courses/ 里翻出来读。）")
                                .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }

            Rectangle().fill(theme.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Spacer()
                Button { dismiss() } label: {
                    Text("取消").font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(theme.surface1))
                }.buttonStyle(.plain)
                Button { onEnroll(); dismiss() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "graduationcap.fill").font(.system(size: 12))
                        Text("让 AI 学这门课").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(theme.accent))
                }
                .buttonStyle(.plain).help("新建一个上学标签页，用 Claude Code 真去上这门课（需本机装 Claude Code）")
            }
            .padding(14)
        }
        .frame(width: 580, height: 640)
        .background(theme.surface1)
        .environment(\.colorScheme, theme.colorScheme)
        .task {
            // 读课程正文（文件 IO 放后台），找不到就用 summary 兜底
            let id = course.id
            let text = await Task.detached { SkillLibrary.courseBody(id: id) }.value
            body_ = text
            loading = false
        }
    }
}
