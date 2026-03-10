import SwiftUI

struct SettingsView: View {
    @AppStorage("obsidianVaultPath") private var obsidianVaultPath = ""
    @AppStorage("ollamaEndpoint") private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage("ollamaModel") private var ollamaModel = "llama3.2"
    @AppStorage("whisperModelSize") private var whisperModelSize = "base"
    @AppStorage("defaultTranscriptionLanguage") private var defaultTranscriptionLanguage = "en-US"
    @AppStorage("summaryPromptTemplate") private var summaryPromptTemplate = SummarizationService.defaultPromptTemplate
    @State private var availableOllamaModels: [String] = []
    @State private var isLoadingOllamaModels = false
    @State private var ollamaModelsError = ""

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
        }
        .frame(width: 560, height: 520)
        .task {
            await refreshOllamaModels()
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Obsidian Vault") {
                HStack {
                    TextField("Vault path", text: $obsidianVaultPath)
                        .textFieldStyle(.roundedBorder)

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
                    Text("Select your Obsidian vault to enable export")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
        .padding()
    }

    private var aiSettings: some View {
        Form {
            Section("Transcription") {
                Picker("Default language", selection: $defaultTranscriptionLanguage) {
                    ForEach(TranscriptionService.supportedLanguages, id: \.id) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                }

                Text("Can be overridden per meeting before transcribing")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Section("Ollama (Summarization)") {
                TextField("Endpoint", text: $ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task {
                            await refreshOllamaModels()
                        }
                    }

                HStack(spacing: CasaSpace.md) {
                    Picker("Model", selection: $ollamaModel) {
                        ForEach(ollamaModelOptions, id: \.self) { model in
                            if availableOllamaModels.contains(model) {
                                Text(model).tag(model)
                            } else {
                                Text("\(model) (not installed)").tag(model)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isLoadingOllamaModels || ollamaModelOptions.isEmpty)

                    Button("Refresh Models") {
                        Task {
                            await refreshOllamaModels()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isLoadingOllamaModels)
                }

                if isLoadingOllamaModels {
                    HStack(spacing: CasaSpace.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading installed Ollama models…")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                } else if !ollamaModelsError.isEmpty {
                    Text(ollamaModelsError)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                } else if availableOllamaModels.isEmpty {
                    Text("No Ollama models were found at this endpoint yet.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                } else if !availableOllamaModels.contains(ollamaModel) {
                    Text("The current model is not installed at this endpoint. Pick one of the detected models above.")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }

                Text("Casablanca loads the installed models from Ollama so summarization uses a valid local model.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Section("Summary Prompt") {
                TextEditor(text: $summaryPromptTemplate)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)

                Text("Supported placeholders: {{title}}, {{scheduled_time}}, {{transcript}}, {{timestamped_notes}}, {{freeform_notes}}")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)

                Button("Reset to Default Prompt") {
                    summaryPromptTemplate = SummarizationService.defaultPromptTemplate
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding()
    }

    private var ollamaModelOptions: [String] {
        if availableOllamaModels.contains(ollamaModel) || ollamaModel.isEmpty {
            return availableOllamaModels
        }
        return [ollamaModel] + availableOllamaModels
    }

    private func refreshOllamaModels() async {
        isLoadingOllamaModels = true
        ollamaModelsError = ""

        defer {
            isLoadingOllamaModels = false
        }

        do {
            let models = try await SummarizationService.fetchAvailableModels(endpoint: ollamaEndpoint)
            availableOllamaModels = models

            if ollamaModel.isEmpty, let firstModel = models.first {
                ollamaModel = firstModel
            }
        } catch {
            availableOllamaModels = []
            ollamaModelsError = error.localizedDescription
        }
    }
}
