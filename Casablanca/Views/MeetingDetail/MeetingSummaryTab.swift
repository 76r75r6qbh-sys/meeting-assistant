import AppKit
import SwiftData
import SwiftUI

struct MeetingSummaryTab: View {
    @Bindable var meeting: Meeting
    let isSummarizing: Bool
    let statusMessage: String
    let canSummarize: Bool
    let onSummarize: () -> Void
    /// A speaker was renamed or merged since this summary was made: offer to
    /// regenerate it with the names (never done automatically).
    var showRegenerateOffer: Bool = false
    var onRegenerateOffer: () -> Void = {}
    var onDismissRegenerateOffer: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel

    var body: some View {
        summaryTab
    }

    @ViewBuilder
    private var summaryTab: some View {
        if isSummarizing {
            VStack(alignment: .leading, spacing: CasaSpace.sm) {
                HStack(spacing: CasaSpace.sm) {
                    ProgressView()
                        .controlSize(.small)

                    Text(statusMessage.isEmpty ? "Generating summary..." : statusMessage)
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                }

                // Skeleton placeholder lines while the summary is being drafted.
                VStack(alignment: .leading, spacing: CasaSpace.sm) {
                    Text(String(repeating: "\u{2588}", count: 48))
                    Text(String(repeating: "\u{2588}", count: 40))
                    Text(String(repeating: "\u{2588}", count: 44))
                }
                .font(.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .casaSkeleton(true)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let summary = meeting.summary,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = SummaryResponseParser.parse(summary)

            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                if showRegenerateOffer {
                    regenerateOfferBanner
                }

                summaryHero(parsed)

                // Proposed to-dos are reviewed here first (spec B6).
                TodoReviewStrip(meeting: meeting)

                if !parsed.decisions.isEmpty {
                    parsedSection("Decisions", systemImage: "diamond.fill") {
                        ForEach(Array(parsed.decisions.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "diamond.fill", color: Color.accentSuccess, text: text)
                        }
                    }
                }

                if !parsed.todoTexts.isEmpty {
                    actionItemsSection(parsed.todoTexts)
                }

                if !parsed.risks.isEmpty {
                    parsedSection("Risks & blockers", systemImage: "exclamationmark.triangle.fill") {
                        ForEach(Array(parsed.risks.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "exclamationmark.triangle.fill", color: Color.accentWarning, text: text)
                        }
                    }
                }

                if !parsed.followUps.isEmpty {
                    parsedSection("Follow-ups", systemImage: "arrow.turn.down.right") {
                        ForEach(Array(parsed.followUps.enumerated()), id: \.offset) { _, text in
                            bulletRow(symbol: "arrow.turn.down.right", color: Color.textSecondary, text: text)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView {
                Label("No Summary Yet", systemImage: "sparkles")
            } description: {
                Text("Generate a structured summary from the transcript and notes.")
            } actions: {
                if canSummarize {
                    Button("Summarize") {
                        onSummarize()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    /// Small, non-modal: the summary stays readable and usable underneath.
    private var regenerateOfferBanner: some View {
        HStack(alignment: .center, spacing: CasaSpace.sm) {
            Image(systemName: "person.2.wave.2")
                .foregroundStyle(Color.accentSecondary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text("Speaker names changed. Regenerate the summary to use them; accepted and rejected to-dos are kept.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Regenerate summary", action: onRegenerateOffer)
                .buttonStyle(GhostButtonStyle())
                .font(.caption)
                .disabled(!canSummarize)
            Button(action: onDismissRegenerateOffer) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss regenerate summary offer")
        }
        .padding(CasaSpace.sm)
        .background(Color.accentSecondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func summaryHero(_ parsed: SummaryResponseParser.ParsedResponse) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack {
                Label("AI Summary", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentSecondary)
                    .symbolRenderingMode(.hierarchical)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.summary ?? "", forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .help("Copy summary to clipboard")
                .accessibilityLabel("Copy summary")
            }

            // The service runs one summary at a time and ignores a second
            // request, so the menu is off while any meeting is summarizing.
            SummaryTemplateMenu(meeting: meeting) { templateID in
                appModel.summarizationService.summarizeInBackground(
                    meeting: meeting,
                    modelContext: modelContext,
                    templateID: templateID
                )
            }
            .disabled(appModel.summarizationService.isSummarizing || !canSummarize)

            renderedMarkdownSummary(parsed.summary)
        }
        .padding(CasaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stateAIGenerated, in: RoundedRectangle(cornerRadius: CasaRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.xl)
                .strokeBorder(Color.accentSecondary.opacity(0.22), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func parsedSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.textTertiary)
                .symbolRenderingMode(.hierarchical)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func bulletRow(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(color)
            linkedText(text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func actionItemsSection(_ texts: [String]) -> some View {
        let todos = meeting.todos
        let items = meeting.actionItems
        let states = texts.map { TodoReviewPresentation.summaryBulletState(for: $0, todos: todos, items: items) }
        let doneSummary = TodoReviewPresentation.doneSummary(states)

        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack(spacing: CasaSpace.xs) {
                Label("Action items", systemImage: "checklist")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textTertiary)
                    .symbolRenderingMode(.hierarchical)

                if let doneSummary {
                    Text(doneSummary)
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            ForEach(Array(zip(texts, states).enumerated()), id: \.offset) { _, pair in
                actionItemRow(text: pair.0, state: pair.1, items: items)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One action-item bullet: the completion toggle (accepted, or a legacy
    /// meeting), the review state for a proposal (no toggle; the strip above
    /// accepts, edits or rejects it), or another person's item read-only with
    /// its owner and verification badge.
    @ViewBuilder
    private func actionItemRow(
        text: String,
        state: TodoReviewPresentation.SummaryBulletState,
        items: [ExtractedActionItem]
    ) -> some View {
        switch state {
        case .review(let todo):
            HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                Text("In review")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, CasaSpace.xs)
                    .padding(.vertical, 1)
                    .background(Color.textTertiary.opacity(0.15), in: Capsule())
                    .help("Proposed to-do, waiting for review")
                    .accessibilityLabel("In review: \(text)")
                TodoVerificationBadge(badge: TodoReviewPresentation(todo: todo, actionItems: items).badge)
                linkedText(text)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .readOnly(let owner, let action, let badge):
            HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                TodoVerificationBadge(badge: badge)
                VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                    linkedText(action)
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                    Text(owner ?? "Unassigned")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        case .toggle(let todo):
            let completed = todo?.isCompleted ?? false
            HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                Button {
                    toggleActionItem(text)
                } label: {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(completed ? Color.accentSuccess : Color.textTertiary)
                        .symbolEffect(.bounce, value: completed)
                }
                .buttonStyle(.borderless)
                .help(completed ? "Mark as not done" : "Mark as done")
                .accessibilityLabel(completed ? "Completed: \(text)" : "Not completed: \(text)")

                linkedText(text)
                    .font(.body)
                    .strikethrough(completed)
                    .foregroundStyle(completed ? Color.textTertiary : Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func renderedMarkdownSummary(_ summary: String) -> some View {
        let rendered = MarkdownConverter.markdownToAttributedString(
            summary,
            baseFont: .systemFont(ofSize: NSFont.systemFontSize)
        )

        if !rendered.string.isEmpty {
            let attributed = TimestampLinks.addingLinks(to: AttributedString(rendered), meetingID: meeting.id)
            Text(attributed)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            linkedText(summary)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
    }

    /// `text` with its `[mm:ss]` labels linked to this meeting's transcript
    /// and recording (point 8).
    private func linkedText(_ text: String) -> Text {
        TimestampLinkText.text(text, meetingID: meeting.id)
    }

    // MARK: - Action item ↔ todo sync

    /// The meeting `TodoItem` a parsed action item stands for, per
    /// `ActionItemTodoMatcher`: rejected rows never match; among several,
    /// a row whose owner only partly matches loses, then accepted beats
    /// proposed, then a row at the bullet's timestamp wins, then the oldest.
    private func matchingTodo(for text: String) -> TodoItem? {
        ActionItemTodoMatcher.matchingTodo(for: text, in: meeting.todos)
    }

    /// Toggles a parsed action item's completion through the existing
    /// `ObsidianTodoSyncService` flow. If a meeting `TodoItem` already exists for
    /// the text, its `isCompleted` is flipped; otherwise a new completed todo is
    /// created (a check on a not-yet-tracked item).
    private func toggleActionItem(_ text: String) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        do {
            if let todo = matchingTodo(for: text) {
                // Proposals cannot be completed; the strip reviews them.
                guard todo.status == .accepted else { return }
                try ObsidianTodoSyncService.setCompleted(
                    !todo.isCompleted,
                    for: todo,
                    in: modelContext
                )
            } else {
                try ObsidianTodoSyncService.createMeetingTodo(
                    text: text,
                    meeting: meeting,
                    in: modelContext
                )
                if let created = matchingTodo(for: text) {
                    try ObsidianTodoSyncService.setCompleted(true, for: created, in: modelContext)
                }
            }
        } catch {
            appModel.toastCenter.show(message: "Couldn't sync to Obsidian — \(error.localizedDescription)")
        }
    }
}
