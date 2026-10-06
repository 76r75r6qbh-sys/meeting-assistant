// Casablanca/Views/ActionCards/TicketDraftCard.swift
import SwiftUI

/// Jira-shaped card for the `ticket_draft` bucket. Header announces the issue
/// type + project; a wrapping field row shows priority / labels / components /
/// fix version / epic / assignee as chips; custom fields render as a key→value
/// table (with the "Release notes radio" row emphasized); the summary is a
/// prominent editable field; and the description is an editable Jira-markdown
/// editor with a live rendered preview below.
///
/// The editable content lives in the reusable `TicketDraftCardContent`, which the
/// roadmap-commitment card reuses for its nested ticket preview.
struct TicketDraftCard: View {
    let item: ActionQueueItem
    @State private var model: TicketDraftBody
    @Binding var editedBody: String

    init(item: ActionQueueItem, model: TicketDraftBody, editedBody: Binding<String>) {
        self.item = item
        _model = State(initialValue: model)
        _editedBody = editedBody
    }

    var body: some View {
        TicketDraftCardContent(model: $model)
            .onChange(of: model) { _, newValue in
                editedBody = newValue.serialized()
            }
    }
}

/// Reusable editable body of a ticket-draft card. Bound to a `TicketDraftBody`
/// so it can be hosted either by `TicketDraftCard` (its own `@State`) or by
/// `RoadmapCommitmentCard` (a binding into `model.ticket`). It performs NO
/// serialization itself — the host owns the `.onChange`/round-trip.
struct TicketDraftCardContent: View {
    @Binding var model: TicketDraftBody

    /// Custom-field name we call out visually.
    private static let releaseNotesRadioKey = "Release notes radio"

    private var headerText: String {
        let type = model.issueType.isEmpty ? "issue" : model.issueType
        return "Create \(type) in \(model.project)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            // Header.
            Label(headerText, systemImage: "ticket")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)

            // Field row — priority / labels / components / fix version / epic /
            // assignee, wrapped as chips.
            fieldChips

            // Custom fields — key→value table.
            if !model.customFields.isEmpty {
                customFieldsTable
            }

            // Summary — prominent + editable.
            CardTextField(label: "Summary", text: $model.summary)

            // Description — editable raw Jira markdown + live preview.
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text("Description · editable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                CardBodyEditor(text: $model.description, minHeight: 160)

                Text("Preview")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, CasaSpace.xs)
                JiraMarkupText(markup: model.description)
                    .padding(CasaSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: CasaRadius.md)
                            .fill(Color.accentSecondary.opacity(0.06))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var fieldChips: some View {
        FlowChips {
            if !model.priority.isEmpty {
                CasaChip("Priority: \(model.priority)", systemImage: "flag", tint: .accentWarning)
            }
            ForEach(model.labels, id: \.self) { label in
                CasaChip(label, systemImage: "tag")
            }
            ForEach(model.components, id: \.self) { component in
                CasaChip(component, systemImage: "puzzlepiece")
            }
            if let fixVersion = model.fixVersion {
                CasaChip("Fix version: \(fixVersion)", systemImage: "shippingbox", tint: .accentPrimary)
            }
            if let epic = model.epicLink {
                CasaChip("Epic: \(epic)", systemImage: "bolt", tint: .accentSecondary)
            }
            CasaChip(
                "Assignee: \(model.assignee ?? "Unassigned")",
                systemImage: "person",
                tint: model.assignee == nil ? .textSecondary : .accentPrimary
            )
        }
    }

    @ViewBuilder
    private var customFieldsTable: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
            Text("Custom fields")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                ForEach(Array(model.customFields.enumerated()), id: \.offset) { _, field in
                    let isRadio = field.name.caseInsensitiveCompare(Self.releaseNotesRadioKey) == .orderedSame
                    HStack(alignment: .top, spacing: CasaSpace.sm) {
                        Text(field.name)
                            .font(.caption)
                            .foregroundStyle(isRadio ? Color.accentSecondary : Color.textSecondary)
                            .frame(width: 160, alignment: .leading)
                        Text(field.value)
                            .font(isRadio ? .body.weight(.semibold) : .body)
                            .foregroundStyle(isRadio ? Color.accentSecondary : Color.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, CasaSpace.xxs)
                    .padding(.horizontal, isRadio ? CasaSpace.sm : 0)
                    .background(
                        RoundedRectangle(cornerRadius: CasaRadius.sm)
                            .fill(isRadio ? Color.accentSecondary.opacity(0.1) : Color.clear)
                    )
                }
            }
        }
    }
}
