// Casablanca/Views/ActionCards/TodoCard.swift
import SwiftUI

/// Minimal display-only card for the `todo` bucket. Shows the title, proposed
/// action, source, and rationale. No body editing — todos are marked complete
/// locally rather than approved.
struct TodoCard: View {
    let item: ActionQueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            Label("To-do", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)

            if !item.title.isEmpty {
                CardLabeledRow(label: "Title", value: item.title)
            }
            if let proposed = item.proposedAction, !proposed.isEmpty {
                CardLabeledRow(label: "Proposed action", value: proposed)
            }
            if let source = item.source, !source.isEmpty {
                CardLabeledRow(label: "Source", value: source)
            }
            if let rationale = item.rationale, !rationale.isEmpty {
                CardLabeledRow(label: "Rationale", value: rationale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
