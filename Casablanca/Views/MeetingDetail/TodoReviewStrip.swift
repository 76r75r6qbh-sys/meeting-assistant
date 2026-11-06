// Casablanca/Views/MeetingDetail/TodoReviewStrip.swift
import SwiftData
import SwiftUI

/// The review decisions every review surface (summary strip, Todos → Review,
/// meeting panel) runs: `TodoReviewService` against the view's context, an
/// automatic export after any accept (so Apple Notes / the summary file get
/// the accepted list), and failures as a toast.
@MainActor
struct TodoReviewActions {
    let modelContext: ModelContext
    let appModel: AppModel

    func accept(_ todo: TodoItem) {
        let meeting = todo.meeting
        let succeeded = perform("accept the to-do") {
            try TodoReviewService.accept(todo, in: modelContext)
        }
        if succeeded { exportAfterAccept(meeting) }
    }

    func reject(_ todo: TodoItem) {
        perform("reject the to-do") {
            try TodoReviewService.reject(todo, in: modelContext)
        }
    }

    func edit(_ todo: TodoItem, task: String, owner: String?, dueDate: Date?) {
        perform("save the edit") {
            try TodoReviewService.edit(todo, task: task, owner: owner, dueDate: dueDate, in: modelContext)
        }
    }

    func acceptAllVerified(in meeting: Meeting) {
        guard TodoReviewPresentation.acceptAllVerifiedCount(meeting.todos) > 0 else { return }
        perform("accept the verified to-dos") {
            try TodoReviewService.acceptAllVerified(in: meeting, in: modelContext)
        }
        // Also after a failure part-way: the earlier ones are accepted.
        exportAfterAccept(meeting)
    }

    @discardableResult
    private func perform(_ what: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            appModel.toastCenter.show(message: "Couldn't \(what) — \(error.localizedDescription)")
            return false
        }
    }

    /// One export per burst of accepts: rapid accepts would otherwise start
    /// overlapping full exports, which can race the Apple Notes upsert into
    /// duplicate notes.
    private func exportAfterAccept(_ meeting: Meeting?) {
        guard let meeting else { return }
        let reporter = appModel.exportStatusCenter
        MeetingExportCoalescer.shared.schedule(meeting.id) { [weak meeting] in
            guard let meeting else { return }
            await ExportService.exportAutomaticallyIfEnabled(meeting, reporter: reporter)
        }
    }
}

/// Coalesces work per meeting: a request replaces the meeting's pending one
/// (still in its `delay`), so a burst runs the work once, after the last
/// request. Runs for one meeting never overlap: a run waits for the previous
/// run to finish. A run that has started is never cancelled. `flushAll()`
/// starts every pending run at once (app quit).
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

    private func startRun(_ meetingID: UUID, _ operation: @escaping @MainActor () async -> Void) {
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
    }

    private func resumeIdleWaitersIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Top of the summary tab (below the hero) while the meeting has proposed
/// to-dos: "Review to-dos (N)", "Accept all verified (K)" and one
/// `TodoReviewRow` per proposal.
struct TodoReviewStrip: View {
    @Bindable var meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let proposed = TodoReviewPresentation.proposedTodos(of: meeting)
        if !proposed.isEmpty {
            let actions = TodoReviewActions(modelContext: modelContext, appModel: appModel)
            TodoReviewStripContent(
                todos: proposed,
                actionItems: meeting.actionItems,
                verifiedCount: TodoReviewPresentation.acceptAllVerifiedCount(proposed),
                onAccept: actions.accept,
                onReject: actions.reject,
                onEdit: { todo, task, owner, due in actions.edit(todo, task: task, owner: owner, dueDate: due) },
                onAcceptAllVerified: { actions.acceptAllVerified(in: meeting) }
            )
        }
    }
}

/// The strip's layout, without environment, so it can be laid out in tests.
struct TodoReviewStripContent: View {
    let todos: [TodoItem]
    /// The meeting's decoded extracted items, decoded once for all rows.
    var actionItems: [ExtractedActionItem] = []
    let verifiedCount: Int
    let onAccept: (TodoItem) -> Void
    let onReject: (TodoItem) -> Void
    let onEdit: (TodoItem, String, String?, Date?) -> Void
    let onAcceptAllVerified: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            // Side by side when there is room, stacked in a narrow column.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                    title
                    Spacer(minLength: CasaSpace.sm)
                    acceptAllButton
                }
                VStack(alignment: .leading, spacing: CasaSpace.sm) {
                    title
                    acceptAllButton
                }
            }

            ForEach(todos) { todo in
                if todo.id != todos.first?.id {
                    Divider()
                }
                TodoReviewRow(
                    todo: todo,
                    actionItems: actionItems,
                    onAccept: { onAccept(todo) },
                    onReject: { onReject(todo) },
                    onEdit: { task, owner, due in onEdit(todo, task, owner, due) }
                )
            }
        }
        .padding(CasaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.textTertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: CasaRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.lg)
                .strokeBorder(Color.textTertiary.opacity(0.25), lineWidth: 1)
        )
    }

    private var title: some View {
        Label("Review to-dos (\(todos.count))", systemImage: "checklist")
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Color.textSecondary)
            .symbolRenderingMode(.hierarchical)
            // Never truncated: in a narrow column the header stacks instead.
            .fixedSize(horizontal: true, vertical: false)
    }

    private var acceptAllButton: some View {
        Button("Accept all verified (\(verifiedCount))", action: onAcceptAllVerified)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(verifiedCount == 0)
            .help("Accept every to-do whose quote is confirmed by the transcript")
    }
}
