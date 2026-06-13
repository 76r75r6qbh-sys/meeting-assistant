import SwiftUI

/// A Spotlight-style global search overlay (⌘F).
///
/// Searches via ``GlobalSearchViewModel`` (debounced, two-tier: SQLite
/// predicates + a bounded in-memory transcript/participant scan) plus the
/// action-queue items, groups the results by source, and navigates the app on
/// selection. Presented as a sheet from `ContentView`.
///
/// The view does NO searching itself: it binds the field to the VM and renders
/// `searchViewModel.results` / `searchViewModel.approvalItems`. The search runs
/// once per settled query in the VM, not on every render/keystroke.
///
/// Keyboard: ↑/↓ move the selection, ⏎ opens the selected result, esc dismisses.
/// Rows are also clickable.
struct GlobalSearchView: View {
    let searchViewModel: GlobalSearchViewModel
    @Bindable var viewModel: MeetingListViewModel
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if trimmedQuery.isEmpty {
                emptyPrompt
            } else if rows.isEmpty {
                // While the debounced search is still in flight (the VM hasn't
                // settled on this query yet) show nothing rather than flashing
                // "No Results"; only show it once the search has completed and
                // genuinely returned nothing.
                if searchCompleted {
                    noResults
                }
            } else {
                resultsList
                Divider()
                footer
            }
        }
        .frame(width: CasaLayout.modalWidthLarge)
        .frame(maxHeight: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: CasaRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.xl)
                .strokeBorder(Color.borderSubtle, lineWidth: 1)
        )
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, newValue in
            selectedIndex = 0
            // Hand the query to the VM, which debounces (250 ms) and runs the
            // two-tier search once the query settles — never per keystroke.
            searchViewModel.search(newValue)
        }
        .onDisappear { searchViewModel.clear() }
    }

    // MARK: - Header / search field

    private var searchField: some View {
        HStack(spacing: CasaSpace.md) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(Color.textTertiary)

            TextField("Search meetings, people, summaries, approvals…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit { openSelected() }
                .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }

            if !rows.isEmpty {
                Text("\(rows.count) result\(rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.md)
    }

    // MARK: - States

    private var emptyPrompt: some View {
        VStack(spacing: CasaSpace.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(Color.textTertiary)
            Text("Search everything")
                .font(.headline)
                .foregroundStyle(Color.textSecondary)
            Text("Titles, people, summaries, transcripts, notes, and approvals.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CasaSpace.xxl)
    }

    private var noResults: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing matches \u{201C}\(trimmedQuery)\u{201D}. Try a different name, keyword, or phrase.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CasaSpace.xl)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.rows) { row in
                                resultRow(row)
                                    .id(row.index)
                            }
                        } header: {
                            sectionHeader(group.title)
                        }
                    }
                }
                .padding(.bottom, CasaSpace.xs)
            }
            .onChange(of: selectedIndex) { _, new in
                withAnimation(reduceMotion ? nil : CasaAnimation.fast) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.7)
            .foregroundStyle(Color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CasaSpace.lg)
            .padding(.top, CasaSpace.sm)
            .padding(.bottom, CasaSpace.xs)
            .background(.regularMaterial)
    }

    private func resultRow(_ row: ResultRow) -> some View {
        let isSelected = row.index == selectedIndex
        return HStack(alignment: .top, spacing: CasaSpace.md) {
            Image(systemName: row.icon)
                .font(.body)
                .foregroundStyle(isSelected ? Color.white : Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: CasaRadius.md)
                        .fill(isSelected ? Color.accentColor.opacity(0.5) : Color.textTertiary.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                highlighted(row.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.textPrimary)
                    .lineLimit(1)
                Text(row.caption)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.textTertiary)
                    .lineLimit(1)
                if let snippet = row.snippet {
                    highlighted(snippet)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.25) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { open(row) }
    }

    /// Renders `text` with EVERY case-insensitive occurrence of the *settled*
    /// query accent-tinted. Uses the VM's settled query (not the in-flight field
    /// text) so highlighting always matches the results actually on screen.
    private func highlighted(_ text: String) -> Text {
        Text(highlightOccurrences(of: searchViewModel.settledQuery, in: text))
    }

    private var footer: some View {
        HStack(spacing: CasaSpace.lg) {
            shortcut("\u{2191}\u{2193}", "navigate")
            shortcut("\u{21A9}", "open")
            shortcut("esc", "close")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.sm)
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: CasaSpace.xs) {
            Text(key)
                .font(.caption2.monospaced())
                .padding(.horizontal, CasaSpace.xs)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: CasaRadius.sm).fill(Color.textTertiary.opacity(0.15)))
            Text(label)
        }
    }

    // MARK: - Query / results

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the VM has finished searching for the *current* field text, so
    /// the view can tell "still debouncing" apart from "searched, found nothing".
    private var searchCompleted: Bool {
        searchViewModel.settledQuery == trimmedQuery
    }

    /// All rows flattened in display order, each tagged with its global index
    /// (so arrow-key selection maps onto a single integer).
    private var rows: [ResultRow] {
        groups.flatMap(\.rows)
    }

    /// Grouped, display-ordered results, built from the VM's already-computed
    /// (debounced) results — the view does NO searching here. Empty groups are
    /// omitted.
    private var groups: [ResultGroup] {
        let searchResults = searchViewModel.results
        guard !searchResults.isEmpty || !searchViewModel.approvalItems.isEmpty else { return [] }

        // People — dedupe by person name, count their meetings.
        var personMeetings: [String: Set<UUID>] = [:]
        var personLatest: [String: Meeting] = [:]
        var personOrder: [String] = []
        for result in searchResults where result.kind == .person {
            guard let person = result.person else { continue }
            if personMeetings[person] == nil { personOrder.append(person) }
            personMeetings[person, default: []].insert(result.meeting.id)
            if let current = personLatest[person] {
                if result.meeting.date > current.date { personLatest[person] = result.meeting }
            } else {
                personLatest[person] = result.meeting
            }
        }

        let titleResults = searchResults.filter { $0.kind == .title }
        let summaryResults = searchResults.filter { $0.kind == .summary }
        let transcriptResults = searchResults.filter { $0.kind == .transcript }
        let notesResults = searchResults.filter { $0.kind == .notes }

        var built: [ResultGroup] = []
        var cursor = 0

        func makeGroup(_ title: String, _ payloads: [RowPayload]) {
            guard !payloads.isEmpty else { return }
            let rows = payloads.map { payload -> ResultRow in
                defer { cursor += 1 }
                return ResultRow(index: cursor, payload: payload)
            }
            built.append(ResultGroup(title: title, rows: rows))
        }

        makeGroup("People", personOrder.map { person in
            .person(name: person, count: personMeetings[person]?.count ?? 0,
                    meeting: personLatest[person])
        })
        makeGroup("Meetings", titleResults.map { .meeting($0.meeting) })
        makeGroup("In summaries", summaryResults.map { .snippetMeeting($0.meeting, kind: .summary, snippet: $0.snippet) })
        makeGroup("In transcripts", transcriptResults.map { .snippetMeeting($0.meeting, kind: .transcript, snippet: $0.snippet) })
        makeGroup("Notes", notesResults.map { .snippetMeeting($0.meeting, kind: .notes, snippet: $0.snippet) })
        makeGroup("Approvals", searchViewModel.approvalItems.map { .approval($0) })

        return built
    }

    // MARK: - Selection / navigation

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let count = rows.count
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func openSelected() {
        guard let row = rows.first(where: { $0.index == selectedIndex }) ?? rows.first else { return }
        open(row)
    }

    private func open(_ row: ResultRow) {
        switch row.payload {
        case .meeting(let meeting),
             .snippetMeeting(let meeting, _, _):
            viewModel.sidebarSelection = .meeting(meeting.id)
        case .person(_, _, let meeting):
            if let meeting {
                viewModel.sidebarSelection = .meeting(meeting.id)
            }
        case .approval:
            viewModel.sidebarSelection = .actionQueue
        }
        onDismiss()
    }
}

