import Foundation
import Observation
import SwiftData

/// One answer of the cross-meeting Ask feature.
struct AskAnswer: Equatable {
    let question: String
    let text: String
    let segments: [AskAnswerSegment]
    /// The sources that were in the prompt (empty when nothing matched).
    let sources: [AskSource]
}

/// Single-turn questions over all meetings: a lazily built, in-memory BM25
/// index → budgeted sources → one LLM call → citations resolved against the
/// sources that were in the prompt.
///
/// The index is built on first use (or ``prepareIndex()``) and cached until
/// ``invalidateIndex()``; with ``observeStoreChanges(debounce:)`` a burst of
/// store saves invalidates it once, after the debounce. Snapshots come either
/// from a main-actor loader (tests, small stores) or from a background loader
/// that pages a fetch-only `ModelContext` off the main actor
/// (``init(container:isPendingDeletion:providerFactory:retryPolicy:thinkingEnabled:observesStoreChanges:pageSize:)``).
/// Chunking and the BM25 build always run in a detached task.
///
/// Each ask replaces ``answer``; no history goes into the prompt. LLM wiring
/// (provider factory, retry status, timeout, thinking switch) follows
/// `MeetingChatService`.
@MainActor
@Observable
final class AskService {
    static let noMatchText = "No meeting content matches this question and filter."
    static let indexUnavailableText = "The meeting index could not be built. Try again."
    static let outdatedIndexText = "Couldn't refresh the meeting index; answers may be out of date."
    static let defaultInvalidationDebounce: Duration = .seconds(2)
    nonisolated static let defaultPageSize = 200

    private(set) var answer: AskAnswer?
    private(set) var isAnswering = false
    private(set) var isIndexing = false
    private(set) var statusMessage: String?
    var errorMessage: String?
    /// Participants and tags of the searchable meetings, from the last
    /// snapshot load (pending deletions left out).
    private(set) var filterOptions: (participants: [String], tags: [String]) = ([], [])
    /// `true` when the last rebuild failed and answers come from an older
    /// index; the view shows ``outdatedIndexText``. Cleared by the next
    /// successful build.
    private(set) var indexMayBeOutdated = false

    // MARK: - Dependencies

    private enum SnapshotSource {
        case mainActor(@MainActor () throws -> [AskMeetingSnapshot])
        case background(@Sendable () async throws -> [AskMeetingSnapshot])
    }

    @ObservationIgnored private let snapshotSource: SnapshotSource
    @ObservationIgnored private let isPendingDeletion: @MainActor (UUID) -> Bool
    @ObservationIgnored private let providerFactory: () -> LLMProvider
    @ObservationIgnored private let retryPolicy: LLMRetryPolicy
    @ObservationIgnored private let thinkingEnabled: () -> Bool

    // MARK: - Index state

    /// `meetings` holds metadata-only snapshots (id, title, date,
    /// participants, tags; no summary, action items or transcript): all that
    /// source selection, filtering and citations read. The chunk text lives
    /// in `index`.
    private struct BuiltIndex: Sendable {
        let index: BM25Index
        let meetings: [UUID: AskMeetingSnapshot]
    }

    @ObservationIgnored private var built: BuiltIndex?
    /// Bumped by ``invalidateIndex()``; the index is fresh while it was built
    /// for the current generation.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var builtGeneration = -1
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexTaskGeneration = -1
    /// Identifies the newest build so a superseded one cannot publish or
    /// reset `isIndexing`.
    @ObservationIgnored private var buildID = 0

    @ObservationIgnored private var answerTask: Task<Void, Never>?
    /// Identifies the newest ask so a cancelled one cannot touch state.
    @ObservationIgnored private var answerID = 0

    @ObservationIgnored private let storeObserver = StoreObserverBox()
    @ObservationIgnored private var invalidationTask: Task<Void, Never>?

    // MARK: - Init

    private init(
        source: SnapshotSource,
        isPendingDeletion: @escaping @MainActor (UUID) -> Bool,
        providerFactory: @escaping () -> LLMProvider,
        retryPolicy: LLMRetryPolicy,
        thinkingEnabled: @escaping () -> Bool
    ) {
        self.snapshotSource = source
        self.isPendingDeletion = isPendingDeletion
        self.providerFactory = providerFactory
        self.retryPolicy = retryPolicy
        self.thinkingEnabled = thinkingEnabled
    }

