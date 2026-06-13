import AppKit
import SwiftUI

struct MeetingSummaryTab: View {
    @Bindable var meeting: Meeting
    let isSummarizing: Bool
    let statusMessage: String
    let canSummarize: Bool
    let onSummarize: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        summaryTab
    }

    @ViewBuilder
    private var summaryTab: some View {
        if isSummarizing {
            HStack(spacing: CasaSpace.sm) {
                ProgressView()
                    .controlSize(.small)

                Text(statusMessage.isEmpty ? "Generating summary..." : statusMessage)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let summary = meeting.summary,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = SummaryResponseParser.parse(summary)

            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                summaryHero(parsed)

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
            }

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
            Text(text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func actionItemsSection(_ texts: [String]) -> some View {
        let doneCount = texts.filter { isActionItemCompleted($0) }.count

        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack(spacing: CasaSpace.xs) {
                Label("Action items", systemImage: "checklist")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.textTertiary)
                    .symbolRenderingMode(.hierarchical)

                Text("· \(doneCount) of \(texts.count) done")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                let completed = isActionItemCompleted(text)
                HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
                    Button {
                        toggleActionItem(text)
                    } label: {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(completed ? Color.accentSuccess : Color.textTertiary)
                    }
                    .buttonStyle(.borderless)

                    Text(text)
                        .font(.body)
                        .strikethrough(completed)
                        .foregroundStyle(completed ? Color.textTertiary : Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderedMarkdownSummary(_ summary: String) -> some View {
        let rendered = MarkdownConverter.markdownToAttributedString(
            summary,
            baseFont: .systemFont(ofSize: NSFont.systemFontSize)
        )

        if !rendered.string.isEmpty {
            let attributed = AttributedString(rendered)
            Text(attributed)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(summary)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
    }

    // MARK: - Action item ↔ todo sync

    /// Finds the meeting-scoped `TodoItem` whose text matches a parsed action item.
    private func matchingTodo(for text: String) -> TodoItem? {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return meeting.todos.first {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }
    }

    private func isActionItemCompleted(_ text: String) -> Bool {
        matchingTodo(for: text)?.isCompleted ?? false
    }

    /// Toggles a parsed action item's completion through the existing
    /// `ObsidianTodoSyncService` flow. If a meeting `TodoItem` already exists for
    /// the text, its `isCompleted` is flipped; otherwise a new completed todo is
    /// created (a check on a not-yet-tracked item).
    private func toggleActionItem(_ text: String) {
        if let todo = matchingTodo(for: text) {
            try? ObsidianTodoSyncService.setCompleted(
                !todo.isCompleted,
                for: todo,
                in: modelContext
            )
        } else {
            try? ObsidianTodoSyncService.createMeetingTodo(
                text: text,
                meeting: meeting,
                in: modelContext
            )
            if let created = matchingTodo(for: text) {
                try? ObsidianTodoSyncService.setCompleted(true, for: created, in: modelContext)
            }
        }
    }
}
