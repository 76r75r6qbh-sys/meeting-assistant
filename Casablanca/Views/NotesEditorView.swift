import AppKit
import SwiftData
import SwiftUI

struct MeetingWorkspacePresentation {
    let meeting: Meeting
    let activeMeetingID: UUID?
    let isRecording: Bool
    let isPreparing: Bool
    let isFinalizing: Bool
    let prefersRecordingFocusMode: Bool

    var isActiveMeeting: Bool {
        activeMeetingID == meeting.id
    }

    var showsRecordingChrome: Bool {
        meeting.status == .recording || meeting.status == .pausedRecording
    }

    var showsFocusedRecordingControls: Bool {
        showsRecordingChrome && prefersRecordingFocusMode
    }

    /// Focus mode is a pure view state: it can be active whether or not a
    /// recording is in progress. It hides chrome (prep, to-dos, the device
    /// chip, the recording bar) and centers the notes for distraction-free
    /// writing. Recording + autosave keep running underneath.
    var isFocusModeActive: Bool {
        prefersRecordingFocusMode && !isFinalizing
    }

    /// In focus mode, while recording, the live state collapses to a single
    /// unobtrusive pill (pulsing dot + timer) that still exposes pause/stop.
    var showsFocusRecordingPill: Bool {
        isFocusModeActive && showsRecordingChrome
    }

    var showsExpandedRecordingChrome: Bool {
        showsRecordingChrome && !showsFocusedRecordingControls
    }

    /// The in-content meeting header (title + meta + avatars + Show Prep) is
    /// shown in the calm notes-taking state only: not while recording (the
    /// recording bar serves that role) and not in focus mode (distraction-free).
    var showsNotesHeader: Bool {
        !showsRecordingChrome && !isFocusModeActive && !isFinalizing
    }

    var showsCompactRecordingControls: Bool {
        showsFocusedRecordingControls
    }

    var showsStartRecordingButton: Bool {
        meeting.status == .notesOnly || meeting.status == .upcoming
    }

    var showsPauseRecordingButton: Bool {
        meeting.status == .recording && isActiveMeeting && isRecording && !isFinalizing
    }

    var showsResumeRecordingButton: Bool {
        meeting.status == .pausedRecording && !isFinalizing
    }

    var showsStopRecordingButton: Bool {
        showsRecordingChrome && !isFinalizing
    }

    var backButtonDisabled: Bool {
        isFinalizing || (meeting.status == .recording && isActiveMeeting && isRecording)
    }

    var showsBlockingOverlay: Bool {
        isFinalizing
    }

    var blockingOverlayTitle: String? {
        guard isFinalizing else { return nil }
        return "Recording finaliseren..."
    }

    var stateLabel: String {
        if isFinalizing { return "Finalizing" }
        if isPreparing { return "Preparing" }
        if meeting.status == .pausedRecording { return "Paused" }
        return "Recording"
    }
}

struct MeetingPrepPresentation: Equatable {
    let markdown: String?
    let isExpanded: Bool

