import Foundation

/// Turns the raw "Teams is running microphone input" signal into call
/// start/end transitions. Pure value type with the clock passed in, so every
/// timing rule is unit-testable.
///
/// - Started: input has run continuously for `startThreshold`. Teams opens the
///   microphone briefly for the pre-join preview and device checks; those blips
///   must not start a recording.
/// - Ended: neither input nor output for `endThreshold`. Holds, device
///   switches and a reconnect drop audio for a few seconds mid-call; those must
///   not stop one. Output counts only once a call is running: the remote
///   stream keeps it going while the user is muted (Teams may release the
///   microphone then), but a notification sound or a video must never START a
///   call.
struct TeamsCallDebouncer: Equatable {
    enum Transition: Equatable {
        case callStarted
        case callEnded
    }

    static let defaultStartThreshold: TimeInterval = 5
    static let defaultEndThreshold: TimeInterval = 20

    let startThreshold: TimeInterval
    let endThreshold: TimeInterval

    private(set) var isInCall = false
    /// Start of the current unbroken stretch of input, while not yet in a call.
    private var activeSince: Date?
    /// Start of the current stretch without input or output, while in a call.
    private var inactiveSince: Date?

    init(
        startThreshold: TimeInterval = TeamsCallDebouncer.defaultStartThreshold,
        endThreshold: TimeInterval = TeamsCallDebouncer.defaultEndThreshold
    ) {
        self.startThreshold = startThreshold
        self.endThreshold = endThreshold
    }

    /// Feeds one observation. Returns a transition at most once per edge.
    mutating func update(isInputActive: Bool, isOutputActive: Bool = false, at now: Date) -> Transition? {
        if isInCall, isOutputActive {
            inactiveSince = nil
            return nil
        }
        if isInputActive {
            inactiveSince = nil
            guard !isInCall else { return nil }
            let since = activeSince ?? now
            activeSince = since
            guard now.timeIntervalSince(since) >= startThreshold else { return nil }
            isInCall = true
            activeSince = nil
            return .callStarted
        }

        activeSince = nil
        guard isInCall else { return nil }
        let since = inactiveSince ?? now
        inactiveSince = since
        guard now.timeIntervalSince(since) >= endThreshold else { return nil }
        isInCall = false
        inactiveSince = nil
        return .callEnded
    }

    /// When a transition becomes due if the input stays as it is now — the
    /// monitor re-evaluates then, since an unchanged signal produces no
    /// CoreAudio callback to wake it. `nil` while nothing is pending.
    var nextDeadline: Date? {
        if !isInCall, let activeSince { return activeSince.addingTimeInterval(startThreshold) }
        if isInCall, let inactiveSince { return inactiveSince.addingTimeInterval(endThreshold) }
        return nil
    }

    mutating func reset() {
        self = TeamsCallDebouncer(startThreshold: startThreshold, endThreshold: endThreshold)
    }
}

/// Watches for Microsoft Teams calls and reports debounced start/end edges.
///
/// Three wake-ups feed the debouncer: CoreAudio change callbacks (the fast
/// path), a timer at the debouncer's next deadline (an unchanged signal fires
/// no callback), and a low-frequency safety poll for a listener that never
/// fires — a helper process that started between list syncs, a coreaudiod
/// restart. Every wake-up re-reads the source; none trusts the callback.
@MainActor
final class TeamsCallMonitor {
    static let defaultPollInterval: Duration = .seconds(5)

    var onCallStarted: (@MainActor () -> Void)?
    var onCallEnded: (@MainActor () -> Void)?
    /// Called on every evaluation while a call is in progress (after any
    /// `onCallStarted`), so a recording that starts or resumes mid-call can be
    /// tied to it within one poll interval.
    var onCallTick: (@MainActor () -> Void)?

    private let source: TeamsAudioActivitySource
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private let pollInterval: Duration
    private var debouncer: TeamsCallDebouncer
    private var pollTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private(set) var isRunning = false

    init(
        source: TeamsAudioActivitySource,
        debouncer: TeamsCallDebouncer = TeamsCallDebouncer(),
        pollInterval: Duration = TeamsCallMonitor.defaultPollInterval,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.debouncer = debouncer
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
    }

    var isSupported: Bool { source.isSupported }
    var isInCall: Bool { debouncer.isInCall }

    /// Idempotent. A no-op where the HAL cannot report process activity.
    func start() {
        guard !isRunning else { return }
        guard source.isSupported else {
            Log.recording.notice("Teams monitor: per-process audio activity unavailable on this macOS; not starting")
            return
        }
        isRunning = true
        source.startObserving { [weak self] in self?.evaluate() }
        let interval = pollInterval
        let sleep = self.sleep
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled else { return }
                self?.evaluate()
            }
        }
        Log.recording.notice("Teams monitor started")
        evaluate()
    }

    /// Stops watching and forgets any call in progress without reporting an
    /// end: turning the feature off is not the call ending.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        source.stopObserving()
        pollTask?.cancel()
        pollTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        debouncer.reset()
        Log.recording.notice("Teams monitor stopped")
    }

    /// Reads the source once and advances the debouncer. Internal so tests can
    /// drive it with a hand-moved clock.
    func evaluate() {
        guard isRunning else { return }
        let transition = debouncer.update(
            isInputActive: source.isTeamsInputRunning(),
            isOutputActive: source.isTeamsOutputRunning(),
            at: now()
        )
        scheduleDeadline()
        switch transition {
        case .callStarted:
            Log.recording.notice("Teams monitor: call started (microphone input running)")
            onCallStarted?()
        case .callEnded:
            Log.recording.notice("Teams monitor: call ended (microphone input stopped)")
            onCallEnded?()
        case nil:
            break
        }
        if debouncer.isInCall {
            onCallTick?()
        }
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = debouncer.nextDeadline else { return }
        // A hair past the deadline, so the re-read lands on the far side of it.
        let delay = max(deadline.timeIntervalSince(now()), 0) + 0.1
        let sleep = self.sleep
        deadlineTask = Task { @MainActor [weak self] in
            await sleep(.milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }
}
