import AppKit
import Foundation

@MainActor
@Observable
final class ProfileSettingsStore {
    static let shared = ProfileSettingsStore()

    var userDisplayName: String
    private var userAvatarPath: String
    private var modeProfiles: [String: ModeProfile]
    private var revision: Int = 0

    private init() {
        let stored = Self.loadStored()
        self.userDisplayName = stored?.userDisplayName ?? ""
        self.userAvatarPath = stored?.userAvatarPath ?? ""
        self.modeProfiles = stored?.modeProfiles ?? [:]
    }

    func resolvedUserDisplayName() -> String {
        let trimmed = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "你" : trimmed
    }

    func customDisplayName(for mode: AgentMode) -> String {
        modeProfiles[mode.rawValue]?.displayName ?? ""
    }

    func resolvedAssistantDisplayName(for mode: AgentMode) -> String {
        guard mode.allowsCustomDisplayName else { return mode.label }
        let trimmed = customDisplayName(for: mode).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? mode.label : trimmed
    }

    func avatarImage(for target: ProfileAvatarTarget) -> NSImage? {
        _ = revision
        guard let path = avatarPath(for: target), !path.isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }

    func updateUserDisplayName(_ value: String) {
        userDisplayName = value
        save()
    }

    func updateDisplayName(_ value: String, for mode: AgentMode) {
        guard mode.allowsCustomDisplayName else { return }
        var profile = modeProfile(for: mode)
        profile.displayName = value
        modeProfiles[mode.rawValue] = profile
        save()
    }

    func setAvatar(from sourceURL: URL, for target: ProfileAvatarTarget) throws {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(
            at: Self.profileDirectory,
            withIntermediateDirectories: true
        )

        let ext = normalizedImageExtension(from: sourceURL)
        let destination = Self.profileDirectory
            .appendingPathComponent(target.fileStem)
            .appendingPathExtension(ext)
        if sourceURL.standardizedFileURL.path == destination.standardizedFileURL.path {
            updateAvatarPath(destination.path, for: target)
            return
        }

        let temporaryURL = Self.profileDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        removeExistingAvatarFile(for: target)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        updateAvatarPath(destination.path, for: target)
    }

    private func updateAvatarPath(_ path: String, for target: ProfileAvatarTarget) {
        switch target {
        case .user:
            userAvatarPath = path
        case .mode(let mode):
            var profile = modeProfile(for: mode)
            profile.avatarPath = path
            modeProfiles[mode.rawValue] = profile
        }
        revision += 1
        save()
    }

    func resetAvatar(for target: ProfileAvatarTarget) {
        removeExistingAvatarFile(for: target)
        switch target {
        case .user:
            userAvatarPath = ""
        case .mode(let mode):
            var profile = modeProfile(for: mode)
            profile.avatarPath = ""
            modeProfiles[mode.rawValue] = profile
        }
        revision += 1
        save()
    }

    private func avatarPath(for target: ProfileAvatarTarget) -> String? {
        switch target {
        case .user:
            return userAvatarPath
        case .mode(let mode):
            return modeProfiles[mode.rawValue]?.avatarPath
        }
    }

    private func modeProfile(for mode: AgentMode) -> ModeProfile {
        modeProfiles[mode.rawValue] ?? ModeProfile()
    }

    private func normalizedImageExtension(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "webp":
            return ext
        default:
            return "png"
        }
    }

    private func removeExistingAvatarFile(for target: ProfileAvatarTarget) {
        let stems = [target.fileStem]
        let extensions = ["jpg", "jpeg", "png", "heic", "webp"]
        for stem in stems {
            for ext in extensions {
                let url = Self.profileDirectory
                    .appendingPathComponent(stem)
                    .appendingPathExtension(ext)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func save() {
        let stored = Stored(
            userDisplayName: userDisplayName,
            userAvatarPath: userAvatarPath,
            modeProfiles: modeProfiles
        )
        if let data = try? JSONEncoder().encode(stored) {
            try? FileManager.default.createDirectory(
                at: Self.profileDirectory,
                withIntermediateDirectories: true
            )
            try? data.write(to: Self.profileURL, options: .atomic)
        }
    }

    private static func loadStored() -> Stored? {
        guard let data = try? Data(contentsOf: profileURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private struct Stored: Codable {
        var userDisplayName: String = ""
        var userAvatarPath: String = ""
        var modeProfiles: [String: ModeProfile] = [:]
    }

    private struct ModeProfile: Codable {
        var displayName: String = ""
        var avatarPath: String = ""
    }

    private static let profileDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".hermespet/profile", isDirectory: true)
    private static let profileURL = profileDirectory.appendingPathComponent("profile.json")
}

enum ProfileAvatarTarget: Hashable {
    case user
    case mode(AgentMode)

    var fileStem: String {
        switch self {
        case .user:
            return "user-avatar"
        case .mode(let mode):
            return "\(mode.rawValue)-avatar"
        }
    }
}

extension AgentMode {
    var allowsCustomDisplayName: Bool {
        switch self {
        case .hermes, .openclaw:
            return true
        case .directAPI, .claudeCode, .codex:
            return false
        }
    }
}
