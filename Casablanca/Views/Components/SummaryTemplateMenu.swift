import SwiftUI

/// What the summary header shows about templates: the template the meeting is
/// summarized with, and the "Regenerate with…" entries. Pure, so it is tested
/// without a view.
///
/// `currentID` is the meeting's explicit override (`Meeting.summaryTemplateID`);
/// nil or blank means auto, and `autoID` is what `SummaryTemplateSelector`
/// picks for the meeting now. An override whose template no longer exists (a
/// deleted custom template) is summarized with General, so General is shown.
struct SummaryTemplateMenuPresentation {
    let currentName: String
    let items: [(id: String, name: String, isCurrent: Bool)]

    init(templates: [SummaryTemplate], currentID: String?, autoID: String) {
        let override = currentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAuto = override.isEmpty
        let wanted = isAuto ? autoID : override
        // Same fallback as `SummaryTemplateStore.template(id:in:)`: General.
        let current = templates.first { $0.id == wanted }
            ?? templates.first { $0.id == SummaryTemplateID.general }
            ?? templates.first

        if let current {
            currentName = isAuto ? "\(current.name) (auto)" : current.name
        } else {
            currentName = ""
        }
        items = templates.map { (id: $0.id, name: $0.name, isCurrent: $0.id == current?.id) }
    }
}

/// The summary header's template row: `Template: <name>` and a
/// "Regenerate with…" menu listing every template, the current one checked.
/// `onPick` gets the chosen template's id; the caller regenerates with it.
/// The caller disables this while a summary is running.
struct SummaryTemplateMenu: View {
    let meeting: Meeting
    let onPick: (String) -> Void

    @Environment(AppModel.self) private var appModel
    @AppStorage(AppPreferenceKey.summaryTemplates) private var storedTemplates = ""
    @AppStorage(AppPreferenceKey.summaryPromptTemplate) private var legacyPrompt = SummarizationService.defaultPromptTemplate

    /// The templates and the auto pick, computed off the render path: the auto
    /// pick reads the calendar event (EventKit) and the templates decode JSON.
    /// Refreshed whenever an input of either changes.
    @State private var resolved: Resolved?

    private struct Resolved {
        let templates: [SummaryTemplate]
        let autoID: String
    }

    /// Everything `resolved` depends on: the selector's inputs and both
    /// template settings keys. (User name aliases are not observed; they only
    /// change in Settings, and the next refresh picks them up.)
    private struct RefreshKey: Equatable {
        let title: String
        let calendarEventID: String?
        let participants: [String]
        let storedTemplates: String
        let legacyPrompt: String
    }

    var body: some View {
        // Until the first refresh has run, resolve once inline so the first
        // frame already shows the right "(auto)" name instead of a placeholder.
        let current = resolved ?? resolve()
        SummaryTemplateMenuContent(
            presentation: SummaryTemplateMenuPresentation(
                templates: current.templates,
                currentID: meeting.summaryTemplateID,
                autoID: current.autoID
            ),
            onPick: onPick
        )
        .task(id: RefreshKey(
            title: meeting.title,
            calendarEventID: meeting.calendarEventID,
            participants: meeting.participants,
            storedTemplates: storedTemplates,
            legacyPrompt: legacyPrompt
        )) {
            resolved = resolve()
        }
    }

    private func resolve() -> Resolved {
        let service = appModel.summarizationService
        return Resolved(templates: service.summaryTemplates(), autoID: service.autoTemplateID(for: meeting))
    }
}

/// The row itself, separate from `SummaryTemplateMenu` so layout tests can host
/// it without an `AppModel`.
struct SummaryTemplateMenuContent: View {
    let presentation: SummaryTemplateMenuPresentation
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            Text("Template: \(presentation.currentName)")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Template: \(presentation.currentName)")

            Spacer(minLength: CasaSpace.sm)

            Menu {
                ForEach(presentation.items, id: \.id) { item in
                    Button {
                        onPick(item.id)
                    } label: {
                        if item.isCurrent {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                Text("Regenerate with…")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Summarize this meeting again with another template")
        }
    }
}
