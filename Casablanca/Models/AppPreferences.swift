import Foundation

enum ExportDestination: String {
    case obsidian
    case appleNotes
}

enum PrepTodoStorage: String {
    case obsidian
    case local
}

enum LLMProviderKind: String, CaseIterable {
    case ollama
    case omlx
    case claudeCode
}

enum AppPreferences {
    static func exportDestination(in defaults: UserDefaults = .standard) -> ExportDestination {
        let raw = defaults.string(forKey: AppPreferenceKey.exportDestination) ?? ""
        return ExportDestination(rawValue: raw) ?? .obsidian
    }

    static func setExportDestination(_ value: ExportDestination, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: AppPreferenceKey.exportDestination)
    }

    static func prepTodoStorage(in defaults: UserDefaults = .standard) -> PrepTodoStorage {
        let raw = defaults.string(forKey: AppPreferenceKey.prepTodoStorage) ?? ""
        return PrepTodoStorage(rawValue: raw) ?? .obsidian
    }

    static func setPrepTodoStorage(_ value: PrepTodoStorage, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: AppPreferenceKey.prepTodoStorage)
    }

    static func llmProvider(in defaults: UserDefaults = .standard) -> LLMProviderKind {
        let raw = defaults.string(forKey: AppPreferenceKey.llmProvider) ?? ""
        return LLMProviderKind(rawValue: raw) ?? .ollama
    }

    static func setLLMProvider(_ value: LLMProviderKind, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: AppPreferenceKey.llmProvider)
    }

    static func autoExportEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.autoExportEnabled)
    }

    /// When `true`, the finished recording's WAV mixdown is preserved as-is and
    /// no AAC/m4a compression runs. Default `false`: after transcription
    /// succeeds, the WAV is re-encoded to AAC/m4a and the original WAV deleted.
    static func keepOriginalWAV(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.keepOriginalWAV)
    }

    /// Start a recording automatically when a Microsoft Teams call starts.
    /// Default `false`: recording a call is something the user opts into.
    static func teamsAutoRecordEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.teamsAutoRecordEnabled)
    }

    /// Stop a recording once the Teams call it overlapped ends — auto-started
    /// or started by hand. Default `true` (absence of the key means on). A
    /// recording that never overlapped a call is never stopped. Independent of
    /// `teamsAutoRecordEnabled`.
    static func teamsAutoRecordStopWhenCallEnds(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppPreferenceKey.teamsAutoRecordStopWhenCallEnds) as? Bool ?? true
    }

    static func hasCompletedOnboarding(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.hasCompletedOnboarding)
    }

    static func setHasCompletedOnboarding(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: AppPreferenceKey.hasCompletedOnboarding)
    }

    /// The names the user goes by, used to decide which summary action items are
    /// theirs. Read from the comma-separated `userNameAliases` setting; when that
    /// is empty, derived from the account's full name (see
    /// ``derivedUserNameAliases(fullName:)``). `fullNameProvider` is injectable so
    /// tests never depend on the machine's real account name.
    static func userNameAliases(
        in defaults: UserDefaults = .standard,
        fullNameProvider: () -> String = { NSFullUserName() }
    ) -> [String] {
        let stored = parseUserNameAliases(defaults.string(forKey: AppPreferenceKey.userNameAliases) ?? "")
        return stored.isEmpty ? derivedUserNameAliases(fullName: fullNameProvider()) : stored
    }

    /// Splits the comma-separated alias setting into trimmed, non-empty names,
    /// keeping the first occurrence of case-insensitive duplicates.
    static func parseUserNameAliases(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Default aliases when none are configured: the full name plus the first
    /// name ("Youri Broekhuizen" → ["Youri Broekhuizen", "Youri"]).
    static func derivedUserNameAliases(fullName: String) -> [String] {
        let full = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return [] }
        let first = full.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? full
        return first == full ? [full] : [full, first]
    }

    /// When `true`, action items without an owner (`**?**`, or no owner prefix
    /// at all) also become to-dos. Default `false`: only the user's own items do.
    static func includeUnassignedActionItems(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppPreferenceKey.includeUnassignedActionItems)
    }

    /// One-shot migration: if the legacy `autoExportNotesToObsidian` key has a value but the new
    /// `autoExportEnabled` key has none, seed the new key from the legacy value. The legacy key is
    /// preserved (do not delete user data). Idempotent.
    static func migrateLegacyAutoExportKeyIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: AppPreferenceKey.autoExportEnabled) == nil else { return }
        guard let legacyValue = defaults.object(forKey: AppPreferenceKey.legacyAutoExportNotesToObsidian) as? Bool else {
            return
        }
        defaults.set(legacyValue, forKey: AppPreferenceKey.autoExportEnabled)
    }
}
