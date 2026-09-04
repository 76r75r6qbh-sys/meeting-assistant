import Foundation

/// What an interrupt actually did to the recording. The coordinator needs the
/// distinction: an interrupt that found nothing recording (a sleep while a
/// notes-only workspace is open) must not persist `.pausedRecording`, because
/// that later reads back as a paused recording that can no longer be resumed.
enum InterruptOutcome: Equatable {
    case nothingRecording
    case segmentFinalized(duration: TimeInterval)
    case finalizeFailed(String)
}

protocol RecordingInterruptionServicing: AnyObject {
    func handleSystemInterrupt(reason: RecordingInterruptionReason) async -> InterruptOutcome
    func resumeRecording(for meeting: Meeting) async throws
}

protocol RecordingInterruptionNotifying: AnyObject {
    func post(title: String, body: String)
}

protocol RecordingInterruptionEmitting: AnyObject {
    var onEvent: ((RecordingInterruptionEvent) -> Void)? { get set }
}

extension AudioRecordingService: RecordingInterruptionServicing {}
extension RecordingInterruptionMonitor: RecordingInterruptionEmitting {}

/// How long after a pause a wake may still auto-resume the recording.
///
/// The coordinator's original fixed 30 s window was written for a screen lock,
/// and it made a real system sleep unrecoverable: a sleep lasts minutes, so
/// every wake landed outside the window and the meeting stayed
/// `.pausedRecording` while the user assumed the recording was lost. Sleep and
/// lock are judged against the meeting's own slot instead — resume while the
/// meeting could still plausibly be running, and hand the decision to the user
/// once it cannot.
enum SleepResumePolicy {
    /// How far past its scheduled end a meeting may still be resumed. Meetings
    /// run over, and a wake inside the overrun is still the same meeting.
    static let meetingEndGrace: TimeInterval = 15 * 60

    /// The window used when there is no scheduled end to measure against (a
    /// meeting started by hand), counted from the pause.
    static let fallbackWindow: TimeInterval = 30 * 60

    /// Whether this reason's resume stays bound to the coordinator's short
    /// fixed window instead of the meeting slot. `.displayUnavailable` does:
    /// past the window there is still no display to capture system audio from.
    /// `.audioDeviceLost` / `.streamFailure` never auto-resume at all.
    static func isWindowBound(_ reason: RecordingInterruptionReason) -> Bool {
        switch reason {
        case .systemSleep, .screenLock: return false
        case .displayUnavailable, .audioDeviceLost, .streamFailure: return true
        }
    }

    /// The first moment at which a wake no longer auto-resumes a recording
    /// paused at `pausedAt`: the later of the meeting slot (+ grace) and the
    /// fallback window, so a meeting that was already running long when it
    /// paused still gets its full 30 minutes.
    static func deadline(pausedAt: Date, meetingEnd: Date?) -> Date {
        let fallback = pausedAt.addingTimeInterval(fallbackWindow)
        guard let meetingEnd else { return fallback }
        return max(meetingEnd.addingTimeInterval(meetingEndGrace), fallback)
    }

    static func shouldAutoResume(
        reason: RecordingInterruptionReason,
        pausedAt: Date,
        wakeAt: Date,
        meetingEnd: Date?
    ) -> Bool {
        guard reason.allowsAutoResume, !isWindowBound(reason) else { return false }
        return wakeAt < deadline(pausedAt: pausedAt, meetingEnd: meetingEnd)
    }
}

@MainActor
final class RecordingInterruptionCoordinator {
    struct InterruptionRecord: Equatable {
        let reason: RecordingInterruptionReason
        let startedAt: Date
        var endedAt: Date?
        var resumedAutomatically: Bool
    }

    private(set) var recentEvents: [InterruptionRecord] = []

    private weak var service: RecordingInterruptionServicing?
    private weak var monitor: RecordingInterruptionEmitting?
    private weak var notifier: RecordingInterruptionNotifying?
    private let autoResumeWindow: TimeInterval
    private let now: () -> Date
    private let save: () -> Void

    private var meeting: Meeting?
    private var activeReasons: Set<RecordingInterruptionReason> = []
    /// Every reason raised during the current interruption window, the ones that
    /// already ended included. Which resume rule applies is a property of the
    /// window as a whole: a closing lid raises both `.screenLock` and
    /// `.displayUnavailable`, and which of the two ends last is not ours to pick.
    private var windowReasons: Set<RecordingInterruptionReason> = []
    /// What the interrupt actually did, once the service has said. A wake after
    /// an interrupt that found nothing recording has nothing to resume; asking
    /// the service anyway failed and toasted "Could not resume recording" about
    /// a recording that never existed.
    private var lastInterruptOutcome: InterruptOutcome?
    private var startedAt: Date?
    private var resumeAllowedForActiveWindow = true
    private var deadlineTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    /// Invalidates an interrupt whose finalize is still in flight. The status
    /// flip waits for the service now, so a user Stop or a rebind can land in
    /// between — and writing `.pausedRecording` over a meeting the user just
    /// stopped strands a finished recording as unresumable.
    private var interruptGeneration = 0

