// Casablanca/Views/TodosView.swift
import AppKit
import SwiftUI
import SwiftData

struct TodosView: View {
    @Bindable var viewModel: MeetingListViewModel
    /// Rejected to-dos are never shown, so they are not fetched.
    @Query(filter: TodoCounting.notRejectedPredicate, sort: \TodoItem.createdAt, order: .reverse)
    private var allTodos: [TodoItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @State private var filter: TodoFilter = .open
    @State private var newTodoText = ""
    @State private var isRefreshing = false
    /// The to-do whose draft sheet is open. The sheet hangs off the list, not
    /// a row, so a lazily recycled row cannot take it down.
    @State private var draftReplyTodo: TodoItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum TodoFilter: String, CaseIterable {
        case open = "Open"
        case done = "Done"
        case all = "All"
        case review = "Review"

        /// Open, Done and All list accepted to-dos only; Review lists the
        /// proposed ones. Rejected to-dos are never shown.
        func todos(from todos: [TodoItem]) -> [TodoItem] {
            switch self {
            case .open: return todos.filter { $0.status == .accepted && !$0.isCompleted }
            case .done: return todos.filter { $0.status == .accepted && $0.isCompleted }
            case .all: return todos.filter { $0.status == .accepted }
            case .review: return todos.filter { $0.status == .proposed }
            }
        }

        /// The segment label; Review shows its count when there is one.
        func label(reviewCount: Int) -> String {
            self == .review && reviewCount > 0 ? "\(rawValue) (\(reviewCount))" : rawValue
        }
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
        .sheet(item: $draftReplyTodo) { todo in
            DraftReplySheet(todo: todo, toastCenter: appModel.toastCenter) {
                navigateToMeeting(of: todo)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter) {
                    ForEach(TodoFilter.allCases, id: \.self) { filter in
                        Text(filter.label(reviewCount: reviewCount)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
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
        filter.todos(from: allTodos)
    }

    private var reviewCount: Int {
        TodoFilter.review.todos(from: allTodos).count
    }

    private var todoList: some View {
        let todos = filteredTodos
        let itemsByMeeting = filter == .review ? Self.actionItemsByMeeting(of: todos) : [:]
        return List(todos) { todo in
            if filter == .review {
                reviewRow(todo, actionItems: todo.meeting.flatMap { itemsByMeeting[$0.id] } ?? [])
            } else {
                TodoRow(
                    todo: todo,
                    reduceMotion: reduceMotion,
                    toastCenter: appModel.toastCenter,
                    onNavigateToMeeting: { navigateToMeeting(of: todo) },
                    onDraftReply: { draftReplyTodo = todo }
                )
            }
        }
        .listStyle(.inset)
        .animation(reduceMotion ? nil : CasaAnimation.fast, value: todos.map(\.id))
    }

    /// Each meeting's extracted items, decoded once per meeting.
    private static func actionItemsByMeeting(of todos: [TodoItem]) -> [UUID: [ExtractedActionItem]] {
        var result: [UUID: [ExtractedActionItem]] = [:]
        for case let meeting? in todos.map(\.meeting) where result[meeting.id] == nil {
            result[meeting.id] = meeting.actionItems
        }
        return result
    }

    /// A proposal across meetings: the review row, with its meeting below it.
    private func reviewRow(_ todo: TodoItem, actionItems: [ExtractedActionItem]) -> some View {
        let actions = TodoReviewActions(modelContext: modelContext, appModel: appModel)
        let presentation = TodoRowPresentation(todo: todo)
        return VStack(alignment: .leading, spacing: CasaSpace.xs) {
            TodoReviewRow(
                todo: todo,
                actionItems: actionItems,
                onAccept: { actions.accept(todo) },
                onReject: { actions.reject(todo) },
                onEdit: { task, owner, due in actions.edit(todo, task: task, owner: owner, dueDate: due) }
            )
            if let subtitle = presentation.meetingSubtitle {
                Button {
                    navigateToMeeting(of: todo)
                } label: {
                    Label(subtitle, systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(GhostButtonStyle())
                .help("Open the meeting")
            }
        }
        .padding(.vertical, CasaSpace.xs)
    }

    private func navigateToMeeting(of todo: TodoItem) {
        if let meetingID = TodoRowPresentation(todo: todo).meetingID {
            viewModel.sidebarSelection = .meeting(meetingID)
        }
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
        case .review: return "Nothing to Review"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .open: return "checkmark.circle"
        case .done: return "circle"
        case .all: return "checklist"
        case .review: return "checkmark.seal"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .open: return "No open action items. Nice work."
        case .done: return "Completed action items will appear here."
        case .all: return "Action items from your meetings and the managed Casablanca todo file will appear here."
        case .review: return "To-dos proposed from meeting summaries appear here until you accept or reject them."
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

/// Which to-dos count as open everywhere a count is shown (the sidebar's
/// To-Dos badge): accepted and not completed. Proposed to-dos wait for review
/// and rejected ones are gone, so neither counts.
enum TodoCounting {
    static var openTodoPredicate: Predicate<TodoItem> {
        let accepted = TodoStatus.accepted.rawValue
        return #Predicate<TodoItem> { !$0.isCompleted && $0.statusRaw == accepted }
    }

    /// Everything the Todos view can show: rejected to-dos are left out.
    static var notRejectedPredicate: Predicate<TodoItem> {
        let rejected = TodoStatus.rejected.rawValue
        return #Predicate<TodoItem> { $0.statusRaw != rejected }
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

    /// "Draft reply" is offered on open, accepted to-dos only: not on done
    /// ones, nor on proposals still in review.
    var canDraftReply: Bool {
        todo.status == .accepted && !todo.isCompleted
    }

    /// The to-do's source link, when it has a readable one.
    var sourceLink: TodoSourceLink? {
        todo.sourceRef.flatMap(TodoSourceLink.init)
    }
}

/// A to-do's source link under its text: the label as a caption pill, a
/// button opening the URL when the link has one. Its own button, so a click
/// opens the link and never the row's meeting.
struct TodoSourceLinkChip: View {
    let link: TodoSourceLink
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = link.url {
            Button {
                openURL(url)
            } label: {
                pill(systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open \(link.label)")
            .accessibilityLabel("Open source: \(link.label)")
        } else {
            pill(systemImage: "link")
                .help("Source: \(link.label)")
                .accessibilityLabel("Source: \(link.label)")
        }
    }

    private func pill(systemImage: String) -> some View {
        HStack(spacing: CasaSpace.xxs) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(link.label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xxs)
        .background(Color.backgroundTertiary, in: Capsule())
    }
}

struct TodoRow: View {
    @Bindable var todo: TodoItem
    var reduceMotion: Bool = false
    let toastCenter: ToastCenter
    let onNavigateToMeeting: () -> Void
    /// Opens the draft sheet; offered only when ``TodoRowPresentation/canDraftReply``.
    let onDraftReply: () -> Void
    @State private var isHovering = false
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

                if presentation.meetingSubtitle != nil || presentation.sourceLink != nil {
                    HStack(spacing: CasaSpace.sm) {
                        if let subtitle = presentation.meetingSubtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.textTertiary)
                        }
                        if let sourceLink = presentation.sourceLink {
                            TodoSourceLinkChip(link: sourceLink)
                        }
                    }
                }
            }

            Spacer()

            if presentation.canDraftReply {
                Button {
                    onDraftReply()
                } label: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Draft reply")
                .accessibilityLabel("Draft reply")
                // Revealed on hover; the context menu offers it too.
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }

            if presentation.canNavigateToMeeting {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard presentation.canNavigateToMeeting else { return }
            onNavigateToMeeting()
        }
        .contextMenu {
            if presentation.canDraftReply {
                Button("Draft reply", systemImage: "text.bubble") {
                    onDraftReply()
                }
            }
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
