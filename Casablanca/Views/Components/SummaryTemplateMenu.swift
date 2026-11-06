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
    // Observed only so an edit in Settings re-renders the names.
    @AppStorage(AppPreferenceKey.summaryTemplates) private var storedTemplates = ""
    @AppStorage(AppPreferenceKey.summaryPromptTemplate) private var legacyPrompt = SummarizationService.defaultPromptTemplate

    var body: some View {
        let service = appModel.summarizationService
        SummaryTemplateMenuContent(
            presentation: SummaryTemplateMenuPresentation(
                templates: service.summaryTemplates(),
                currentID: meeting.summaryTemplateID,
                autoID: service.autoTemplateID(for: meeting)
            ),
            onPick: onPick
        )
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