    var hasPrep: Bool {
        !(markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var showsPrepPane: Bool {
        hasPrep && isExpanded
    }

    var showsShowPrepButton: Bool {
        hasPrep && !isExpanded
    }

    var markdownText: String {
        markdown ?? ""
    }
}

struct FreeformWorkspacePresentation: Equatable {
    let showsRecordingChrome: Bool

    var showsTodosArea: Bool {
        true
    }
}

struct AutoPauseIndicatorPresentation {
    let records: [RecordingInterruptionCoordinator.InterruptionRecord]
    let referenceDate: Date

    private static let visibilityWindow: TimeInterval = 300

    var shouldShow: Bool {
        guard let latest = records.last, let endedAt = latest.endedAt else { return false }
        return referenceDate.timeIntervalSince(endedAt) < Self.visibilityWindow
    }

    var summary: String {
        guard let latest = records.last, let endedAt = latest.endedAt else { return "" }
        let duration = Int(endedAt.timeIntervalSince(latest.startedAt).rounded())
        let timeOfDay = formattedTime(latest.startedAt)
        let suffix = latest.resumedAutomatically ? "recording resumed." : "tap Resume to continue."
        let cause: String
        switch latest.reason {
        case .screenLock: cause = "Auto-paused at \(timeOfDay) for \(duration)s"
        case .systemSleep: cause = "Auto-paused at \(timeOfDay) (sleep, \(duration)s)"
        case .audioDeviceLost: cause = "Auto-paused at \(timeOfDay) — microphone disconnected"
        case .streamFailure: cause = "Auto-paused at \(timeOfDay) — recording stream stopped"
        }
        return "\(cause) — \(suffix)"
    }

    func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct NotesEditorView: View {
    private enum RecordingActionPhase { case start, pause, resume, stop }

    @Bindable var meeting: Meeting
    @Bindable var recordingService: AudioRecordingService
    var interruptionCoordinator: RecordingInterruptionCoordinator? = nil
    let autoStartRecording: Bool
    let onBack: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppPreferenceKey.recordingWorkspaceFocusMode) private var recordingWorkspaceFocusMode = false
    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerStart = false
    @State private var newTodoText = ""
    @AppStorage(AppPreferenceKey.prepInspectorWidth) private var prepInspectorWidth = Double(CasaLayout.prepInspectorDefault)
    @State private var prepMarkdown: String?
    @State private var isPrepExpanded = false
    @State private var showingQuickControl = false
    @State private var isFinalizingRecording = false
    @State private var recordingActionPhase: RecordingActionPhase = .start
    @State private var pulseOpacity: Double = 1

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if presentation.showsExpandedRecordingChrome && !presentation.isFocusModeActive {
                    recordingBar
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
                focusRecordingPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(CasaSpace.lg)
                    .transition(.opacity)
            }

            if presentation.isFocusModeActive {
                focusExitButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(CasaSpace.lg)
                    .transition(.opacity)
            }

            if presentation.showsBlockingOverlay {
                finalizingOverlay
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
            isExpanded: isPrepExpanded
        )
    }

    private var freeformPresentation: FreeformWorkspacePresentation {
        FreeformWorkspacePresentation(
            showsRecordingChrome: presentation.showsRecordingChrome
        )
    }

    @ViewBuilder
    private var mainContent: some View {
        freeformWorkspace
    }

    // MARK: - Calm recording bar

    private var isRecordingState: Bool {
        meeting.status == .recording && recordingService.isRecording
    }

    private var recordingBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let presentation = autoPauseIndicatorPresentation, presentation.shouldShow {
                Text(presentation.summary)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CasaSpace.xl)
                    .padding(.top, CasaSpace.sm)
            }

