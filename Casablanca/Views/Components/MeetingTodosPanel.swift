import AppKit
import SwiftData
import SwiftUI

/// Scrollable to-do list for a meeting plus an inline add field. Reads and
/// mutates todos through ObsidianTodoSyncService against the model context.
/// The list holds accepted to-dos only; proposed ones are reviewed in a
/// compact section above it, and rejected ones are never shown.
struct MeetingTodosPanel: View {
    @Bindable var meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @State private var newTodoText = ""

    private var acceptedTodos: [TodoItem] {
        meeting.todos.filter { $0.status == .accepted }
    }

    var body: some View {
        let proposed = TodoReviewPresentation.proposedTodos(of: meeting)
        let accepted = acceptedTodos
        VStack(spacing: 0) {
            ScrollView {
                if !proposed.isEmpty {
                    let actions = TodoReviewActions(modelContext: modelContext, appModel: appModel)
                    MeetingTodosReviewSection(
                        todos: proposed,
                        onAccept: actions.accept,
                        onReject: actions.reject,
                        onEdit: { todo, task, owner, due in actions.edit(todo, task: task, owner: owner, dueDate: due) }
                    )
                    .padding([.horizontal, .top], CasaSpace.lg)
                }
                if accepted.isEmpty && proposed.isEmpty {
                    Text("No to-dos yet. Add one below.")
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
                } else {
                    LazyVStack(alignment: .leading, spacing: CasaSpace.xs) {
                        ForEach(accepted) { todo in
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
        guard todo.status == .accepted else { return }
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

/// "N to-dos to review": the meeting's proposed to-dos as compact review rows,
/// above the accepted list in MeetingTodosPanel.
struct MeetingTodosReviewSection: View {
    let todos: [TodoItem]
    let onAccept: (TodoItem) -> Void
    let onReject: (TodoItem) -> Void
    let onEdit: (TodoItem, String, String?, Date?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text(todos.count == 1 ? "1 to-do to review" : "\(todos.count) to-dos to review")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.textTertiary)

            ForEach(todos) { todo in
                TodoReviewRow(
                    todo: todo,
                    onAccept: { onAccept(todo) },
                    onReject: { onReject(todo) },
                    onEdit: { task, owner, due in onEdit(todo, task, owner, due) }
                )
                .padding(.vertical, CasaSpace.xs)
            }

            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
