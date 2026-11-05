import CryptoKit
import Foundation
import OSLog
import Observation
import SwiftData

enum SummarizationError: LocalizedError {
    case invalidEndpoint(provider: String)
    case missingSourceMaterial
    case requestFailed(String)
    case emptyResponse(provider: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let provider):
            return "The \(provider) endpoint is invalid. Update it in Settings."
        case .missingSourceMaterial:
            return "Casablanca needs a transcript or notes before it can summarize the meeting."
        case .requestFailed(let message):
            return message
        case .emptyResponse(let provider):
            return "\(provider) returned an empty summary."
        }
    }
}

@MainActor
@Observable
final class SummarizationService {
    static let defaultPromptTemplate = """
    You are a meeting assistant creating structured, high-signal meeting notes.

    Write the notes in the dominant language of the transcript (Dutch transcript -> Dutch notes, English transcript -> English notes).

    Use only the information provided below. If something is unclear or missing, leave it out instead of guessing.

    The transcript comes from machine speech recognition and may misspell names of people, companies and products. Correct obvious mistranscriptions using the terminology list and the participants list. Never invent names, and never comment on transcript quality in the notes.

    Structure the notes as follows:

    1. Start with a single `# Summary` heading (Dutch: `# Samenvatting`) followed by a 2-4 sentence paragraph: what the meeting was about and its main outcome.
    2. Then 2-5 thematic sections, each with a descriptive `## <theme>` heading, containing a short intro sentence and/or `- **subtopic:** detail` bullets. Capture the reasoning behind conclusions, not just the conclusions.
    3. If the meeting discussed planning across dates, weeks or months, add a `## Planning` section with chronological bullets: `- **<period>** — <milestone or activity>`.
    4. If hiring or staffing was discussed, add a `## Personele zaken` (English: `## Personnel`) section.
    5. End with these four sections, always present, in this order. Use exactly these headings — Dutch notes / English notes:
       `## Besluiten` / `## Decisions`
       `## Actiepunten` / `## Action Items`
       `## Risico's en blockers` / `## Risks and Blockers`
       `## Opvolging` / `## Follow-ups`

    Rules for the four closing sections:
    - Every item is a `- ` bullet. If a section has no items, keep the heading with nothing below it.
    - Decisions include their stated rationale.
    - Each action item is one bullet formatted `- **<owner>** — <action>`. Resolve the owner against the participants list; use the person's name, never "me" or "I". If no owner was stated, use `- **?** — <action>`.
    - The note-taker is {{user_name}}. When the note-taker commits to something ("I will…", "ik pak dat op"), the owner is {{user_name}}.
    - Transcript lines may start with a speaker label (`[12:34] Kim: …`). A labelled speaker's first-person commitment makes that speaker the owner. Generic labels such as "Speaker 1", "Spreker 2", "Others" or "Anderen" are not names.
    - Omit optional sections that have nothing meaningful. Never add sections about the transcript itself.

    {{terminology_list}}

    Meeting title: {{title}}
    Scheduled time: {{scheduled_time}}
    Participants: {{participants}}

    {{user_focus}}

    Transcript:
    {{transcript}}
    """

    /// Upper bound on generated summary length when thinking is OFF. Local models
    /// can otherwise ramble or loop for thousands of tokens on a short transcript.
    /// Kept as a forwarding alias to the shared helper so existing callers
    /// (PrepEditorView, tests) keep working.
    static var maxSummaryTokens: Int { LLMPromptSupport.cappedOutputTokens }

    /// Removes chain-of-thought blocks reasoning models emit before their answer.
    /// Forwards to the shared `LLMPromptSupport.stripReasoning` so the summary,
    /// prep and chat flows all use one copy.
    static func stripReasoning(_ text: String) -> String {
        LLMPromptSupport.stripReasoning(text)
    }

    /// Where the summarization pipeline currently is. Drives `statusMessage`.
    enum SummarizationPhase: Equatable {
        case idle
        case sending
        /// Map step of a long transcript: condensing part `part` (1-based) of `of`.
        case condensing(part: Int, of: Int)
        /// Hierarchical merge of condensed notes, level 1…`maxMergeLevels`.
        case merging(level: Int)
        case retrying(attempt: Int, maxAttempts: Int)
        case parsing
        /// One repair (or rebuild) call because the JSON facts block was invalid or missing.
        case repairing
        /// Checking the extracted action items against the transcript.
        case verifying
    }

    private(set) var isSummarizing = false
    private(set) var phase: SummarizationPhase = .idle

    /// Human-readable status derived from `phase`. Kept as a computed property so
    /// existing views that read `statusMessage` keep working. `.idle` maps to "",
    /// which RecordedMeetingView turns into its "Generating summary..." fallback.
    var statusMessage: String {
        switch phase {
        case .idle:
            return ""
        case .sending:
            return "Sending transcript and notes to \(providerDisplayName)..."
        case .condensing(let part, let of):
            return Self.condensingStatus(part: part, of: of, provider: providerDisplayName)
        case .merging(let level):
            return Self.mergingStatus(level: level)
        case .retrying(let attempt, let maxAttempts):
            return "\(providerDisplayName) request failed, retrying (\(attempt)/\(maxAttempts))..."
        case .parsing:
            return "Processing summary…"
        case .repairing:
            return Self.repairingStatus
        case .verifying:
            return Self.verifyingStatus
        }
    }

    /// Status line for `.repairing`, shared with `MeetingPipelinePresentation`.
    nonisolated static let repairingStatus = "Repairing the structured notes…"

    /// Status line for `.verifying`.
    nonisolated static let verifyingStatus = "Checking action items against the transcript…"

    /// Status line for `.condensing`, shared with `MeetingPipelinePresentation`
    /// so the summary tab, sidebar and processing card say the same thing.
    nonisolated static func condensingStatus(part: Int, of total: Int, provider: String) -> String {
        "Summarizing part \(part) of \(total) with \(provider)…"
    }

    /// Status line for `.merging`, shared with `MeetingPipelinePresentation`.
    nonisolated static func mergingStatus(level: Int) -> String {
        "Combining notes (step \(level))…"
    }

    /// Display name of the provider for the in-flight summarization, captured so
    /// `statusMessage` (and the pipeline card, via the views) can name it
    /// without re-reading preferences off-thread.
    private(set) var providerDisplayName = "the model"

    var errorMessage: String?
    var warningMessage: String?

    /// The meeting currently being summarized in the background (nil when idle).
    /// Lets list rows show a spinner on the specific meeting being processed.
    private(set) var summarizingMeetingID: UUID?

    /// Wall-clock time the current summarization began (nil when idle). Used by
    /// the pipeline-status UI to show elapsed time for the indeterminate
    /// summarization stage.
    private(set) var summarizationStartedAt: Date?

    private var backgroundTask: Task<Void, Never>?

