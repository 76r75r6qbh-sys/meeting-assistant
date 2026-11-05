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
    /// here. A load error lands in ``errorMessage``.
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
                self.filterOptions = AskCorpus.filterOptions(unique.filter { !self.isPendingDeletion($0.id) })
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self.buildID == id else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        indexTask = task
        indexTaskGeneration = gen
        return task
    }

    /// Invalidates the index once per burst of `ModelContext.didSave`
    /// notifications (macOS 14+), `debounce` after the last one. Idempotent.
    func observeStoreChanges(debounce: Duration = AskService.defaultInvalidationDebounce) {
        storeObserver.remove()
        storeObserver.token = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Saves happen on the main actor, but hop explicitly rather than
            // assume it: this observer only schedules work.
            Task { @MainActor [weak self] in
                self?.scheduleInvalidation(after: debounce)
            }
        }
    }

    private func scheduleInvalidation(after debounce: Duration) {
        invalidationTask?.cancel()
        invalidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
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

            if !self.isIndexFresh {
                let build = self.prepareIndex()
                await withTaskCancellationHandler {
                    await build.value
                } onCancel: {
                    build.cancel()
                }
            }
            guard !Task.isCancelled, let built = self.built else { return }

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
            meetings[snapshot.id] = snapshot
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