    init(
        service: RecordingInterruptionServicing,
        monitor: RecordingInterruptionEmitting,
        notifier: RecordingInterruptionNotifying,
        autoResumeWindow: TimeInterval = 30,
        now: @escaping () -> Date = Date.init,
        save: @escaping () -> Void = {}
    ) {
        self.service = service
        self.monitor = monitor
        self.notifier = notifier
        self.autoResumeWindow = autoResumeWindow
        self.now = now
        self.save = save
        monitor.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
    }

    func bind(meeting newMeeting: Meeting?) {
        // Sleeping tears down the recording workspace, so SwiftUI's
        // `onDisappear` unbinds us while the interruption is still in flight.
        // Letting that win drops the meeting on the floor: the wake then finds
        // nothing to resume. Navigating to another meeting still rebinds — only
        // "no meeting at all" is deferred, and only while this one is still a
        // recording that a resume could apply to.
        if newMeeting == nil,
           let current = meeting,
           hasLiveInterruption,
           current.status == .recording || current.status == .pausedRecording {
            Log.recording.notice(
                """
                Keeping the interruption binding for meeting \
                \(current.id.uuidString, privacy: .public) \
                (\(current.status.rawValue, privacy: .public)) across the unbind: \
                an interruption is still in flight
                """
            )
            return
        }

        meeting = newMeeting
        clearInterruptionBookkeeping()
        recentEvents.removeAll()
    }

    /// An interruption this coordinator is still steering: either a reason is
    /// active, or one just ended and the resume decision has not been made yet.
    private var hasLiveInterruption: Bool {
        !activeReasons.isEmpty || startedAt != nil
    }

    private func clearInterruptionBookkeeping() {
        cancelPendingDeadline()
        resumeTask?.cancel()
        resumeTask = nil
        activeReasons.removeAll()
        windowReasons.removeAll()
        lastInterruptOutcome = nil
        startedAt = nil
        interruptGeneration += 1
    }

    /// The view telling us it moved the meeting itself. Every such transition
    /// supersedes any open interruption bookkeeping — including
    /// `.pausedRecording`: a pause the user chose must not be undone by a later
    /// wake auto-resuming the recording behind their back. An interruption's own
    /// pause never comes through here; `handleStart` sets that status directly.
    func notifyMeetingTransitioned(to status: MeetingStatus) {
        Log.recording.notice(
            """
            Meeting moved to \(status.rawValue, privacy: .public) by the user; \
            clearing interruption bookkeeping
            """
        )
        clearInterruptionBookkeeping()
    }

    private func handle(event: RecordingInterruptionEvent) {
        switch event.kind {
        case .started: handleStart(event)
        case .ended: handleEnd(event)
        }
    }

    private func handleStart(_ event: RecordingInterruptionEvent) {
        let isFirst = activeReasons.isEmpty
        activeReasons.insert(event.reason)
        windowReasons.insert(event.reason)
        if !event.reason.allowsAutoResume {
            resumeAllowedForActiveWindow = false
        }

        guard isFirst else {
            appendRecentEvent(InterruptionRecord(reason: event.reason, startedAt: event.at, endedAt: nil, resumedAutomatically: false))
            // A start that coalesces into an interrupt already in flight does no
            // finalize of its own, but it may still be carrying a power-change
            // deferral. Release it now; otherwise the only thing letting the Mac
            // sleep is the monitor's safety timer.
            event.completion?()
            return
        }

        resumeAllowedForActiveWindow = event.reason.allowsAutoResume
        startedAt = event.at
        appendRecentEvent(InterruptionRecord(reason: event.reason, startedAt: event.at, endedAt: nil, resumedAutomatically: false))
        // Pausing the meeting has to wait for the service's verdict: a sleep
        // while nothing is recording must leave the meeting alone, so the
        // status flip, the save and the notification all live after the await.
        let reason = event.reason
        let capturedMeeting = meeting
        let generation = interruptGeneration
        Task { @MainActor [weak self, service, notifier] in
            // The kernel is holding the sleep until this runs (IOKit sleep path
            // only; `nil` otherwise). `defer` so every path out releases it —
            // nothing recording, a stale outcome, a dropped `self` — and so the
            // status flip and its save still land inside the deferral window.
            defer { event.completion?() }
            let outcome = await service?.handleSystemInterrupt(reason: reason) ?? .nothingRecording
            guard let self else { return }
            self.log(outcome: outcome, reason: reason, meetingID: capturedMeeting?.id)
            if generation == self.interruptGeneration {
                self.lastInterruptOutcome = outcome
            }
            guard outcome != .nothingRecording else { return }

            // Everything the user could have done in the meantime — Stop,
            // Discard, switching meetings — bumps the generation, and only a
            // still-recording meeting can be paused. A stale outcome is
            // dropped: the pause it describes has already been superseded.
            guard generation == self.interruptGeneration,
                  let capturedMeeting,
                  self.meeting?.id == capturedMeeting.id,
                  self.meeting?.status == .recording
            else {
                self.logDiscarded(outcome: outcome, reason: reason, meetingID: capturedMeeting?.id)
                return
            }

            self.meeting?.status = .pausedRecording
            self.save()
            notifier?.post(title: "Recording paused", body: self.bodyForPause(reason, outcome: outcome))
        }
        // Only the fixed-window reasons get a timer. Sleep and lock are judged
        // against the meeting slot when they end (`SleepResumePolicy`), and a
        // timer would only expire while the Mac is asleep anyway.
        if SleepResumePolicy.isWindowBound(event.reason) {
            scheduleDeadline()
        }
    }

