import Foundation

/// Coalesces work per meeting: a request replaces the meeting's pending one
/// (still in its `delay`), so a burst runs the work once, after the last
/// request. Runs for one meeting never overlap: a run waits for the previous
/// run to finish. A run that has started is never cancelled. `flushAll()`
/// starts every pending run at once (app quit). `run(_:_:)` is for a caller
/// that must wait for the work: no delay, but still in the meeting's chain.
///
/// Every automatic export goes through `.shared` (`scheduleAutomaticExport`,
/// or `runAutomaticExport` where the caller continues only afterwards), so two
/// exports of one meeting never overlap and race the Apple Notes upsert into
/// duplicate notes. A meeting's pending export is cancelled when the meeting
/// is deleted (`cancel(_:)`), and an export never runs for a deleted or
/// soft-deleted meeting.
@MainActor
final class MeetingExportCoalescer {
    static let shared = MeetingExportCoalescer(delay: .milliseconds(600))

    private struct Pending {
        let token: UUID
        let task: Task<Void, Never>
        let operation: @MainActor () async -> Void
    }

    private let delay: Duration
    private let sleep: @MainActor (Duration) async -> Void
    private var pending: [UUID: Pending] = [:]
    private var lastRun: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether a meeting is soft-deleted (hidden, in the undo grace period).
    /// Set by ContentView to `MeetingListViewModel.isPendingDeletion`; the
    /// automatic exports skip such meetings.
    var isPendingDeletion: @MainActor (UUID) -> Bool = { _ in false }

    /// `sleep` waits out the delay; injectable so tests need no wall clock.
    init(
        delay: Duration,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.delay = delay
        self.sleep = sleep
    }

    /// No request is waiting and no run is in progress.
    var isIdle: Bool { pending.isEmpty && lastRun.isEmpty }

    func schedule(_ meetingID: UUID, _ operation: @escaping @MainActor () async -> Void) {
        pending[meetingID]?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(self.delay)
            // Replaced by a newer request, or already started by `flushAll`.
            guard !Task.isCancelled, self.pending[meetingID]?.token == token else { return }
            self.pending[meetingID] = nil
            self.startRun(meetingID, operation)
        }
        pending[meetingID] = Pending(token: token, task: task, operation: operation)
    }

    /// Runs `operation` now — no delay, not coalesced — after the meeting's
    /// run in progress (if any), and returns when it has finished. A pending
    /// request stays pending and runs after this one.
    ///
    /// Never call it from inside a run for the same meeting: that run would
    /// wait for itself and never finish.
    func run(_ meetingID: UUID, _ operation: @escaping @MainActor () async -> Void) async {
        await startRun(meetingID, operation).value
    }

    /// Drops the meeting's pending request (the meeting is being deleted). A
    /// run that has already started is not interrupted; the export's own
    /// guard skips a meeting that is gone by then.
    func cancel(_ meetingID: UUID) {
        pending.removeValue(forKey: meetingID)?.task.cancel()
        resumeIdleWaitersIfIdle()
    }

    /// Starts every pending request now instead of after its delay.
    func flushAll() {
        let flushed = pending
        pending.removeAll()
        for (meetingID, request) in flushed {
            request.task.cancel()
            startRun(meetingID, request.operation)
        }
        resumeIdleWaitersIfIdle()
    }

    /// For the quit path, where nothing can be awaited: flushes, then runs
    /// the main run loop (which executes MainActor work) until every run has
    /// finished or `timeout` has passed. Call it from synchronous main-thread
    /// code such as a `willTerminate` observer: from inside a MainActor async
    /// job the main queue is not drained re-entrantly, so the runs could not
    /// progress and it would return at the timeout.
    func flushAndWait(timeout: TimeInterval) {
        flushAll()
        let deadline = Date().addingTimeInterval(timeout)
        while !isIdle && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Returns once nothing is pending and nothing is running.
    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    @discardableResult
    private func startRun(_ meetingID: UUID, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lastRun[meetingID]
        let run = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lastRun[meetingID] = run
        Task { @MainActor [weak self] in
            await run.value
            guard let self else { return }
            if self.lastRun[meetingID] == run { self.lastRun[meetingID] = nil }
            self.resumeIdleWaitersIfIdle()
        }
        return run
    }

    private func resumeIdleWaitersIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

extension MeetingExportCoalescer {
    /// Exports `meeting` when automatic export is on; injectable for tests.
    typealias AutomaticExporter = @MainActor (Meeting, UserDefaults, ExportStatusCenter?) async -> Void

    static let liveAutomaticExporter: AutomaticExporter = { meeting, defaults, reporter in
        await ExportService.exportAutomaticallyIfEnabled(meeting, defaults: defaults, reporter: reporter)
    }

    /// The automatic export (if enabled) of `meeting`, coalesced: after a
    /// save, an accept, a retry. The meeting is held weakly while it waits.
    func scheduleAutomaticExport(
        of meeting: Meeting,
        reporter: ExportStatusCenter?,
        defaults: UserDefaults = .standard,
        export: @escaping AutomaticExporter = liveAutomaticExporter
    ) {
        schedule(meeting.id) { [weak self, weak meeting] in
            guard let self, let meeting, self.canExport(meeting) else { return }
            await export(meeting, defaults, reporter)
        }
    }

    /// The automatic export (if enabled) of `meeting` now, serialized with the
    /// meeting's other exports; returns once it has finished.
    func runAutomaticExport(
        of meeting: Meeting,
        defaults: UserDefaults,
        reporter: ExportStatusCenter?,
        export: @escaping AutomaticExporter = liveAutomaticExporter
    ) async {
        await run(meeting.id) { [weak self] in
            guard let self, self.canExport(meeting) else { return }
            await export(meeting, defaults, reporter)
        }
    }

    /// Checked when the run starts: a meeting deleted (or soft-deleted) while
    /// its export waited is never exported, and its deleted model is not read.
    private func canExport(_ meeting: Meeting) -> Bool {
        meeting.modelContext != nil && !meeting.isDeleted && !isPendingDeletion(meeting.id)
    }
}
