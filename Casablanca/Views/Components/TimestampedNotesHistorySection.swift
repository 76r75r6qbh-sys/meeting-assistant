import AppKit
import SwiftUI

struct TimestampedNotesHistorySection: View {
    let notes: [TimestampedNote]
    var title = "Timestamped Notes"

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                ForEach(notes) { note in
                    HStack(alignment: .top, spacing: CasaSpace.sm) {
                        Text(note.formattedTimestamp)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.textSecondary)
                            .padding(.horizontal, CasaSpace.xs)
                            .padding(.vertical, CasaSpace.xxs)
                            .background(Color.backgroundHover)
                            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
                            .frame(minWidth: 52, alignment: .center)

                        Text(note.text)
                            .font(.body)
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, CasaSpace.xxs)
                }
            }
            .padding(.top, CasaSpace.sm)
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                Text("\(notes.count)")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.horizontal, CasaSpace.xs)
                    .padding(.vertical, CasaSpace.xxs)
                    .background(Color.backgroundHover)
                    .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))

                Spacer()

                Button {
                    copyNotes()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }

    private func copyNotes() {
        let text = notes
            .map { "[\($0.formattedTimestamp)] \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
