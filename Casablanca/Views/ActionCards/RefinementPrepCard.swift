// Casablanca/Views/ActionCards/RefinementPrepCard.swift
import AppKit
import SwiftUI

/// Refinement-prep card for the `refinement_prep` bucket. Shows a clickable story
/// header, two-column current→proposed compare rows for the release-notes radio
/// and priority (only the *proposed* value is editable), a heuristic/confidence
/// footer, and flag pills calling out estimation / AC gaps / open comments.
struct RefinementPrepCard: View {
    let item: ActionQueueItem
    @State private var model: RefinementPrepBody
    @Binding var editedBody: String

    init(item: ActionQueueItem, model: RefinementPrepBody, editedBody: Binding<String>) {
        self.item = item
        _model = State(initialValue: model)
        _editedBody = editedBody
    }

    private static let radioOptions = ["Yes-External", "Yes-Internal", "No"]
    private static let priorityOptions = ["High", "Medium", "Low"]

    private var storyURL: URL? {
        JiraLink.url(fromTarget: item.target) ?? JiraLink.url(forKey: model.storyKey)
    }

    private var hasEstimationGap: Bool {
        let trimmed = model.estimation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "missing"
    }

    private var hasOpenComments: Bool {
        let trimmed = model.openComments.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            header

            // Two-column compare rows.
            VStack(alignment: .leading, spacing: CasaSpace.sm) {
                compareRow(
                    label: "Release notes radio",
                    current: model.currentRadio,
                    selection: $model.proposedRadio,
                    options: Self.radioOptions
                )
                compareRow(
                    label: "Priority",
                    current: model.currentPriority,
                    selection: $model.proposedPriority,
                    options: Self.priorityOptions
                )
            }

            // Flag pills.
            if hasEstimationGap || !model.acGaps.isEmpty || hasOpenComments {
                FlowChips {
                    if hasEstimationGap {
                        flagPill("Estimation: missing")
                    }
                    if !model.acGaps.isEmpty {
                        flagPill("AC gaps: \(ActionBodyParsing.joinList(model.acGaps))")
                    }
                    if hasOpenComments {
                        flagPill("Open comments: \(model.openComments)")
                    }
                }
            }

            // Footer.
            Text("Heuristic: \(model.heuristic.isEmpty ? "—" : model.heuristic) · Confidence: \(model.confidence.isEmpty ? "—" : model.confidence)")
                .font(.caption2)
                .foregroundStyle(Color.textTertiary)
        }
        .onChange(of: model) { _, newValue in
            editedBody = newValue.serialized()
        }
    }

    @ViewBuilder
    private var header: some View {
        let title = model.storyTitle.isEmpty ? model.storyKey : "\(model.storyKey) — \(model.storyTitle)"
        if let url = storyURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(title, systemImage: "link")
                    .font(.headline)
                    .foregroundStyle(Color.accentPrimary)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .help("Open in Jira")
            .accessibilityHint("Open in Jira")
        } else {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
        }
    }

    @ViewBuilder
    private func compareRow(
        label: String,
        current: String,
        selection: Binding<String>,
        options: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            HStack(spacing: CasaSpace.sm) {
                Text(current.isEmpty ? "—" : current)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                    .frame(minWidth: 90, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                Picker(label, selection: selection) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                    // Preserve an out-of-set proposed value so it isn't silently dropped.
                    if !options.contains(selection.wrappedValue) {
                        Text(selection.wrappedValue).tag(selection.wrappedValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }
        }
    }

    /// A flag pill with a leading red dot indicating a problem to address.
    @ViewBuilder
    private func flagPill(_ text: String) -> some View {
        HStack(spacing: CasaSpace.xxs) {
            Circle()
                .fill(Color.accentDanger)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xxs)
        .background(Capsule().fill(Color.accentDanger.opacity(0.12)))
    }
}
