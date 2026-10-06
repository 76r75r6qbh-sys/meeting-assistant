// Casablanca/Views/ActionCards/LegacyDraftEditor.swift
import SwiftUI

/// The original plain-text draft editor, extracted verbatim from
/// `ActionQueueDetailSheet` so it can be reused as the fallback for buckets that
/// don't (yet) have a bespoke card: nil/General, `.unknown`, and the complex
/// buckets handled in a later task. Behavior is IDENTICAL to the pre-card flow —
/// pencil label + "· editable", the empty-state warning, and the styled
/// `TextEditor` bound directly to `$editedBody`.
struct LegacyDraftEditor: View {
    let label: String
    @Binding var editedBody: String

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xs) {
            HStack(spacing: CasaSpace.xs) {
                Image(systemName: "pencil.line")
                    .font(.caption)
                    .foregroundStyle(Color.accentSecondary)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                Text("· editable")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            if editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No draft text yet — type a reply or ask your copilot to prepare one.")
                    .font(.caption)
                    .foregroundStyle(Color.accentWarning)
            }
            TextEditor(text: $editedBody)
                .font(.system(.body))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(CasaSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: CasaRadius.md)
                        .fill(Color.accentSecondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CasaRadius.md)
                        .stroke(Color.textTertiary.opacity(0.3))
                )
        }
    }
}
