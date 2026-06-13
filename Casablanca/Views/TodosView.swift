// Casablanca/Views/TodosView.swift
import AppKit
import SwiftUI
import SwiftData

struct TodosView: View {
    @Bindable var viewModel: MeetingListViewModel
    @Query(sort: \TodoItem.createdAt, order: .reverse) private var allTodos: [TodoItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @State private var filter: TodoFilter = .open
    @State private var newTodoText = ""
    @State private var isRefreshing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum TodoFilter: String, CaseIterable {
        case open = "Open"
        case done = "Done"
        case all = "All"
    }

    var body: some View {
        VStack(spacing: 0) {
            if isRefreshing {
                HStack(spacing: CasaSpace.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing with Obsidian\u{2026}")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, CasaSpace.lg)
                .padding(.vertical, CasaSpace.xs)
            }
            content
            Divider()
            composerBar
        }
        .frame(maxWidth: CasaLayout.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("To-Dos")
        .task {
            isRefreshing = true
            // Yield so the "Syncing…" caption paints before the (synchronous)
            // file-backed refresh blocks the MainActor.
            await Task.yield()
            defer { isRefreshing = false }
            do {
                try ObsidianTodoSyncService.refreshAllTodos(in: modelContext)
            } catch {
                appModel.toastCenter.show(message: "Couldn't sync to Obsidian — \(error.localizedDescription)")
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter) {
                    ForEach(TodoFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if filteredTodos.isEmpty {
            VStack {
                emptyState
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else {
            todoList
        }
    }

    private var filteredTodos: [TodoItem] {
        switch filter {
        case .open:
            return allTodos.filter { !$0.isCompleted }
        case .done:
            return allTodos.filter { $0.isCompleted }
        case .all:
            return allTodos
        }
    }

    private var todoList: some View {
        List(filteredTodos) { todo in
            TodoRow(todo: todo, reduceMotion: reduceMotion, toastCenter: appModel.toastCenter) {
                if let meetingID = TodoRowPresentation(todo: todo).meetingID {
                    viewModel.sidebarSelection = .meeting(meetingID)
                }
            }
        }
        .listStyle(.inset)
        .animation(reduceMotion ? nil : CasaAnimation.fast, value: filteredTodos.map(\.id))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDescription)
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .open: return "All Done"
        case .done: return "No Completed Items"
        case .all: return "No Action Items"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .open: return "checkmark.circle"
        case .done: return "circle"
        case .all: return "checklist"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .open: return "No open action items. Nice work."
        case .done: return "Completed action items will appear here."
        case .all: return "Action items from your meetings and the managed Casablanca todo file will appear here."
        }
    }

    private var composerBar: some View {
        HStack(spacing: CasaSpace.sm) {
            TextField("Add a to-do...", text: $newTodoText)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit {
                    addGenericTodo()
                }

            Button {
                addGenericTodo()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.textTertiary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Add to-do")
            .accessibilityLabel("Add to-do")
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.md)
        .background(.bar)
    }

    private func addGenericTodo() {
        let trimmed = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try? ObsidianTodoSyncService.createGenericTodo(
            text: trimmed,
            in: modelContext
        )
        newTodoText = ""
    }
}

struct TodoRowPresentation {
    let todo: TodoItem

    var meetingID: UUID? {
        todo.meeting?.id
    }

    var canNavigateToMeeting: Bool {
        meetingID != nil
    }

    var meetingSubtitle: String? {
        guard let meeting = todo.meeting else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(meeting.title) \u{00B7} \(formatter.string(from: meeting.date))"
    }
}

private struct TodoRow: View {
    @Bindable var todo: TodoItem
    var reduceMotion: Bool = false
    let toastCenter: ToastCenter
    let onNavigateToMeeting: () -> Void
    @Environment(\.modelContext) private var modelContext

    private var presentation: TodoRowPresentation {
        TodoRowPresentation(todo: todo)
    }

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            Button {
                toggle()
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.isCompleted ? Color.accentSuccess : Color.textTertiary)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: todo.isCompleted)
            }
            .buttonStyle(.borderless)
            .help(todo.isCompleted ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(todo.isCompleted ? "Completed: \(todo.text)" : "Not completed: \(todo.text)")

            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(todo.text)
                    .font(.body)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? Color.textTertiary : Color.textPrimary)

                if let subtitle = presentation.meetingSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            Spacer()

            if presentation.canNavigateToMeeting {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard presentation.canNavigateToMeeting else { return }
            onNavigateToMeeting()
        }
    }

    private func toggle() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(reduceMotion ? nil : CasaAnimation.fast) {
            do {
                try ObsidianTodoSyncService.setCompleted(
                    !todo.isCompleted,
                    for: todo,
                    in: modelContext
                )
            } catch {
                toastCenter.show(message: "Couldn't sync to Obsidian — \(error.localizedDescription)")
            }
        }
    }
}
