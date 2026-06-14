// Casablanca/Views/ActionCards/PartnerApiReplyCard.swift
import AppKit
import SwiftUI

/// Email-shaped card for the `partner_api_reply` bucket. Renders recipients as
/// chips, an editable subject, an editable monospace-friendly body, and the
/// item's `attachments` (from the item, NOT the body) as reveal-in-Finder chips.
struct PartnerApiReplyCard: View {
    let item: ActionQueueItem
    @State private var model: PartnerApiReplyBody
    @Binding var editedBody: String

    init(item: ActionQueueItem, model: PartnerApiReplyBody, editedBody: Binding<String>) {
        self.item = item
        _model = State(initialValue: model)
        _editedBody = editedBody
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            // Header — "Email to <recipient>" with To and Cc chips.
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                Label("Email to \(model.to)", systemImage: "envelope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)

                FlowChips {
                    CasaChip(model.to, systemImage: "person", tint: .accentPrimary)
                    ForEach(model.cc, id: \.self) { addr in
                        CasaChip("Cc: \(addr)", systemImage: "person", tint: .accentSecondary)
                    }
                }
            }

            // Subject — prominent + editable.
            CardTextField(label: "Subject", text: $model.subject)

            // Body — editable, monospace-friendly.
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text("Body · editable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                CardBodyEditor(text: $model.bodyText, minHeight: 200)
            }

            // Attachments — from item.attachments, reveal-in-Finder only.
            if let attachments = item.attachments, !attachments.isEmpty {
                VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                    Text("Attachments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    FlowChips {
                        ForEach(attachments, id: \.self) { path in
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: path)]
                                )
                            } label: {
                                CasaChip(
                                    URL(fileURLWithPath: path).lastPathComponent,
                                    systemImage: "paperclip",
                                    tint: .textSecondary
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Reveal in Finder")
                        }
                    }
                }
            }
        }
        .onChange(of: model) { _, newValue in
            editedBody = newValue.serialized()
        }
    }
}