    /// Snapshots come from `snapshotLoader` on the main actor; chunking and
    /// the BM25 build run in a detached task. Does not observe the store.
    convenience init(
        snapshotLoader: @escaping @MainActor () throws -> [AskMeetingSnapshot],
        providerFactory: @escaping () -> LLMProvider = { LLMProviderFactory.current() },
        retryPolicy: LLMRetryPolicy = LLMRetryPolicy(),
        thinkingEnabled: @escaping () -> Bool = { LLMPromptSupport.thinkingEnabled() }
    ) {
        self.init(
            source: .mainActor(snapshotLoader),
            isPendingDeletion: { _ in false },
            providerFactory: providerFactory,
            retryPolicy: retryPolicy,
            thinkingEnabled: thinkingEnabled
        )
    }

    /// Production setup: snapshots are paged off the main actor from a
    /// fetch-only `ModelContext` on `container` (never saved), and the index
    /// is invalidated (debounced) on store saves. `isPendingDeletion` is
    /// applied on the main actor at ask time, so an undone deletion is
    /// searchable again without a rebuild.
    convenience init(
        container: ModelContainer,
        isPendingDeletion: @escaping @MainActor (UUID) -> Bool,
        providerFactory: @escaping () -> LLMProvider = { LLMProviderFactory.current() },
        retryPolicy: LLMRetryPolicy = LLMRetryPolicy(),
        thinkingEnabled: @escaping () -> Bool = { LLMPromptSupport.thinkingEnabled() },
        observesStoreChanges: Bool = true,
        pageSize: Int = AskService.defaultPageSize
    ) {
        self.init(
            source: .background(Self.pagedSnapshotLoader(container: container, pageSize: pageSize)),
            isPendingDeletion: isPendingDeletion,
            providerFactory: providerFactory,
            retryPolicy: retryPolicy,
            thinkingEnabled: thinkingEnabled
        )
        if observesStoreChanges {
            observeStoreChanges()
        }
    }

    deinit {
        storeObserver.remove()
    }

    // MARK: - Index

    /// The metadata snapshots the current index holds (no summary, action
    /// items or transcript). For tests and diagnostics.
    var indexedMeetings: [AskMeetingSnapshot] { built.map { Array($0.meetings.values) } ?? [] }

    /// Whether a built index exists for the current generation.
    var isIndexFresh: Bool { built != nil && builtGeneration == generation }

    /// Marks the index stale; the next ask (or ``prepareIndex()``) rebuilds.
    /// The current index keeps serving until the rebuild publishes.
    func invalidateIndex() {
        generation += 1
    }

