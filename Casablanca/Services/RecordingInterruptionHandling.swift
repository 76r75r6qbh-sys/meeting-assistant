import Foundation

/// Owns the sleep/lock/device interruption machinery for the whole app run:
/// the monitor, the notifier and the coordinator. `AudioRecordingService` and
/// the coordinator only hold these weakly, so something has to keep them alive.
///
/// That owner used to be the main window's `@State`. Closing the window while
/// recording freed all three: no sleep deferral and no auto-pause any more, which
/// matters most for Teams calls that are auto-recorded with no window open, and
/// reopening the window built a second set. `AppModel` now creates one instance
/// at bootstrap and keeps it.
@MainActor
final class RecordingInterruptionHandling {
    let monitor: RecordingInterruptionMonitor
    let coordinator: RecordingInterruptionCoordinator
    private let notifier: RecordingInterruptionNotifying

    init(
        service: AudioRecordingService,
        monitor: RecordingInterruptionMonitor,
        notifier: RecordingInterruptionNotifying,
        lookupMeeting: @escaping (UUID) -> Meeting?,
        save: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.notifier = notifier
        // System-audio-unavailable (no display) is handled as an auto-pause via
        // the monitor/coordinator (`.displayUnavailable`), so the service's
        // `onSystemAudioUnavailable` is deliberately NOT wired to a
        // microphone-only notification: the recording pauses rather than
        // silently continuing mic-only.
        service.interruptionMonitor = monitor
        coordinator = RecordingInterruptionCoordinator(
            service: service,
            monitor: monitor,
            notifier: notifier,
            // The coordinator acts on the meeting that is RECORDING, which the
            // user may have navigated away from (or never opened, for a Teams
            // auto-recording) before the Mac slept.
            lookupMeeting: lookupMeeting,
            save: save
        )
    }

    /// Registers for system power and session-lock notifications. Idempotent.
    func start() {
        monitor.start()
    }
}
