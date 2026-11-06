import SwiftUI

/// The rules behind the template editor's buttons and saves; pure, so they are
/// tested without the view.
enum SummaryTemplateSettingsEditing {
    static let newTemplateName = "New template"

    /// A custom template that copies General's current (possibly customised)
    /// prompt. Not saved yet.
    static func newTemplate(in defaults: UserDefaults) -> SummaryTemplate {
        SummaryTemplate(
            id: "custom-\(UUID().uuidString)",
            name: newTemplateName,
            prompt: SummaryTemplateStore.template(id: SummaryTemplateID.general, in: defaults).prompt,
            isBuiltIn: false
        )
    }

    static func canDelete(_ template: SummaryTemplate) -> Bool { !template.isBuiltIn }
    static func canReset(_ template: SummaryTemplate) -> Bool { template.isBuiltIn }

    /// Writes an edit through `SummaryTemplateStore.save` (General → the legacy
    /// `summaryPromptTemplate` key). A custom template with a blank name keeps
    /// its saved name, else "New template", so no list or menu row is empty.
    static func apply(_ template: SummaryTemplate, in defaults: UserDefaults) {
        var edited = template
        if !edited.isBuiltIn, edited.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let saved = SummaryTemplateStore.all(in: defaults).first { $0.id == edited.id }?.name
            edited.name = saved ?? newTemplateName
        }
        SummaryTemplateStore.save(edited, in: defaults)
    }

    /// Whether the stored template changed somewhere else (the legacy prompt
    /// editor, another window) and the draft should show it. Our own write
    /// notifies us too, possibly after the user typed on; then the store still
    /// equals `lastWritten` and reloading would drop the newer keystrokes.
    static func shouldReload(stored: SummaryTemplate, draft: SummaryTemplate, lastWritten: SummaryTemplate?) -> Bool {
        stored != draft && stored != lastWritten
    }

    /// The name field's text once editing ends: a blank custom name was saved
    /// as the stored name, so show that again.
    static func committedName(draft: String, stored: SummaryTemplate) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stored.name : draft
    }
}

/// Settings → AI → Summary Templates: the templates (built-ins first, then the
/// user's own), with the selected one's name and prompt editable. Every edit is
/// saved as it is typed. General is the same text as the "Customize Prompt…"
/// editor (both use `summaryPromptTemplate`).
struct SummaryTemplatesSettingsSection: View {
    // Observed so changes made elsewhere (the legacy prompt editor) re-render
    // the list and reload the draft.
    @AppStorage(AppPreferenceKey.summaryTemplates) private var storedTemplates = ""
    @AppStorage(AppPreferenceKey.summaryPromptTemplate) private var legacyPrompt = SummarizationService.defaultPromptTemplate

    @State private var selectedID = SummaryTemplateID.general
    @State private var draftName = ""
    @State private var draftPrompt = ""
    @State private var didLoad = false
    /// What this view last saved, per template id, as the store resolved it.
    @State private var lastWritten: [String: SummaryTemplate] = [:]
    @FocusState private var isNameFocused: Bool

    private var defaults: UserDefaults { .standard }