    /// Starts (or joins) building the index for the current generation and
    /// returns the task; a fresh index returns an already finished task.
    /// Snapshots load first (on the main actor or in a background task), then
    /// chunks and the BM25 index are built in a detached task and published
    /// here. A load error lands in ``errorMessage`` when there is no index
    /// yet, and sets ``indexMayBeOutdated`` when an older index keeps serving.
    @discardableResult
    func prepareIndex() -> Task<Void, Never> {
        if isIndexFresh { return Task {} }
        if let indexTask, indexTaskGeneration == generation { return indexTask }

        indexTask?.cancel()
        buildID += 1
        let id = buildID
        let gen = generation
        let source = snapshotSource
        isIndexing = true

        let task = Task { @MainActor in
            defer {
                if self.buildID == id {
                    self.isIndexing = false
                    self.indexTask = nil
                }
            }
            do {
                let snapshots: [AskMeetingSnapshot]
                switch source {
                case let .mainActor(load):
                    snapshots = try load()
                case let .background(load):
                    snapshots = try await Self.detached(load)
                }
                try Task.checkCancellation()
                let unique = Self.dedupe(snapshots)
                let built = try await Self.detached { Self.build(unique) }
                try Task.checkCancellation()
                guard self.buildID == id else { return }
                self.built = built
                self.builtGeneration = gen
                self.indexMayBeOutdated = false
                self.refreshFilterOptions()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self.buildID == id else { return }
                if self.built != nil {
                    self.indexMayBeOutdated = true
                } else {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        indexTask = task
        indexTaskGeneration = gen
        return task
    }

    /// Invalidates the index once per burst of `ModelContext.didSave`
    /// notifications (macOS 14+), `debounce` after the last one. Idempotent.
    ///
    /// `sleep` is the debounce wait (default `Task.sleep(for:)`); tests inject
    /// a gate instead of waiting on the clock.
    func observeStoreChanges(
        debounce: Duration = AskService.defaultInvalidationDebounce,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        storeObserver.remove()
        storeObserver.token = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Saves happen on the main actor, but hop explicitly rather than
            // assume it: this observer only schedules work.
            Task { @MainActor [weak self] in
                self?.scheduleInvalidation(after: debounce, sleep: sleep)
            }
        }
    }

    private func scheduleInvalidation(
        after debounce: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        invalidationTask?.cancel()
        invalidationTask = Task { @MainActor [weak self] in
            try? await sleep(debounce)
            guard !Task.isCancelled else { return }
            self?.invalidateIndex()
        }
    }

    // MARK: - Ask

    /// Answers `question` over the meetings matching `filter`. Returns `nil`
    /// (and does nothing) when the trimmed question is empty or an answer is
    /// already in progress. The previous answer is cleared at once.
    @discardableResult
    func ask(_ question: String, filter: AskFilter) -> Task<Void, Never>? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return nil }

        answer = nil
        errorMessage = nil
        statusMessage = nil
        isAnswering = true
        answerID += 1
        let id = answerID

        let provider = providerFactory()
        let thinking = thinkingEnabled()
        let retryPolicy = self.retryPolicy

        let task = Task { @MainActor in
            defer {
                if self.answerID == id {
                    self.isAnswering = false
                    self.statusMessage = nil
                    self.answerTask = nil
                }
            }

            // The build this ask waits on can be superseded (a newer
            // generation cancels it) before anything is published; wait on the
            // current build once more before giving up, and never end with
            // neither an answer nor an error.
            var waits = 0
            while !self.isIndexFresh && waits < 2 {
                waits += 1
                let build = self.prepareIndex()
                await withTaskCancellationHandler {
                    await build.value
                } onCancel: {
                    build.cancel()
                }
                if Task.isCancelled { return }
                // No newer build in flight: the one awaited settled (published
                // or failed), so waiting again would only repeat the load.
                if self.indexTask == nil { break }
            }
            guard let built = self.built else {
                if self.errorMessage == nil { self.errorMessage = Self.indexUnavailableText }
                return
            }
            self.refreshFilterOptions()

            let allowed = self.allowedMeetings(filter, in: built)
            let scored = built.index.search(trimmed, allowedMeetings: allowed, limit: AskPrompt.retrievalLimit)
            // Keep room for the `/no_think` switch appended after selection.
            let switchTokens = thinking
                ? 0
                : LLMPromptSupport.budgetTokens(
                    forCharCount: LLMPromptSupport.applyThinkingSwitch(to: "", thinkingEnabled: false).count
                )
            let sources = AskPrompt.selectSources(
                scored, meetings: built.meetings, question: trimmed, filter: filter,
                tokenBudget: provider.promptTokenBudget - switchTokens
            )

            guard !sources.isEmpty else {
                self.answer = AskAnswer(
                    question: trimmed, text: Self.noMatchText, segments: [.text(Self.noMatchText)], sources: []
                )
                return
            }

            let prompt = LLMPromptSupport.applyThinkingSwitch(
                to: AskPrompt.render(question: trimmed, filter: filter, sources: sources),
                thinkingEnabled: thinking
            )
            do {
                let raw = try await retryPolicy.withRetry(
                    onAttempt: { [weak self] attempt in
                        guard let self, self.answerID == id else { return }
                        self.statusMessage = "\(provider.displayName) request failed, retrying (\(attempt)/\(retryPolicy.maxAttempts))…"
                    }
                ) {
                    try await provider.generate(
                        prompt: prompt,
                        temperature: nil,
                        maxTokens: LLMPromptSupport.tokenBudget(thinkingEnabled: thinking),
                        timeout: provider.timeout(orDefault: 120),
                        truncated: nil
                    )
                }
                if Task.isCancelled { return }
                // Not `stripReasoning`: an answer may legitimately contain `#` headings.
                let stripped = LLMPromptSupport.stripReasoningTags(raw)
                let text = stripped.isEmpty ? "\(provider.displayName) returned an empty answer." : stripped
                self.answer = AskAnswer(
                    question: trimmed,
                    text: text,
                    segments: AskCitations.segments(in: text, sources: sources),
                    sources: sources
                )
            } catch {
                if Task.isCancelled { return }
                self.errorMessage = error.localizedDescription
            }
        }
        answerTask = task
        return task
    }

