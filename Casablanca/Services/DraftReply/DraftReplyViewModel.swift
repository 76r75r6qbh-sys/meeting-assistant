import Foundation
import Observation

/// What the draft sheet needs from ``DraftReplyService``; a seam for tests.
protocol DraftReplyDrafting: Sendable {
    func draft(_ context: DraftReplyContext) async throws -> DraftReplyOutput
    func revise(draft: String, steer: String, context: DraftReplyContext) async throws -> DraftReplyOutput
}

/// `@unchecked`: the service is an immutable struct whose only non-`Sendable`
/// member is `UserDefaults`, which is thread-safe by contract (the same reasoning
/// as `ClaudeCLIProvider`'s defaults box).
extension DraftReplyService: @unchecked Sendable {}
extension DraftReplyService: DraftReplyDrafting {}

/// Drives the draft sheet for one to-do: the first draft, revisions with a
/// steer, starting over and cancelling. Nothing is persisted; the draft lives
/// only as long as the sheet.
@MainActor
@Observable
final class DraftReplyViewModel {
    enum Phase: Equatable {
        /// A run is in flight; the associated value is its progress label.
        case generating(String)
        case ready
        case failed(String)
    }

    static let readingSourceLabel = "Reading the source…"
    static let writingLabel = "Writing the draft…"
    static let revisingLabel = "Revising…"
    static let cancelledMessage = "Cancelled."

    private(set) var phase: Phase = .ready
    /// The draft as shown in the editor. A change made by the user (not by a
    /// result arriving) sets ``isEdited``.
    var draftText = "" {
        didSet {
            if !isApplyingResult, draftText != oldValue { isEdited = true }
        }
    }
    var steer = ""
    private(set) var channel: String?
    /// Why the last revision failed. A failed revision leaves the sheet
    /// `.ready` with the draft, edits and steer intact; this is shown beside it.
    /// Cleared when the next ``revise()`` or ``start()`` begins.
    private(set) var revisionError: String?
    /// True once the user changed the draft since the last result; the view
    /// asks before discarding it on Start over.
    var isEdited = false

    var canRevise: Bool {
        phase == .ready && hasDraft
            && (!steer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEdited)
    }

    /// The run in flight, or the last one. Kept after ``cancel()`` so tests can
    /// await it settling.
    @ObservationIgnored private(set) var inFlight: Task<Void, Never>?

    /// What the draft is about; the sheet builds its Claude Code prompt from it.
    @ObservationIgnored let context: DraftReplyContext
    @ObservationIgnored private let drafter: any DraftReplyDrafting
    /// Bumped by every run and by ``cancel()``; a result whose run is no longer
    /// the current one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isApplyingResult = false
    /// Whether a draft has arrived since the last ``start()``: what a cancelled
    /// revision falls back on, and what ``canRevise`` needs.
    private var hasDraft = false

    init(context: DraftReplyContext, drafter: any DraftReplyDrafting) {
        self.context = context
        self.drafter = drafter
    }

    /// Safety net for a sheet torn down without ``cancel()``: the run's task
    /// holds `self` weakly, so it would otherwise run to completion unseen.
    deinit {
        inFlight?.cancel()
    }

    /// Drafts from scratch, discarding any current draft, edits and steer.
    func start() {
        setDraft("", channel: nil)
        hasDraft = false
        steer = ""
        revisionError = nil
        let label = context.sourceRef == nil ? Self.writingLabel : Self.readingSourceLabel
        let drafter = drafter
        let context = context
        run(label: label) {
            try await drafter.draft(context)
        } onSuccess: { [weak self] output in
            self?.setDraft(output.body, channel: output.channel)
        }
    }

    /// Rewrites the current draft, including the user's edits, as ``steer`` asks.
    /// On failure the phase returns to `.ready` with the draft, edits and steer
    /// untouched and the message in ``revisionError``.
    func revise() {
        guard canRevise else { return }
        revisionError = nil
        let drafter = drafter
        let context = context
        let draft = draftText
        let steer = steer
        run(label: Self.revisingLabel) {
            try await drafter.revise(draft: draft, steer: steer, context: context)
        } onSuccess: { [weak self] output in
            guard let self else { return }
            self.setDraft(output.body, channel: output.channel ?? self.channel)
            self.steer = ""
        } onFailure: { [weak self] message in
            // Revise never loses edits: back to the draft as it was, with the error.
            self?.revisionError = message
            self?.phase = .ready
        }
    }

    /// The view confirms first when ``isEdited``.
    func startOver() {
        start()
    }

    /// Stops the run in flight. A revision falls back to the draft it started
    /// from; a first draft ends as ``Phase/failed(_:)`` so Retry can start again.
    func cancel() {
        guard case .generating = phase else { return }
        inFlight?.cancel()
        generation += 1
        phase = hasDraft ? .ready : .failed(Self.cancelledMessage)
    }

    private func run(
        label: String,
        _ operation: @escaping @MainActor @Sendable () async throws -> DraftReplyOutput,
        onSuccess: @escaping @MainActor @Sendable (DraftReplyOutput) -> Void,
        onFailure: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        inFlight?.cancel()
        generation += 1
        let token = generation
        phase = .generating(label)
        inFlight = Task { [weak self] in
            do {
                let output = try await operation()
                guard let self, self.generation == token else { return }
                onSuccess(output)
                self.hasDraft = true
                self.phase = .ready
            } catch {
                guard let self, self.generation == token else { return }
                let message = Self.message(for: error)
                if let onFailure {
                    onFailure(message)
                } else {
                    self.phase = .failed(message)
                }
            }
        }
    }

    private func setDraft(_ text: String, channel: String?) {
        isApplyingResult = true
        draftText = text
        isApplyingResult = false
        self.channel = channel
        isEdited = false
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