    var body: some View {
        let templates = SummaryTemplateStore.all(in: defaults)
        let selected = SummaryTemplateStore.template(id: selectedID, in: defaults)

        Section("Summary Templates") {
            Text("Casablanca picks a template from the meeting title and attendees. Use \"Regenerate with…\" on a summary to choose another one.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(templates) { template in
                templateRow(template, isSelected: template.id == selected.id)
            }

            TextField("Name", text: $draftName)
                .focused($isNameFocused)
                .onSubmit { commitName() }
                .disabled(selected.isBuiltIn)
                .help(selected.isBuiltIn ? "Built-in templates keep their name" : "")

            TextEditor(text: $draftPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(height: 220)
                .accessibilityLabel("Prompt for \(selected.name)")

            HStack {
                Button("Add") { add() }
                    .help("Add a template that starts as a copy of General")
                Button("Delete") { delete(selected) }
                    .disabled(!SummaryTemplateSettingsEditing.canDelete(selected))
                Button("Reset") { reset(selected) }
                    .disabled(!SummaryTemplateSettingsEditing.canReset(selected)
                              || !SummaryTemplateStore.isModified(id: selected.id, in: defaults))
                    .help("Restore the shipped prompt")
                Spacer()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .onAppear {
            guard !didLoad else { return }
            loadDraft()
            didLoad = true
        }
        .onChange(of: draftName) { _, _ in saveDraft() }
        .onChange(of: draftPrompt) { _, _ in saveDraft() }
        .onChange(of: isNameFocused) { _, focused in
            if !focused { commitName() }
        }
        .onChange(of: legacyPrompt) { _, _ in reloadIfChangedElsewhere() }
        .onChange(of: storedTemplates) { _, _ in reloadIfChangedElsewhere() }
    }

    private func templateRow(_ template: SummaryTemplate, isSelected: Bool) -> some View {
        Button {
            select(template.id)
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Text(template.name)
                    .foregroundStyle(Color.textPrimary)
                if SummaryTemplateStore.isModified(id: template.id, in: defaults) {
                    Text("Modified")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, CasaSpace.xs)
                        .padding(.vertical, 1)
                        .background(Color.textTertiary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Actions

    private func select(_ id: String) {
        selectedID = id
        loadDraft()
    }

    private func add() {
        let template = SummaryTemplateSettingsEditing.newTemplate(in: defaults)
        SummaryTemplateStore.save(template, in: defaults)
        select(template.id)
    }

    private func delete(_ template: SummaryTemplate) {
        guard SummaryTemplateSettingsEditing.canDelete(template) else { return }
        SummaryTemplateStore.delete(id: template.id, in: defaults)
        select(SummaryTemplateID.general)
    }

    private func reset(_ template: SummaryTemplate) {
        guard SummaryTemplateSettingsEditing.canReset(template) else { return }
        SummaryTemplateStore.reset(id: template.id, in: defaults)
        loadDraft()
    }

    // MARK: - Draft

    private func loadDraft() {
        let template = SummaryTemplateStore.template(id: selectedID, in: defaults)
        // An unknown id (a template deleted elsewhere) resolves to General.
        selectedID = template.id
        draftName = template.name
        draftPrompt = template.prompt
        // The draft now equals the store, so an earlier own write must not mask
        // a later external change back to that same value.
        lastWritten[template.id] = nil
    }

    /// Saves only real edits, so loading a template never rewrites it.
    private func saveDraft() {
        guard didLoad else { return }
        let saved = SummaryTemplateStore.template(id: selectedID, in: defaults)
        guard saved.id == selectedID, draftName != saved.name || draftPrompt != saved.prompt else { return }
        SummaryTemplateSettingsEditing.apply(draft(isBuiltIn: saved.isBuiltIn), in: defaults)
        lastWritten[saved.id] = SummaryTemplateStore.template(id: saved.id, in: defaults)
    }

    private func draft(isBuiltIn: Bool) -> SummaryTemplate {
        SummaryTemplate(id: selectedID, name: draftName, prompt: draftPrompt, isBuiltIn: isBuiltIn)
    }

    /// A blank custom name was saved as the stored name; show it again.
    private func commitName() {
        let stored = SummaryTemplateStore.template(id: selectedID, in: defaults)
        guard stored.id == selectedID else { return }
        let name = SummaryTemplateSettingsEditing.committedName(draft: draftName, stored: stored)
        if name != draftName { draftName = name }
    }

    /// Another editor (or window) changed the selected template, or deleted
    /// it: show the stored version. Notifications of our own saves are ignored
    /// (see `SummaryTemplateSettingsEditing.shouldReload`).
    private func reloadIfChangedElsewhere() {
        let stored = SummaryTemplateStore.template(id: selectedID, in: defaults)
        guard stored.id == selectedID else {
            loadDraft()
            return
        }
        if SummaryTemplateSettingsEditing.shouldReload(
            stored: stored,
            draft: draft(isBuiltIn: stored.isBuiltIn),
            lastWritten: lastWritten[stored.id]
        ) {
            loadDraft()
        }
    }
}
