import SwiftUI
import AppKit
import CoreGraphics

/// First-run setup flow. A 4-step guided onboarding presented as a sheet on the
/// main window when `hasCompletedOnboarding` is false. Re-runnable from Settings.
///
/// Steps:
///  1. Welcome — app name + privacy reassurance.
///  2. Vault & export destination — reuses the same `@AppStorage` keys as Settings.
///  3. Permissions — Microphone, System audio (screen recording), Calendar with live status.
///  4. LLM check — shows the configured provider/endpoint and a cheap reachability probe.
struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false

    // Reuse the SAME preference keys as SettingsView.
    @AppStorage(AppPreferenceKey.obsidianVaultPath) private var obsidianVaultPath = ""
    @AppStorage(AppPreferenceKey.exportDestination) private var exportDestinationRaw: String = ExportDestination.obsidian.rawValue
    @AppStorage(AppPreferenceKey.prepTodoStorage) private var prepTodoStorageRaw: String = PrepTodoStorage.obsidian.rawValue
    @AppStorage(AppPreferenceKey.llmProvider) private var llmProviderRaw: String = LLMProviderKind.ollama.rawValue
    @AppStorage(AppPreferenceKey.ollamaEndpoint) private var ollamaEndpoint = "http://localhost:11434"
    @AppStorage(AppPreferenceKey.omlxEndpoint) private var omlxEndpoint = "http://localhost:8000/v1"
    @AppStorage(AppPreferenceKey.claudeCLIPath) private var claudeCLIPath = ""

    @State private var step: Step = .welcome
    @State private var llmCheck: LLMCheckState = .idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int, CaseIterable {
        case welcome, vault, permissions, llm
    }

    private enum LLMCheckState: Equatable {
        case idle
        case checking
        case reachable(modelCount: Int)
        case unreachable(message: String)
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

    private var providerName: String {
        LLMProviderCopy.displayName(for: llmProvider)
    }

    private var providerEndpoint: String {
        switch llmProvider {
        case .ollama: return ollamaEndpoint
        case .omlx: return omlxEndpoint
        // Carries the `claude` CLI path, not a URL. Empty means auto-detect.
        case .claudeCode: return claudeCLIPath
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBand

            VStack(alignment: .leading, spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: CasaSpace.lg)

                progressDots

                navigationBar
            }
            .padding(.horizontal, CasaSpace.xl)
            .padding(.top, CasaSpace.xl)
            .padding(.bottom, CasaSpace.lg)
        }
        .frame(width: CasaLayout.modalWidthSmall)
        .frame(minHeight: 520)
        .background(Color.backgroundPrimary)
    }

    // MARK: - Header

    private var headerBand: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentPrimary, Color.accentSecondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: headerSymbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(height: 120)
    }

    private var headerSymbol: String {
        switch step {
        case .welcome: return "mic.circle.fill"
        case .vault: return "folder.fill"
        case .permissions: return "lock.shield.fill"
        case .llm: return "sparkles"
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .vault: vaultStep
        case .permissions: permissionsStep
        case .llm: llmStep
        }
    }

    private func stepHeader(_ label: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Color.accentPrimary)

            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.textPrimary)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 1 — Welcome

    private var welcomeStep: some View {
        // Rendered before the provider step, so it describes whatever provider is
        // stored right now — including the `.ollama` default on a first run.
        let summaries = LLMProviderCopy.summariesFeature(for: llmProvider)
        return VStack(alignment: .leading, spacing: CasaSpace.lg) {
            stepHeader(
                "Step 1 of 4 · Welcome",
                "Welcome to Casablanca",
                LLMProviderCopy.privacySubtitle(for: llmProvider)
            )

            VStack(alignment: .leading, spacing: CasaSpace.md) {
                // Recording and transcription are on-device for every provider.
                featureRow("waveform", "Record meetings", "Capture microphone and system audio.")
                featureRow("text.bubble", "Local transcription", "Whisper runs on-device.")
                featureRow("sparkles", summaries.title, summaries.subtitle)
            }
        }
    }

    private func featureRow(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: CasaSpace.md) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Color.accentPrimary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(Color.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(Color.textTertiary)
            }
        }
    }

    // MARK: Step 2 — Vault & export destination

    private var vaultStep: some View {
        VStack(alignment: .leading, spacing: CasaSpace.lg) {
            stepHeader(
                "Step 2 of 4 · Storage",
                "Where should notes live?",
                "Choose how Casablanca exports meeting notes and stores prep & todos. You can change this later in Settings."
            )

            VStack(alignment: .leading, spacing: CasaSpace.sm) {
                Text("Export destination")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                Picker("", selection: $exportDestinationRaw) {
                    Text("Obsidian").tag(ExportDestination.obsidian.rawValue)
                    Text("Apple Notes").tag(ExportDestination.appleNotes.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if exportDestination == .obsidian || prepTodoStorage == .obsidian {
                VStack(alignment: .leading, spacing: CasaSpace.sm) {
                    Text("Obsidian vault folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    HStack {
                        TextField("Vault path", text: $obsidianVaultPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseForVault() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    if obsidianVaultPath.isEmpty {
                        Text("Required when Obsidian is selected for export or storage.")
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: CasaSpace.sm) {
                Text("Prep & todo storage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                Picker("", selection: $prepTodoStorageRaw) {
                    Text("Obsidian").tag(PrepTodoStorage.obsidian.rawValue)
                    Text("Local (Casablanca only)").tag(PrepTodoStorage.local.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func browseForVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"
        if panel.runModal() == .OK, let url = panel.url {
            obsidianVaultPath = url.path
        }
    }

    // MARK: Step 3 — Permissions

    private var captureStatus: OnboardingCaptureStatus {
        OnboardingCaptureStatus(
            microphoneGranted: appModel.permissionsManager.microphoneAuthorized,
            screenCaptureGranted: appModel.permissionsManager.screenCaptureAuthorized
        )
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: CasaSpace.lg) {
            stepHeader(
                "Step 3 of 4 · Permissions",
                "Let Casablanca hear your meetings",
                "Grant access so Casablanca can record audio and read your calendar. These run entirely on your Mac."
            )

            VStack(spacing: CasaSpace.sm) {
                permissionRow(
                    symbol: "mic.fill",
                    title: "Microphone",
                    subtitle: "Captures your own voice — required to record.",
                    granted: appModel.permissionsManager.microphoneAuthorized,
                    action: { Task { await grantMicrophone() } }
                )
                permissionRow(
                    symbol: "display",
                    title: "Screen Recording (system audio)",
                    subtitle: "Captures the other participants' audio. Optional — skip for mic-only.",
                    granted: appModel.permissionsManager.screenCaptureAuthorized,
                    action: { grantScreenCapture() }
                )
                permissionRow(
                    symbol: "calendar",
                    title: "Calendar",
                    subtitle: "Shows upcoming meetings. Optional.",
                    granted: appModel.permissionsManager.calendarAuthorized,
                    action: { Task { await grantCalendar() } }
                )
            }

            captureStatusBanner

            Text("Screen Recording uses macOS's permission of the same name. After granting it you may need to restart Casablanca.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            await appModel.permissionsManager.checkAll()
        }
    }

    @ViewBuilder
    private var captureStatusBanner: some View {
        let status = captureStatus
        HStack(alignment: .top, spacing: CasaSpace.sm) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(CasaSpace.md)
        .background(status.tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: CasaRadius.lg))
    }

    private func permissionRow(symbol: String, title: String, subtitle: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: CasaSpace.md) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(granted ? Color.accentSuccess : Color.accentPrimary)
                .frame(width: 30, height: 30)
                .background(Color.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: CasaRadius.lg))

            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentSuccess)
            } else {
                Button("Grant", action: action)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, CasaSpace.md)
        .padding(.vertical, CasaSpace.sm)
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.lg)
                .strokeBorder(Color.borderSubtle, lineWidth: 1)
        )
    }

    private func grantMicrophone() async {
        _ = await appModel.permissionsManager.requestMicrophone()
        // requestMicrophone updates the published flag; refresh others too.
        await appModel.permissionsManager.checkAll()
    }

    private func grantCalendar() async {
        _ = await appModel.calendarService.requestAccess()
        await appModel.permissionsManager.checkCalendar()
    }

    private func grantScreenCapture() {
        // Trigger the real system prompt. macOS only honors this once per launch
        // and requires a restart to take effect, so also surface System Settings.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            openScreenCaptureSettings()
        }
        Task { await appModel.permissionsManager.checkScreenCapture() }
    }

    private func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Step 4 — LLM check

    private var llmStep: some View {
        let header = LLMProviderCopy.llmStepHeader(for: llmProvider)
        return VStack(alignment: .leading, spacing: CasaSpace.lg) {
            stepHeader(
                "Step 4 of 4 · Language model",
                header.title,
                header.subtitle
            )

            VStack(alignment: .leading, spacing: CasaSpace.sm) {
                infoRow(label: "Provider", value: providerName)
                Divider()
                infoRow(label: LLMProviderCopy.locationFieldLabel(for: llmProvider), value: providerEndpoint)
            }
            .padding(CasaSpace.md)
            .background(Color.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.lg))

            llmStatusView

            Text("Change the provider, endpoint and model anytime in Settings → AI.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
        }
        .task {
            await runLLMCheck()
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var llmStatusView: some View {
        switch llmCheck {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: CasaSpace.sm) {
                ProgressView().controlSize(.small)
                Text("Checking \(providerName)…")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        case .reachable(let count):
            HStack(spacing: CasaSpace.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentSuccess)
                Text(LLMProviderCopy.reachableSummary(modelCount: count, for: llmProvider))
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        case .unreachable(let message):
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.accentWarning)
                    Text("Could not reach \(providerName).")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    Button("Retry") { Task { await runLLMCheck() } }
                        .buttonStyle(GhostButtonStyle())
                        .controlSize(.small)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runLLMCheck() async {
        llmCheck = .checking
        do {
            let models = try await SummarizationService.fetchAvailableModels(endpoint: providerEndpoint)
            llmCheck = .reachable(modelCount: models.count)
        } catch {
            llmCheck = .unreachable(message: error.localizedDescription)
        }
    }

    // MARK: - Progress + navigation

    private var progressDots: some View {
        HStack(spacing: CasaSpace.sm) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s == step ? Color.accentPrimary : Color.textTertiary.opacity(0.4))
                    .frame(width: s == step ? 20 : 7, height: 7)
                    .casaAnimation(CasaAnimation.fast, value: step)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, CasaSpace.lg)
    }

    private var navigationBar: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            Spacer()

            if step != .llm {
                Button("Skip", action: finish)
                    .buttonStyle(GhostButtonStyle())
            }

            Button(step == .llm ? "Finish" : "Continue") {
                if step == .llm { finish() } else { goForward() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func goForward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(reduceMotion ? nil : CasaAnimation.standard) { step = next }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(reduceMotion ? nil : CasaAnimation.standard) { step = prev }
    }

    private func finish() {
        hasCompletedOnboarding = true
    }
}
