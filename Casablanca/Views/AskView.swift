import SwiftUI

/// Opens the meeting (and, from Phase 2, the moment) a citation points to.
typealias AskCitationHandler = @MainActor (AskCitationTarget) -> Void

/// The Ask form's input, kept pure so the filter mapping is testable without
/// a view. The view binds its controls to these fields.
struct AskFormState: Equatable {
    var question = ""
    var useDateRange = false
    var from: Date
    var to: Date
    /// `""` = anyone.
    var participant = ""
    /// `""` = any tag.
    var tag = ""

    /// The date pickers start on the last 30 days (only used once the user
    /// turns the date range on).
    init(now: Date = Date(), calendar: Calendar = .current) {
        self.to = now
        self.from = calendar.date(byAdding: .day, value: -30, to: now) ?? now
    }

    /// Empty participant/tag → `nil`; no dates unless `useDateRange`; a
    /// reversed range is swapped so `from <= to`.
    var filter: AskFilter {
        var filter = AskFilter()
        if useDateRange {
            filter.from = min(from, to)
            filter.to = max(from, to)
        }
        filter.participant = Self.criterion(participant)
        filter.tag = Self.criterion(tag)
        return filter
    }

    var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func criterion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// "Ask across meetings": one question over every meeting's summary, action
/// items and transcript, answered with tappable `[title, date, mm:ss]`
/// citations. Single-turn; each ask replaces the previous answer.
struct AskView: View {
    @Bindable var service: AskService
    /// The local model handles one request at a time; asking is disabled
    /// while a summary runs for any meeting.
    let isSummaryInProgress: Bool
    let onOpenCitation: AskCitationHandler

    @State private var form = AskFormState()
    @State private var showsSources = false
    @FocusState private var questionFocused: Bool

    static let summaryBusyHint = "Available after the summary finishes — the local model handles one request at a time."

    private var canAsk: Bool {
        form.canSubmit && !service.isAnswering && !isSummaryInProgress
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.lg) {
                header
                questionField
                filterRow

                HStack(spacing: CasaSpace.sm) {
                    Button("Ask", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAsk)
                        .help("Ask across meetings (⏎)")
                    Spacer(minLength: 0)
                }

                if isSummaryInProgress {
                    banner(Self.summaryBusyHint, systemImage: "info.circle")
                }

                if service.indexMayBeOutdated {
                    banner(AskService.outdatedIndexText, systemImage: "exclamationmark.arrow.circlepath")
                }

                if let progress = progressText {
                    progressRow(progress)
                }

                if let error = service.errorMessage {
                    errorRow(error)
                }

                if let answer = service.answer {
                    answerView(answer)
                } else if !service.isAnswering {
                    emptyState
                }
            }
            .padding(CasaSpace.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { service.prepareIndex() }
        // Leaving Ask stops an in-flight answer, so the local model is not
        // kept busy next to a summary nobody is waiting on.
        .onDisappear { service.cancel() }
        // Index invalidation on store saves is the service's own (debounced)
        // `ModelContext.didSave` observer — no per-view observer here.
        .onChange(of: service.filterOptions.participants) { _, participants in
            if !form.participant.isEmpty, !participants.contains(form.participant) { form.participant = "" }
        }
        .onChange(of: service.filterOptions.tags) { _, tags in
            if !form.tag.isEmpty, !tags.contains(form.tag) { form.tag = "" }
        }
    }

    // MARK: - Header and input

    private var header: some View {
        HStack {
            Label("Ask across meetings", systemImage: "text.bubble")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.accentSecondary)
                .symbolRenderingMode(.hierarchical)
            Spacer(minLength: 0)
        }
    }

    private var questionField: some View {
        TextField("Ask a question about your meetings…", text: $form.question, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .focused($questionFocused)
            .onSubmit(submit)
            .accessibilityLabel("Question")
    }

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CasaSpace.sm) { dateRangeControls }
                VStack(alignment: .leading, spacing: CasaSpace.xs) { dateRangeControls }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CasaSpace.md) { pickerControls }
                VStack(alignment: .leading, spacing: CasaSpace.xs) { pickerControls }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var dateRangeControls: some View {
        Toggle("Date range", isOn: $form.useDateRange)
            .toggleStyle(.checkbox)
        if form.useDateRange {
            DatePicker("From", selection: $form.from, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .accessibilityLabel("From date")
            Text("–")
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
            DatePicker("To", selection: $form.to, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .accessibilityLabel("To date")
        }
    }

    @ViewBuilder
    private var pickerControls: some View {
        Picker("Participant", selection: $form.participant) {
            Text("Anyone").tag("")
            ForEach(service.filterOptions.participants, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 260, alignment: .leading)

        Picker("Tag", selection: $form.tag) {
            Text("Any tag").tag("")
            ForEach(service.filterOptions.tags, id: \.self) { tag in
                Text(tag).tag(tag)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 220, alignment: .leading)
    }

    private func submit() {
        guard canAsk else { return }
        showsSources = false
        service.ask(form.question, filter: form.filter)
    }

    // MARK: - Status rows

    /// A retry status wins (it explains a long wait), then a running index
    /// build, then the generic answering label.
    private var progressText: String? {
        if service.isAnswering, let status = service.statusMessage { return status }
        if service.isIndexing { return "Indexing meetings…" }
        if service.isAnswering { return "Thinking…" }
        return nil
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: CasaSpace.sm) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if service.isAnswering {
                Button("Cancel") { service.cancel() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(CasaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.lg))
        .accessibilityElement(children: .combine)
    }

    private func banner(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.textTertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CasaSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.md))
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.accentWarning)
                .symbolRenderingMode(.hierarchical)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { service.errorMessage = nil }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(CasaSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: CasaRadius.md))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Ask anything across your meetings")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            Text("Answers cite the meeting and moment they draw from. Try: “What did we decide about the BgZ exchange?”")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CasaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.lg))
    }

    // MARK: - Answer

    @ViewBuilder
    private func answerView(_ answer: AskAnswer) -> some View {
        let rendered = AskCitations.attributed(answer.segments)
        let targets = rendered.targets
        let open = onOpenCitation
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            Text(answer.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(rendered.text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    if let index = AskCitations.index(from: url), let target = targets[index] {
                        open(target)
                        return .handled
                    }
                    return .systemAction
                })

            if !answer.sources.isEmpty {
                sourcesList(answer.sources)
            }
        }
        .padding(CasaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.lg))
    }

    private func sourcesList(_ sources: [AskSource]) -> some View {
        DisclosureGroup(isExpanded: $showsSources) {
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                ForEach(sources) { source in
                    Button {
                        onOpenCitation(AskCitationTarget(
                            meetingID: source.meetingID,
                            seconds: source.timeLabel.flatMap(TranscriptLineFormat.seconds(fromLabel:))
                        ))
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                            Text(source.citation)
                                .font(.caption)
                                .foregroundStyle(Color.accentPrimary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.kindLabel(source.kind))
                                .font(.caption2)
                                .foregroundStyle(Color.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open this meeting")
                    .accessibilityLabel("Open source \(source.citation), \(Self.kindLabel(source.kind))")
                }
            }
            .padding(.top, CasaSpace.xs)
        } label: {
            Text("Sources (\(sources.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
        }
    }

    static func kindLabel(_ kind: AskChunkKind) -> String {
        switch kind {
        case .summary: return "Summary"
        case .actionItem: return "Action item"
        case .transcript: return "Transcript"
        }
    }
}
