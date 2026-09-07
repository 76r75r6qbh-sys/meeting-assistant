import Foundation

/// What an interrupt actually did to the recording. The coordinator needs the
/// distinction: an interrupt that found nothing recording (a sleep while a
/// notes-only workspace is open) must not persist `.pausedRecording`, because
/// that later reads back as a paused recording that can no longer be resumed.
///
/// The meeting ID travels WITH the outcome because the coordinator must act on
/// the meeting that was recording, which is not necessarily the one on screen:
/// the user can navigate to the dashboard or to another meeting before the Mac
/// sleeps, and the recording keeps running. Reading the bound meeting instead
/// left the recording meeting stuck `.recording` in SwiftData and made the wake
/// try to resume the wrong one ("Could not resume recording").
enum InterruptOutcome: Equatable {
    case nothingRecording
    case segmentFinalized(meetingID: UUID, duration: TimeInterval)
    case finalizeFailed(meetingID: UUID, String)

    /// The meeting the interrupt acted on, or nil when it acted on nothing.
    var meetingID: UUID? {
        switch self {
        case .nothingRecording: return nil
        case .segmentFinalized(let meetingID, _): return meetingID
        case .finalizeFailed(let meetingID, _): return meetingID
        }
    }
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
    /// `true` when the login session locks, `false` when it unlocks. A lock is
    /// not an interruption (the recording keeps running behind the lock screen);
    /// the unlock is what matters here, as the moment the user is demonstrably
    /// back and a failed auto-resume is worth one more try.
    var onSessionLockChanged: ((Bool) -> Void)? { get set }
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
    /// Finds a meeting by id — wired to the app's model context. The
    /// coordinator has to be able to act on the RECORDING meeting even when the
    /// user has navigated away from it, and the bound meeting is then the wrong
    /// one (or nil). Defaults to "not found", which reduces to the bound
    /// meeting only.
    private let lookupMeeting: (UUID) -> Meeting?
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
    /// The meeting the interrupt actually paused, as the SERVICE reported it.
    /// The wake resumes this one — not whatever happens to be on screen, which
    /// after a navigation is another meeting or none at all.
    private var pausedMeetingID: UUID?
    private var startedAt: Date?
    /// Whether any reason in this window forbids auto-resume outright
    /// (`allowsAutoResume == false`). That is its only meaning: how long a
    /// resume stays allowed is decided when the window ends, by
    /// `SleepResumePolicy` or by the window-bound elapsed check — never by a
    /// timer, which used to expire mid-sleep and veto both.
    private var resumeAllowedForActiveWindow = true
    private var resumeTask: Task<Void, Never>?
    /// Invalidates an interrupt whose finalize is still in flight. The status
    /// flip waits for the service now, so a user Stop or a rebind can land in
    /// between — and writing `.pausedRecording` over a meeting the user just
    /// stopped strands a finished recording as unresumable.
    private var interruptGeneration = 0
    /// An auto-resume that threw, kept until the next unlock gets to retry it
    /// once. Cleared by `clearInterruptionBookkeeping`, so a Stop, a Discard or
    /// a rebind takes the retry with it.
    private var pendingResumeRetry: PendingResumeRetry?

    private struct PendingResumeRetry {
        let meetingID: UUID
        let reason: RecordingInterruptionReason
        /// When the interruption paused the recording, so the retry can be
        /// refused once the meeting itself is long over.
        let pausedAt: Date
    }

