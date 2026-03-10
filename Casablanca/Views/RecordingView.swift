import AppKit
import SwiftData
import SwiftUI

struct RecordingView: View {
    @Bindable var meeting: Meeting
    @Bindable var recordingService: AudioRecordingService
    let onBack: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var saveTask: Task<Void, Never>?
    @State private var didTriggerStart = false
    @State private var noteText = ""
    @State private var showFreeformNotes = false
    @State private var editorCoordinator: MarkdownTextEditorCoordinator?
    @FocusState private var isNoteFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // Main content area
            if showFreeformNotes {
                freeformNotesEditor
            } else {
                timestampedNotesArea
            }

            Divider()
            footer
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(recordingService.isRecording && recordingService.activeMeetingID == meeting.id)
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: CasaSpace.sm) {
                    Circle()
                        .fill(recordingService.isRecording ? Color.stateRecording : Color.stateIdle)
                        .frame(width: 8, height: 8)
                    Text(formattedElapsed)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(recordingService.isRecording ? Color.stateRecording : Color.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(recordingService.isRecording ? "Recording, elapsed time \(formattedElapsed)" : "Not recording")
            }
        }
        .navigationTitle("\(meeting.title) · Recording")
        .task {
            recordingService.refreshInputDevices(forcePreferredSelection: true)
            await startIfNeeded()
        }
        .alert("Recording Error", isPresented: recordingErrorBinding) {
            Button("Retry") {
                recordingService.clearError()
                didTriggerStart = false
                Task {
                    await startIfNeeded()
                }
            }

            Button("Open Privacy Settings") {
                openRelevantPrivacySettings()
            }

            Button("Back to Notes", role: .cancel) {
                meeting.status = .notesOnly
                save()
            }
        } message: {
            Text(recordingService.errorMessage ?? "Unable to start recording.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
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

                    Text(statusTitle)
                        .font(.headline)
                        .foregroundStyle(Color.textPrimary)
                }

                Spacer()

                Text(formattedElapsed)
                    .font(.system(.title3, design: .default, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(recordingService.isRecording ? Color.stateRecording : Color.textSecondary)
                    .accessibilityLabel("Elapsed time: \(formattedElapsed)")
            }

            HStack(spacing: CasaSpace.sm) {
                Text("Transcription Language")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                Picker("Transcription Language", selection: $meeting.transcriptionLanguage) {
                    ForEach(TranscriptionService.supportedLanguages, id: \.id) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: meeting.transcriptionLanguage) {
                    save()
                }
            }

            HStack(spacing: CasaSpace.md) {
                HStack(spacing: CasaSpace.sm) {
                    Text("Microphone")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    if recordingService.availableInputDevices.isEmpty {
                        Text("No microphone found")
                            .font(.callout)
                            .foregroundStyle(Color.textTertiary)
                    } else {
                        Picker("Microphone", selection: selectedMicrophoneBinding) {
                            ForEach(recordingService.availableInputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .disabled(recordingService.isPreparing)
                    }
                }

                Button {
                    recordingService.toggleSystemAudioEnabled()
                } label: {
                    Label(
                        recordingService.isSystemAudioEnabled ? "System Audio On" : "System Audio Off",
                        systemImage: recordingService.isSystemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
                    )
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(recordingService.isPreparing)
            }

            Text(statusMessage)
                .font(.body)
                .foregroundStyle(Color.textSecondary)

            HStack {
                AudioLevelMeterView(level: recordingService.audioLevel)

                Spacer()

                // Toggle between timestamped and freeform notes
                Picker("", selection: $showFreeformNotes) {
                    Label("Timestamped", systemImage: "clock")
                        .tag(false)
                    Label("Freeform", systemImage: "text.alignleft")
                        .tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                if let outputURL = recordingService.outputURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    } label: {
                        Label("Show Recording", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(CasaSpace.xl)
    }

    // MARK: - Timestamped Notes

    private var timestampedNotesArea: some View {
        VStack(spacing: 0) {
            // Scrollable notes list
            ScrollViewReader { proxy in
                ScrollView {
                    if meeting.timestampedNotes.isEmpty {
                        VStack(spacing: CasaSpace.sm) {
                            Image(systemName: "text.badge.plus")
                                .font(.title2)
                                .foregroundStyle(Color.textTertiary)
                            Text("Type a note below and press Return to add it with a timestamp")
                                .font(.body)
                                .foregroundStyle(Color.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(CasaSpace.xxxl)
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

            // Note input bar
            noteInputBar
        }
    }

    private func timestampedNoteRow(_ note: TimestampedNote) -> some View {
        HStack(alignment: .top, spacing: CasaSpace.sm) {
            Text(note.formattedTimestamp)
                .font(.caption.monospaced())
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, CasaSpace.xs)
                .padding(.vertical, CasaSpace.xxs)
                .background(Color.accentColor.opacity(0.1))
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
                    .foregroundStyle(Color.stateRecording)
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

    // MARK: - Freeform Notes

    private var freeformNotesEditor: some View {
        VStack(spacing: 0) {
            MarkdownFormattingToolbar(coordinator: editorCoordinator)
            Divider()
            MarkdownTextEditor(
                text: $meeting.userNotes,
                font: .systemFont(ofSize: NSFont.systemFontSize),
                coordinator: $editorCoordinator
            )
            .padding(CasaSpace.lg)
            .onChange(of: meeting.userNotes) {
                debouncedSave()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if recordingService.isPreparing {
                ProgressView()
                    .controlSize(.small)
            }

            Text("\(meeting.timestampedNotes.count) notes")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)

            Spacer()

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
        .padding(CasaSpace.lg)
    }

    // MARK: - Helpers

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

    private var statusTitle: String {
        if recordingService.isPreparing {
            return "Preparing Audio Capture"
        }
        if recordingService.isRecording {
            return "Recording Meeting"
        }
        return "Starting Recording"
    }

    private var statusMessage: String {
        if recordingService.isPreparing {
            return "Casablanca is attaching to your microphone and system audio."
        }
        if recordingService.isRecording {
            if recordingService.isSystemAudioEnabled {
                return "The selected microphone and system audio are being mixed into a single local WAV file."
            }
            return "Only the selected microphone is being recorded right now. System audio is muted."
        }
        return "Waiting for the recording pipeline to start."
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

    private func startIfNeeded() async {
        guard !didTriggerStart else { return }
        guard recordingService.activeMeetingID == nil || recordingService.activeMeetingID == meeting.id else {
            recordingService.clearError()
            return
        }

        didTriggerStart = true

        if recordingService.isRecording && recordingService.activeMeetingID == meeting.id {
            return
        }

        do {
            try await recordingService.startRecording(for: meeting)
            meeting.status = .recording
            save()
        } catch {
            didTriggerStart = false
        }
    }

    private func stopRecording() async {
        do {
            let result = try await recordingService.stopRecording()
            meeting.recordingFileURL = result.outputURL.path
            meeting.recordingDuration = result.duration
            meeting.status = .processing
            save()
        } catch {}
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
