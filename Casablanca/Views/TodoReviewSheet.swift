// Casablanca/Views/TodoReviewSheet.swift
import SwiftUI

struct TodoReviewSheet: View {
    let meetingTitle: String
    let summary: String
    @Binding var todoTexts: [String]
    let onSave: () -> Void
    let onDiscard: () -> Void

    @State private var newItemText = ""
    @FocusState private var focusedItemIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: CasaSpace.lg) {
                    summaryPreview
                    todoList
                }
                .padding(CasaSpace.xl)
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 400, idealHeight: 500)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(meetingTitle)
                    .font(.headline)
                Text("Review action items before saving")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            Button("Discard All", role: .destructive, action: onDiscard)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentDanger)
        }
        .padding(CasaSpace.lg)
    }

    private var summaryPreview: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Summary")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)

            Text(summary)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CasaSpace.md)
                .background(Color.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CasaRadius.md))
        }
    }

    private var todoList: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Action Items (\(todoTexts.count))")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)

            ForEach(todoTexts.indices, id: \.self) { index in
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "circle")
                        .foregroundStyle(Color.textTertiary)
                        .font(.body)

                    TextField("Action item", text: $todoTexts[index])
                        .textFieldStyle(.plain)
                        .focused($focusedItemIndex, equals: index)

                    Button {
                        todoTexts.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.textTertiary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(CasaSpace.sm)
                .background(Color.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
            }

            HStack(spacing: CasaSpace.sm) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.accentPrimary)

                TextField("Add action item...", text: $newItemText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let trimmed = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        todoTexts.append(trimmed)
                        newItemText = ""
                    }
            }
            .padding(CasaSpace.sm)
            .background(Color.backgroundSecondary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(action: onSave) {
                Text("Save Meeting & To-Dos")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(CasaSpace.lg)
    }
}
