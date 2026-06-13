import AppKit
import SwiftData
import SwiftUI

struct NotesEditorView: View {
    private enum RecordingActionPhase { case start, pause, resume, stop }

    @Bindable var meeting: Meeting
    @Bindable var recordingService: AudioRecordingService
    var interruptionCoordinator: RecordingInterruptionCoordinator? = nil
    let autoStartRecording: Bool
    let onBack: () -> Void

    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferenceKey.recordingWorkspaceFocusMode) private var recordingWorkspaceFocusMode = false
    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerStart = false
    @State private var prepMarkdown: String?
    // Native trailing inspector hosting Prep + To-Dos as tabs. Resizing and the
    // toggle state are handled by AppKit (smooth + HIG-compliant).
    @State private var isInspectorPresented = false
    @State private var inspectorTab: InspectorTab = .prep
    @State private var isFinalizingRecording = false
    @State private var recordingActionPhase: RecordingActionPhase = .start

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if presentation.showsExpandedRecordingChrome && !presentation.isFocusModeActive {
                    RecordingStatusBar(
                        presentation: presentation,
                        autoPause: autoPauseIndicatorPresentation,
                        elapsed: formattedElapsed,
                        audioLevel: recordingService.audioLevel,
                        isPreparing: recordingService.isPreparing,
                        isFinalizing: isFinalizingRecording,
                        isRecordingState: isRecordingState,
                        onPause: { Task { await pauseRecording() } },
                        onResume: { Task { await resumeRecording() } },
                        onStop: { Task { await stopRecording() } },
                        deviceChip: { deviceLanguageChip }
                    )
                    Divider()
                }

                if presentation.showsNotesHeader {
                    MeetingNotesHeader(meeting: meeting)
                    Divider()
                }

                mainContent

                if !presentation.isFocusModeActive {
                    Divider()
                    footer
                }
            }
            .blur(radius: presentation.showsBlockingOverlay ? 1.5 : 0)

            if presentation.showsFocusRecordingPill {
                FocusRecordingPill(
                    presentation: presentation,
                    elapsed: formattedElapsed,
                    isRecordingState: isRecordingState,
                    isPreparing: recordingService.isPreparing,
                    isFinalizing: isFinalizingRecording,
                    onPause: { Task { await pauseRecording() } },
                    onResume: { Task { await resumeRecording() } },
                    onStop: { Task { await stopRecording() } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(CasaSpace.lg)
                .transition(.opacity)
            }

            if presentation.isFocusModeActive {
                FocusExitButton(onExitFocus: { recordingWorkspaceFocusMode = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(CasaSpace.lg)
                    .transition(.opacity)
            }

            if presentation.showsBlockingOverlay {
                BlockingProgressOverlay(
                    title: presentation.blockingOverlayTitle ?? "Finalizing recording…",
                    message: "Just a moment — Casablanca is preparing the recording for transcription."
                )
            }
        }
        .animation(CasaAnimation.standard, value: presentation.isFocusModeActive)
        .onExitCommand {
            if recordingWorkspaceFocusMode {
                recordingWorkspaceFocusMode = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(presentation.backButtonDisabled)
            }

            // Pane controls live in the toolbar (top-right), consistent across the
            // notes and recording states — matching the approved mockup.
            if !presentation.isFocusModeActive && !presentation.isFinalizing {
                ToolbarItemGroup {
                    // Single inspector toggle (Prep & To-Dos live as tabs inside).
                    // A Toggle with .button style shows a clear on-state natively.
                    Toggle(isOn: $isInspectorPresented) {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .toggleStyle(.button)
                    .help(isInspectorPresented ? "Hide Inspector" : "Show Prep & To-Dos")

                    Button {
                        recordingWorkspaceFocusMode = true
                    } label: {
                        Label("Focus", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Distraction-free notes (Esc to exit)")
                }
            }
        }
        .navigationTitle("\(meeting.title) · \(meeting.formattedTime)")
        .task(id: meeting.id) {
            interruptionCoordinator?.bind(meeting: meeting)
            try? ObsidianTodoSyncService.refreshTodos(for: meeting, in: modelContext)
            loadPrepMarkdown()

            if meeting.status == .pausedRecording && !recordingService.hasResumableSession(for: meeting.id) {
                recordingActionPhase = .resume
                recordingService.setErrorMessage("This paused recording can no longer be resumed.")
                meeting.status = .notesOnly
                save()
            }
        }
        .onDisappear {
            interruptionCoordinator?.bind(meeting: nil)
        }
        .task(id: autoStartRecording) {
            guard autoStartRecording else { return }
            recordingService.refreshInputDevices(forcePreferredSelection: true)
            await startRecordingIfNeeded()
        }
        .alert("Recording Error", isPresented: recordingErrorBinding) {
            if recordingActionPhase == .start {
                Button("Retry") {
                    recordingService.clearError()
                    didTriggerStart = false
                    Task {
                        await startRecordingIfNeeded()
                    }
                }

                Button("Open Privacy Settings") {
                    openRelevantPrivacySettings()
                }

                Button("Back to Notes", role: .cancel) {
                    meeting.status = .notesOnly
                    save()
                }
            } else {
                Button("OK", role: .cancel) {
                    if !recordingService.hasResumableSession(for: meeting.id) && meeting.status != .pausedRecording {
                        meeting.status = .notesOnly
                        save()
                    }
                }
            }
        } message: {
            Text(recordingService.errorMessage ?? "Unable to start recording.")
        }
    }

    private var presentation: MeetingWorkspacePresentation {
        MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: recordingService.activeMeetingID,
            isRecording: recordingService.isRecording,
            isPreparing: recordingService.isPreparing,
            isFinalizing: isFinalizingRecording,
            prefersRecordingFocusMode: recordingWorkspaceFocusMode
        )
    }

    private var autoPauseIndicatorPresentation: AutoPauseIndicatorPresentation? {
        guard let interruptionCoordinator else { return nil }
        return AutoPauseIndicatorPresentation(
            records: interruptionCoordinator.recentEvents.suffix(5).map { $0 },
            referenceDate: Date()
        )
    }

    private var prepPresentation: MeetingPrepPresentation {
        MeetingPrepPresentation(
            markdown: prepMarkdown,
            isExpanded: isInspectorPresented
        )
    }

    @ViewBuilder
    private var mainContent: some View {
        freeformWorkspace
    }

    private var isRecordingState: Bool {
        meeting.status == .recording && recordingService.isRecording
    }

    // MARK: - Device & language quick-control

    private var deviceLanguageChip: some View {
        DeviceLanguageChip(
            recordingService: recordingService,
            transcriptionLanguage: $meeting.transcriptionLanguage,
            onLanguageChanged: { save() }
        )
    }

    @ViewBuilder
    private var freeformWorkspace: some View {
        if presentation.isFocusModeActive {
            focusNotesCanvas
        } else {
            // Native trailing inspector (AppKit-driven resize, HIG-compliant)
            // hosting Prep & To-Dos as tabs. The notes editor keeps its proven
            // bounded layout as the primary content.
            notesColumn
                .inspector(isPresented: $isInspectorPresented) {
                    NotesEditorInspector(
                        meeting: meeting,
                        prepPresentation: prepPresentation,
                        inspectorTab: $inspectorTab
                    )
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 560)
                }
        }
    }

    // MARK: - Focus mode

    /// Distraction-free writing surface: centers the editor at a comfortable
    /// reading measure with airier, slightly larger text. No prep, no to-dos,
    /// no device chip — just the notes.
    private var focusNotesCanvas: some View {
        // ToastMarkdownEditor wraps a WKWebView, which has no intrinsic height.
        // It must be given a bounded fill frame (it scrolls its own content
        // internally) — wrapping it in a SwiftUI ScrollView collapses it to
        // zero height (blank screen). Mirror the working `notesColumn` framing,
        // just centered at a comfortable reading measure.
        ToastMarkdownEditor(
            text: $meeting.userNotes,
            placeholder: "Type your notes here..."
        )
        .frame(maxWidth: 600, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, CasaSpace.xl)
        .padding(.vertical, CasaSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.backgroundPrimary)
        .onChange(of: meeting.userNotes) {
            debouncedSave()
        }
    }

    private var notesColumn: some View {
        // Pane controls now live in the toolbar (consistent across states), so
        // the notes column is just the editor — its proven layout is untouched.
        freeformNotesEditor
    }

    private var freeformNotesEditor: some View {
        ToastMarkdownEditor(
            text: $meeting.userNotes,
            placeholder: "Type your notes here..."
        )
        .padding(CasaSpace.lg)
        .onChange(of: meeting.userNotes) {
            debouncedSave()
        }
    }

    private var footer: some View {
        HStack {
            if recordingService.isPreparing && presentation.showsExpandedRecordingChrome {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if presentation.showsStartRecordingButton {
                deviceLanguageChip

                Button(action: requestRecordingStart) {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            Button {
                recordingWorkspaceFocusMode = true
            } label: {
                Label("Focus", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Distraction-free notes (Esc to exit)")

            Button {
                exportNotes()
            } label: {
                Label("Save & Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(CasaSpace.lg)
        .background(.bar)
    }

    private func requestRecordingStart() {
        guard meeting.status != .recording else { return }
        meeting.status = .recording
        save()
        recordingService.refreshInputDevices(forcePreferredSelection: true)
        Task {
            await startRecordingIfNeeded()
        }
    }

    private func pauseRecording() async {
        recordingActionPhase = .pause
        do {
            let result = try await recordingService.pauseRecording()
            meeting.recordingDuration = (meeting.recordingDuration ?? 0) + result.duration
            meeting.status = .pausedRecording
            interruptionCoordinator?.notifyMeetingTransitioned(to: .pausedRecording)
            save()
        } catch {
            recordingService.setErrorMessage(error.localizedDescription)
            save()
        }
    }

    private func resumeRecording() async {
        recordingActionPhase = .resume
        do {
            try await recordingService.resumeRecording(for: meeting)
            meeting.status = .recording
            interruptionCoordinator?.notifyMeetingTransitioned(to: .recording)
            save()
        } catch {
            meeting.status = .pausedRecording
            save()
        }
    }

    private var formattedElapsed: String {
        let totalSeconds = max(Int(recordingService.elapsedTime.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var recordingErrorBinding: Binding<Bool> {
        Binding(
            get: { recordingService.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    recordingService.clearError()
                }
            }
        )
    }

    private func startRecordingIfNeeded() async {
        guard !didTriggerStart else { return }

        if recordingService.isRecording && recordingService.activeMeetingID == meeting.id {
            return
        }

        recordingActionPhase = .start
        didTriggerStart = true

        do {
            try await recordingService.startRecording(for: meeting)
            meeting.status = .recording
            save()
        } catch {
            didTriggerStart = false
            meeting.status = .notesOnly
            save()
        }
    }

    private func stopRecording() async {
        guard !isFinalizingRecording else { return }

        recordingActionPhase = .stop
        isFinalizingRecording = true

        do {
            let result = try await recordingService.stopRecording(for: meeting)
            meeting.recordingFileURL = result.outputURL.path
            meeting.recordingDuration = result.duration
            meeting.status = .processing
            interruptionCoordinator?.notifyMeetingTransitioned(to: .processing)
            save()
        } catch {
            isFinalizingRecording = false
            recordingService.setErrorMessage(error.localizedDescription)
            meeting.status = recordingService.hasResumableSession(for: meeting.id) ? .pausedRecording : .notesOnly
            save()
        }
    }

    private func loadPrepMarkdown() {
        prepMarkdown = MeetingPrepService.loadPrepMarkdown(for: meeting)
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        try? modelContext.save()
        Task { @MainActor in
            await ExportService.exportAutomaticallyIfEnabled(meeting)
        }
    }

    private func exportNotes() {
        save()

        Task { @MainActor in
            do {
                let result = try await ExportService.exportRawNotes(meeting)
                switch result {
                case .obsidian(let export):
                    presentExportAlert(
                        title: "Export Complete",
                        message: "Saved raw notes to your Obsidian meeting notes folder.",
                        exportedURLs: export.exportedURLs
                    )
                case .appleNotes:
                    presentExportAlert(
                        title: "Export Complete",
                        message: "Saved to Apple Notes folder \"Casablanca\".",
                        exportedURLs: []
                    )
                }
            } catch {
                presentExportAlert(
                    title: "Export Failed",
                    message: error.localizedDescription,
                    exportedURLs: []
                )
            }
        }
    }

    private func presentExportAlert(title: String, message: String, exportedURLs: [URL]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message

        if exportedURLs.isEmpty {
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(exportedURLs)
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openRelevantPrivacySettings() {
        let message = recordingService.errorMessage ?? ""
        let anchor = message.localizedCaseInsensitiveContains("microphone")
            ? "Privacy_Microphone"
            : "Privacy_ScreenCapture"
        openPrivacySettings(anchor: anchor)
    }
}
