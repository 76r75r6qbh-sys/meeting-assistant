import SwiftUI

struct SettingsView: View {
    @AppStorage("obsidianVaultPath") private var obsidianVaultPath = ""
    @AppStorage("ollamaEndpoint") private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage("ollamaModel") private var ollamaModel = "llama3.2"
    @AppStorage("whisperModelSize") private var whisperModelSize = "base"

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
        .frame(width: 450, height: 300)
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
            Section("Whisper (Transcription)") {
                Picker("Model size", selection: $whisperModelSize) {
                    Text("Tiny (fastest)").tag("tiny")
                    Text("Base (balanced)").tag("base")
                    Text("Small (accurate)").tag("small")
                }
            }

            Section("Ollama (Summarization)") {
                TextField("Endpoint", text: $ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)

                TextField("Model", text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)

                Text("Make sure Ollama is running and the model is pulled")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .padding()
    }
}
