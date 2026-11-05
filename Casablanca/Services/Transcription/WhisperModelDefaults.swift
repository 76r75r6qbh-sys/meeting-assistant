import Foundation

/// Which Whisper model a user gets when they never picked one.
///
/// The fallback in `AppPreferenceValue.defaultWhisperModel` (`base`) is read
/// wherever the `whisperModel` key is absent, so changing it would silently
/// move every existing user who never touched the picker onto a different
/// (and multi-GB) model. Instead the key is written explicitly once at launch:
/// existing installs are pinned to what they have been running all along, and
/// only a genuinely new install gets `newInstallDefault`.
enum WhisperModelDefaults {
    /// What an install without a stored choice has used so far.
    static let legacyDefault = "openai_whisper-base"

    /// The best model measured with the benchmark harness
    /// (`docs/transcription-benchmarks.md`, 2026-09 campaign: ≈ 4× realtime on
    /// an M4 Pro). The turbo variant is offered in Settings but is not the
    /// default until it passes the gate on device; see the doc's "Default
    /// model for new installs" section.
    static let newInstallDefault = "openai_whisper-large-v3"

    /// Writes `whisperModel` when it is absent: `legacyDefault` for an existing
    /// install, `newInstallDefault` for a new one. A present value — including
    /// an earlier pin — is never touched, so this is idempotent.
    ///
    /// - Parameter storeExists: whether the app's meeting store is already on
    ///   disk. Checked by the caller before the container is opened (which
    ///   would create it).
    static func pinIfNeeded(defaults: UserDefaults = .standard, storeExists: Bool) {
        guard defaults.object(forKey: AppPreferenceKey.whisperModel) == nil else { return }
        let model = isExistingInstall(defaults: defaults, storeExists: storeExists)
            ? legacyDefault
            : newInstallDefault
        defaults.set(model, forKey: AppPreferenceKey.whisperModel)
    }

    /// Keys whose mere presence marks an existing install.
    static let existingInstallKeys = [
        AppPreferenceKey.llmProvider,
        AppPreferenceKey.obsidianVaultPath,
        AppPreferenceKey.terminologyList,
    ]

    /// Every key `pinIfNeeded` reads. None of them may ever get a registered
    /// default: a registered value is "present" to `object(forKey:)`, which
    /// would make every new install look existing (or skip the pin outright
    /// for `whisperModel`). Guarded by a test.
    static let keysRead = [AppPreferenceKey.whisperModel, AppPreferenceKey.hasCompletedOnboarding]
        + existingInstallKeys

    private static func isExistingInstall(defaults: UserDefaults, storeExists: Bool) -> Bool {
        if storeExists { return true }
        if defaults.bool(forKey: AppPreferenceKey.hasCompletedOnboarding) { return true }
        return existingInstallKeys.contains { defaults.object(forKey: $0) != nil }
    }
}
