import Foundation

/// Keeps the Mac from idle-sleeping while a job that must not be interrupted is
/// running.
///
/// macOS hands coreaudiod an idle-sleep assertion of its own while a mic is
/// live, but drops it once the *display* sleeps — so a machine left alone with
/// a recording running goes to sleep and the capture dies with it. That is how
/// a 75-minute recording was lost; a transcription lost 37 minutes the same
/// way. The app therefore holds its own assertion for as long as it is
/// recording or transcribing.
///
/// A protocol so tests can count assertions instead of touching real power
/// management. Deliberately **not** `Sendable`: both consumers
/// (`AudioRecordingService`, `TranscriptionService`) are `@MainActor`, take and
/// release their assertions from main-actor code, and never hand a preventer or
/// a token to another isolation domain.
protocol SleepPreventing: AnyObject {
    func begin(reason: String) -> SleepPreventionToken
}

/// One held assertion. Releasing is idempotent — the recording service tears a
/// session down from several paths (pause, stop, interrupt) and each of them
/// may reach the release — and `deinit` is a last-resort safety net so a
/// dropped token can never keep the machine awake forever.
final class SleepPreventionToken {
    private var release: (() -> Void)?

    init(release: @escaping () -> Void) {
        self.release = release
    }

    func end() {
        guard let release else { return }
        self.release = nil
        release()
    }

    deinit {
        end()
    }
}

/// The real thing: an activity registered with `ProcessInfo`, which holds a
/// `PreventUserIdleSystemSleep` power assertion for its lifetime.
///
/// `.idleDisplaySleepDisabled` is intentionally absent — recording should not
/// keep the screen lit, only the machine awake.
final class ProcessInfoSleepPreventer: SleepPreventing {
    func begin(reason: String) -> SleepPreventionToken {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
        return SleepPreventionToken {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
