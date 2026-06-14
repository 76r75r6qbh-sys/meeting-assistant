// Casablanca/Views/ActionCards/RoadmapCommitmentCard.swift
import AppKit
import SwiftUI

/// Roadmap-commitment card for the `roadmap_commitment` bucket. Shows who asked,
/// an excerpt block (topic + source line, with an "Open Teams" button when a
/// permalink exists), the promised timeline as a chip, and — when present — a
/// fully editable nested ticket preview reusing `TicketDraftCardContent`.
struct RoadmapCommitmentCard: View {
    let item: ActionQueueItem
    @State private var model: RoadmapCommitmentBody
    @Binding var editedBody: String

    init(item: ActionQueueItem, model: RoadmapCommitmentBody, editedBody: Binding<String>) {
        self.item = item
        _model = State(initialValue: model)
        _editedBody = editedBody
    }

    /// Binding into the optional nested ticket. Only constructed when non-nil so
    /// the nested content view always has a concrete value to edit.
    private var ticketBinding: Binding<TicketDraftBody>? {
        guard model.ticket != nil else { return nil }
        return Binding(
            get: { model.ticket ?? TicketDraftBody(project: "", summary: "") },
            set: { model.ticket = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            // Header.
            Label("Roadmap commitment from \(model.asker)", systemImage: "map")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)

            // Excerpt block.
            excerptBlock

            // Promised timeline chip.
            FlowChips {
                CasaChip("Promised: \(model.promisedTimeline)", systemImage: "calendar.badge.clock", tint: .accentWarning)
            }

            // Nested ticket preview — editable, reuses the ticket renderer.
            if let ticketBinding {
                VStack(alignment: .leading, spacing: CasaSpace.xs) {
                    Text("Proposed ticket")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    TicketDraftCardContent(model: ticketBinding)
                        .padding(CasaSpace.md)
                        .background(
                            RoundedRectangle(cornerRadius: CasaRadius.md)
                                .fill(Color.textTertiary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CasaRadius.md)
                                .stroke(Color.textTertiary.opacity(0.2))
                        )
                }
            }
        }
        .onChange(of: model) { _, newValue in
            editedBody = newValue.serialized()
        }
    }

    @ViewBuilder
    private var excerptBlock: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xs) {
            if !model.topic.isEmpty {
                Text(model.topic)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.sourceLine.isEmpty {
                Text(model.sourceLine)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let permalink = model.permalink, let url = URL(string: permalink) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open Teams", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentPrimary)
                .help("Open the source conversation in Teams")
            }
        }
        .padding(CasaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CasaRadius.md)
                .fill(Color.textTertiary.opacity(0.08))
        )
    }
}
