import AppKit
import SwiftData
import SwiftUI

/// Scrollable to-do list for a meeting plus an inline add field. Reads and
/// mutates todos through ObsidianTodoSyncService against the model context.
struct MeetingTodosPanel: View {
    @Bindable var meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @State private var newTodoText = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if meeting.todos.isEmpty {
                    Text("No to-dos yet. Add one below.")
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
                } else {
                    LazyVStack(alignment: .leading, spacing: CasaSpace.xs) {
                        ForEach(meeting.todos) { todo in
                            HStack(spacing: CasaSpace.sm) {
                                Button {
                                    toggle(todo)
                                } label: {
                                    Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.body)
                                        .foregroundStyle(todo.isCompleted ? Color.accentColor : Color.textTertiary)
                                        .symbolEffect(.bounce, value: todo.isCompleted)
                                }
                                .buttonStyle(.plain)
                                .help(todo.isCompleted ? "Mark as not done" : "Mark as done")
                                .accessibilityLabel(todo.isCompleted ? "Completed: \(todo.text)" : "Not completed: \(todo.text)")

                                Text(todo.text)
                                    .font(.body)
                                    .foregroundStyle(todo.isCompleted ? Color.textTertiary : Color.textPrimary)
                                    .strikethrough(todo.isCompleted, color: Color.textTertiary)
                                    .textSelection(.enabled)

                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, CasaSpace.xs)
                        }
                    }
                    .padding(CasaSpace.lg)
                }
            }

            Divider()

            HStack(spacing: CasaSpace.sm) {
                TextField("Add a to-do...", text: $newTodoText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit {
                        addTodo()
                    }

                Button {
                    addTodo()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(newTodoText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Color.textTertiary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newTodoText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add to-do")
                .accessibilityLabel("Add to-do")
            }
            .padding(.horizontal, CasaSpace.lg)
            .padding(.vertical, CasaSpace.md)
            .background(.bar)
        }
    }

    private func toggle(_ todo: TodoItem) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        do {
            try ObsidianTodoSyncService.setCompleted(
                !todo.isCompleted,
                for: todo,
                in: modelContext
            )
        } catch {
            appModel.toastCenter.show(message: "Couldn't sync to Obsidian — \(error.localizedDescription)")
        }
    }

    private func addTodo() {
        let trimmed = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try? ObsidianTodoSyncService.createMeetingTodo(
            text: trimmed,
            meeting: meeting,
            in: modelContext
        )
        newTodoText = ""
    }
}