    init(
        service: RecordingInterruptionServicing,
        monitor: RecordingInterruptionEmitting,
        notifier: RecordingInterruptionNotifying,
        lookupMeeting: @escaping (UUID) -> Meeting? = { _ in nil },
        autoResumeWindow: TimeInterval = 30,
        now: @escaping () -> Date = Date.init,
        save: @escaping () -> Void = {}
    ) {
        self.service = service
        self.monitor = monitor
        self.notifier = notifier
        self.lookupMeeting = lookupMeeting
        self.autoResumeWindow = autoResumeWindow
        self.now = now
        self.save = save
        monitor.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
        monitor.onSessionLockChanged = { [weak self] locked in
            self?.handleSessionLockChanged(locked)
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

    /// The meeting an interruption applies to. `nil` id means "nothing recorded
    /// it yet", which falls back to the bound meeting; otherwise the bound
    /// meeting is a fast path and the app-wide lookup is the real answer.
    private func resolveMeeting(_ id: UUID?) -> Meeting? {
        guard let id else { return meeting }
        if let meeting, meeting.id == id { return meeting }
        return lookupMeeting(id)
    }

    private func clearInterruptionBookkeeping() {
        resumeTask?.cancel()
        resumeTask = nil
        activeReasons.removeAll()
        windowReasons.removeAll()
        lastInterruptOutcome = nil
        pausedMeetingID = nil
        pendingResumeRetry = nil
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
        // A new window supersedes whatever the previous one left behind: its
        // retry would be judged against a `pausedAt` that no longer describes
        // anything, and this window's own rules (a reason that forbids
        // auto-resume, say) must be the ones that decide.
        pendingResumeRetry = nil
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
            guard let interruptedMeetingID = outcome.meetingID else { return }

            // The meeting to pause is the one the SERVICE finalized, resolved
            // through the app-wide lookup when it is not the one on screen.
            // Reading the bound meeting instead dropped the whole outcome
            // whenever the user had navigated away before the sleep, leaving the
            // recording meeting `.recording` in SwiftData — and the wake then
            // tried to resume the wrong meeting.
            //
            // Everything the user could have done in the meantime — Stop,
            // Discard, switching meetings — bumps the generation, and only a
            // still-recording meeting can be paused. A stale outcome is
            // dropped: the pause it describes has already been superseded.
            guard generation == self.interruptGeneration,
                  let interruptedMeeting = self.resolveMeeting(interruptedMeetingID),
                  interruptedMeeting.status == .recording
            else {
                self.logDiscarded(outcome: outcome, reason: reason, meetingID: interruptedMeetingID)
                return
            }

            interruptedMeeting.status = .pausedRecording
            self.pausedMeetingID = interruptedMeetingID
            self.save()
            notifier?.post(title: "Recording paused", body: self.bodyForPause(reason, outcome: outcome))
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
        let pausedMeetingIDThisWindow = pausedMeetingID
        defer {
            startedAt = nil
            resumeAllowedForActiveWindow = true
            windowReasons.removeAll()
            lastInterruptOutcome = nil
            pausedMeetingID = nil
        }

        guard resumeAllowedForActiveWindow else { return }
        guard let startedAt else { return }

        // Nothing was paused (a sleep while a notes-only meeting is open), so
        // there is nothing to resume.
        guard outcomeThisWindow != .nothingRecording else {
            Log.recording.notice(
                """
                Not resuming meeting \(pausedMeetingIDThisWindow?.uuidString ?? "none", privacy: .public) after \
                \(String(describing: event.reason), privacy: .public): the interrupt found \
                nothing recording
                """
            )
            return
        }

        // The RECORDING meeting, which the user may have navigated away from
        // long before the sleep. `pausedMeetingID` is nil only when the pause
        // itself has not landed yet (a finalize still in flight), in which case
        // the bound meeting is still the best guess.
        guard let meeting = resolveMeeting(pausedMeetingIDThisWindow) else {
            Log.recording.notice(
                """
                Not resuming after \(String(describing: event.reason), privacy: .public): meeting \
                \(pausedMeetingIDThisWindow?.uuidString ?? "none", privacy: .public) could not be \
                found any more
                """
            )
            return
        }

        // The window as a whole decides: any sleep/lock reason in it earns the
        // meeting-slot policy, whichever reason happens to end last. A sleep
        // outranks a lock so the choice is deterministic when a lid close
        // raises both (the two share a policy, but the log must not vary).
        let governingReason: RecordingInterruptionReason = reasonsThisWindow.contains(.systemSleep)
            ? .systemSleep
            : reasonsThisWindow.first { !SleepResumePolicy.isWindowBound($0) } ?? event.reason
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

        dispatchResume(
            meeting: meeting,
            reasonForBody: event.reason,
            pausedAt: startedAt,
            recordIndex: recentEvents.indices.last,
            isRetry: false
        )
    }

    /// The session locking or unlocking. A lock never pauses — the recording's
    /// power assertion keeps capture alive behind the lock screen — so the only
    /// interesting edge is the unlock, which retries a failed auto-resume once.
    private func handleSessionLockChanged(_ locked: Bool) {
        // The monitor already logs the lock itself; nothing to add unless the
        // unlock has a retry to make.
        guard !locked else { return }
        retryFailedAutoResumeAfterUnlock()
    }

    /// One extra attempt at a resume that threw, taken when the user comes back.
    /// A wake often beats the display or the audio device to being ready; by the
    /// time the session unlocks, the thing that broke the first attempt has
    /// usually settled. Strictly one-shot: the token is consumed here whether or
    /// not this attempt succeeds, so an unlock loop can't hammer the service.
    private func retryFailedAutoResumeAfterUnlock() {
        guard let retry = pendingResumeRetry else { return }
        pendingResumeRetry = nil
        guard let meeting = resolveMeeting(retry.meetingID), meeting.status == .pausedRecording else {
            Log.recording.notice(
                """
                Not retrying the failed auto-resume for meeting \
                \(retry.meetingID.uuidString, privacy: .public) on unlock: it is no longer a \
                paused recording
                """
            )
            return
        }
        // An unlock says the user is back, not that the meeting still is: the
        // same deadline that governs a wake governs the retry, so a Mac unlocked
        // hours later doesn't restart a recording nobody is holding any more.
        let deadline = SleepResumePolicy.deadline(pausedAt: retry.pausedAt, meetingEnd: meeting.endDate)
        guard now() < deadline else {
            Log.recording.notice(
                """
                Not retrying the failed auto-resume for meeting \
                \(meeting.id.uuidString, privacy: .public) on unlock: the unlock is past the \
                resume deadline (\(deadline.timeIntervalSince1970, privacy: .public))
                """
            )
            return
        }
        Log.recording.notice(
            """
            Session unlocked: retrying the failed auto-resume for meeting \
            \(meeting.id.uuidString, privacy: .public) once
            """
        )
        dispatchResume(
            meeting: meeting,
            reasonForBody: retry.reason,
            pausedAt: retry.pausedAt,
            recordIndex: recentEvents.indices.last,
            isRetry: true
        )
    }

    private func dispatchResume(
        meeting capturedMeeting: Meeting,
        reasonForBody: RecordingInterruptionReason,
        pausedAt: Date,
        recordIndex recordIndexAtDispatch: Int?,
        isRetry: Bool
    ) {
        resumeTask = Task { @MainActor [weak self, service, notifier] in
            do {
                try await service?.resumeRecording(for: capturedMeeting)
                if let self {
                    self.pendingResumeRetry = nil
                    if let lastIdx = recordIndexAtDispatch, lastIdx < self.recentEvents.count {
                        self.recentEvents[lastIdx].resumedAutomatically = true
                    }
                    // The meeting that was resumed, whether or not it is the one
                    // on screen: it is the recording's own status, and leaving it
                    // `.pausedRecording` while capture ran again was how a
                    // resumed meeting still read as paused.
                    capturedMeeting.status = .recording
                    self.save()
                    notifier?.post(
                        title: "Recording resumed",
                        body: "Continued after \(self.bodyForResume(reasonForBody))"
                    )
                } else {
                    notifier?.post(title: "Recording resumed", body: "")
                }
            } catch {
                // The user pressing Stop cancels this task (via
                // `clearInterruptionBookkeeping`), and the resume then throws
                // `CancellationError`. That is the user getting exactly what
                // they asked for — toasting "Could not resume recording" over it
                // reads as a bug, so it is only logged.
                if error is CancellationError || Task.isCancelled {
                    Log.recording.notice(
                        """
                        Auto-resume for meeting \(capturedMeeting.id.uuidString, privacy: .public) was \
                        cancelled; the recording was stopped or the meeting unbound
                        """
                    )
                    return
                }
                // One retry, at the next unlock. A retry that fails again does
                // not arm another (its token was consumed on dispatch).
                if !isRetry {
                    self?.pendingResumeRetry = PendingResumeRetry(
                        meetingID: capturedMeeting.id,
                        reason: reasonForBody,
                        pausedAt: pausedAt
                    )
                }
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
        case .segmentFinalized(_, let duration):
            Log.recording.notice(
                """
                Interruption (\(reasonDescription, privacy: .public)) paused meeting \
                \(meetingDescription, privacy: .public) after finalizing \(duration, privacy: .public)s
                """
            )
        case .finalizeFailed(_, let message):
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
        guard case .finalizeFailed(_, let message) = outcome else { return cause }
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
