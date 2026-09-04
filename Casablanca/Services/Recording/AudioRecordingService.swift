import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class AudioRecordingService {
    static let systemDefaultDevicePreferenceID = AppPreferenceValue.systemDefaultRecordingInputDevice

    private(set) var isRecording = false
    private(set) var isPreparing = false
    private(set) var activeMeetingID: UUID?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var audioLevel: Double = 0
    private(set) var outputURL: URL?
    private(set) var errorMessage: String?
    private(set) var availableInputDevices: [AudioInputDevice] = []
    private(set) var selectedInputDeviceID = ""
    private(set) var isSystemAudioEnabled = true

    private var session: RecordingSessionControlling?
    private var timerTask: Task<Void, Never>?
    /// The single finalize in flight for the live session, keyed by that
    /// session's identity. Pause, Stop and the interruption handler all funnel
    /// through it: whoever gets there first owns `session.stop()` and everyone
    /// else awaits the same result. Without it, Stop arriving while an
    /// interrupt was suspended inside `stop()` got `.sessionAlreadyStopped`
    /// back and ran on to merge and delete the session *before* the in-flight
    /// finalize could append its segment — a short recording plus deleted audio.
    private var pendingFinalize: (sessionID: ObjectIdentifier, task: Task<RecordingResult, Error>)?

    private let sessionStore: RecordingResumeSessionStore
    private let makeRecordingSession: RecordingSessionFactory
    private let makeFinalOutputURL: (Meeting) throws -> URL
    private let mergeSegments: ([URL], URL) throws -> TimeInterval

    /// Held for as long as a segment is actually capturing. Without it the Mac
    /// idle-sleeps mid-recording once the display sleeps — macOS drops
    /// coreaudiod's own assertion at that point — which is how a 75-minute
    /// recording was lost.
    private let sleepPreventer: SleepPreventing
    private var sleepAssertion: SleepPreventionToken?
    private static let sleepPreventionReason = "Casablanca is recording a meeting"

    /// How long to wait before each retry of a *resumed* segment's
    /// `session.start()`. Right after the Mac wakes, CoreAudio is regularly not
    /// ready yet and the first `AVAudioEngine.start()` throws, which made the
    /// auto-resume fail once and leave the meeting paused. Empty disables the
    /// retry; `attempts == 1 + startRetryDelays.count`.
    private let startRetryDelays: [Duration]
    /// The backoff wait, injectable so the retry tests are deterministic
    /// instead of seven seconds long.
    private let sleep: @Sendable (Duration) async -> Void

    weak var interruptionMonitor: RecordingInterruptionMonitor?

    /// Invoked (non-fatally) when a recording started or resumed but system-audio
    /// capture was unavailable, so it fell back to microphone-only. Wired by the
    /// app to a notification — NOT to `errorMessage`, which drives a modal that
    /// would interrupt the recording. Remote meeting audio comes through system
    /// audio, so the user should know it is missing, but the recording continues.
    var onSystemAudioUnavailable: ((String) -> Void)?

    init(
        sessionStore: RecordingResumeSessionStore = RecordingResumeSessionStore(),
        makeRecordingSession: @escaping RecordingSessionFactory = AudioRecordingService.defaultSessionFactory,
        makeFinalOutputURL: @escaping (Meeting) throws -> URL = AudioRecordingService.defaultFinalOutputURL,
        mergeSegments: @escaping ([URL], URL) throws -> TimeInterval = RecordingSegmentMerger.merge,
        sleepPreventer: SleepPreventing = ProcessInfoSleepPreventer(),
        startRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.sessionStore = sessionStore
        self.makeRecordingSession = makeRecordingSession
        self.makeFinalOutputURL = makeFinalOutputURL
        self.mergeSegments = mergeSegments
        self.sleepPreventer = sleepPreventer
        self.startRetryDelays = startRetryDelays
        self.sleep = sleep
        refreshInputDevices(forcePreferredSelection: true)
    }

    // MARK: - Lifecycle

    func startRecording(for meeting: Meeting) async throws {
        guard session == nil else {
            throw RecordingError.activeRecordingExists
        }

        isPreparing = true
        errorMessage = nil
        audioLevel = 0
        elapsedTime = 0

        do {
            refreshInputDevices()
            let persisted = try sessionStore.loadSession(for: meeting.id)

            // Starting on top of a session that already captured segments is a
            // resume, not a fresh start. Treating it as a start recorded into
            // `segment-001.wav` again and overwrote finished audio — that is how
            // a 75-minute recording was lost.
            if let persisted, !persisted.segments.isEmpty {
                Log.recording.notice(
                    """
                    startRecording for meeting \(meeting.id.uuidString, privacy: .public) found \
                    \(persisted.segments.count, privacy: .public) existing segment(s); resuming instead of restarting
                    """
                )
                return try await resumeRecording(for: meeting)
            }

            if persisted == nil {
                _ = try sessionStore.createSession(
                    for: meeting.id,
                    systemAudioEnabled: isSystemAudioEnabled,
                    selectedInputDeviceID: selectedInputDeviceID
                )
            }

            // Reserve, then build/start immediately: constructing the session
            // creates the raw `.pcm` files that make the number taken.
            let segmentURL = try sessionStore.reserveNextSegmentURL(for: meeting.id)
            try FileManager.default.createDirectory(at: segmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let session = try buildSession(
                outputURL: segmentURL,
                meeting: meeting,
                selectedInputDeviceID: selectedInputDeviceID,
                systemAudioEnabled: isSystemAudioEnabled
            )
            try await session.start()

            self.session = session
            beginSleepPrevention()
            activeMeetingID = meeting.id
            outputURL = session.outputURL
            isRecording = true
            isPreparing = false
            startTimer(from: session.startedAt)
            interruptionMonitor?.setActiveInputDevice(selectedInputDeviceID)
            surfaceSystemAudioFallbackIfNeeded(session)
            Log.recording.notice(
                "Recording started for meeting \(meeting.id.uuidString, privacy: .public) into \(segmentURL.path, privacy: .public)"
            )
        } catch {
            errorMessage = error.localizedDescription
            isPreparing = false
            session = nil
            endSleepPrevention()
            activeMeetingID = nil
            outputURL = nil
            throw error
        }
    }

    func pauseRecording() async throws -> RecordingResult {
        guard let session, let activeMeetingID else {
            throw RecordingError.noActiveRecording
        }

        let meetingID = activeMeetingID
        let result = try await finalizeActiveSegment(session: session, meetingID: meetingID, dropIfEmpty: false)
        clearActiveSessionState()
        Log.recording.notice(
            """
            Recording paused for meeting \(meetingID.uuidString, privacy: .public) at \
            \(result.outputURL.path, privacy: .public) after \(result.duration, privacy: .public)s
            """
        )
        // Show the cumulative recorded time (all segments), so the paused display
        // matches where the timer resumes from.
        elapsedTime = accumulatedSegmentDuration(for: meetingID)
        return result
    }

    func resumeRecording(for meeting: Meeting) async throws {
        guard session == nil else {
            throw RecordingError.activeRecordingExists
        }
        guard let persisted = try sessionStore.loadSession(for: meeting.id) else {
            throw RecordingError.noActiveRecording
        }

        isPreparing = true
        errorMessage = nil

        do {
            // The manifest counter alone is not enough: it can point at a
            // number whose WAV or raw PCM is still on disk (a crash mid-segment,
            // a manifest write that never landed). Reserving probes the
            // directory so a resume can never record over existing audio.
            let segmentURL = try sessionStore.reserveNextSegmentURL(for: meeting.id)
            try FileManager.default.createDirectory(at: segmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Resuming is the wake path, so this start is retried; a manual
            // start above deliberately still fails fast.
            let session = try await startWithRetry(meetingID: meeting.id) {
                try buildSession(
                    outputURL: segmentURL,
                    meeting: meeting,
                    selectedInputDeviceID: persisted.selectedInputDeviceID,
                    systemAudioEnabled: persisted.systemAudioEnabled
                )
            }

            // The entry `guard session == nil` ran before the retry loop, and
            // the attempt that finally worked has its own suspension point, so
            // re-assert the precondition before publishing. A Stop landing in
            // there merges and deletes the manifest; publishing on top of that
            // would hand a live session, a running timer and an idle-sleep
            // assertion to a meeting already in `.processing`, and the next Stop
            // would fail with `sessionNotFound` — orphaning the segment while
            // the Mac stays awake.
            try await discardStartedSessionIfNoLongerPublishable(session, meetingID: meeting.id)

            self.session = session
            beginSleepPrevention()
            activeMeetingID = meeting.id
            outputURL = segmentURL
            isRecording = true
            isPreparing = false
            // Continue the timer from the total already recorded in earlier
            // segments so resuming doesn't reset the display to 00:00.
            startTimer(from: session.startedAt, baseElapsed: persisted.segments.reduce(0) { $0 + $1.duration })
            interruptionMonitor?.setActiveInputDevice(persisted.selectedInputDeviceID ?? selectedInputDeviceID)
            surfaceSystemAudioFallbackIfNeeded(session)
            Log.recording.notice(
                "Recording resumed for meeting \(meeting.id.uuidString, privacy: .public) into \(segmentURL.path, privacy: .public)"
            )
        } catch {
            // A cancelled resume is the user pressing Stop, not a failure:
            // `errorMessage` drives a modal, and throwing one at someone who
            // just stopped the recording would be nonsense. The teardown below
            // still runs.
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
            isPreparing = false
            session = nil
            endSleepPrevention()
            activeMeetingID = nil
            outputURL = nil
            throw error
        }
    }

    func stopRecording(for meeting: Meeting) async throws -> RecordingResult {
        if let liveSession = session, activeMeetingID == meeting.id {
            defer { clearActiveSessionState() }
            _ = try await finalizeActiveSegment(
                session: liveSession,
                meetingID: meeting.id,
                dropIfEmpty: true,
                // Everything below this line merges and then deletes the
                // session, so a segment whose finalize belongs to someone else
                // must abort the stop rather than be merged around.
                alreadyStopped: .refuse
            )
        }

        guard let persisted = try sessionStore.loadSession(for: meeting.id) else {
            throw RecordingError.noActiveRecording
        }

        let segmentURLs = persisted.segments.map { URL(fileURLWithPath: $0.filePath) }
        guard !segmentURLs.isEmpty else {
            // An empty manifest is NOT proof that nothing was captured: raw
            // `.pcm` from an interrupted segment is audio the manifest never
            // heard about. Deleting unconditionally here destroyed a whole
            // recording, so the store decides and keeps anything recoverable.
            Log.recording.error(
                "Stop for meeting \(meeting.id.uuidString, privacy: .public) found no manifest segments; keeping any recoverable audio"
            )
            bestEffort("delete empty recording session", Log.recording) {
                try sessionStore.deleteSessionIfEmpty(for: meeting.id)
            }
            throw RecordingError.noCapturedAudio
        }

        let finalURL = try makeFinalOutputURL(meeting)
        let duration = try mergeSegments(segmentURLs, finalURL)
        try sessionStore.deleteSession(for: meeting.id)

        outputURL = finalURL
        elapsedTime = duration
        interruptionMonitor?.setActiveInputDevice(nil)
        Log.recording.notice(
            """
            Recording stopped for meeting \(meeting.id.uuidString, privacy: .public): merged \
            \(segmentURLs.count, privacy: .public) segment(s) into \(finalURL.path, privacy: .public) (\(duration, privacy: .public)s)
            """
        )
        return RecordingResult(outputURL: finalURL, duration: duration)
    }

    func handleSystemInterrupt(reason: RecordingInterruptionReason) async -> InterruptOutcome {
        guard let session, let activeMeetingID else { return .nothingRecording }

        // Release the service however the finalize goes. Clearing only on the
        // happy path left `self.session` set after a failed stop, so every
        // later start/resume hit `.activeRecordingExists` while the captured
        // audio sat unreachable on disk.
        defer { clearActiveSessionState() }

        let reasonDescription = String(describing: reason)
        do {
            let result = try await finalizeActiveSegment(session: session, meetingID: activeMeetingID, dropIfEmpty: true)
            Log.recording.notice(
                """
                Recording interrupted (\(reasonDescription, privacy: .public)) for meeting \
                \(activeMeetingID.uuidString, privacy: .public); finalized \(result.outputURL.path, privacy: .public) \
                after \(result.duration, privacy: .public)s
                """
            )
            return .segmentFinalized(duration: result.duration)
        } catch {
            errorMessage = error.localizedDescription
            Log.recording.error(
                """
                Recording interrupted (\(reasonDescription, privacy: .public)) for meeting \
                \(activeMeetingID.uuidString, privacy: .public); finalize failed: \
                \(error.localizedDescription, privacy: .public) — captured audio left on disk for recovery
                """
            )
            return .finalizeFailed(error.localizedDescription)
        }
    }

    func clearError() { errorMessage = nil }

    func setErrorMessage(_ message: String) { errorMessage = message }

    /// A meeting is resumable when its manifest survived *or* audio is still
    /// on disk for it. The manifest alone is too strict: a write that never
    /// landed (crash, full disk) would make recoverable audio look gone and let
    /// the UI demote the meeting to notes-only.
    func hasResumableSession(for meetingID: UUID) -> Bool {
        if (try? sessionStore.loadSession(for: meetingID)) != nil {
            return true
        }
        return sessionStore.hasRecoverableAudio(for: meetingID)
    }

    /// Puts the total already recorded for a paused meeting back on the elapsed
    /// display. Nothing ticks the timer across an app relaunch, so a paused
    /// recording showed 00:00 — which reads as "my recording is gone" and is
    /// exactly the moment the user reaches for Resume. Leaves `elapsedTime`
    /// untouched when there is no manifest to read: an unknown total must not
    /// overwrite a live one with zero.
    func refreshElapsed(for meetingID: UUID) {
        guard (try? sessionStore.loadSession(for: meetingID)) != nil else { return }

        let total = accumulatedSegmentDuration(for: meetingID)
        elapsedTime = total
        Log.recording.notice(
            "Elapsed display refreshed for meeting \(meetingID.uuidString, privacy: .public) to \(total, privacy: .public)s"
        )
    }

    func forwardStreamFailure(_ error: Error) {
        interruptionMonitor?.reportStreamFailure(error)
    }

    // MARK: - Existing input-device APIs (unchanged behavior)

    func refreshInputDevices(forcePreferredSelection: Bool = false) {
        let devices = Self.fetchInputDevices()
        availableInputDevices = devices

        if forcePreferredSelection {
            selectedInputDeviceID = Self.preferredInputDeviceID(in: devices) ?? devices.first?.id ?? ""
            return
        }

        if let selected = devices.first(where: { $0.id == selectedInputDeviceID }) {
            selectedInputDeviceID = selected.id
            return
        }

        selectedInputDeviceID = Self.preferredInputDeviceID(in: devices) ?? devices.first?.id ?? ""
    }

    func selectInputDevice(_ deviceID: String) async {
        guard let device = availableInputDevices.first(where: { $0.id == deviceID }) else { return }
        do {
            try session?.setMicrophoneDevice(device.deviceID)
            selectedInputDeviceID = device.id
            interruptionMonitor?.setActiveInputDevice(device.id)
        } catch {
            errorMessage = error.localizedDescription
            refreshInputDevices()
        }
    }

    func toggleSystemAudioEnabled() {
        isSystemAudioEnabled.toggle()
        session?.setSystemAudioEnabled(isSystemAudioEnabled)
    }

    static func availableRecordingInputDevices() -> [AudioInputDevice] {
        fetchInputDevices()
    }

    static func systemDefaultInputDeviceName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return deviceName(deviceID)
    }

    // MARK: - Defaults & helpers

    static func defaultSessionFactory(
        outputURL: URL,
        meeting: Meeting,
        inputDeviceID: AudioDeviceID?,
        systemAudioEnabled: Bool,
        onLevelUpdate: @escaping (Double) -> Void,
        onFailure: @escaping (Error) -> Void,
        onStreamFatal: @escaping (Error) -> Void
    ) throws -> RecordingSessionControlling {
        try RecordingSession(
            outputURL: outputURL,
            meeting: meeting,
            inputDeviceID: inputDeviceID,
            systemAudioEnabled: systemAudioEnabled,
            onLevelUpdate: onLevelUpdate,
            onFailure: onFailure,
            onStreamFatal: onStreamFatal
        )
    }

    static func defaultFinalOutputURL(for meeting: Meeting) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("Casablanca", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let timestamp = formatter.string(from: Date())
        return directory.appendingPathComponent("\(meeting.sanitizedTitle) \(timestamp).wav")
    }

    /// Builds and starts a resumed segment, retrying with backoff while
    /// CoreAudio comes back after a wake. Only the resume path uses it: a manual
    /// start must surface its failure immediately rather than spin for seconds.
    ///
    /// Each attempt builds a *fresh* session through the factory rather than
    /// re-calling `start()` on the failed one: `RecordingSession.startedAt` is
    /// fixed at init (a reused session would bill the backoff wait as recorded
    /// audio) and its `configure()` is not idempotent — a second call would
    /// replace the writers and the capture unit while orphaning the first
    /// attempt's engine and file handles. Rebuilding on the same reserved
    /// segment URL is safe because the writers create their temp `.pcm` files
    /// with `FileManager.createFile`, which truncates the empty ones the failed
    /// attempt left behind.
    ///
    /// Nothing is published until an attempt succeeds, so `session` stays nil
    /// across failed attempts and a concurrent Stop can never see a half-built
    /// session; the sleep assertion is taken by the caller afterwards.
    private func startWithRetry(
        meetingID: UUID,
        makeSession: () throws -> RecordingSessionControlling
    ) async throws -> RecordingSessionControlling {
        let totalAttempts = 1 + startRetryDelays.count
        var attempt = 1

        while true {
            // Top of the iteration, so this covers both the first attempt and
            // every wake from a backoff wait. A Stop cancels the coordinator's
            // resume task (`clearInterruptionBookkeeping`) while we may be
            // sitting in that wait, and the default `sleep`
            // (`try? await Task.sleep`) swallows the cancellation — without
            // this, the remaining attempts ran back-to-back and one of them
            // could start a segment for a meeting the user had already stopped.
            try Task.checkCancellation()

            do {
                let session = try makeSession()
                try await session.start()
                if attempt > 1 {
                    Log.recording.notice(
                        """
                        Audio engine start for meeting \(meetingID.uuidString, privacy: .public) succeeded on \
                        attempt \(attempt, privacy: .public) of \(totalAttempts, privacy: .public)
                        """
                    )
                }
                return session
            } catch {
                guard attempt < totalAttempts else {
                    Log.recording.error(
                        """
                        Audio engine start for meeting \(meetingID.uuidString, privacy: .public) failed on all \
                        \(totalAttempts, privacy: .public) attempt(s): \(error.localizedDescription, privacy: .public)
                        """
                    )
                    throw error
                }
                let delay = startRetryDelays[attempt - 1]
                Log.recording.notice(
                    """
                    Audio engine start for meeting \(meetingID.uuidString, privacy: .public) failed on attempt \
                    \(attempt, privacy: .public) of \(totalAttempts, privacy: .public) \
                    (\(error.localizedDescription, privacy: .public)); retrying in \
                    \(delay.timeInterval, privacy: .public)s
                    """
                )
                await sleep(delay)
                attempt += 1
            }
        }
    }

    /// Tears a just-started segment down instead of publishing it when the
    /// resume it belongs to has been cancelled or overtaken. Safe to stop
    /// unconditionally: `start()` has only just returned, so the segment has no
    /// frames and `RecordingSession.stop()` removes its own provably empty files
    /// (reporting `.noCapturedAudio`, which is the expected outcome here — hence
    /// `try?`).
    private func discardStartedSessionIfNoLongerPublishable(
        _ session: RecordingSessionControlling,
        meetingID: UUID
    ) async throws {
        let overtaken = self.session != nil
        guard overtaken || Task.isCancelled else { return }

        _ = try? await session.stop()
        Log.recording.error(
            """
            Resume for meeting \(meetingID.uuidString, privacy: .public) started a segment but was \
            \(overtaken ? "overtaken by another session" : "cancelled", privacy: .public); \
            tore it down instead of publishing it
            """
        )
        if overtaken {
            throw RecordingError.activeRecordingExists
        }
        throw CancellationError()
    }

    private func buildSession(
        outputURL: URL,
        meeting: Meeting,
        selectedInputDeviceID: String?,
        systemAudioEnabled: Bool
    ) throws -> RecordingSessionControlling {
        let effectiveInputDeviceID = selectedInputDeviceID ?? self.selectedInputDeviceID
        let audioDeviceID = availableInputDevices.first(where: { $0.id == effectiveInputDeviceID })?.deviceID
        return try makeRecordingSession(
            outputURL,
            meeting,
            audioDeviceID,
            systemAudioEnabled,
            { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.audioLevel = level
                }
            },
            { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            },
            { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.forwardStreamFailure(error)
                }
            }
        )
    }

    /// What a finalize does when `stop()` reports that the segment's finalize
    /// is owned by someone else.
    private enum AlreadyStoppedPolicy {
        /// Return a zero-duration result: nothing to append, nothing to delete.
        /// Safe for pause and interrupt, which touch nothing but the manifest.
        case tolerate
        /// Rethrow. Stop must never merge or delete a session while another
        /// finalize may still be appending a segment to it.
        case refuse
    }

    /// Finalizes the live segment exactly once, however many callers ask.
    ///
    /// The first caller owns the finalize; a caller that arrives while it is
    /// still in flight awaits that same task instead of calling `stop()` again.
    /// A joiner therefore inherits the owner's `dropIfEmpty`/`alreadyStopped`
    /// handling — which is the point: one `stop()`, one append, one result, and
    /// no caller can run ahead of the append that is already underway.
    private func finalizeActiveSegment(
        session: RecordingSessionControlling,
        meetingID: UUID,
        dropIfEmpty: Bool,
        alreadyStopped: AlreadyStoppedPolicy = .tolerate
    ) async throws -> RecordingResult {
        let sessionID = ObjectIdentifier(session)

        if let pendingFinalize, pendingFinalize.sessionID == sessionID {
            Log.recording.notice(
                """
                Joining the finalize already in flight for meeting \
                \(meetingID.uuidString, privacy: .public) instead of stopping the session twice
                """
            )
            return try await pendingFinalize.task.value
        }

        let finalize = Task<RecordingResult, Error> {
            try await self.performFinalize(
                session: session,
                meetingID: meetingID,
                dropIfEmpty: dropIfEmpty,
                alreadyStopped: alreadyStopped
            )
        }
        pendingFinalize = (sessionID, finalize)
        defer {
            if pendingFinalize?.task == finalize {
                pendingFinalize = nil
            }
        }
        return try await finalize.value
    }

    /// The finalize itself. Only ever reached through `finalizeActiveSegment`,
    /// which guarantees one call per session.
    ///
    /// Deletes nothing, ever. The only component allowed to remove capture
    /// files is `RecordingSession.stop()`, which does so only after proving
    /// both tracks empty (0 frames *and* 0 bytes). This method used to remove
    /// `result.outputURL` whenever `hasCapturedFrames` read false — a counter a
    /// previous finalize had already released — which deleted a 75-minute
    /// recording that was fully on disk.
    private func performFinalize(
        session: RecordingSessionControlling,
        meetingID: UUID,
        dropIfEmpty: Bool,
        alreadyStopped: AlreadyStoppedPolicy
    ) async throws -> RecordingResult {
        let result: RecordingResult
        do {
            result = try await session.stop()
        } catch RecordingError.noCapturedAudio {
            // The session proved the segment empty and removed its own files.
            // Nothing to append, nothing left to clean up — and not an error
            // worth surfacing: a silent segment is not a failed recording.
            Log.recording.notice(
                """
                Segment \(session.outputURL.path, privacy: .public) for meeting \
                \(meetingID.uuidString, privacy: .public) captured no audio; nothing to append
                """
            )
            return RecordingResult(outputURL: session.outputURL, duration: 0)
        } catch RecordingError.sessionAlreadyStopped {
            // A finalize outside this service's serialization owns the segment
            // and either appended it or is about to. Appending again would
            // duplicate it; deleting anything would destroy audio the owner
            // just wrote.
            switch alreadyStopped {
            case .tolerate:
                Log.recording.notice(
                    """
                    Segment \(session.outputURL.path, privacy: .public) for meeting \
                    \(meetingID.uuidString, privacy: .public) was already finalized; leaving it to the owning stop()
                    """
                )
                return RecordingResult(outputURL: session.outputURL, duration: 0)
            case .refuse:
                Log.recording.error(
                    """
                    Segment \(session.outputURL.path, privacy: .public) for meeting \
                    \(meetingID.uuidString, privacy: .public) is being finalized elsewhere; refusing to merge or \
                    delete the session while that segment may still be appended
                    """
                )
                throw RecordingError.sessionAlreadyStopped
            }
        } catch {
            Log.recording.error(
                """
                Finalizing segment \(session.outputURL.path, privacy: .public) for meeting \
                \(meetingID.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public) \
                — every file is left on disk for recovery
                """
            )
            throw error
        }

        if dropIfEmpty && !session.hasCapturedFrames {
            // Not appended (a frameless segment merges as silence at best), but
            // the file stays: only the session may call a segment empty.
            Log.recording.notice(
                """
                Segment \(result.outputURL.path, privacy: .public) for meeting \
                \(meetingID.uuidString, privacy: .public) reported no frames; keeping the file, not appending it
                """
            )
            return RecordingResult(outputURL: result.outputURL, duration: 0)
        }

        _ = try sessionStore.appendSegment(
            for: meetingID,
            segmentURL: result.outputURL,
            duration: result.duration
        )
        return result
    }

    /// Silent backstop for the no-display case. The visible behavior is now an
    /// auto-pause driven by `RecordingInterruptionMonitor.displayUnavailable`;
    /// this only fires in the narrow race where `start()`/`resume()` runs during
    /// a brief no-display gap before the monitor pauses, in which case the
    /// recording continues microphone-only for that short window. `onSystemAudioUnavailable`
    /// is intentionally left unwired in production (the pause owns the UX); it
    /// stays here as a seam for tests and any future non-modal surfacing. Never
    /// sets `errorMessage` — that drives a modal that would derail recording.
    private func surfaceSystemAudioFallbackIfNeeded(_ session: RecordingSessionControlling) {
        guard session.systemAudioUnavailableError != nil else { return }
        onSystemAudioUnavailable?(
            "System audio couldn’t be captured (no available display — is the lid closed?). Recording continues with the microphone only."
        )
    }

    /// Takes the idle-sleep assertion for the segment that just started.
    /// Never stacks a second one: an assertion still held from an earlier
    /// segment would be released only by its token's `deinit`.
    private func beginSleepPrevention() {
        guard sleepAssertion == nil else { return }
        sleepAssertion = sleepPreventer.begin(reason: Self.sleepPreventionReason)
        Log.recording.notice(
            "Holding an idle-sleep assertion: \(Self.sleepPreventionReason, privacy: .public)"
        )
    }

    /// Releases it. Idempotent, because every teardown path (pause, stop,
    /// interrupt, a failed start) funnels through here and more than one of
    /// them can run for the same session.
    private func endSleepPrevention() {
        guard let sleepAssertion else { return }
        self.sleepAssertion = nil
        sleepAssertion.end()
        Log.recording.notice(
            "Released the idle-sleep assertion: \(Self.sleepPreventionReason, privacy: .public)"
        )
    }

    private func clearActiveSessionState() {
        self.session = nil
        endSleepPrevention()
        isRecording = false
        isPreparing = false
        activeMeetingID = nil
        timerTask?.cancel()
        timerTask = nil
        audioLevel = 0
    }

    /// Drives the elapsed-time display. `baseElapsed` carries the cumulative
    /// duration already recorded in earlier segments so the timer continues from
    /// the total when a paused recording resumes, instead of restarting at 00:00
    /// for the new segment. Set synchronously up front so the display is correct
    /// immediately, then ticked each second.
    private func startTimer(from startDate: Date, baseElapsed: TimeInterval = 0) {
        timerTask?.cancel()
        elapsedTime = baseElapsed + Date().timeIntervalSince(startDate)
        timerTask = Task {
            while !Task.isCancelled {
                elapsedTime = baseElapsed + Date().timeIntervalSince(startDate)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Total duration already captured in finalized segments for a meeting — the
    /// recorded time before the current/next segment.
    private func accumulatedSegmentDuration(for meetingID: UUID) -> TimeInterval {
        guard let persisted = try? sessionStore.loadSession(for: meetingID) else { return 0 }
        return persisted.segments.reduce(0) { $0 + $1.duration }
    }
}
