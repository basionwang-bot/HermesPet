import SwiftUI
import AppKit

/// 设置 → 账号（iOS 设置风：顶部头像账户卡 + 分组圆角卡片）。
/// App 侧脚手架（零服务器依赖）：资料（头像+昵称）/ 连接账号占位 / 意见反馈。
/// 复用 `SettingsKit`（SettingsCard / SettingsIconTile）。守决策 #11 / #20。
struct AccountSettingsView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var profile = UserProfileStore.shared

    // 反馈
    @State private var feedbackKind = "bug"
    @State private var feedbackText = ""
    @State private var includeDiag = true
    @State private var sending = false
    @State private var resultNote: (ok: Bool, text: String)?
    @State private var copiedDevice = false

    // 云端连接（手机远程操控）
    @State private var cloudAccountEmail = ""
    @State private var cloudEmail = ""
    @State private var cloudPassword = ""
    @State private var cloudInvite = ""
    @State private var cloudIsRegister = false
    @State private var cloudLoading = false
    @State private var cloudError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroCard
            profileGroup
            cloudRelayGroup
            connectGroup
            feedbackGroup
        }
        .onAppear { cloudAccountEmail = CloudAccount.savedEmail }
    }

    // MARK: - 云端连接（手机远程操控本机）

    private var cloudRelayGroup: some View {
        SettingsCard(header: "云端连接（让手机远程操控本机）", spacing: 10) {
            if !cloudAccountEmail.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("已登录：\(cloudAccountEmail)").font(.system(size: 13))
                    Spacer()
                    Button("断开") {
                        Task { @MainActor in
                            CloudAccount.signOut()
                            cloudAccountEmail = ""
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 13))
                }
                Text("手机用同一账号登录，即可在外网远程操控这台电脑。保持 HermesPet 开着即可。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("登录后，手机用同一账号即可在外网（4G/5G）远程操控这台电脑。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("邮箱", text: $cloudEmail)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13))
                SecureField("密码（至少 6 位）", text: $cloudPassword)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13))
                if cloudIsRegister {
                    TextField("邀请码", text: $cloudInvite)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                }
                if let cloudError {
                    Text(cloudError).font(.system(size: 11)).foregroundStyle(.red)
                }
                HStack {
                    Toggle("没有账号，注册一个", isOn: $cloudIsRegister)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                    Spacer()
                    Button { cloudLogin() } label: {
                        Label(cloudLoading ? "连接中…" : (cloudIsRegister ? "注册并连接" : "登录并连接"),
                              systemImage: "link")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .disabled(cloudLoading || !cloudEmail.contains("@") || cloudPassword.count < 6
                              || (cloudIsRegister && cloudInvite.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }

    private func cloudLogin() {
        cloudLoading = true; cloudError = nil
        Task { @MainActor in
            let err = await CloudAccount.login(register: cloudIsRegister,
                                               email: cloudEmail.trimmingCharacters(in: .whitespaces),
                                               password: cloudPassword,
                                               invite: cloudInvite.trimmingCharacters(in: .whitespaces))
            cloudLoading = false
            if let err {
                cloudError = err
            } else {
                cloudPassword = ""
                cloudAccountEmail = CloudAccount.savedEmail
            }
        }
    }

    // MARK: - 顶部头像账户卡

    private var heroCard: some View {
        SettingsCard(padding: 16) {
            HStack(spacing: 14) {
                heroAvatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.system(size: 19, weight: .bold)).lineLimit(1)
                    Text(profile.isSignedIn ? (profile.email ?? "")
                                            : L("settings.account.hero.tapHint"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private var heroAvatar: some View {
        Button { chooseAvatar() } label: {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue.opacity(0.25), .purple.opacity(0.18)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 66, height: 66)
                    if let img = profile.avatar {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 66, height: 66).clipShape(Circle())
                    } else if !profile.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(profile.initials).font(.system(size: 24, weight: .semibold)).foregroundStyle(.blue)
                    } else {
                        Image(systemName: "person.fill").font(.system(size: 28)).foregroundStyle(.blue)
                    }
                }
                .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
                Circle().fill(Color.accentColor).frame(width: 21, height: 21)
                    .overlay(Image(systemName: "camera.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
        }
        .buttonStyle(.plain)
        .help(L("settings.account.avatar.choose"))
    }

    private func chooseAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            AvatarCropController.shared.present(image: img) { cropped in
                profile.setAvatar(image: cropped)
            }
        }
    }

    // MARK: - 个人资料（昵称 / 头像操作）

    private var profileGroup: some View {
        SettingsCard(header: L("settings.account.section.profile")) {
            HStack(spacing: 8) {
                Text(L("settings.account.nickname.placeholder"))
                    .font(.system(size: 13))
                Spacer()
                TextField(L("settings.account.nickname.unset"),
                          text: Binding(get: { profile.nickname }, set: { profile.setNickname($0) }))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13))
                    .frame(maxWidth: 220)
            }
            if profile.avatar != nil {
                SettingsRowDivider()
                Button {
                    profile.clearAvatar()
                } label: {
                    Text(L("settings.account.avatar.remove"))
                        .font(.system(size: 13)).foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 连接账号（占位）

    private var connectGroup: some View {
        SettingsCard(header: L("settings.account.section.account"), spacing: 10) {
            if profile.isSignedIn {
                HStack {
                    Text(L("settings.account.signedInAs", profile.email ?? profile.accountID ?? ""))
                        .font(.system(size: 13))
                    Spacer()
                    Button(L("settings.account.signOut")) { profile.signOut() }
                        .buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 13))
                }
            } else {
                HStack(alignment: .top, spacing: 11) {
                    SettingsIconTile(icon: "person.crop.circle.badge.plus", color: .blue, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(L("settings.account.connect.title")).font(.system(size: 13, weight: .medium))
                            Text(L("settings.account.connect.soon"))
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                        Text(L("settings.account.connect.desc"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                Button {
                    // 占位：服务器 / 网站上线后在这里打开登录流程
                } label: {
                    Label(L("settings.account.connect.button"), systemImage: "arrow.right.circle.fill")
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(true)
            }

            SettingsRowDivider()

            infoRow(label: L("settings.account.connect.gateway"), value: OfficialGateway.plannedBaseURL)
            HStack(spacing: 6) {
                infoRow(label: L("settings.account.connect.device"), value: profile.deviceID)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(profile.deviceID, forType: .string)
                    copiedDevice = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedDevice = false }
                } label: {
                    Image(systemName: copiedDevice ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - 意见反馈 / 报 bug

    private var feedbackGroup: some View {
        SettingsCard(header: L("settings.account.section.feedback"), spacing: 10) {
            HStack(spacing: 8) {
                SettingsIconTile(icon: "exclamationmark.bubble.fill", color: .orange, size: 24)
                Text(L("settings.account.feedback.title")).font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("", selection: $feedbackKind) {
                    Text(L("settings.account.feedback.kind.bug")).tag("bug")
                    Text(L("settings.account.feedback.kind.idea")).tag("idea")
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $feedbackText)
                    .font(.system(size: 12)).frame(height: 80).scrollContentBackground(.hidden)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                if feedbackText.isEmpty {
                    Text(L("settings.account.feedback.placeholder"))
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.vertical, 15).allowsHitTesting(false)
                }
            }

            Toggle(isOn: $includeDiag) {
                Text(L("settings.account.feedback.includeDiag")).font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            HStack {
                if let r = resultNote {
                    HStack(spacing: 6) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.ok ? .green : .orange)
                        Text(r.text).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button(action: send) {
                    Label(sending ? L("settings.account.feedback.sending") : L("settings.account.feedback.send"),
                          systemImage: "paperplane.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .disabled(sending || feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
            }

            Text(L("settings.account.feedback.note"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func send() {
        let text = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 else { return }
        sending = true; resultNote = nil
        let ctx = includeDiag ? diagnostics() : nil
        let kind = feedbackKind
        Task { @MainActor in
            let outcome = await FeedbackService.submit(kind: kind, message: text, context: ctx)
            sending = false
            switch outcome {
            case .sentToServer:
                resultNote = (true, L("settings.account.feedback.sent")); feedbackText = ""
            case .openedGitHub:
                resultNote = (true, L("settings.account.feedback.openedGitHub")); feedbackText = ""
            case .failed(let e):
                resultNote = (false, L("settings.account.feedback.failed", e))
            }
        }
    }

    /// 诊断上下文：环境 + 最近崩溃 + 当前对话片段。
    private func diagnostics() -> String {
        var lines: [String] = []
        let v = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("env: macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        if let crash = CrashReporter.shared.latestCrash {
            lines.append("lastCrash: v\(crash.appVersion) \(crash.exceptionType)")
        }
        let transcript = viewModel.currentConversationTranscript(maxChars: 3000)
        if !transcript.isEmpty {
            lines.append("--- 当前对话（截断）---")
            lines.append(transcript)
        }
        return lines.joined(separator: "\n")
    }
}
