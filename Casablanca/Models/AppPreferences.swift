import Foundation

enum ExportDestination: String {
    case obsidian
    case appleNotes
}

enum PrepTodoStorage: String {
    case obsidian
    case local
}

enum LLMProviderKind: String {
    case ollama
    case omlx
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
