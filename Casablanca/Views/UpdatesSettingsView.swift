// Casablanca/Views/UpdatesSettingsView.swift
import SwiftUI

struct UpdatesSettingsView: View {
    let updateService: UpdateService
    @State private var preferences = UpdatePreferences()
    @State private var showHidden = false
    @State private var lastCheckedDisplay = "—"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { preferences.automaticChecksEnabled },
                    set: { newValue in
                        preferences.automaticChecksEnabled = newValue
                        if newValue { updateService.startScheduling() } else { updateService.stopScheduling() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically check for updates")
                        Text("Checks GitHub every 24 hours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Last checked: \(lastCheckedDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check for Updates…") {
                    Task { await updateService.checkNow(trigger: .manual) }
                }
            } header: {
                Text("Updates")
                    .gesture(
                        TapGesture()
                            .modifiers(.option)
                            .onEnded { showHidden.toggle() }
                    )
            }

            if showHidden {
                Section("Advanced") {
                    Toggle("Include prereleases", isOn: Binding(
                        get: { preferences.includePrereleases },
                        set: { preferences.includePrereleases = $0 }
                    ))
                    Button("Reveal install logs in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([UpdatePaths.default.logsRoot])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            lastCheckedDisplay = preferences.lastCheckAt.map { Self.dateFormatter.string(from: $0) } ?? "—"
        }
    }
}