    private func handleEnd(_ event: RecordingInterruptionEvent) {
        activeReasons.remove(event.reason)
        if let lastIdx = recentEvents.lastIndex(where: { $0.reason == event.reason && $0.endedAt == nil }) {
            recentEvents[lastIdx].endedAt = event.at
        }
        guard activeReasons.isEmpty else { return }

        let reasonsThisWindow = windowReasons
        let outcomeThisWindow = lastInterruptOutcome
        defer {
            startedAt = nil
            resumeAllowedForActiveWindow = true
            windowReasons.removeAll()
            lastInterruptOutcome = nil
        }
        cancelPendingDeadline()

        guard let meeting else { return }
        guard resumeAllowedForActiveWindow else { return }
        guard let startedAt else { return }

        // Nothing was paused (a sleep while a notes-only meeting is open), so
        // there is nothing to resume.
        guard outcomeThisWindow != .nothingRecording else {
            Log.recording.notice(
                """
                Not resuming meeting \(meeting.id.uuidString, privacy: .public) after \
                \(String(describing: event.reason), privacy: .public): the interrupt found \
                nothing recording
                """
            )
            return
        }

        // The window as a whole decides: any sleep/lock reason in it earns the
        // meeting-slot policy, whichever reason happens to end last.
        let governingReason = reasonsThisWindow.first { !SleepResumePolicy.isWindowBound($0) } ?? event.reason
        // The monitor's timestamp and the clock can disagree across a sleep, so
        // take the later of the two: a stale event may not buy extra time.
        let wakeAt = max(event.at, now())

        if SleepResumePolicy.isWindowBound(governingReason) {
            let elapsed = wakeAt.timeIntervalSince(startedAt)
            let allowed = elapsed < autoResumeWindow
            Log.recording.notice(
                """
                Auto-resume \(allowed ? "granted" : "declined", privacy: .public) for meeting \
                \(meeting.id.uuidString, privacy: .public): \
                \(String(describing: governingReason), privacy: .public) is window-bound, \
                elapsed \(elapsed, privacy: .public)s vs window \(self.autoResumeWindow, privacy: .public)s
                """
            )
            guard allowed else { return }
        } else {
            let allowed = SleepResumePolicy.shouldAutoResume(
                reason: governingReason,
                pausedAt: startedAt,
                wakeAt: wakeAt,
                meetingEnd: meeting.endDate
            )
            logSleepResumeDecision(
                allowed: allowed,
                reason: governingReason,
                pausedAt: startedAt,
                wakeAt: wakeAt,
                meetingEnd: meeting.endDate,
                meetingID: meeting.id
            )
            guard allowed else {
                // The manifest is deliberately left alone, so Resume still works
                // from the workspace once the user opens the meeting.
                notifier?.post(title: Self.stayedPausedTitle, body: Self.stayedPausedBody)
                return
            }
        }

        let reasonForBody = event.reason
        let recordIndexAtDispatch = recentEvents.indices.last
        let capturedMeeting = meeting
        resumeTask = Task { @MainActor [weak self, service, notifier] in
            do {
                try await service?.resumeRecording(for: capturedMeeting)
                if let self {
                    if let lastIdx = recordIndexAtDispatch, lastIdx < self.recentEvents.count {
                        self.recentEvents[lastIdx].resumedAutomatically = true
                    }
                    // Only mutate the bound meeting if it's still the one we resumed.
                    if self.meeting?.id == capturedMeeting.id {
                        self.meeting?.status = .recording
                        self.save()
                    }
                    notifier?.post(
                        title: "Recording resumed",
                        body: "Continued after \(self.bodyForResume(reasonForBody))"
                    )
                } else {
                    notifier?.post(title: "Recording resumed", body: "")
                }
            } catch {
                notifier?.post(title: "Could not resume recording", body: error.localizedDescription)
            }
        }
    }