    /// Cancels the in-flight answer (and an index build it is waiting on).
    /// The cancelled request never sets an answer or an error.
    func cancel() {
        answerTask?.cancel()
        answerTask = nil
        answerID += 1
        isAnswering = false
        statusMessage = nil
    }

    /// Recomputes ``filterOptions`` from the indexed meetings minus those
    /// pending deletion. Called on publish and on every ask; call it too when
    /// the pending-deletion set changes.
    func refreshFilterOptions() {
        guard let built else { return }
        let visible = built.meetings.values.filter { !isPendingDeletion($0.id) }
        let options = AskCorpus.filterOptions(Array(visible))
        if options != filterOptions { filterOptions = options }
    }

    // MARK: - Background loading

    /// Pages ``AskCorpus/loadPage(from:limit:offset:isPendingDeletion:)``
    /// over a fresh fetch-only `ModelContext` per page (released after each
    /// page, never saved), stopping once a page fetched fewer rows than
    /// `pageSize`, and dedupes by meeting id. Call it off the main actor.
    nonisolated static func pagedSnapshotLoader(
        container: ModelContainer,
        pageSize: Int = AskService.defaultPageSize
    ) -> @Sendable () async throws -> [AskMeetingSnapshot] {
        let limit = max(1, pageSize)
        return {
            var result: [AskMeetingSnapshot] = []
            var seen: Set<UUID> = []
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try autoreleasepool { () throws -> (snapshots: [AskMeetingSnapshot], fetchedRows: Int) in
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    return try AskCorpus.loadPage(from: context, limit: limit, offset: offset) { _ in false }
                }
                for snapshot in page.snapshots where seen.insert(snapshot.id).inserted {
                    result.append(snapshot)
                }
                if page.fetchedRows < limit { break }
                offset += limit
            }
            return result
        }
    }

    // MARK: - Private

    /// `nil` (all meetings) when nothing restricts the search; otherwise the
    /// ids matching `filter`, minus meetings pending deletion.
    private func allowedMeetings(_ filter: AskFilter, in built: BuiltIndex) -> Set<UUID>? {
        let pending = Set(built.meetings.keys.filter { isPendingDeletion($0) })
        if filter.isEmpty && pending.isEmpty { return nil }
        var allowed: Set<UUID> = []
        for (id, meeting) in built.meetings where !pending.contains(id) {
            if filter.isEmpty || filter.matches(meeting) { allowed.insert(id) }
        }
        return allowed
    }

    nonisolated private static func dedupe(_ snapshots: [AskMeetingSnapshot]) -> [AskMeetingSnapshot] {
        var seen: Set<UUID> = []
        return snapshots.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func build(_ snapshots: [AskMeetingSnapshot]) -> BuiltIndex {
        let chunks = snapshots.flatMap(AskCorpus.chunks(for:))
        var titles: [UUID: String] = [:]
        var meetings: [UUID: AskMeetingSnapshot] = [:]
        for snapshot in snapshots {
            titles[snapshot.id] = snapshot.title
            meetings[snapshot.id] = AskMeetingSnapshot(
                id: snapshot.id, title: snapshot.title, date: snapshot.date,
                participants: snapshot.participants, tags: snapshot.tags,
                summary: nil, actionItems: [], transcript: nil
            )
        }
        return BuiltIndex(index: BM25Index(chunks: chunks, titles: titles), meetings: meetings)
    }

    /// Runs `work` in a detached task; cancelling the caller cancels it.
    nonisolated private static func detached<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Nonisolated holder for the `didSave` observer token, so the main-actor
/// service can remove it from its nonisolated `deinit`.
private final class StoreObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: NSObjectProtocol?

    var token: NSObjectProtocol? {
        get { lock.withLock { storedToken } }
        set { lock.withLock { storedToken = newValue } }
    }

    func remove() {
        let token = lock.withLock { () -> NSObjectProtocol? in
            defer { storedToken = nil }
            return storedToken
        }
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
