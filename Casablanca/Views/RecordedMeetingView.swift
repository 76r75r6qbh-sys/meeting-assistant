import AppKit
import SwiftUI

struct RecordedMeetingView: View {
    @Bindable var meeting: Meeting
    let onRecordAgain: () -> Void
    let onTranscribe: () -> Void
    /// Navigate to another meeting (used by the recurring-series prev/next links
    /// in the inspector). Optional so previews/tests can omit it.
    var onSelectMeeting: ((Meeting) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.autoSummarizeAfterTranscription) private var autoSummarizeAfterTranscription = false
    @AppStorage(AppPreferenceKey.autoExportEnabled) private var autoExportEnabled = false
    @Environment(AppModel.self) private var appModel
    private var summarizationService: SummarizationService { appModel.summarizationService }
    private var terminologyService: TerminologyService { appModel.terminologyService }
    private var transcriptionService: TranscriptionService { appModel.transcriptionService }
    private var exportStatusCenter: ExportStatusCenter { appModel.exportStatusCenter }
    /// The meeting the automatic summary was already requested for. Keyed by
    /// id, not a Bool: ContentView shows every completed meeting in this same
    /// view instance, so a Bool set for meeting A kept B from ever
    /// auto-summarizing.
    @State private var automaticSummaryTriggeredFor: UUID?
    @State private var selectedTab: DetailTab = .summary
    // Real initial value is owned by `.onChange(of: widthClass, initial: true)`,
    // which opens the inspector only when the window is wide enough.
    @State private var showInspector = false
    // Owned by this long-lived view so they survive tab switches: the notes
    // edit toggle persists, and a pending debounced save is not cancelled when
    // the user leaves the Notes tab (which tears down MeetingNotesTab).
    @State private var isEditingNotes = false
    @State private var saveTask: Task<Void, Never>?
    // In-memory chat, owned by this detail view so it survives tab switches and
    // resets when the user navigates to a different meeting (keyed internally by
    // meeting id). No persistence in v1.
    @State private var chatService = MeetingChatService()
    /// A timestamp-link jump handed to the transcript tab, until it is done.
    @State private var transcriptJump: TimestampJump?
    /// "Regenerate summary" after a speaker rename or merge, per meeting.
    @State private var summaryOffer = SummaryRegenerationOffer()
    private let navigator = MeetingDetailNavigator.shared
    private let playback = TranscriptPlayback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Responsive width tier of the window, published by ContentView. Defaults
    /// to `.expanded` so previews and tests keep the inspector visible.
    @Environment(\.layoutWidthClass) private var widthClass

    private enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "Notes"
        case ask = "Ask"