    /// The wake-past-the-slot toast, which reads as the confirmed line
    /// "Recording paused — open the meeting to Resume or Stop".
    static let stayedPausedTitle = "Recording paused"
    static let stayedPausedBody = "Open the meeting to Resume or Stop."

    private func logSleepResumeDecision(
        allowed: Bool,
        reason: RecordingInterruptionReason,
        pausedAt: Date,
        wakeAt: Date,
        meetingEnd: Date?,
        meetingID: UUID
    ) {
        let deadline = SleepResumePolicy.deadline(pausedAt: pausedAt, meetingEnd: meetingEnd)
        Log.recording.notice(
            """
            Auto-resume \(allowed ? "granted" : "declined", privacy: .public) for meeting \
            \(meetingID.uuidString, privacy: .public) after \
            \(String(describing: reason), privacy: .public): pausedAt \
            \(pausedAt.timeIntervalSince1970, privacy: .public), wakeAt \
            \(wakeAt.timeIntervalSince1970, privacy: .public), meetingEnd \
            \(meetingEnd.map { String($0.timeIntervalSince1970) } ?? "none", privacy: .public), \
            deadline \(deadline.timeIntervalSince1970, privacy: .public)
            """
        )
    }

    private func appendRecentEvent(_ record: InterruptionRecord) {
        recentEvents.append(record)
        if recentEvents.count > 5 {
            recentEvents.removeFirst(recentEvents.count - 5)
        }
    }

    private func scheduleDeadline() {
        cancelPendingDeadline()
        let window = autoResumeWindow
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window))
            self?.resumeAllowedForActiveWindow = false
        }
    }

    private func cancelPendingDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func log(outcome: InterruptOutcome, reason: RecordingInterruptionReason, meetingID: UUID?) {
        let reasonDescription = String(describing: reason)
        let meetingDescription = meetingID?.uuidString ?? "none"
        switch outcome {
        case .nothingRecording:
            Log.recording.notice(
                """
                Interruption (\(reasonDescription, privacy: .public)) found nothing recording; meeting \
                \(meetingDescription, privacy: .public) left as it was
                """
            )
        case .segmentFinalized(let duration):
            Log.recording.notice(
                """
                Interruption (\(reasonDescription, privacy: .public)) paused meeting \
                \(meetingDescription, privacy: .public) after finalizing \(duration, privacy: .public)s
                """
            )
        case .finalizeFailed(let message):
            Log.recording.error(
                """
                Interruption (\(reasonDescription, privacy: .public)) paused meeting \
                \(meetingDescription, privacy: .public); finalize failed: \(message, privacy: .public)
                """
            )
        }
    }

    private func logDiscarded(outcome: InterruptOutcome, reason: RecordingInterruptionReason, meetingID: UUID?) {
        Log.recording.notice(
            """
            Discarding stale interrupt outcome \(String(describing: outcome), privacy: .public) \
            (\(String(describing: reason), privacy: .public)) for meeting \
            \(meetingID?.uuidString ?? "none", privacy: .public): the meeting was stopped, \
            discarded or unbound while the finalize was in flight
            """
        )
    }

    private func bodyForPause(_ reason: RecordingInterruptionReason, outcome: InterruptOutcome) -> String {
        let cause = bodyForPause(reason)
        guard case .finalizeFailed(let message) = outcome else { return cause }
        return "\(cause) The audio up to this point may not have been saved: \(message)"
    }

    private func bodyForPause(_ reason: RecordingInterruptionReason) -> String {
        switch reason {
        case .screenLock: return "Screen locked."
        case .systemSleep: return "System went to sleep."
        case .audioDeviceLost(let id): return "Microphone disconnected (\(id))."
        case .displayUnavailable: return "No display available for system audio (lid closed?)."
        case .streamFailure(let description): return description
        }
    }

    private func bodyForResume(_ reason: RecordingInterruptionReason) -> String {
        switch reason {
        case .screenLock: return "screen unlock."
        case .systemSleep: return "system wake."
        case .audioDeviceLost: return "microphone reconnect."
        case .displayUnavailable: return "display reconnect."
        case .streamFailure: return "stream recovery."
        }
    }
}