// MARK: - Result model

private struct ResultGroup {
    let title: String
    let rows: [ResultRow]
}

private enum RowPayload {
    case person(name: String, count: Int, meeting: Meeting?)
    case meeting(Meeting)
    case snippetMeeting(Meeting, kind: ResultKind, snippet: String?)
    case approval(ActionQueueItem)
}

private struct ResultRow: Identifiable {
    let index: Int
    let payload: RowPayload

    var id: Int { index }

    var icon: String {
        switch payload {
        case .person: return "person.crop.circle"
        case .meeting: return "mic"
        case .snippetMeeting(_, let kind, _):
            switch kind {
            case .summary: return "sparkles"
            case .transcript: return "text.alignleft"
            case .notes: return "note.text"
            default: return "doc"
            }
        case .approval: return "tray.full"
        }
    }

    var title: String {
        switch payload {
        case .person(let name, _, _): return name
        case .meeting(let meeting), .snippetMeeting(let meeting, _, _): return meeting.title
        case .approval(let item): return item.title.isEmpty ? "(untitled)" : item.title
        }
    }

    var caption: String {
        switch payload {
        case .person(_, let count, let meeting):
            let plural = count == 1 ? "meeting" : "meetings"
            if let meeting {
                return "Participant in \(count) \(plural) · last: \(Self.dateString(meeting.date))"
            }
            return "Participant in \(count) \(plural)"
        case .meeting(let meeting):
            return "\(Self.dateString(meeting.date)) · \(meeting.status.rawValue)"
        case .snippetMeeting(let meeting, let kind, _):
            return "\(Self.dateString(meeting.date)) · \(Self.kindLabel(kind))"
        case .approval(let item):
            return "Approval · \(ActionQueuePresentation.statusLabel(item.status))"
        }
    }

    var snippet: String? {
        if case .snippetMeeting(_, _, let snippet) = payload {
            guard let snippet, !snippet.isEmpty else { return nil }
            return "…\(snippet)…"
        }
        return nil
    }

    private static func kindLabel(_ kind: ResultKind) -> String {
        switch kind {
        case .summary: return "summary"
        case .transcript: return "transcript"
        case .notes: return "notes"
        case .title: return "title"
        case .person: return "person"
        }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