            HStack(spacing: CasaSpace.lg) {
                recordingStatusDot

                Text(presentation.stateLabel)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(isRecordingState ? Color.stateRecording : Color.textPrimary)

                Text(formattedElapsed)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityLabel("Elapsed time: \(formattedElapsed)")

                AudioLevelMeterView(level: recordingService.audioLevel)

                deviceLanguageChip

                Spacer(minLength: CasaSpace.md)

                recordingControls
            }
            .padding(.horizontal, CasaSpace.xl)
            .padding(.vertical, CasaSpace.md)
        }
        .background(Color.stateRecording.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.stateRecording.opacity(0.22))
                .frame(height: 1)
        }
    }

    private var recordingStatusDot: some View {
        Circle()
            .fill(Color.stateRecording)
            .frame(width: 10, height: 10)
            .opacity(pulseOpacity)
            .onAppear { startPulseIfNeeded() }
            .onChange(of: isRecordingState) { startPulseIfNeeded() }
            .onChange(of: reduceMotion) { startPulseIfNeeded() }
            .accessibilityLabel(isRecordingState ? "Recording in progress" : "Recording paused")
    }

    private func startPulseIfNeeded() {
        if isRecordingState && !reduceMotion {
            pulseOpacity = 1
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.45
            }
        } else {
            withAnimation(.default) {
                pulseOpacity = 1
            }
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        if presentation.showsPauseRecordingButton {
            Button {
                Task { await pauseRecording() }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut("p", modifiers: .command)
            .disabled(recordingService.isPreparing)
        }

        if presentation.showsResumeRecordingButton {
            Button {
                Task { await resumeRecording() }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut("p", modifiers: .command)
            .disabled(recordingService.isPreparing)
        }

        if presentation.showsStopRecordingButton {
            Button {
                Task { await stopRecording() }
            } label: {
                Label("Stop & Process", systemImage: "stop.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(recordingService.isPreparing || isFinalizingRecording)
        }
    }

    // MARK: - Device & language quick-control

    private var selectedDeviceName: String {
        recordingService.availableInputDevices
            .first(where: { $0.id == recordingService.selectedInputDeviceID })?
            .name ?? "No microphone"
    }

    private var selectedLanguageShortLabel: String {
        let id = meeting.transcriptionLanguage
        switch id {
        case "en-US": return "EN-US"
        case "en-GB": return "EN-GB"
        case "nl-NL": return "NL"
        default:
            // Fall back to the language subtag of a BCP-47 id, uppercased.
            let primary = id.split(separator: "-").first.map(String.init) ?? id
            return primary.uppercased()
        }
    }

    private var deviceLanguageChip: some View {
        Button {
            showingQuickControl.toggle()
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                Text("\(selectedDeviceName) · \(selectedLanguageShortLabel)")
                    .font(.caption)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, CasaSpace.md)
            .padding(.vertical, CasaSpace.xs)
            .background(Color.backgroundActive, in: RoundedRectangle(cornerRadius: CasaRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: CasaRadius.lg)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording device and language")
        .accessibilityValue("\(selectedDeviceName), \(selectedLanguageShortLabel)")
        .popover(isPresented: $showingQuickControl, arrowEdge: .bottom) {
            deviceLanguagePopover
        }
    }

    private var deviceLanguagePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Input device")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, CasaSpace.sm)
                .padding(.bottom, CasaSpace.xs)

            if recordingService.availableInputDevices.isEmpty {
                Text("No microphone found")
                    .font(.body)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.horizontal, CasaSpace.sm)
                    .padding(.vertical, CasaSpace.xs)
            } else {
                ForEach(recordingService.availableInputDevices) { device in
                    deviceRow(device)
                }
            }

            Toggle(isOn: Binding(
                get: { recordingService.isSystemAudioEnabled },
                set: { newValue in
                    if newValue != recordingService.isSystemAudioEnabled {
                        recordingService.toggleSystemAudioEnabled()
                    }
                }
            )) {
                Label("Also capture system audio", systemImage: "speaker.wave.2.fill")
                    .font(.body)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(recordingService.isPreparing)
            .padding(.horizontal, CasaSpace.sm)
            .padding(.top, CasaSpace.xs)

            Divider()
                .padding(.vertical, CasaSpace.md)

            Text("Transcription language")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, CasaSpace.sm)
                .padding(.bottom, CasaSpace.xs)

            ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
                languageRow(id: language.id, name: language.name)
            }

            Divider()
                .padding(.vertical, CasaSpace.md)

            SettingsLink {
                Label("Recording defaults in Settings…", systemImage: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, CasaSpace.sm)
        }
        .padding(CasaSpace.md)
        .frame(width: 288)
    }

    @ViewBuilder
    private func deviceRow(_ device: AudioInputDevice) -> some View {
        let isSelected = device.id == recordingService.selectedInputDeviceID

        Button {
            guard !isSelected else { return }
            Task { await recordingService.selectInputDevice(device.id) }
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.textSecondary)
                    .frame(width: 16)

                Text(device.name)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: CasaSpace.sm)

                if isSelected {
                    AudioLevelMeterView(level: recordingService.audioLevel)
                        .frame(height: 14)
                }
            }
            .padding(.horizontal, CasaSpace.sm)
            .padding(.vertical, CasaSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: CasaRadius.md)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recordingService.isPreparing)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func languageRow(id: String, name: String) -> some View {
        let isSelected = id == meeting.transcriptionLanguage

        Button {
            guard !isSelected else { return }
            meeting.transcriptionLanguage = id
            save()
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: CasaSpace.sm)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, CasaSpace.sm)
            .padding(.vertical, CasaSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: CasaRadius.md)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var freeformWorkspace: some View {
        if presentation.isFocusModeActive {
            focusNotesCanvas
        } else {
            // The meeting header sits once at the top of the workspace, above
            // whichever sub-layout renders (prep pane, to-dos, or plain notes),
            // gated to the calm notes-taking state via `showsNotesHeader`.
            VStack(spacing: 0) {
                if presentation.showsNotesHeader {
                    meetingHeader
                    Divider()
                }

                notesWorkspaceBody
            }
        }
    }

    @ViewBuilder
    private var notesWorkspaceBody: some View {
        if freeformPresentation.showsTodosArea {
            HStack(spacing: 0) {
                prepAwareNotesWorkspace
                Divider()
                todosArea
                    .frame(width: 260)
            }
        } else {
            prepAwareNotesWorkspace
        }
    }

    @ViewBuilder
    private var prepAwareNotesWorkspace: some View {
        if prepPresentation.showsPrepPane {
            GeometryReader { proxy in
                let maxWidth = max(
                    Double(CasaLayout.prepInspectorMin),
                    Double(proxy.size.width) * Double(CasaLayout.prepInspectorMaxFraction)
                )
                let clampedWidth = min(max(prepInspectorWidth, Double(CasaLayout.prepInspectorMin)), maxWidth)

                HStack(spacing: 0) {
                    prepPane
                        .frame(width: CGFloat(clampedWidth))

                    // Divider drags to its RIGHT: moving right widens the
                    // left-side prep pane, so the delta is added directly.
                    ResizableInspectorDivider(
                        width: $prepInspectorWidth,
                        minWidth: Double(CasaLayout.prepInspectorMin),
                        maxWidth: maxWidth,
                        deltaSign: 1
                    )

                    notesColumn
                }
                .onAppear {
                    // Keep a stored width that exceeds the current cap honest.
                    prepInspectorWidth = clampedWidth
                }
            }
        } else {
            notesColumn
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

    private var focusRecordingPill: some View {
        HStack(spacing: CasaSpace.sm) {
            Circle()
                .fill(Color.stateRecording)
                .frame(width: 8, height: 8)
                .opacity(pulseOpacity)
                .onAppear { startPulseIfNeeded() }
                .onChange(of: isRecordingState) { startPulseIfNeeded() }
                .onChange(of: reduceMotion) { startPulseIfNeeded() }
                .accessibilityLabel(isRecordingState ? "Recording in progress" : "Recording paused")

            Text(formattedElapsed)
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isRecordingState ? Color.stateRecording : Color.textPrimary)
                .accessibilityLabel("Elapsed time: \(formattedElapsed)")

            if presentation.showsPauseRecordingButton {
                pillIconButton("pause.fill", label: "Pause") {
                    Task { await pauseRecording() }
                }
                .disabled(recordingService.isPreparing)
                .keyboardShortcut("p", modifiers: .command)
            }

            if presentation.showsResumeRecordingButton {
                pillIconButton("play.fill", label: "Resume") {
                    Task { await resumeRecording() }
                }
                .disabled(recordingService.isPreparing)
                .keyboardShortcut("p", modifiers: .command)
            }

            if presentation.showsStopRecordingButton {
                pillIconButton("stop.fill", label: "Stop & Process") {
                    Task { await stopRecording() }
                }
                .disabled(recordingService.isPreparing || isFinalizingRecording)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.leading, CasaSpace.md)
        .padding(.trailing, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xs)
        .background(Color.stateRecording.opacity(0.14), in: Capsule())
        .overlay(
            Capsule().stroke(Color.stateRecording.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording status")
    }

    private func pillIconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Color.backgroundActive, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textPrimary)
        .help(label)
        .accessibilityLabel(label)
    }

    private var focusExitButton: some View {
        Button {
            recordingWorkspaceFocusMode = false
        } label: {
            Label("Exit Focus", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.callout)
        }
        .buttonStyle(SecondaryButtonStyle())
        .keyboardShortcut(.escape, modifiers: [])
        .help("Exit Focus (Esc)")
    }

    private var notesColumn: some View {
        freeformNotesEditor
    }

    private var prepPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: CasaSpace.sm) {
                Text("Preparation")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                Button {
                    isPrepExpanded = false
                } label: {
                    Label("Hide Prep", systemImage: "sidebar.left")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, CasaSpace.lg)
            .padding(.vertical, CasaSpace.md)

            Divider()

            ToastMarkdownViewer(markdown: prepPresentation.markdownText)
                .padding(CasaSpace.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// In-content meeting header for the calm notes-taking state, mirroring the
    /// prep/detail headers: a meeting title with a meta line (date · time ·
    /// participant count) and overlapping participant avatars. The existing
    /// "Show Prep" affordance is folded in on the trailing side so prep stays
    /// reachable without a second header row.
    private var meetingHeader: some View {
        HStack(alignment: .top, spacing: CasaSpace.md) {
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(meeting.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text(meetingHeaderMetaLine)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer(minLength: CasaSpace.md)

            ParticipantAvatars(names: meeting.participants)

            if prepPresentation.showsShowPrepButton {
                Button {
                    isPrepExpanded = true
                } label: {
                    Label("Show Prep", systemImage: "sidebar.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, CasaSpace.xl)
        .padding(.vertical, CasaSpace.lg)
    }

    private var meetingHeaderMetaLine: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM"
        let day = dateFormatter.string(from: meeting.date)
        let count = meeting.participants.count
        guard count > 0 else {
            return "\(day) · \(meeting.formattedTime)"
        }
        let participantLabel = count == 1 ? "1 participant" : "\(count) participants"
        return "\(day) · \(meeting.formattedTime) · \(participantLabel)"
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

    @ViewBuilder
    private var todosArea: some View {
        VStack(spacing: 0) {
            ScrollView {
                if meeting.todos.isEmpty {
                    Text("No to-dos yet. Add one below.")
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
                } else {
                    LazyVStack(alignment: .leading, spacing: CasaSpace.xs) {
                        ForEach(meeting.todos) { todo in
                            HStack(spacing: CasaSpace.sm) {
                                Button {
                                    try? ObsidianTodoSyncService.setCompleted(
                                        !todo.isCompleted,
                                        for: todo,
                                        in: modelContext
                                    )
                                } label: {
                                    Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.body)
                                        .foregroundStyle(todo.isCompleted ? Color.accentColor : Color.textTertiary)
                                }
                                .buttonStyle(.plain)

                                Text(todo.text)
                                    .font(.body)
                                    .foregroundStyle(todo.isCompleted ? Color.textTertiary : Color.textPrimary)
                                    .strikethrough(todo.isCompleted, color: Color.textTertiary)
                                    .textSelection(.enabled)

                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, CasaSpace.xs)
                        }
                    }
                    .padding(CasaSpace.lg)
                }
            }

            Divider()

            HStack(spacing: CasaSpace.sm) {
                TextField("Add a to-do...", text: $newTodoText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit {
                        addTodo()
                    }

                Button {
                    addTodo()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(newTodoText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Color.textTertiary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newTodoText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, CasaSpace.lg)
            .padding(.vertical, CasaSpace.md)
            .background(.bar)
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

    private var finalizingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: CasaSpace.md) {
                ProgressView()
                    .controlSize(.regular)

                Text(presentation.blockingOverlayTitle ?? "Recording finaliseren...")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                Text("Even geduld, Casablanca maakt de opname klaar voor transcriptie.")
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(CasaSpace.xxl)
            .frame(width: 360)
            .background(Color.backgroundPrimary.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.lg))
            .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        }
        .transition(.opacity)
    }

    private func addTodo() {
        let trimmed = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try? ObsidianTodoSyncService.createMeetingTodo(
            text: trimmed,
            meeting: meeting,
            in: modelContext
        )
        newTodoText = ""
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
        let markdown = MeetingPrepService.loadPrepMarkdown(for: meeting)
        prepMarkdown = markdown
        isPrepExpanded = markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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

/// A thin, draggable vertical divider used to resize an adjacent inspector
/// pane. On hover it shows an accent grip and switches the cursor to the
/// horizontal resize arrow; dragging updates `width`, clamped to
/// `[minWidth, maxWidth]`.
///
/// `deltaSign` accounts for which side the resized pane sits on relative to
/// the divider: use `+1` when the pane is to the LEFT of the divider (drag
/// right → wider), and `-1` when the pane is to the RIGHT (drag left → wider).
struct ResizableInspectorDivider: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double
    var deltaSign: Double = 1

    @State private var isHovering = false
    @State private var dragStartWidth: Double?

    var body: some View {
        ZStack {
            // Hairline that becomes a visible accent line on hover/drag.
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.borderSubtle)
                .frame(width: isActive ? 2 : 1)

            if isActive {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 42)
            }
        }
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStartWidth ?? width
                    if dragStartWidth == nil { dragStartWidth = start }
                    let proposed = start + deltaSign * Double(value.translation.width)
                    width = min(max(proposed, minWidth), maxWidth)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Resize prep panel")
        .accessibilityValue("\(Int(width)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                width = min(width + 20, maxWidth)
            case .decrement:
                width = max(width - 20, minWidth)
            @unknown default:
                break
            }
        }
    }

    private var isActive: Bool {
        isHovering || dragStartWidth != nil
    }
}