    /// Identity of one condensed transcript part: everything that shapes the map
    /// prompt or its output, so a cached part is only reused for an identical call.
    struct CondensedPartKey: Hashable {
        let meetingID: UUID
        let transcriptSHA256: String
        /// Display name + endpoint: the protocol exposes no model, and switching
        /// provider or server is what changes the output.
        let provider: String
        let terminologyBlock: String
        /// The map prompt's focus block (prep + notes): a changed prep must
        /// re-extract every part.
        let focusSHA256: String
        /// Relative due dates resolve against it.
        let meetingDate: Date
        let thinkingEnabled: Bool
        let chunkTokens: Int
        let chunkIndex: Int
    }

    /// What one map call produced: decoded facts, or (when the JSON and its one
    /// repair were both unreadable) the raw text, used as markdown notes.
    enum CondensedPart: Equatable {
        case facts(SummaryFacts)
        case markdown(String)
    }

    /// Condensed parts of the most recent map-reduce run, so Retry after a failed
    /// part re-uses the parts that already succeeded (a local model spends a
    /// minute or more per part). In memory only, one meeting at a time.
    private var condensedPartCache: [CondensedPartKey: CondensedPart] = [:]
    private var condensedPartCacheMeetingID: UUID?

    /// How `summarize` obtains its provider. Injectable so the tests can assert what
    /// the call site hands `generate` without reaching a live backend.
    private let providerFactory: () -> LLMProvider

    /// Where every setting `summarize` reads comes from: the prompt template,
    /// terminology list, thinking flag and the to-do ownership settings (user
    /// name aliases, include-unassigned). Injectable so tests use a suite, never
    /// the user's domain.
    private let userDefaults: UserDefaults

    /// Wraps each generation. Injectable (as in `MeetingChatService`) so tests can
    /// retry without sleeping through the real backoff.
    private let retryPolicy: LLMRetryPolicy

    /// Calendar attendees (names, e-mails, which one is the user) for the
    /// participants line. Injectable so tests never touch EventKit.
    private let attendeeProvider: MeetingAttendeeProviding

    /// Loads the meeting's prep (vault file or local prep notes) for the focus
    /// block. Injectable so tests never read the user's vault.
    private let prepLoader: @MainActor (Meeting, UserDefaults) async -> String?

    /// Resolves the meeting date for the JSON instruction and relative due
    /// dates. Injectable so tests pin ISO-8601 and a time zone.
    private let calendar: Calendar

    init(
        providerFactory: @escaping () -> LLMProvider = { LLMProviderFactory.current() },
        userDefaults: UserDefaults = .standard,
        retryPolicy: LLMRetryPolicy = LLMRetryPolicy(),
        attendeeProvider: MeetingAttendeeProviding = EventKitAttendeeProvider(),
        prepLoader: @escaping @MainActor (Meeting, UserDefaults) async -> String? = {
            await MeetingPrepService.loadResolvedPrepMarkdown(for: $0, userDefaults: $1)
        },
        calendar: Calendar = .current
    ) {
        self.providerFactory = providerFactory
        self.userDefaults = userDefaults
        self.retryPolicy = retryPolicy
        self.attendeeProvider = attendeeProvider
        self.prepLoader = prepLoader
        self.calendar = calendar
    }

