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

    var isPausedRecording: Bool {
        meeting.status == .pausedRecording
    }

    var showsRecordingChrome: Bool {
        meeting.status == .recording || meeting.status == .pausedRecording
    }

    var showsFocusedRecordingControls: Bool {
        showsRecordingChrome && prefersRecordingFocusMode
    }

    var showsExpandedRecordingChrome: Bool {
        showsRecordingChrome && !showsFocusedRecordingControls
    }

    var showsCompactRecordingControls: Bool {
        showsFocusedRecordingControls
    }

    var showsTimestampedTools: Bool {
        meeting.status == .recording && isActiveMeeting && isRecording
    }

    var showsStartRecordingButton: Bool {
        meeting.status == .notesOnly
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

enum MeetingNotesMode {
    case timestamped
    case freeform

    static let defaultForWorkspaceEntry: Self = .freeform
}

struct NotesEditorView: View {
    private enum RecordingActionPhase { case start, stop }

    @Bindable var meeting: Meeting
    @Bindable var recordingService: AudioRecordingService
    let autoStartRecording: Bool
    let onBack: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppPreferenceKey.recordingWorkspaceFocusMode) private var recordingWorkspaceFocusMode = false
    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerStart = false
    @State private var noteText = ""
    @State private var notesMode: MeetingNotesMode = .defaultForWorkspaceEntry
    @State private var newTodoText = ""
    @State private var prepMarkdown: String?
    @State private var isPrepExpanded = false
    @State private var showingAudioSettings = false
    @State private var isFinalizingRecording = false
    @State private var recordingActionPhase: RecordingActionPhase = .start
    @FocusState private var isNoteFieldFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if presentation.showsExpandedRecordingChrome {
                    header
                    Divider()
                }

                mainContent

                Divider()
                footer
            }
            .blur(radius: presentation.showsBlockingOverlay ? 1.5 : 0)

            if presentation.showsBlockingOverlay {
                finalizingOverlay
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
            try? ObsidianTodoSyncService.refreshTodos(for: meeting, in: modelContext)
            loadPrepMarkdown()
        }
        .task(id: autoStartRecording) {
            guard autoStartRecording else { return }
            notesMode = .defaultForWorkspaceEntry
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
                    meeting.status = .notesOnly
                    save()
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
        switch notesMode {
        case .timestamped where presentation.showsTimestampedTools:
            timestampedNotesArea
        default:
            freeformWorkspace
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CasaSpace.lg) {
            HStack(alignment: .center) {
                HStack(spacing: CasaSpace.sm) {
                    Circle()
                        .fill(recordingService.isRecording ? Color.stateRecording : Color.stateIdle)
                        .frame(width: 10, height: 10)
                        .scaleEffect(recordingService.isRecording ? 1 : 0.85)
                        .animation(
                            recordingService.isRecording && !reduceMotion
                                ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                                : .default,
                            value: recordingService.isRecording
                        )
                        .accessibilityLabel(recordingService.isRecording ? "Recording in progress" : "Not recording")

                    Text(presentation.stateLabel)
                        .font(.headline)
                        .foregroundStyle(Color.textPrimary)
                }

                Spacer()

                Text(formattedElapsed)
                    .font(.system(.title3, design: .default, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityLabel("Elapsed time: \(formattedElapsed)")

                Button("Focus on Notes") {
                    recordingWorkspaceFocusMode = true
                }
                .buttonStyle(.plain)
            }

            HStack {
                AudioLevelMeterView(level: recordingService.audioLevel)

                Spacer()

                if presentation.showsTimestampedTools {
                    Picker("Notes Mode", selection: $notesMode) {
                        Text("Timestamped").tag(MeetingNotesMode.timestamped)
                        Text("Freeform").tag(MeetingNotesMode.freeform)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }

            DisclosureGroup("Audio Settings", isExpanded: $showingAudioSettings) {
                VStack(alignment: .leading, spacing: CasaSpace.md) {
                    if recordingService.availableInputDevices.isEmpty {
                        Text("No microphone found")
                            .font(.body)
                            .foregroundStyle(Color.textTertiary)
                    } else {
                        Picker("Microphone", selection: selectedMicrophoneBinding) {
                            ForEach(recordingService.availableInputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .disabled(recordingService.isPreparing)
                    }

                    Toggle(isOn: Binding(
                        get: { recordingService.isSystemAudioEnabled },
                        set: { newValue in
                            if newValue != recordingService.isSystemAudioEnabled {
                                recordingService.toggleSystemAudioEnabled()
                            }
                        }
                    )) {
                        Label("Capture system audio", systemImage: "speaker.wave.2.fill")
                    }
                    .disabled(recordingService.isPreparing)
                }
                .padding(.top, CasaSpace.sm)
            }
            .tint(Color.textPrimary)
        }
        .padding(.horizontal, CasaSpace.xl)
        .padding(.top, CasaSpace.xl)
        .padding(.bottom, CasaSpace.xxl)
    }

    private var timestampedNotesArea: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if meeting.timestampedNotes.isEmpty {
                        ContentUnavailableView {
                            Label("No Timestamped Notes Yet", systemImage: "clock")
                        } description: {
                            Text("Type a note below or switch to freeform notes.")
                        } actions: {
                            Button("Use Freeform Notes") {
                                notesMode = .freeform
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        LazyVStack(alignment: .leading, spacing: CasaSpace.xs) {
                            ForEach(meeting.timestampedNotes) { note in
                                timestampedNoteRow(note)
                                    .id(note.id)
                            }
                        }
                        .padding(CasaSpace.lg)
                    }
                }
                .onChange(of: meeting.timestampedNotes.count) {
                    if let last = meeting.timestampedNotes.last {
                        withAnimation(CasaAnimation.standard) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
            noteInputBar
        }
    }

    private func timestampedNoteRow(_ note: TimestampedNote) -> some View {
        HStack(alignment: .top, spacing: CasaSpace.sm) {
            Text(note.formattedTimestamp)
                .font(.caption.monospaced())
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, CasaSpace.xs)
                .padding(.vertical, CasaSpace.xxs)
                .background(Color.backgroundHover)
                .clipShape(RoundedRectangle(cornerRadius: CasaRadius.sm))
                .frame(minWidth: 52, alignment: .center)

            Text(note.text)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.vertical, CasaSpace.xs)
    }

    private var noteInputBar: some View {
        HStack(spacing: CasaSpace.sm) {
            if recordingService.isRecording {
                Text(formattedElapsed)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.textSecondary)
                    .frame(minWidth: 52)
            }

            TextField("Add a note...", text: $noteText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isNoteFieldFocused)
                .onSubmit {
                    addTimestampedNote()
                }

            Button {
                addTimestampedNote()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(noteText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? Color.textTertiary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.md)
        .background(.bar)
    }

    @ViewBuilder
    private var freeformWorkspace: some View {
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
            HStack(spacing: 0) {
                prepPane
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)

                Divider()
                notesColumn
            }
        } else {
            notesColumn
        }
    }

    private var notesColumn: some View {
        VStack(spacing: 0) {
            if prepPresentation.showsShowPrepButton {
                notesHeader
                Divider()
            }

            freeformNotesEditor

            if showsTimestampedHistorySection {
                Divider()

                TimestampedNotesHistorySection(notes: meeting.timestampedNotes)
                    .padding(CasaSpace.lg)
            }
        }
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

    private var notesHeader: some View {
        HStack {
            Spacer()

            Button {
                isPrepExpanded = true
            } label: {
                Label("Show Prep", systemImage: "sidebar.left")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.md)
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

            if presentation.showsCompactRecordingControls {
                compactRecordingControls
            }

            if !meeting.timestampedNotes.isEmpty {
                Text("\(meeting.timestampedNotes.count) timestamped notes")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Spacer()

            if presentation.showsStartRecordingButton {
                Button(action: requestRecordingStart) {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    Task {
                        await stopRecording()
                    }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!recordingService.isRecording || recordingService.activeMeetingID != meeting.id)
            }

            Button {
                exportNotes()
            } label: {
                Label("Save & Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && meeting.timestampedNotes.isEmpty)
        }
        .padding(CasaSpace.lg)
        .background(.bar)
    }

    private var compactRecordingControls: some View {
        HStack(spacing: CasaSpace.md) {
            HStack(spacing: CasaSpace.xs) {
                Circle()
                    .fill(recordingService.isRecording ? Color.stateRecording : Color.stateIdle)
                    .frame(width: 8, height: 8)

                Text(presentation.stateLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
            }

            Text(formattedElapsed)
                .font(.caption.monospaced())
                .foregroundStyle(Color.textSecondary)

            Button("Show Recording Controls") {
                recordingWorkspaceFocusMode = false
            }
            .buttonStyle(.plain)
        }
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

    private func addTimestampedNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let note = TimestampedNote(
            timestamp: recordingService.elapsedTime,
            text: trimmed
        )
        meeting.timestampedNotes.append(note)
        noteText = ""
        save()
        isNoteFieldFocused = true
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
        notesMode = .defaultForWorkspaceEntry
        meeting.status = .recording
        save()
        recordingService.refreshInputDevices(forcePreferredSelection: true)
        Task {
            await startRecordingIfNeeded()
        }
    }

    private var selectedMicrophoneBinding: Binding<String> {
        Binding(
            get: { recordingService.selectedInputDeviceID },
            set: { newValue in
                Task {
                    await recordingService.selectInputDevice(newValue)
                }
            }
        )
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
            let result = try await recordingService.stopRecording()
            meeting.recordingFileURL = result.outputURL.path
            meeting.recordingDuration = result.duration
            meeting.status = .processing
            save()
        } catch {
            isFinalizingRecording = false
            meeting.status = .notesOnly
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
        ExportService.exportAutomaticallyIfEnabled(meeting)
    }

    private func exportNotes() {
        save()

        do {
            let result = try ExportService.exportRawNotes(meeting)
            presentExportAlert(
                title: "Export Complete",
                message: "Saved raw notes to your Obsidian meeting notes folder.",
                exportedURLs: result.exportedURLs
            )
        } catch {
            presentExportAlert(
                title: "Export Failed",
                message: error.localizedDescription,
                exportedURLs: []
            )
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

    private var showsTimestampedHistorySection: Bool {
        !presentation.showsTimestampedTools && !meeting.timestampedNotes.isEmpty
    }
}
