// Casablanca/Views/ActionCards/TopdeskResponseCard.swift
import AppKit
import SwiftUI

/// Topdesk-shaped card for the `topdesk_response` bucket. Header shows the
/// MC-ref + customer with the caller as subtitle; a visibility toggle maps to
/// the Topdesk "internal only" flag; an optional Jira-link chip; and an editable
/// response body.
struct TopdeskResponseCard: View {
    @State private var model: TopdeskResponseBody
    @Binding var editedBody: String

    init(model: TopdeskResponseBody, editedBody: Binding<String>) {
        _model = State(initialValue: model)
        _editedBody = editedBody
    }

    /// Bridges the model's two-case visibility enum to the Toggle's Bool.
    private var visibleToCaller: Binding<Bool> {
        Binding(
            get: { model.visibility == .visibleToCaller },
            set: { model.visibility = $0 ? .visibleToCaller : .internalOnly }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            // Header.
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Label("Reply to \(model.mcRef) — \(model.customer)", systemImage: "ticket")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                if let caller = model.caller, !caller.isEmpty {
                    Text(caller)
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            // Visibility toggle.
            Toggle(isOn: visibleToCaller) {
                Text(visibleToCaller.wrappedValue ? "Visible to caller" : "Internal only")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Visible to caller")

            // Jira link chip — only when present.
            if let jira = model.addJiraLink, !jira.isEmpty {
                Button {
                    if let url = jiraURL(jira) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    CasaChip("Also add Jira link: \(jira)", systemImage: "link", tint: .accentPrimary)
                }
                .buttonStyle(.plain)
                .help(jiraURL(jira) != nil ? "Open in browser" : jira)
                .accessibilityLabel("Linked Jira issue \(jira)")
                .accessibilityHint(jiraURL(jira) != nil ? "Open in browser" : "")
            }

            // Response body — editable.
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text("Response · editable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                CardBodyEditor(text: $model.response, minHeight: 200)
            }
        }
        .onChange(of: model) { _, newValue in
            editedBody = newValue.serialized()
        }
    }

    /// Returns a URL only when the Jira value looks like one; otherwise nil (the
    /// chip then just displays the key).
    private func jiraURL(_ raw: String) -> URL? {
        guard let str = ActionBodyParsing.firstURL(in: raw) else { return nil }
        return URL(string: str)
    }
}