        var id: String { rawValue }
    }

    /// Changes when the meeting or the pending jump does.
    private struct JumpKey: Equatable {
        let meetingID: UUID
        let token: UUID?
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                readingColumn(scrollProxy: scrollProxy)
                    .padding(CasaSpace.xl)
                    .frame(maxWidth: CasaLayout.contentMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            // Pinned above the transcript, outside the scroll content.
            // Playback keeps going on other tabs; it stops when the meeting
            // changes or this view goes away.
            .safeAreaInset(edge: .top, spacing: 0) {
                if selectedTab == .transcript {
                    TranscriptTransportInset(
                        meeting: meeting,
                        isTranscribing: isTranscribingThisMeeting,
                        playback: playback
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A timestamp link for this meeting: show the transcript tab, which
        // scrolls and plays. `initial` covers a jump that selected this
        // meeting and created this view.
        .onChange(of: JumpKey(meetingID: meeting.id, token: navigator.pendingJump?.token), initial: true) { _, _ in
            guard let jump = navigator.pendingJump, jump.meetingID == meeting.id else { return }
            selectedTab = .transcript
            transcriptJump = jump
            navigator.complete(jump)
        }
        .onDisappear { stopPlayback(unlessItBelongsTo: nil) }
        // Any new summary run (banner, template menu, retry, toolbar) reads the
        // renamed transcript, so it answers that meeting's offer. Keyed on the
        // start time, not on "this meeting is summarizing", so navigating back
        // to a meeting mid-run does not count as a new start.
        .onChange(of: summarizationService.summarizationStartedAt) { _, started in
            guard started != nil, let id = summarizationService.summarizingMeetingID else { return }
            summaryOffer.summaryStarted(for: id)
        }
        // Native trailing inspector (AppKit-driven resize, HIG-compliant),
        // presented only while the window is wide enough to hold it.
        .widthGatedInspector(isPresented: $showInspector, idealWidth: 320) {
            MeetingDetailInspector(meeting: meeting, canExport: canExport, onSelectMeeting: onSelectMeeting)
        }
        // Show the inspector by default only when the window is wide enough.
        // Re-evaluated on tier crossings, so a manual toggle within a tier sticks.
        .onChange(of: widthClass, initial: true) { _, cls in
            withAnimation(reduceMotion ? nil : CasaAnimation.fast) {
                showInspector = (cls == .expanded)
            }
        }
        .navigationTitle(meeting.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let primaryToolbarAction {
                    toolbarButton(for: primaryToolbarAction, isPrimary: true)
                }

                Button {
                    withAnimation(reduceMotion ? nil : CasaAnimation.fast) { showInspector.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .disabled(!widthClass.allowsInspector)
                .help(widthClass.allowsInspector
                    ? (showInspector ? "Hide inspector" : "Show inspector")
                    : "Widen the window to show the inspector")

                secondaryActionsMenu
            }
        }
        .task(id: meeting.id) {
            // This view instance is reused across completed meetings, so the
            // per-meeting state is reset here rather than by `.id(meeting.id)`,
            // which would also rebuild the inspector and reset its visibility,
            // the selected tab and the scroll position on every navigation.
            // A pending debounced save is let run (not cancelled): it saves the
            // previous meeting's edit, and the next edit must not cancel it.
            isEditingNotes = false
            saveTask = nil
            terminologyService.clearWarning()
            // Another meeting's recording must not keep playing without a
            // visible transport (a jump into this meeting may already play).
            stopPlayback(unlessItBelongsTo: meeting)
            if transcriptJump?.meetingID != meeting.id { transcriptJump = nil }
            await triggerAutomaticSummaryIfNeeded()
        }
        .alert("Summary Error", isPresented: summaryErrorBinding) {
            Button("OK", role: .cancel) {
                summarizationService.clearError()
            }
        } message: {
            Text(summarizationService.errorMessage ?? "Unable to summarize the meeting.")
        }
    }

    // MARK: - Reading column

    private func readingColumn(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.xl) {
            infoBar

            Picker("View", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if shouldShowPipelineCard {
                ProcessingStatusCard(
                    presentation: pipelinePresentation,
                    transcriptionProgress: transcriptionService.progress,
                    summarizationStartedAt: summarizationService.summarizationStartedAt,
                    onCancel: cancelActiveStage,
                    onRetry: retryFailedStage,
                    onDismissError: dismissPipelineError,
                    onDismissWarning: { summarizationService.clearWarning() }
                )
            }

            switch selectedTab {
            case .summary:
                MeetingSummaryTab(
                    meeting: meeting,
                    isSummarizing: isSummarizingThisMeeting,
                    statusMessage: summarizationService.statusMessage,
                    canSummarize: canSummarize,
                    onSummarize: {
                        summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
                    },
                    showRegenerateOffer: summaryOffer.offerRegenerateSummary(
                        for: meeting,
                        isSummarizing: summarizationService.isSummarizing
                    ),
                    onRegenerateOffer: regenerateSummaryWithNames,
                    onDismissRegenerateOffer: { summaryOffer.dismiss(meeting) }
                )
            case .transcript:
                MeetingTranscriptTab(
                    meeting: meeting,
                    terminologyService: terminologyService,
                    onTranscribe: onTranscribe,
                    onSave: save,
                    onSpeakersChanged: { changed in
                        summaryOffer.speakersChanged(
                            on: changed,
                            isSummarizingThisMeeting: isSummarizingThisMeeting
                        )
                    },
                    jump: transcriptJump,
                    scrollProxy: scrollProxy,
                    isTranscribing: isTranscribingThisMeeting,
                    onJumpHandled: { transcriptJump = nil },
                    playback: playback
                )
            case .notes:
                MeetingNotesTab(
                    meeting: meeting,
                    isEditingNotes: $isEditingNotes,
                    onNotesEdited: debouncedSave
                )
            case .ask:
                MeetingChatTab(
                    meeting: meeting,
                    chatService: chatService,
                    hasGroundingContent: hasGroundingContent,
                    // The local LLM serializes requests — a chat during any
                    // background summary would queue and risk the 120s timeout.
                    isSummaryInProgress: summarizationService.summarizingMeetingID != nil
                )
            }

            Spacer(minLength: 0)
        }
    }

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack(spacing: CasaSpace.md) {
                Label(meeting.formattedTime, systemImage: "calendar")

                if let duration = meeting.recordingDuration {
                    Label(duration.formattedRecordingDuration, systemImage: "timer")
                }

                if recordingURL != nil {
                    Label("Recording saved locally", systemImage: "waveform")
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.textSecondary)
            .symbolRenderingMode(.hierarchical)

            if meeting.transcript == nil, recordingURL != nil {
                HStack(spacing: CasaSpace.md) {
                    Text("Language")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)

                    Picker("Language", selection: $meeting.transcriptionLanguage) {
                        ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: meeting.transcriptionLanguage) {
                        save()
                    }
                }
            }
        }
    }

    /// Pure presentation driving the ProcessingStatusCard, built fresh each render
    /// from the live services + this meeting's state.
    private var pipelinePresentation: MeetingPipelinePresentation {
        MeetingPipelinePresentation(
            isThisMeetingTranscribing: isTranscribingThisMeeting,
            transcriptionProgress: transcriptionService.progress,
            isSummarizingThisMeeting: isSummarizingThisMeeting,
            summarizationPhase: summarizationService.phase,
            summarizationStartedAt: summarizationService.summarizationStartedAt,
            summarizationError: summarizationService.errorMessage,
            summarizationWarning: summarizationService.warningMessage,
            summarizationProviderName: summarizationService.providerDisplayName,
            autoExportFailure: exportStatusCenter.failure(for: meeting.id),
            meetingStatus: meeting.status,
            hasTranscript: meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasSummary: meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            autoSummarize: autoSummarizeAfterTranscription,
            autoExport: autoExportEnabled
        )
    }

    /// True while this meeting is the one actively transcribing. Transcription is
    /// app-wide and ordinarily runs in TranscriptionView, but the meeting carries
    /// `.processing` for its duration, so we scope by that + the service flag.
    private var isTranscribingThisMeeting: Bool {
        transcriptionService.isTranscribing && meeting.status == .processing
    }

    private func cancelActiveStage() {
        switch pipelinePresentation.stage {
        case .transcribing:
            transcriptionService.cancel()
        case .summarizing:
            summarizationService.cancelBackgroundWork()
        default:
            break
        }
    }

    private func retryFailedStage() {
        guard case .failed(let stage, _) = pipelinePresentation.stage else { return }
        switch stage {
        case .transcription:
            onTranscribe()
        case .summarization:
            summarizationService.clearError()
            summarizationService.clearWarning()
            summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
        case .export:
            exportStatusCenter.clearFailure(for: meeting.id)
            Task { @MainActor in
                await ExportService.exportAutomaticallyIfEnabled(meeting, reporter: exportStatusCenter)
            }
        }
    }

    private func dismissPipelineError() {
        guard case .failed(let stage, _) = pipelinePresentation.stage else { return }
        switch stage {
        case .transcription:
            break
        case .summarization:
            summarizationService.clearError()
            summarizationService.clearWarning()
        case .export:
            exportStatusCenter.clearFailure(for: meeting.id)
        }
    }

    @ViewBuilder
    private func toolbarButton(for action: ReviewPrimaryAction, isPrimary: Bool) -> some View {
        switch action {
        case .transcribe:
            Button(action: onTranscribe) {
                Label("Transcribe", systemImage: "waveform")
            }
        case .summarize:
            Button {
                summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
            } label: {
                Label("Summarize", systemImage: isSummarizingThisMeeting ? "hourglass" : "sparkles")
            }
            .disabled(!canSummarize || summarizationService.isSummarizing)
        case .export:
            Button {
                exportMeeting()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!canExport)
        }
    }

    private var hasNotes: Bool {
        !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSummarize: Bool {
        meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || hasNotes
    }

    /// Whether there's anything to ground a chat answer on — a transcript or a
    /// summary. (Notes alone aren't enough signal for grounded Q&A; the summary
    /// captures notes anyway.)
    private var hasGroundingContent: Bool {
        meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var canExport: Bool {
        meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || hasNotes
    }

    private var recordingURL: URL? {
        guard let path = meeting.recordingFileURL else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Stops the shared player unless it holds one of `owner`'s audio files.
    private func stopPlayback(unlessItBelongsTo owner: Meeting?) {
        let player = AudioClipPlayer.shared
        guard let url = player.playingURL else { return }
        if let owner, TimestampJumpPlan.isAudio(
            url,
            ofPaths: [owner.recordingFileURL, owner.micTrackFileURL, owner.systemTrackFileURL]
        ) {
            return
        }
        player.stop()
    }

    /// True only when the shared summarization service is processing THIS
    /// meeting — the service is app-wide, so other meetings' detail views must
    /// not show this one's "generating…" state.
    private var isSummarizingThisMeeting: Bool {
        summarizationService.isSummarizing
            && summarizationService.summarizingMeetingID == meeting.id
    }

    /// Show the pipeline card whenever a stage is active, there's an error to
    /// surface (incl. auto-export failures), or there's a non-fatal warning to
    /// show (a success-with-caveat). Otherwise `.done`/`.idle` hide it.
    private var shouldShowPipelineCard: Bool {
        pipelinePresentation.isActive
            || pipelinePresentation.hasError
            || pipelinePresentation.warning != nil
    }

    private var canReapplyTerminology: Bool {
        guard meeting.rawTranscript != nil else { return false }
        guard UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled) else { return false }
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        return !TerminologyService.parse(raw).isEmpty
    }

    private var primaryToolbarAction: ReviewPrimaryAction? {
        reviewPrimaryAction(
            hasTranscript: meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasRecording: recordingURL != nil,
            hasSummary: meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            canSummarize: canSummarize,
            canExport: canExport
        )
    }

    private var summaryErrorBinding: Binding<Bool> {
        Binding(
            get: { summarizationService.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    summarizationService.clearError()
                }
            }
        )
    }

    private func reapplyTerminology() async {
        guard let raw = meeting.rawTranscript else { return }
        let entries = TerminologyService.parse(
            UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        )
        guard !entries.isEmpty else { return }

        // A labelled transcript keeps its speaker prefixes through the correction.
        let knownSpeakers = Set(
            meeting.speakers.map { TranscriptLineFormat.sanitizedSpeakerName($0.displayName) }.filter { !$0.isEmpty }
        )
        let corrected = await terminologyService.correct(raw, entries: entries, knownSpeakers: knownSpeakers)
        guard meeting.modelContext != nil else { return }
        meeting.transcript = corrected
        save()
    }

    private func exportMeeting() {
        save()

        Task { @MainActor in
            do {
                let result = try await ExportService.exportCompletedMeeting(meeting)
                switch result {
                case .obsidian(let export):
                    let message: String
                    if export.summaryURL != nil {
                        message = "Saved the summary note and raw notes to your Obsidian meeting notes folder."
                    } else {
                        message = "Saved raw notes to Obsidian. Generate a summary and export again to add the summary note."
                    }
                    presentExportAlert(
                        title: "Export Complete",
                        message: message,
                        exportedURLs: export.exportedURLs
                    )
                case .appleNotes:
                    presentExportAlert(
                        title: "Export Complete",
                        message: "Saved to Apple Notes folder \"Casablanca\".",
                        exportedURLs: []
                    )
                }
            } catch {
                presentExportAlert(
                    title: "Export Failed",
                    message: error.localizedDescription,
                    exportedURLs: []
                )
            }
        }
    }

    // MARK: - Secondary actions menu

    private var secondaryActionsMenu: some View {
        Menu {
            if primaryToolbarAction != .export, canExport {
                Button {
                    exportMeeting()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }

            if meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, recordingURL != nil {
                Button {
                    onTranscribe()
                } label: {
                    Label("Re-transcribe", systemImage: "waveform")
                }
            }

            if canReapplyTerminology {
                Button {
                    Task { await reapplyTerminology() }
                } label: {
                    Label("Re-apply terminology", systemImage: "wand.and.sparkles")
                }
                .disabled(terminologyService.isCorrecting)
            }

            Button(action: onRecordAgain) {
                Label("Record Again", systemImage: "record.circle")
            }

            if let recordingURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([recordingURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    private func save() {
        try? modelContext.save()
        Task { @MainActor in
            await ExportService.exportAutomaticallyIfEnabled(meeting, reporter: exportStatusCenter)
        }
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// Never automatic: the user may have accepted or edited to-dos. The
    /// regeneration keeps accepted and rejected to-dos and replaces only
    /// pending proposals; the explicit template is kept (nil = auto).
    private func regenerateSummaryWithNames() {
        summaryOffer.regenerate(meeting) { templateID in
            summarizationService.summarizeInBackground(
                meeting: meeting,
                modelContext: modelContext,
                templateID: templateID
            )
        }
    }

    private func triggerAutomaticSummaryIfNeeded() async {
        guard AutomaticSummaryTrigger.shouldTrigger(
            meetingID: meeting.id,
            alreadyTriggeredFor: automaticSummaryTriggeredFor,
            isEnabled: autoSummarizeAfterTranscription,
            transcript: meeting.transcript,
            summary: meeting.summary
        ) else {
            return
        }

        automaticSummaryTriggeredFor = meeting.id
        // Runs in a service-owned background task — keeps going if the user
        // leaves this screen, and silently saves extracted to-dos on completion.
        summarizationService.summarizeInBackground(meeting: meeting, modelContext: modelContext)
    }
}

/// Whether the detail view should request the automatic summary for a meeting.
/// Pure, so the per-meeting rule is testable without SwiftUI.
enum AutomaticSummaryTrigger {
    static func shouldTrigger(
        meetingID: UUID,
        alreadyTriggeredFor: UUID?,
        isEnabled: Bool,
        transcript: String?,
        summary: String?
    ) -> Bool {
        guard isEnabled, alreadyTriggeredFor != meetingID else { return false }
        let hasTranscript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasTranscript && !hasSummary
    }
}
