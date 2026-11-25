import Foundation

struct UpdatePreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.automaticChecksEnabled: true])
    }

    private enum Keys {
        static let automaticChecksEnabled = "updater.automaticChecksEnabled"
        static let includePrereleases = "updater.includePrereleases"
        static let skippedVersion = "updater.skippedVersion"
        static let lastCheckAt = "updater.lastCheckAt"
        static let applicationsLocationPromptShown = "updater.applicationsLocationPromptShown"
    }

    var automaticChecksEnabled: Bool {
        get { defaults.bool(forKey: Keys.automaticChecksEnabled) }
        set { defaults.set(newValue, forKey: Keys.automaticChecksEnabled) }
    }

    var includePrereleases: Bool {
        get { defaults.bool(forKey: Keys.includePrereleases) }
        set { defaults.set(newValue, forKey: Keys.includePrereleases) }
    }

    var skippedVersion: SemanticVersion? {
        get {
            guard let raw = defaults.string(forKey: Keys.skippedVersion) else { return nil }
            return try? SemanticVersion(parsing: raw)
        }
        set { defaults.set(newValue?.description, forKey: Keys.skippedVersion) }
    }

    var lastCheckAt: Date? {
        get { defaults.object(forKey: Keys.lastCheckAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastCheckAt) }
    }

    var applicationsLocationPromptShown: Bool {
        get { defaults.bool(forKey: Keys.applicationsLocationPromptShown) }
        set { defaults.set(newValue, forKey: Keys.applicationsLocationPromptShown) }
    }
}
