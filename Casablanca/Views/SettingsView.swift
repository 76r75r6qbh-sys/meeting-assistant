import OSLog
import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.obsidianVaultPath) private var obsidianVaultPath = ""
    @AppStorage(AppPreferenceKey.autoExportEnabled) private var autoExportEnabled: Bool = false
    @AppStorage(AppPreferenceKey.exportDestination) private var exportDestinationRaw: String = ExportDestination.obsidian.rawValue
    @AppStorage(AppPreferenceKey.prepTodoStorage) private var prepTodoStorageRaw: String = PrepTodoStorage.obsidian.rawValue
    @AppStorage(AppPreferenceKey.actionQueuePath) private var actionQueuePath = ""
    @AppStorage(AppPreferenceKey.defaultRecordingInputDeviceID) private var defaultRecordingInputDeviceID = AppPreferenceValue.systemDefaultRecordingInputDevice
    @AppStorage(AppPreferenceKey.keepOriginalWAV) private var keepOriginalWAV = false
    @AppStorage(AppPreferenceKey.llmProvider) private var llmProviderRaw: String = LLMProviderKind.ollama.rawValue
    @AppStorage(AppPreferenceKey.ollamaEndpoint) private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage(AppPreferenceKey.ollamaModel) private var ollamaModel = "llama3.2"
    @AppStorage(AppPreferenceKey.omlxEndpoint) private var omlxEndpoint = "http://localhost:8000/v1"
    @AppStorage(AppPreferenceKey.omlxModel) private var omlxModel = ""
    @AppStorage(AppPreferenceKey.omlxAPIKey) private var omlxAPIKey = ""
    @AppStorage(AppPreferenceKey.claudeCLIPath) private var claudeCLIPath = ""
    @AppStorage(AppPreferenceKey.claudeCLIModel) private var claudeCLIModel = "sonnet"
    @AppStorage(AppPreferenceKey.whisperModel) private var whisperModel = AppPreferenceValue.defaultWhisperModel
    @AppStorage(AppPreferenceKey.defaultTranscriptionLanguage) private var defaultTranscriptionLanguage = "en-US"
    @AppStorage(AppPreferenceKey.autoSummarizeAfterTranscription) private var autoSummarizeAfterTranscription = false
    @AppStorage(AppPreferenceKey.summaryThinkingEnabled) private var summaryThinkingEnabled = false
    @AppStorage(AppPreferenceKey.summaryPromptTemplate) private var summaryPromptTemplate = SummarizationService.defaultPromptTemplate
    @AppStorage(AppPreferenceKey.terminologyCorrectionEnabled) private var terminologyCorrectionEnabled = false
    @AppStorage(AppPreferenceKey.terminologyList) private var terminologyList = ""
    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferenceKey.useNativeMarkdownEditor) private var useNativeMarkdownEditor = false
    @AppStorage(AppPreferenceKey.meetingStartNotificationsEnabled) private var meetingStartNotificationsEnabled = true
    @AppStorage(AppPreferenceKey.meetingStartNotificationLeadTime) private var meetingStartLeadTimeRaw = MeetingStartLeadTime.atStart.rawValue
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelsError = ""
    @State private var availableInputDevices: [AudioInputDevice] = []
    @State private var systemDefaultInputDeviceName = ""
    @State private var presentedSheet: SettingsSheet?
    @State private var notificationsDenied = false

    private enum SettingsSheet: Identifiable {
        case summaryPrompt
        case terminologyList
        var id: Self { self }
    }

    private var exportDestination: ExportDestination {
        ExportDestination(rawValue: exportDestinationRaw) ?? .obsidian
    }

    private var prepTodoStorage: PrepTodoStorage {
        PrepTodoStorage(rawValue: prepTodoStorageRaw) ?? .obsidian
    }

    private var llmProvider: LLMProviderKind {
        LLMProviderKind(rawValue: llmProviderRaw) ?? .ollama
    }

    private var providerEndpointBinding: Binding<String> {
        switch llmProvider {
        case .ollama: return Binding(get: { ollamaEndpoint }, set: { ollamaEndpoint = $0 })
        case .omlx: return Binding(get: { omlxEndpoint }, set: { omlxEndpoint = $0 })
        // Carries the `claude` CLI path, not a URL. Empty means auto-detect.
        case .claudeCode: return Binding(get: { claudeCLIPath }, set: { claudeCLIPath = $0 })
        }
    }

    private var providerModelBinding: Binding<String> {
        switch llmProvider {
        case .ollama: return Binding(get: { ollamaModel }, set: { ollamaModel = $0 })
        case .omlx: return Binding(get: { omlxModel }, set: { omlxModel = $0 })
        case .claudeCode: return Binding(get: { claudeCLIModel }, set: { claudeCLIModel = $0 })
        }
    }

    /// Empty for the local providers, which have no caveats worth a caption.
    private var providerCaveats: String {
        LLMProviderCopy.caveats(for: llmProvider)
    }

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            aiSettings
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }

            recordingSettings
                .tabItem {
                    Label("Recording", systemImage: "mic")
                }

            UpdatesSettingsView(updateService: appModel.updateService)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        .task {
            refreshRecordingInputDevices()
            await refreshModels()
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Obsidian Vault") {
                HStack {
                    TextField("Vault path", text: $obsidianVaultPath)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Select your Obsidian vault folder"

                        if panel.runModal() == .OK, let url = panel.url {
                            obsidianVaultPath = url.path
                        }
                    }
                }

                if obsidianVaultPath.isEmpty {
                    Text("Your Obsidian vault path is required when Obsidian is selected for export or for prep & todo storage.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                } else {
                    Text("Casablanca stores generic todos in `tasks/Casablanca Todos.md` and syncs meeting action items from your meeting notes files.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            Section("Export & Storage") {
                Picker("Export destination", selection: $exportDestinationRaw) {
                    Text("Obsidian").tag(ExportDestination.obsidian.rawValue)
                    Text("Apple Notes").tag(ExportDestination.appleNotes.rawValue)
                }

                Text(exportDestination == .obsidian
                    ? "Meeting notes are saved as Markdown to your Obsidian vault."
                    : "Meeting notes are saved to the Casablanca folder in Apple Notes. The first export will ask for permission to control Notes.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Prep & todo storage", selection: $prepTodoStorageRaw) {
                    Text("Obsidian").tag(PrepTodoStorage.obsidian.rawValue)
                    Text("Local (Casablanca only)").tag(PrepTodoStorage.local.rawValue)
                }

                Text(prepTodoStorage == .obsidian
                    ? "Prep notes are read from your Obsidian vault and todos sync to and from your vault."
                    : "Prep notes are hidden. Todos are stored only inside Casablanca.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Action Queue") {
                HStack {
                    TextField("action-queue.json path", text: $actionQueuePath)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowsMultipleSelection = false
                        panel.message = "Select your action-queue.json file"

                        if panel.runModal() == .OK, let url = panel.url {
                            actionQueuePath = url.path
                        }
                    }
                }

                if actionQueuePath.isEmpty {
                    Text("Leave empty to use the default location (`~/.claude/projects/-Users-youri-broekhuizen/memory/action-queue.json`). The Approvals inbox reads draft items from this file and writes back your decisions.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The Approvals inbox reads draft items from this file and writes back your decisions.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Automation") {
                Toggle("Automatically summarize after transcription", isOn: $autoSummarizeAfterTranscription)

                Toggle("Automatically export notes after recording", isOn: $autoExportEnabled)

                Text("Automations run in sequence after recording: transcription, summary generation, then export to the selected destination when enabled.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Section("Setup") {
                Button("Show Setup Guide Again") {
                    hasCompletedOnboarding = false
                }
                .buttonStyle(SecondaryButtonStyle())

                Text("Re-run the first-run onboarding to revisit vault, permissions and language model setup.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: actionQueuePath) { _, _ in
            appModel.actionQueueModel.refreshWatch()
        }
        .onChange(of: prepTodoStorageRaw) { _, newValue in
            if newValue == PrepTodoStorage.obsidian.rawValue {
                Task { @MainActor in
                    do {
                        try ObsidianTodoSyncService.refreshAllTodos(in: modelContext)
                    } catch {
                        // Best-effort refresh — surface non-blocking error in the log only.
                        Log.persistence.error("Storage transition refresh failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private var aiSettings: some View {
        Form {
            Section("Language Model (Summarization)") {
                Picker("Provider", selection: $llmProviderRaw) {
                    Text("Ollama").tag(LLMProviderKind.ollama.rawValue)
                    Text("oMLX").tag(LLMProviderKind.omlx.rawValue)
                    Text("Claude Code").tag(LLMProviderKind.claudeCode.rawValue)
                }
                .pickerStyle(.segmented)
                .onChange(of: llmProviderRaw) { _, _ in
                    Task { await refreshModels() }
                }

                TextField(LLMProviderCopy.locationFieldLabel(for: llmProvider), text: providerEndpointBinding)
                    .onSubmit {
                        Task { await refreshModels() }
                    }

                if llmProvider == .omlx {
                    SecureField("API key", text: $omlxAPIKey)
                        .onSubmit {
                            Task { await refreshModels() }
                        }

                    Text("Optional. Required if oMLX was started with --api-key.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }

                HStack(spacing: CasaSpace.md) {
                    Picker("Model", selection: providerModelBinding) {
                        ForEach(modelOptions, id: \.self) { model in
                            if availableModels.contains(model) {
                                Text(model).tag(model)
                            } else {
                                // Not "(not installed)": under Claude Code nothing is
                                // installed here, the model is simply not on offer.
                                Text("\(model) (unavailable)").tag(model)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isLoadingModels || modelOptions.isEmpty)

                    Button("Refresh Models") {
                        Task { await refreshModels() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isLoadingModels)
                }

                if isLoadingModels {
                    HStack(spacing: CasaSpace.sm) {
                        ProgressView().controlSize(.small)
                        Text(LLMProviderCopy.modelLoadingLabel(for: llmProvider))
                    }
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                } else if !modelsError.isEmpty {
                    Text(modelsError)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                } else if availableModels.isEmpty {
                    Text(LLMProviderCopy.noModelsFound(for: llmProvider))
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                } else if !availableModels.contains(providerModelBinding.wrappedValue) {
                    Text(LLMProviderCopy.modelNotAvailable(for: llmProvider))
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }

                Text(LLMProviderCopy.summarizationFooter(for: llmProvider))
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !providerCaveats.isEmpty {
                    Text(providerCaveats)
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Summary Prompt") {
                Toggle("Allow model thinking", isOn: $summaryThinkingEnabled)
                Text("Reasoning models think before answering. Off (recommended) gives faster, more concise summaries; on allows extended reasoning (slower, larger output budget).")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)

                Button("Customize Prompt...") {
                    presentedSheet = .summaryPrompt
                }
                .buttonStyle(SecondaryButtonStyle())

                Text("Open the prompt editor in a separate sheet to adjust the summary structure and placeholders.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)

                Text("Supported placeholders: {{title}}, {{scheduled_time}}, {{transcript}}, {{freeform_notes}}.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Section("Terminology") {
                Toggle("Correct terminology after transcription", isOn: $terminologyCorrectionEnabled)

                Text("Domain-specific terms that are often misspelled by the transcriber. One term per line. Use a colon to list common misspellings, e.g.:\n    Medicore: Mediscore, Medi-Core")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Customize Terminology List...") {
                    presentedSheet = .terminologyList
                }
                .buttonStyle(SecondaryButtonStyle())

                Text("When the toggle is on and the list is non-empty, Casablanca runs a deterministic find/replace plus a low-temperature pass through \(LLMProviderCopy.displayName(for: llmProvider)) on each new transcript before summarization.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .summaryPrompt:
                summaryPromptSheet
            case .terminologyList:
                terminologyListSheet
            }
        }
    }

    private var recordingSettings: some View {
        Form {
            Section("Input Device") {
                HStack(spacing: CasaSpace.md) {
                    Picker("Default microphone", selection: $defaultRecordingInputDeviceID) {
                        ForEach(recordingInputOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    Button("Refresh Devices") {
                        refreshRecordingInputDevices()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Text(systemDefaultInputDeviceDescription)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Section("Storage") {
                Toggle("Keep original WAV", isOn: $keepOriginalWAV)

                Text("When off (default), finished recordings are compressed to AAC/m4a after transcription and the original WAV is deleted (~8x smaller, no audible loss for speech). Turn on to keep the uncompressed WAV instead.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Section("Transcription") {
                Picker("Default language", selection: $defaultTranscriptionLanguage) {
                    ForEach(TranscriptionService.supportedLanguages, id: \.id) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                }

                Text("Can be overridden per meeting before transcribing")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)

                Picker("Local Whisper model", selection: $whisperModel) {
                    ForEach(TranscriptionService.availableWhisperModels, id: \.id) { model in
                        Text(model.name).tag(model.id)
                    }
                }

                Text("Downloaded automatically inside Casablanca on first use. Larger models are slower but usually more accurate.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Section("Notifications") {
                Toggle("Notify me to start recording at meeting time", isOn: $meetingStartNotificationsEnabled)

                Picker("Notify", selection: $meetingStartLeadTimeRaw) {
                    ForEach(MeetingStartLeadTime.allCases) { lead in
                        Text(lead.displayName).tag(lead.rawValue)
                    }
                }
                .disabled(!meetingStartNotificationsEnabled)

                Text("Shows a notification with a “Start Recording” button at each upcoming meeting's start time, so you can begin recording with one click. Tapping it does nothing if a recording is already running.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if meetingStartNotificationsEnabled, notificationsDenied {
                    Label(
                        "Notifications are disabled in System Settings — enable them for Casablanca to receive these prompts.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Editor") {
                Toggle("Use native notes editor (beta)", isOn: $useNativeMarkdownEditor)

                Text("Replaces the web-based notes editor with a native macOS text view: live markdown highlighting, native undo, ⌘F find, and dictation. Restart not required — open a meeting's notes to try it.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: meetingStartNotificationsEnabled) { _, _ in
            appModel.meetingStartNotifier.reschedule()
            Task { await refreshNotificationAuthorizationStatus() }
        }
        .onChange(of: meetingStartLeadTimeRaw) { _, _ in
            appModel.meetingStartNotifier.reschedule()
        }
        .task {
            await refreshNotificationAuthorizationStatus()
        }
    }

    /// Reflect the current system notification authorization in the Settings hint.
    /// Only `.denied` surfaces the warning; `.notDetermined` stays quiet (the
    /// prompt fires lazily) and `.authorized`/`.provisional` need no caption.
    private func refreshNotificationAuthorizationStatus() async {
        let status = await NotificationAuthorization.shared.currentStatus()
        notificationsDenied = status == .denied
    }

    private var modelOptions: [String] {
        let current = providerModelBinding.wrappedValue
        if availableModels.contains(current) || current.isEmpty {
            return availableModels
        }
        return [current] + availableModels
    }

    private var recordingInputOptions: [(id: String, label: String)] {
        var options: [(id: String, label: String)] = [
            (
                id: AppPreferenceValue.systemDefaultRecordingInputDevice,
                label: systemDefaultPickerLabel
            )
        ]

        if defaultRecordingInputDeviceID != AppPreferenceValue.systemDefaultRecordingInputDevice,
           !availableInputDevices.contains(where: { $0.id == defaultRecordingInputDeviceID }) {
            options.append((
                id: defaultRecordingInputDeviceID,
                label: "Unavailable device (\(defaultRecordingInputDeviceID))"
            ))
        }

        options.append(contentsOf: availableInputDevices.map { ($0.id, $0.name) })
        return options
    }

    private var systemDefaultPickerLabel: String {
        if systemDefaultInputDeviceName.isEmpty {
            return "System Default"
        }
        return "System Default (\(systemDefaultInputDeviceName))"
    }

    private var systemDefaultInputDeviceDescription: String {
        if systemDefaultInputDeviceName.isEmpty {
            return "Choose a specific microphone or let Casablanca follow the current macOS system default input device."
        }
        return "macOS currently reports “\(systemDefaultInputDeviceName)” as the system default microphone."
    }

    private func refreshModels() async {
        isLoadingModels = true
        modelsError = ""
        defer { isLoadingModels = false }

        let endpoint = providerEndpointBinding.wrappedValue
        do {
            let models = try await SummarizationService.fetchAvailableModels(endpoint: endpoint)
            availableModels = models
            let current = providerModelBinding.wrappedValue
            if current.isEmpty, let firstModel = models.first {
                providerModelBinding.wrappedValue = firstModel
            }
        } catch {
            availableModels = []
            modelsError = error.localizedDescription
        }
    }

    private func refreshRecordingInputDevices() {
        if defaultRecordingInputDeviceID.isEmpty {
            defaultRecordingInputDeviceID = AppPreferenceValue.systemDefaultRecordingInputDevice
        }

        availableInputDevices = AudioRecordingService.availableRecordingInputDevices()
        systemDefaultInputDeviceName = AudioRecordingService.systemDefaultInputDeviceName() ?? ""
    }

    private var summaryPromptSheet: some View {
        sheetContainer(title: "Customize Summary Prompt") {
            Text("This template is sent to \(LLMProviderCopy.displayName(for: llmProvider)) whenever Casablanca generates a summary.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)

            TextEditor(text: $summaryPromptTemplate)
                .font(.system(.body, design: .monospaced))
                .frame(height: 240)

            Text("Supported placeholders: {{title}}, {{scheduled_time}}, {{transcript}}, {{freeform_notes}}.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)

            HStack {
                Button("Reset to Default Prompt") {
                    summaryPromptTemplate = SummarizationService.defaultPromptTemplate
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
    }

    private var terminologyListSheet: some View {
        sheetContainer(title: "Customize Terminology List") {
            Text("One term per line. Optional aliases follow a colon, comma-separated.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)

            TextEditor(text: $terminologyList)
                .font(.system(.body, design: .monospaced))
                .frame(height: 200)

            Text("Examples:\n    Medicore: Mediscore, Medi-Core\n    Wegiz BgZ: Wegis, BGZ\n    Orchestra\n\nLines starting with `#` are ignored.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset to Empty") {
                    terminologyList = ""
                }
                .buttonStyle(.bordered)
                .disabled(terminologyList.isEmpty)

                Spacer()
            }
        }
    }

    /// Sheet container with title at the top, content body, and a
    /// bottom-anchored Done bar. Sized to its intrinsic content so macOS
    /// doesn't clip it to the parent Settings window. Escape and Enter
    /// both dismiss.
    @ViewBuilder
    private func sheetContainer<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                Text(title)
                    .font(.title3.weight(.semibold))

                content()
            }
            .padding(.horizontal, CasaSpace.xl)
            .padding(.top, CasaSpace.lg)
            .padding(.bottom, CasaSpace.md)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    presentedSheet = nil
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding(.horizontal, CasaSpace.xl)
            .padding(.vertical, CasaSpace.sm)
        }
        .frame(width: CasaLayout.modalWidthLarge)
        .fixedSize(horizontal: false, vertical: true)
        .background(KeyboardDismissCatcher { presentedSheet = nil })
    }
}

/// Invisible helper view that listens for the Escape key to dismiss the
/// surrounding sheet. SwiftUI's `.keyboardShortcut(.cancelAction)` only
/// works when the focused button is reachable via Tab; placing the
/// shortcut on a hidden Button as a `.background` makes Escape work
/// regardless of focus.
private struct KeyboardDismissCatcher: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
