// Casablanca/Views/TodosView.swift
import SwiftUI
import SwiftData

struct TodosView: View {
    @Bindable var viewModel: MeetingListViewModel
    @Query(sort: \TodoItem.createdAt, order: .reverse) private var allTodos: [TodoItem]
    @Environment(\.modelContext) private var modelContext
    @State private var filter: TodoFilter = .open

    enum TodoFilter: String, CaseIterable {
        case open = "Open"
        case done = "Done"
        case all = "All"
    }

    var body: some View {
        VStack(spacing: 0) {
            if filteredTodos.isEmpty {
                emptyState
            } else {
                todoList
            }
        }
        .frame(maxWidth: CasaLayout.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("To-Dos")
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
            TodoRow(todo: todo) {
                if let meeting = todo.meeting {
                    viewModel.sidebarSelection = .meeting(meeting.id)
                }
            }
        }
        .listStyle(.inset)
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
        case .all: return "Action items from your meetings will appear here."
        }
    }
}

private struct TodoRow: View {
    @Bindable var todo: TodoItem
    let onNavigateToMeeting: () -> Void
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            Button {
                todo.isCompleted.toggle()
                try? modelContext.save()
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.isCompleted ? Color.accentSuccess : Color.textTertiary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(todo.text)
                    .font(.body)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? Color.textTertiary : Color.textPrimary)

                if let meeting = todo.meeting {
                    Text("\(meeting.title) \u{00B7} \(formattedDate(meeting.date))")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onNavigateToMeeting)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