    /// Summarize in a service-owned task that is NOT tied to any view's
    /// lifecycle, so it keeps running if the user navigates away. On success it
    /// stores the (rendered) summary, every extracted action item (all owners)
    /// and the template on the meeting, replaces the meeting's pending
    /// proposals with the user's own items as `.proposed` to-dos (SwiftData
    /// only — nothing reaches the vault until accepted; see
    /// `ProposedTodoPlanner` / `TodoReviewService`), then persists.
    func summarizeInBackground(meeting: Meeting, modelContext: ModelContext, templateID: String? = nil) {
        // If a summary is already in flight, do nothing — never cancel/restart a
        // running summary (e.g. when the view re-appears and re-triggers this).
        guard !isSummarizing else { return }
        // Mark busy synchronously so a near-simultaneous re-trigger can't double-start.
        isSummarizing = true
        summarizingMeetingID = meeting.id
        summarizationStartedAt = Date()

        backgroundTask = Task { @MainActor in
            // Guarantees the busy flag clears on every exit path, including the
            // early "no source material" throw inside summarize().
            defer {
                self.isSummarizing = false
                self.summarizingMeetingID = nil
                self.summarizationStartedAt = nil
            }
            do {
                let outcome = try await self.summarizeWithFacts(meeting: meeting, templateID: templateID)
                meeting.summary = outcome.parsed.rawMarkdown
                meeting.actionItems = outcome.facts.actionItems
                meeting.summaryTemplateID = outcome.templateID

                let proposals = ProposedTodoPlanner.itemsToPropose(
                    outcome.facts.actionItems,
                    aliases: AppPreferences.userNameAliases(in: self.userDefaults),
                    includeUnassigned: AppPreferences.includeUnassignedActionItems(in: self.userDefaults)
                )
                do {
                    try TodoReviewService.replaceProposedTodos(for: meeting, with: proposals, in: modelContext)
                } catch {
                    // The summary itself succeeded; failed proposals are a warning, not a failure.
                    Log.summarization.warning("Proposing meeting to-dos failed: \(error.localizedDescription)")
                    // Surfaced by MeetingPipelinePresentation (errorMessage ??
                    // warningMessage) in the ProcessingStatusCard error row,
                    // with a Dismiss affordance.
                    self.warningMessage = "Summary generated, but proposing its to-dos failed: \(error.localizedDescription)"
                }
                do {
                    try modelContext.save()
                } catch {
                    Log.summarization.error("Saving summary failed: \(error.localizedDescription)")
                }
            } catch {
                // Cancellation (Swift's CancellationError or a wrapped URLSession
                // cancel) is not a real failure — never surface it.
                if Task.isCancelled { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// The parsed summary only; see `summarizeWithFacts(meeting:templateID:)`.
    func summarize(meeting: Meeting) async throws -> SummaryResponseParser.ParsedResponse {
        try await summarizeWithFacts(meeting: meeting).parsed
    }

    /// Summarizes `meeting` and returns the parsed markdown together with its
    /// structured facts. A single pass asks for the facts as a JSON block in
    /// the same call; an invalid block gets one repair call, a missing one a
    /// rebuild call from the notes' closing sections, and when that fails too
    /// the facts come from the markdown with `factsFallbackWarning`. Map-reduce
    /// asks each part for JSON (one repair per part); when every part decoded
    /// the facts are the parts' merged facts (`.mapJSON`), otherwise the
    /// reduce's markdown plus the decoded parts' facts, with the warning.
    /// Facts that are not a markdown fallback are then verified against the
    /// original transcript (pre-check, one `.verifying` call) before the
    /// sections are rendered; a failed verification only adds
    /// `verificationFailedWarning`.
    /// `templateID` is echoed as `"general"` until templates exist.
    func summarizeWithFacts(meeting: Meeting, templateID: String? = nil) async throws -> SummaryOutcome {
        let rawTranscript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let freeformNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawTranscript.isEmpty || !freeformNotes.isEmpty else {
            throw SummarizationError.missingSourceMaterial
        }

        // The provider first: its input budget decides whether the transcript
        // goes in whole (one call) or is condensed in parts first (map-reduce).
        let provider = providerFactory()

        isSummarizing = true
        errorMessage = nil
        warningMessage = nil
        providerDisplayName = provider.displayName
        phase = .sending
        defer {
            isSummarizing = false
            phase = .idle
        }

        // Read once, before the context: the prep shapes every prompt's size.
        let prep = await prepLoader(meeting, userDefaults)
        let aliases = AppPreferences.userNameAliases(in: userDefaults)
        let context = PromptContext(
            meeting: meeting,
            template: userDefaults.string(forKey: AppPreferenceKey.summaryPromptTemplate) ?? Self.defaultPromptTemplate,
            freeformNotes: freeformNotes,
            terminologyBlock: TerminologyService.renderTerminologyBlock(
                enabled: userDefaults.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled),
                raw: userDefaults.string(forKey: AppPreferenceKey.terminologyList) ?? ""
            ),
            userName: aliases.first,
            participantsLine: SummaryPromptContext.participantsLine(
                participants: meeting.participants,
                attendees: attendeeProvider.attendees(for: meeting),
                userAliases: aliases
            ),
            prep: prep,
            // Reasoning models "think out loud" before answering, which on short
            // transcripts becomes pages of rambling that never reaches the summary.
            // When thinking is disabled (default), the Qwen soft-switch is appended
            // and output gets a tight budget; when enabled, the reasoning gets room.
            thinkingEnabled: LLMPromptSupport.thinkingEnabled(defaults: userDefaults),
            calendar: calendar
        )

        var warnings: [String] = []
        // Kept apart: a cut-off map/merge note loses detail from one stretch of
        // the meeting, a cut-off final call loses the end of the summary itself.
        var notesWereTruncated = false
        var summaryWasTruncated = false
        let isSinglePass: Bool
        let finalPrompt: String
        // Single pass at full focus, else with a trimmed focus; map-reduce only
        // when the focus would have to shrink below `minFocusTokens`. The reduce
        // then gets the full-size focus again. Both are measured against
        // `onePassTokenCap` at most, whatever the provider's budget.
        var mapFacts: SummaryFacts?
        var decodedPartFacts: [SummaryFacts] = []
        if let onePassFocus = Self.onePassFocusTokens(
            transcript: rawTranscript, context: context, budget: provider.promptTokenBudget
        ) {
            isSinglePass = true
            finalPrompt = context.singlePassPrompt(transcript: rawTranscript, focusTokens: onePassFocus)
        } else {
            let condensed = try await condense(rawTranscript, context: context, provider: provider)
            notesWereTruncated = condensed.outputWasTruncated
            if condensed.wasElided {
                warnings.append(Self.shortenedWarning)
            }
            mapFacts = condensed.mapFacts
            decodedPartFacts = condensed.decodedPartFacts
            // The reduce gets no JSON instruction: its facts are the parts'.
            isSinglePass = false
            finalPrompt = context.summaryPrompt(transcript: condensed.text)
        }

        let prompt = LLMPromptSupport.applyThinkingSwitch(
            to: finalPrompt,
            thinkingEnabled: context.thinkingEnabled
        )
        // Thinking on → uncapped (user opted in); off → tight cap as the safety net.
        let summary = try await generateStep(
            .sending,
            prompt: prompt,
            maxTokens: LLMPromptSupport.tokenBudget(thinkingEnabled: context.thinkingEnabled),
            provider: provider,
            outputWasTruncated: &summaryWasTruncated
        )

        if notesWereTruncated {
            warnings.append(Self.notesTruncatedWarning)
        }
        if summaryWasTruncated {
            warnings.append("Summary may be truncated: \(provider.displayName) reached its output length limit.")
        }
        // Done with this meeting's parts: a later re-summarize (new template,
        // edited transcript) must condense afresh.
        condensedPartCache = condensedPartCache.filter { $0.key.meetingID != meeting.id }

        phase = .parsing
        // Strip any chain-of-thought the model still emitted (e.g. <think>…</think>).
        let stripped = Self.stripReasoning(summary)
        var facts: SummaryFacts
        let factsSource: FactsSource
        var parsed: SummaryResponseParser.ParsedResponse
        if isSinglePass {
            // The stored summary never shows the JSON block.
            let split = SummaryFactsParser.splitSinglePass(stripped)
            parsed = SummaryResponseParser.parse(split.markdown)
            let resolved = try await singlePassFacts(
                jsonText: split.jsonText,
                markdown: split.markdown,
                parsed: parsed,
                context: context,
                provider: provider
            )
            facts = resolved.facts
            factsSource = resolved.source
            if resolved.warns {
                warnings.append(Self.factsFallbackWarning)
            }
        } else if let mapFacts {
            parsed = SummaryResponseParser.parse(stripped)
            // As in the single pass: never fewer to-dos than the reduce's
            // markdown lists. Its extra items join the parts' (fuzzy duplicates
            // collapse), as a warned fallback.
            let markdownFacts = SummaryFacts.fromMarkdown(parsed)
            if markdownFacts.actionItems.count > mapFacts.actionItems.count {
                facts = SummaryFacts.merged([mapFacts, markdownFacts])
                factsSource = .markdownFallback
                warnings.append(Self.factsFallbackWarning)
            } else {
                facts = mapFacts
                factsSource = .mapJSON
            }
        } else {
            // At least one part had no readable JSON: the reduce's markdown,
            // plus whatever the decoded parts extracted (fuzzy duplicates
            // collapse), so no part's to-do is dropped.
            parsed = SummaryResponseParser.parse(stripped)
            facts = SummaryFacts.merged([SummaryFacts.fromMarkdown(parsed)] + decodedPartFacts)
            factsSource = .markdownFallback
            warnings.append(Self.factsFallbackWarning)
        }

        // Checked against the original transcript before rendering, so an
        // unsupported decision is rendered with its warning prefix. A
        // markdown-fallback summary is not verified: it is kept as written.
        if factsSource != .markdownFallback, !rawTranscript.isEmpty {
            let verification = try await verifiedFacts(facts, transcript: rawTranscript, context: context, provider: provider)
            facts = verification.facts
            if verification.failed {
                warnings.append(Self.verificationFailedWarning)
            }
        }

        // Structured facts render the Decisions and Action Items sections; a
        // markdown-fallback summary is kept exactly as the model wrote it.
        if factsSource != .markdownFallback {
            parsed = SummaryResponseParser.parse(ActionItemRendering.render(facts, into: parsed.rawMarkdown))
        }

        if !warnings.isEmpty {
            warningMessage = warnings.joined(separator: " ")
        }
        return SummaryOutcome(parsed: parsed, facts: facts, factsSource: factsSource, templateID: "general")
    }

    // MARK: - Facts (JSON block, repair, markdown fallback)

    /// Facts of a single pass, where to-dos never silently drop below what the
    /// markdown's Action Items section has:
    /// - A block that decodes is used, unless it has fewer action items than
    ///   the markdown; then the markdown's items replace its items.
    /// - An invalid block gets one repair call with its raw text; no block gets
    ///   one rebuild call from the closing sections — skipped when those hold
    ///   no decisions and no action items (nothing to rebuild).
    /// - A repair that fails to decode, or whose call fails, falls back to the
    ///   markdown; a repair with fewer action items than the markdown takes the
    ///   markdown's items, as above.
    ///
    /// `warns` is true for a fallback when facts were actually lost: the
    /// markdown had items, or the model sent a block that could not be read.
    /// "One repair call" is one `generateStep`: on transient failures the
    /// retry policy can spend up to `maxAttempts` generations on it.
    /// Cancellation propagates.
    private func singlePassFacts(
        jsonText: String?,
        markdown: String,
        parsed: SummaryResponseParser.ParsedResponse,
        context: PromptContext,
        provider: LLMProvider
    ) async throws -> (facts: SummaryFacts, source: FactsSource, warns: Bool) {
        let meetingDate = context.meeting.date
        let markdownFacts = SummaryFacts.fromMarkdown(parsed)
        let markdownHasItems = !markdownFacts.actionItems.isEmpty || !markdownFacts.decisions.isEmpty

        /// `facts` as `source`, unless they have fewer action items than the
        /// markdown: then the markdown's items, as a warned fallback.
        func guarded(_ facts: SummaryFacts, _ source: FactsSource) -> (SummaryFacts, FactsSource, Bool) {
            guard facts.actionItems.count < markdownFacts.actionItems.count else { return (facts, source, false) }
            var kept = facts
            kept.actionItems = markdownFacts.actionItems
            return (kept, .markdownFallback, true)
        }
        let fallback = (markdownFacts, FactsSource.markdownFallback, markdownHasItems || jsonText != nil)

        if let jsonText,
           case .success(let facts) = SummaryFactsParser.decodeFacts(jsonText, meetingDate: meetingDate, calendar: context.calendar) {
            return guarded(facts, .singlePassJSON)
        }

        let repairPrompt: String
        if let jsonText {
            // The raw block, not `extractJSONObject`: a truncated fragment would
            // be cut at an inner `}` and lose its last items.
            repairPrompt = SummaryFactsPrompt.repairPrompt(broken: jsonText)
        } else {
            // Nothing to rebuild from: no call, and nothing was lost.
            guard markdownHasItems else { return (markdownFacts, .markdownFallback, false) }
            repairPrompt = SummaryFactsPrompt.rebuildPrompt(
                fromMarkdown: Self.closingSections(of: markdown),
                meetingDate: meetingDate,
                calendar: context.calendar
            )
        }

        var repairWasTruncated = false
        let reply: String
        do {
            reply = try await generateStep(
                .repairing,
                prompt: LLMPromptSupport.applyThinkingSwitch(to: repairPrompt, thinkingEnabled: context.thinkingEnabled),
                maxTokens: LLMPromptSupport.tokenBudget(thinkingEnabled: context.thinkingEnabled),
                provider: provider,
                outputWasTruncated: &repairWasTruncated
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            Log.summarization.warning("Repairing the facts JSON failed: \(error.localizedDescription)")
            return fallback
        }

        guard let object = SummaryFactsParser.extractJSONObject(LLMPromptSupport.stripReasoningTags(reply)),
              case .success(let repaired) = SummaryFactsParser.decodeFacts(object, meetingDate: meetingDate, calendar: context.calendar)
        else {
            return fallback
        }
        return guarded(repaired, .repairedJSON)
    }

    // MARK: - Verification

    /// `facts` checked against `transcript`: the deterministic pre-check
    /// (``ActionItemVerifier/precheck(_:index:)``), then — when it emitted
    /// claims — one verification call, its reply read with
    /// ``ActionItemVerifier/apply(response:claims:to:)``. An unreadable reply
    /// gets one repair call. When that is unreadable too, or a call fails, the
    /// pre-check's facts are kept (found items `.unverified`) and `failed` is
    /// true; the summary never fails because of verification. Cancellation
    /// propagates. The prompt fits `min(promptTokenBudget, onePassTokenCap)`
    /// with the thinking switch included.
    private func verifiedFacts(
        _ facts: SummaryFacts,
        transcript: String,
        context: PromptContext,
        provider: LLMProvider
    ) async throws -> (facts: SummaryFacts, failed: Bool) {
        let index = TranscriptIndex(
            transcript: transcript,
            knownSpeakers: Set(context.meeting.speakers.map(\.displayName))
        )
        let (checked, claims) = ActionItemVerifier.precheck(facts, index: index)
        guard !claims.isEmpty else { return (checked, false) }

        let switchTokens = context.thinkingEnabled
            ? 0 : LLMPromptSupport.budgetTokens("\n\n" + LLMPromptSupport.noThinkSuffix)
        let prompt = ActionItemVerifier.prompt(
            claims: claims,
            index: index,
            meetingDate: context.meeting.date,
            calendar: context.calendar,
            budgetTokens: Self.onePassBudget(provider.promptTokenBudget) - switchTokens
        )

        func call(_ prompt: String) async throws -> String {
            var truncated = false
            let reply = try await generateStep(
                .verifying,
                prompt: LLMPromptSupport.applyThinkingSwitch(to: prompt, thinkingEnabled: context.thinkingEnabled),
                maxTokens: LLMPromptSupport.tokenBudget(thinkingEnabled: context.thinkingEnabled),
                provider: provider,
                outputWasTruncated: &truncated
            )
            return LLMPromptSupport.stripReasoningTags(reply)
        }

        do {
            let reply = try await call(prompt)
            if let applied = ActionItemVerifier.apply(response: reply, claims: claims, to: checked) {
                return (applied, false)
            }
            // The raw reply, not an extracted span: a cut-off array has no `]`.
            let repaired = try await call(ActionItemVerifier.repairPrompt(broken: reply))
            if let applied = ActionItemVerifier.apply(response: repaired, claims: claims, to: checked) {
                return (applied, false)
            }
            Log.summarization.warning("The verification reply was not a readable JSON array, also after one repair.")
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            Log.summarization.warning("Verifying the action items failed: \(error.localizedDescription)")
        }
        return (checked, true)
    }

    /// The `## Decisions` and `## Action Items` sections of `markdown`, under
    /// any heading `SummaryResponseParser` accepts for them, headings included,
    /// in document order.
    static func closingSections(of markdown: String) -> String {
        let titles = Set(
            ((SummaryResponseParser.sectionAliases["decisions"] ?? [])
                + (SummaryResponseParser.sectionAliases["todoTexts"] ?? []))
                .map(SummaryResponseParser.normalizeTitle)
        )
        var sections: [String] = []
        var current: [String]?
        func flush() {
            if let current {
                sections.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            }
            current = nil
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                flush()
                guard line.hasPrefix("## ") else { continue }
                if titles.contains(SummaryResponseParser.normalizeTitle(String(line.dropFirst(3)))) { current = [line] }
            } else {
                current?.append(line)
            }
        }
        flush()
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Single pass vs map-reduce

    /// Shown when even hierarchical merging could not bring the condensed notes
    /// within the provider's budget and their middle had to be elided.
    static let shortenedWarning = "The meeting was too long to summarize fully; some middle sections were shortened."

    /// Shown when a map or merge call (not the final summary) hit the output
    /// limit, so the notes for that stretch of the meeting are incomplete.
    static let notesTruncatedWarning = "Notes for some parts hit the output limit; the summary may miss details from them."

    /// Everything the prompts are rendered from, read once per summarization so
    /// the decision, the map/merge prompts and the final prompt agree.
    @MainActor
    struct PromptContext {
        let meeting: Meeting
        let template: String
        let freeformNotes: String
        let terminologyBlock: String
        let userName: String?
        /// Participants with e-mails and the user marked `(me)`; also used by the
        /// map/merge prompts' meeting line.
        let participantsLine: String
        /// The meeting's prep, loaded once per summarization.
        let prep: String?
        let thinkingEnabled: Bool
        /// Resolves the meeting date for the JSON instruction and due dates.
        let calendar: Calendar

        /// The user's template rendered with a focus block of at most
        /// `focusTokens`. A template with `{{freeform_notes}}` keeps the notes
        /// there, so the focus carries the prep only.
        func summaryPrompt(
            transcript: String,
            focusTokens: Int = SummaryPromptContext.maxFocusTokens
        ) -> String {
            let notesInTemplate = template.contains("{{freeform_notes}}")
            return SummarizationService.renderPrompt(
                template: template,
                meeting: meeting,
                transcript: transcript,
                freeformNotes: freeformNotes,
                terminologyBlock: terminologyBlock,
                userName: userName,
                participantsLine: participantsLine,
                focusBlock: SummaryPromptContext.focusBlock(
                    prep: prep,
                    notes: notesInTemplate ? nil : freeformNotes,
                    maxTokens: focusTokens
                )
            )
        }

        /// The single-pass prompt: the summary prompt, a blank line, then the
        /// instruction to append the facts as a ```` ```json ```` block. The
        /// thinking switch goes after this.
        func singlePassPrompt(
            transcript: String,
            focusTokens: Int = SummaryPromptContext.maxFocusTokens
        ) -> String {
            summaryPrompt(transcript: transcript, focusTokens: focusTokens)
                + "\n\n"
                + SummaryFactsPrompt.singlePassInstruction(meetingDate: meeting.date, calendar: calendar)
        }

        /// The map prompt's focus block (`mapFocusTokens`) and a line break, or
        /// `""` when there is neither prep nor notes.
        var mapFocus: String {
            let block = SummaryPromptContext.focusBlock(
                prep: prep, notes: freeformNotes, maxTokens: SummaryPromptContext.mapFocusTokens
            )
            return block.isEmpty ? "" : block + "\n"
        }

        /// Output cap for intermediate (map/merge) calls. Uncapped when thinking is
        /// on, otherwise the reasoning eats the budget and the notes vanish.
        var intermediateMaxTokens: Int? {
            thinkingEnabled ? nil : LLMPromptSupport.mapOutputTokens
        }
    }

    /// Tokens the summary prompt costs before any transcript goes in: template,
    /// focus block (at `focusTokens`), terminology, metadata, the JSON facts
    /// instruction (single pass only) and the thinking switch.
    static func summaryOverhead(
        context: PromptContext,
        focusTokens: Int = SummaryPromptContext.maxFocusTokens,
        includesFactsInstruction: Bool = true
    ) -> Int {
        let prompt = includesFactsInstruction
            ? context.singlePassPrompt(transcript: "", focusTokens: focusTokens)
            : context.summaryPrompt(transcript: "", focusTokens: focusTokens)
        return LLMPromptSupport.budgetTokens(
            LLMPromptSupport.applyThinkingSwitch(to: prompt, thinkingEnabled: context.thinkingEnabled)
        )
    }

    /// Upper bound on one call's prompt for the single pass and for each map
    /// part, for every provider: past it, extraction quality drops even where
    /// the context window is far larger. Merge and reduce keep the provider's
    /// full budget.
    static let onePassTokenCap = 25_000

    /// `min(budget, onePassTokenCap)`.
    static func onePassBudget(_ budget: Int) -> Int {
        min(budget, onePassTokenCap)
    }

    /// Single pass when the whole transcript plus the rest of the prompt fits the
    /// provider's input budget, capped at `onePassTokenCap`.
    static func fitsInOnePass(transcript: String, context: PromptContext, budget: Int) -> Bool {
        onePassFocusTokens(transcript: transcript, context: context, budget: budget) != nil
    }

    /// The focus cap that lets the whole transcript go in one call, or nil when
    /// it must be condensed first. Tries `maxFocusTokens`; otherwise shrinks the
    /// focus to `budget − transcriptTokens − overheadWithoutFocus`, which must be
    /// at least `minFocusTokens`. The transcript itself is never trimmed.
    static func onePassFocusTokens(transcript: String, context: PromptContext, budget: Int) -> Int? {
        let budget = onePassBudget(budget)
        let full = SummaryPromptContext.maxFocusTokens
        if transcript.isEmpty { return full }
        let transcriptTokens = LLMPromptSupport.budgetTokens(transcript)
        if transcriptTokens + summaryOverhead(context: context, focusTokens: full) <= budget {
            return full
        }
        let overheadWithoutFocus = summaryOverhead(context: context, focusTokens: 0)
        var focus = budget - transcriptTokens - overheadWithoutFocus
        // The block's own line breaks and rounding can add a token or two;
        // measure the real prompt and give that back from the focus.
        while focus >= SummaryPromptContext.minFocusTokens {
            let tokens = LLMPromptSupport.budgetTokens(
                LLMPromptSupport.applyThinkingSwitch(
                    to: context.singlePassPrompt(transcript: transcript, focusTokens: focus),
                    thinkingEnabled: context.thinkingEnabled
                )
            )
            if tokens <= budget { return focus }
            focus -= tokens - budget
        }
        return nil
    }

    /// One part's (or one merged group's) condensed notes, with the timestamp
    /// range it covers for its `## Part i/N (start–end)` heading.
    struct CondensedNote: Equatable {
        let text: String
        let startLabel: String?
        let endLabel: String?
    }

    /// Map-reduce result: the text that replaces `{{transcript}}` in the user's
    /// template, plus what the user must be warned about.
    private struct CondensedTranscript {
        let text: String
        let wasElided: Bool
        let outputWasTruncated: Bool
        /// The parts' merged facts when every part decoded; nil otherwise.
        let mapFacts: SummaryFacts?
        /// The facts of the parts that did decode.
        let decodedPartFacts: [SummaryFacts]
    }

    /// Condenses `transcript` part by part (map), merges the notes until they fit
    /// (at most `LLMPromptSupport.maxMergeLevels` levels), and as a last resort
    /// middle-elides the joined notes.
    private func condense(
        _ transcript: String,
        context: PromptContext,
        provider: LLMProvider
    ) async throws -> CondensedTranscript {
        let budget = provider.promptTokenBudget
        var outputWasTruncated = false

        let parts = try await mapParts(
            of: transcript,
            context: context,
            provider: provider,
            outputWasTruncated: &outputWasTruncated
        )
        var notes = parts.map(\.note)
        let decoded = parts.compactMap { part -> SummaryFacts? in
            if case .facts(let facts) = part.part { return facts }
            return nil
        }
        // Every part decoded: the reduce gets the merged action items to use
        // verbatim. Otherwise it gets none, and its markdown is the fallback.
        let mapFacts = decoded.count == parts.count ? SummaryFacts.merged(decoded) : nil
        let actionItemsBlock = mapFacts.map(Self.reducedActionItemsBlock) ?? ""

        // The reduce prompt carries no JSON instruction; the action-item list
        // is never elided, so it comes off the notes' room.
        let reduceCapacity = budget
            - Self.summaryOverhead(context: context, includesFactsInstruction: false)
            - LLMPromptSupport.budgetTokens(actionItemsBlock)
        let mergeCapacity = budget - LLMPromptSupport.budgetTokens(
            LLMPromptSupport.applyThinkingSwitch(
                to: Self.mergePrompt(notes: "", context: context),
                thinkingEnabled: context.thinkingEnabled
            )
        )

        var level = 0
        // `reduceCapacity <= 0`: the template and notes alone fill the budget, so
        // no amount of merging can make the notes fit — skip straight to the
        // fallback instead of spending calls on it.
        while reduceCapacity > 0,
              LLMPromptSupport.budgetTokens(Self.reduceJoin(notes)) > reduceCapacity,
              level < LLMPromptSupport.maxMergeLevels {
            let groups = Self.mergeGroups(notes, capacityTokens: mergeCapacity)
            // A level that cannot combine anything would only repeat itself.
            guard groups.count < notes.count else { break }
            level += 1
            notes = try await mergeLevel(
                level,
                notes: notes,
                groups: groups,
                context: context,
                provider: provider,
                outputWasTruncated: &outputWasTruncated
            )
        }

        let joined = Self.reduceJoin(notes)
        let fits = LLMPromptSupport.budgetTokens(joined) <= reduceCapacity
        // Never elide the notes to nothing: a template that leaves (almost) no
        // room still gets `minReduceNotesTokens` of them, over budget if need be.
        let text = fits ? joined : LLMPromptSupport.middleElide(
            joined,
            toCharBudget: max(reduceCapacity, Self.minReduceNotesTokens) * LLMPromptSupport.budgetCharsPerToken
        )
        return CondensedTranscript(
            text: text + actionItemsBlock,
            wasElided: !fits,
            outputWasTruncated: outputWasTruncated,
            mapFacts: mapFacts,
            decodedPartFacts: decoded
        )
    }

    /// The fewest tokens of condensed notes the reduce ever gets after eliding.
    static let minReduceNotesTokens = 500

    /// Heading above the de-duplicated action items appended to the reduce input.
    static let reducedActionItemsHeading = "Action items already extracted from the transcript (de-duplicated; use exactly these in the action items section):"

    /// `"\n\n" + heading + "\n"` and one `- ` + `ActionItemRendering.bullet` line per item.
    static func reducedActionItemsBlock(_ facts: SummaryFacts) -> String {
        let lines = facts.actionItems.map { "- " + ActionItemRendering.bullet(for: $0) }
        return "\n\n" + reducedActionItemsHeading + "\n" + lines.joined(separator: "\n")
    }

    /// One map part: what it produced and its note for the merge/reduce input.
    private struct MappedPart {
        let part: CondensedPart
        let note: CondensedNote
    }

    /// Map step: one call per transcript part, asking for JSON facts. Completed
    /// parts (decoded or fallen back to markdown) are cached so a retry after a
    /// failed part resumes where it stopped.
    private func mapParts(
        of transcript: String,
        context: PromptContext,
        provider: LLMProvider,
        outputWasTruncated: inout Bool
    ) async throws -> [MappedPart] {
        // Measured with wide placeholders (three-digit part numbers, h:mm:ss
        // labels) so a full part plus its real header never exceeds the budget.
        let widestHeader = TranscriptChunk(index: 998, text: "", startLabel: "00:00:00", endLabel: "00:00:00")
        let mapOverhead = LLMPromptSupport.budgetTokens(
            LLMPromptSupport.applyThinkingSwitch(
                to: Self.mapPrompt(chunk: widestHeader, total: 999, context: context),
                thinkingEnabled: context.thinkingEnabled
            )
        )
        let chunkTokens = Self.chunkTokens(budget: provider.promptTokenBudget, mapPromptOverhead: mapOverhead)
        let chunks = TranscriptChunker.chunks(
            of: transcript,
            chunkTokens: chunkTokens,
            // Never let the overlap crowd out the part's own new lines.
            overlapTokens: min(LLMPromptSupport.summaryOverlapTokens, chunkTokens / 2)
        )

        if condensedPartCacheMeetingID != context.meeting.id {
            condensedPartCache = [:]
            condensedPartCacheMeetingID = context.meeting.id
        }
        let transcriptHash = Self.sha256(transcript)
        let focusHash = Self.sha256(context.mapFocus)
        let outputCap = Self.mapJSONOutputTokens(chunkTokens: chunkTokens, thinkingEnabled: context.thinkingEnabled)

        var parts: [MappedPart] = []
        for chunk in chunks {
            let key = CondensedPartKey(
                meetingID: context.meeting.id,
                transcriptSHA256: transcriptHash,
                provider: "\(provider.displayName)|\(provider.endpoint)",
                terminologyBlock: context.terminologyBlock,
                focusSHA256: focusHash,
                meetingDate: context.meeting.date,
                thinkingEnabled: context.thinkingEnabled,
                chunkTokens: chunkTokens,
                chunkIndex: chunk.index
            )
            let part: CondensedPart
            if let cached = condensedPartCache[key] {
                part = cached
            } else {
                let prompt = LLMPromptSupport.applyThinkingSwitch(
                    to: Self.mapPrompt(chunk: chunk, total: chunks.count, context: context),
                    thinkingEnabled: context.thinkingEnabled
                )
                let raw = try await intermediateStep(
                    .condensing(part: chunk.index + 1, of: chunks.count),
                    prompt: prompt,
                    context: context,
                    provider: provider,
                    maxTokens: .some(outputCap),
                    outputWasTruncated: &outputWasTruncated
                )
                part = try await decodeMapPart(
                    raw,
                    context: context,
                    provider: provider,
                    maxTokens: outputCap,
                    outputWasTruncated: &outputWasTruncated
                )
                // A markdown fallback is not cached: Retry tries its JSON again.
                if case .facts = part { condensedPartCache[key] = part }
            }
            let text: String
            switch part {
            case .facts(let facts): text = facts.notesMarkdown()
            case .markdown(let raw): text = raw
            }
            parts.append(MappedPart(
                part: part,
                note: CondensedNote(text: text, startLabel: chunk.startLabel, endLabel: chunk.endLabel)
            ))
        }
        return parts
    }

    /// A map reply's facts; an unreadable reply gets one repair call (the same
    /// prompt as the single pass's), and when that is unreadable too, or the
    /// call fails, the raw reply is kept as markdown notes. Cancellation
    /// propagates.
    private func decodeMapPart(
        _ raw: String,
        context: PromptContext,
        provider: LLMProvider,
        maxTokens: Int?,
        outputWasTruncated: inout Bool
    ) async throws -> CondensedPart {
        func decoded(_ text: String) -> SummaryFacts? {
            guard let object = SummaryFactsParser.extractJSONObject(text),
                  case .success(let facts) = SummaryFactsParser.decodeFacts(
                    object, meetingDate: context.meeting.date, calendar: context.calendar
                  )
            else { return nil }
            return facts
        }
        if let facts = decoded(raw) { return .facts(facts) }

        let reply: String
        do {
            reply = try await generateStep(
                .repairing,
                prompt: LLMPromptSupport.applyThinkingSwitch(
                    to: SummaryFactsPrompt.repairPrompt(broken: raw),
                    thinkingEnabled: context.thinkingEnabled
                ),
                maxTokens: maxTokens,
                provider: provider,
                outputWasTruncated: &outputWasTruncated
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            Log.summarization.warning("Repairing a part's facts JSON failed: \(error.localizedDescription)")
            return .markdown(raw)
        }
        if let facts = decoded(LLMPromptSupport.stripReasoningTags(reply)) { return .facts(facts) }
        return .markdown(raw)
    }

    /// One merge level: every multi-note group becomes one note; a single-note
    /// group passes through without a call.
    private func mergeLevel(
        _ level: Int,
        notes: [CondensedNote],
        groups: [Range<Int>],
        context: PromptContext,
        provider: LLMProvider,
        outputWasTruncated: inout Bool
    ) async throws -> [CondensedNote] {
        var merged: [CondensedNote] = []
        for group in groups {
            let members = Array(notes[group])
            guard members.count > 1 else {
                merged.append(contentsOf: members)
                continue
            }
            let prompt = LLMPromptSupport.applyThinkingSwitch(
                to: Self.mergePrompt(
                    notes: Self.partSections(members, firstPart: group.lowerBound + 1, total: notes.count),
                    context: context
                ),
                thinkingEnabled: context.thinkingEnabled
            )
            let text = try await intermediateStep(
                .merging(level: level),
                prompt: prompt,
                context: context,
                provider: provider,
                outputWasTruncated: &outputWasTruncated
            )
            merged.append(CondensedNote(text: text, startLabel: members.first?.startLabel, endLabel: members.last?.endLabel))
        }
        return merged
    }
    // MARK: - Generation steps

    /// One provider call for a pipeline step: shows `stepPhase`, honours
    /// cancellation, retries transient failures (showing `.retrying`), maps
    /// provider errors, and shows `stepPhase` again once the call succeeded so
    /// "retrying" never sticks. Records an output-limit hit in `outputWasTruncated`.
    private func generateStep(
        _ stepPhase: SummarizationPhase,
        prompt: String,
        maxTokens: Int?,
        provider: LLMProvider,
        outputWasTruncated: inout Bool
    ) async throws -> String {
        phase = stepPhase
        try Task.checkCancellation()
        var wasTruncated = false
        let retryPolicy = self.retryPolicy
        let text: String
        do {
            text = try await retryPolicy.withRetry(
                onAttempt: { [weak self] attempt in
                    self?.phase = .retrying(attempt: attempt, maxAttempts: retryPolicy.maxAttempts)
                }
            ) {
                try await provider.generate(
                    prompt: prompt,
                    temperature: nil,
                    maxTokens: maxTokens,
                    // 120s is what a local model needs for a structured summary;
                    // a provider that answers over the network says so itself,
                    // because a timeout here costs `maxAttempts` generations.
                    timeout: provider.timeout(orDefault: 120),
                    truncated: { wasTruncated = $0 }
                )
            }
        } catch let error as LLMProviderError {
            throw Self.mapProviderError(error)
        }
        if wasTruncated { outputWasTruncated = true }
        phase = stepPhase
        return text
    }

    /// A map or merge call: capped output (unless thinking), reasoning tags
    /// stripped. Empty notes are an error — silently skipping a part would drop
    /// that stretch of the meeting from the summary.
    private func intermediateStep(
        _ stepPhase: SummarizationPhase,
        prompt: String,
        context: PromptContext,
        provider: LLMProvider,
        maxTokens: Int?? = nil,
        outputWasTruncated: inout Bool
    ) async throws -> String {
        let raw = try await generateStep(
            stepPhase,
            prompt: prompt,
            maxTokens: maxTokens ?? context.intermediateMaxTokens,
            provider: provider,
            outputWasTruncated: &outputWasTruncated
        )
        let notes = LLMPromptSupport.stripReasoningTags(raw)
        guard !notes.isEmpty else {
            throw SummarizationError.emptyResponse(provider: provider.displayName)
        }
        return notes
    }

    // MARK: - Map-reduce prompt building

    /// Part size for the map step, against `min(budget, onePassTokenCap)`.
    /// Local providers get ≤ 4,000-token parts; a large-context provider gets
    /// parts of about half the cap instead of dozens of serial calls. Never
    /// below 1,000 tokens.
    static func chunkTokens(budget: Int, mapPromptOverhead: Int) -> Int {
        let budget = onePassBudget(budget)
        return max(1_000, min(budget - mapPromptOverhead, max(4_000, budget / 2)))
    }

    /// Output cap for a JSON map call and its repair: a fifth of the part's
    /// size, at least 1,500 tokens, so quotes and items fit (merge calls keep
    /// `LLMPromptSupport.mapOutputTokens`). Uncapped when thinking is on.
    static func mapJSONOutputTokens(chunkTokens: Int, thinkingEnabled: Bool) -> Int? {
        thinkingEnabled ? nil : max(1_500, chunkTokens / 5)
    }

    /// The fixed map prompt: one JSON facts object per part (English
    /// instructions; values in the transcript's language).
    static func mapPrompt(chunk: TranscriptChunk, total: Int, context: PromptContext) -> String {
        // No blank line where an empty terminology block or focus would have gone.
        let terminology = context.terminologyBlock.isEmpty ? "" : context.terminologyBlock + "\n"
        let focus = context.mapFocus
        return """
        You are extracting facts from part \(chunk.index + 1) of \(total) of a meeting transcript
        (\(chunk.startLabel ?? "?")–\(chunk.endLabel ?? "?")) so it can be summarized later.
        \(meetingLine(context: context))
        \(terminology)\(focus)Return only one JSON object, no prose and no code fence, with exactly this shape:
        \(SummaryFactsPrompt.objectShape)
        \(SummaryFactsPrompt.rules(meetingDate: context.meeting.date, calendar: context.calendar))
        - Keep each "quote" to about 15 words at most.
        Only use this part of the transcript.

        Transcript part:
        \(chunk.text)
        """
    }

    /// The fixed merge prompt: combines consecutive condensed notes into one set
    /// with the map step's headings.
    static func mergePrompt(notes: String, context: PromptContext) -> String {
        """
        You are merging consecutive parts of the condensed notes of one long meeting so it can be summarized later.
        \(meetingLine(context: context))
        Merge these chronological partial meeting notes into one set of notes with the same headings; deduplicate; keep timestamps and owners.
        Write in the language of the notes, as markdown bullets under these headings:
        \(noteHeadings)
        Omit empty headings. No preamble.

        Partial notes:
        \(notes)
        """
    }

    private static let noteHeadings = """
    ### Topics discussed
    ### Decisions
    ### Action items (owner: what)
    ### Open questions and risks
    ### Notable statements and figures
    """

    /// "Meeting: … Participants: … The note-taker is …." — the note-taker sentence
    /// only when a name is known.
    private static func meetingLine(context: PromptContext) -> String {
        var line = "Meeting: \(context.meeting.title). Participants: \(context.participantsLine)."
        if let name = context.userName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            line += " The note-taker is \(name)."
        }
        return line
    }

    /// First line of the reduce input, so the user's template treats the notes as
    /// the transcript and deduplicates across part boundaries.
    static let condensedNotesPreamble = "[Condensed notes of a long transcript, in chronological order — summarize these as the transcript.]"

    /// The notes under `## Part i/N (start–end)` headings, numbered from `firstPart`.
    static func partSections(_ notes: [CondensedNote], firstPart: Int, total: Int) -> String {
        notes.enumerated().map { offset, note in
            "## Part \(firstPart + offset)/\(total) (\(note.startLabel ?? "?")–\(note.endLabel ?? "?"))\n\(note.text)"
        }
        .joined(separator: "\n\n")
    }

    /// The text that replaces `{{transcript}}` in the user's template.
    static func reduceJoin(_ notes: [CondensedNote]) -> String {
        condensedNotesPreamble + "\n\n" + partSections(notes, firstPart: 1, total: notes.count)
    }

    /// Greedy grouping of consecutive notes whose part sections fit
    /// `capacityTokens`. A note too big to share a group stands alone.
    static func mergeGroups(_ notes: [CondensedNote], capacityTokens: Int) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var start = 0
        while start < notes.count {
            var end = start + 1
            while end < notes.count,
                  LLMPromptSupport.budgetTokens(
                    partSections(Array(notes[start...end]), firstPart: start + 1, total: notes.count)
                  ) <= capacityTokens {
                end += 1
            }
            groups.append(start..<end)
            start = end
        }
        return groups
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Cancels the detached background summarization task, if any. Called on app
    /// termination so the view-independent task doesn't outlive the process. The
    /// `Task.isCancelled` guard in `summarizeInBackground`'s catch suppresses the
    /// resulting cancellation error, so this is a clean stop.
    func cancelBackgroundWork() {
        backgroundTask?.cancel()
    }

    func clearError() {
        errorMessage = nil
    }

    func clearWarning() {
        warningMessage = nil
    }

    static func fetchAvailableModels(endpoint: String? = nil) async throws -> [String] {
        let provider = LLMProviderFactory.current()
        do {
            return try await provider.fetchAvailableModels(endpoint: endpoint ?? provider.endpoint)
        } catch let error as LLMProviderError {
            throw Self.mapProviderError(error)
        }
    }

    private static func mapProviderError(_ error: LLMProviderError) -> SummarizationError {
        switch error {
        case .invalidEndpoint(let provider):
            return .invalidEndpoint(provider: provider)
        case .requestFailed(_, _, let message):
            return .requestFailed(message)
        case .emptyResponse(let provider):
            return .emptyResponse(provider: provider)
        }
    }

    static func renderPrompt(
        template: String,
        meeting: Meeting,
        transcript: String,
        freeformNotes: String,
        terminologyBlock: String,
        userName: String? = nil,
        participantsLine: String? = nil,
        focusBlock: String = ""
    ) -> String {
        let formattedDate = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: meeting.date)
        }()

        // Who "I" is in the transcript, so the model attributes the note-taker's
        // own commitments to them. A custom template saved before `{{user_name}}`
        // existed gets the same instruction appended instead, so it still benefits.
        let name = userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var template = template
        if template.contains("{{user_name}}") {
            template = template.replacingOccurrences(of: "{{user_name}}", with: name.isEmpty ? "unknown" : name)
        } else if !name.isEmpty {
            template += "\n\nThe note-taker is \(name). When the note-taker commits to something (\"I will…\", \"ik pak dat op\"), the action item's owner is \(name)."
        }

        template = placeFocus(in: template, hasFocus: !focusBlock.isEmpty)

        let participants = participantsLine
            ?? (meeting.participants.isEmpty ? "Unknown" : meeting.participants.joined(separator: ", "))
        return template
            .replacingOccurrences(of: "{{title}}", with: meeting.title)
            .replacingOccurrences(of: "{{scheduled_time}}", with: formattedDate)
            .replacingOccurrences(of: "{{participants}}", with: participants)
            .replacingOccurrences(of: "{{transcript}}", with: transcript.isEmpty ? "None" : transcript)
            .replacingOccurrences(of: "{{freeform_notes}}", with: freeformNotes.isEmpty ? "None" : freeformNotes)
            .replacingOccurrences(of: "{{terminology_list}}", with: terminologyBlock)
            // Last, so nothing in the user's prep or notes is substituted again.
            .replacingOccurrences(of: focusPlaceholder, with: focusBlock)
    }

    private static let focusPlaceholder = "{{user_focus}}"

    /// Prepares `{{user_focus}}` in the template. Without a focus, a line that is
    /// only the placeholder goes, with one following blank line. With a focus, a
    /// template lacking the placeholder gets it on its own lines directly before
    /// the `{{transcript}}` line (or before a `Transcript:` heading right above
    /// it); with no `{{transcript}}` at all it is appended at the end.
    private static func placeFocus(in template: String, hasFocus: Bool) -> String {
        var lines = template.components(separatedBy: "\n")
        guard hasFocus else {
            guard template.contains(focusPlaceholder) else { return template }
            var index = 0
            while index < lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces) == focusPlaceholder {
                    lines.remove(at: index)
                    if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        lines.remove(at: index)
                    }
                } else {
                    index += 1
                }
            }
            return lines.joined(separator: "\n").replacingOccurrences(of: focusPlaceholder, with: "")
        }
        guard !template.contains(focusPlaceholder) else { return template }
        guard var index = lines.firstIndex(where: { $0.contains("{{transcript}}") }) else {
            return template + "\n\n" + focusPlaceholder
        }
        if index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces) == "Transcript:" {
            index -= 1
        }
        lines.insert(contentsOf: [focusPlaceholder, ""], at: index)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Summary outcome

extension SummarizationService {
    /// Where an outcome's facts came from.
    enum FactsSource: Equatable {
        /// The single pass's JSON block decoded as-is.
        case singlePassJSON
        /// One repair (invalid block) or rebuild (no block) call produced them.
        case repairedJSON
        /// Merged from the map step's per-part JSON.
        case mapJSON
        /// Recovered from the summary's markdown sections.
        case markdownFallback
    }

    /// A summary with its structured facts.
    struct SummaryOutcome {
        let parsed: SummaryResponseParser.ParsedResponse
        let facts: SummaryFacts
        let factsSource: FactsSource
        let templateID: String
    }

    /// Joined into `warningMessage` whenever the facts are `.markdownFallback`
    /// after a failed or lossy repair.
    static let verificationFailedWarning = "Couldn't check the action items against the transcript; review them before accepting."
    static let factsFallbackWarning = "Couldn't read the structured action items; to-dos were taken from the summary text instead."
}
