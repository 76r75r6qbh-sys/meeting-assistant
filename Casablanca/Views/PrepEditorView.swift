import SwiftUI

/// Self-authored preparation mode: write meeting prep in-app before a meeting.
///
/// Loads any existing prep (`MeetingPrepService.loadPrepMarkdown` → falls back
/// to `meeting.localPrepNotes`), edits it with the shared markdown editor +
/// formatting toolbar + appearance controls, and saves it back via
/// `MeetingPrepService.writePrep` (vault `- Prep.md` when storage is Obsidian,
/// else `meeting.localPrepNotes`). Designed to be presented as a `.sheet`.
struct PrepEditorView: View {
    let meeting: Meeting
    /// Begin recording for this meeting. When non-nil the primary button reads
    /// "Start Recording" and dismisses the sheet after kicking off recording;
    /// when nil the primary button becomes "Save & Close".
    var onStartRecording: (() -> Void)?
    let onDismiss: () -> Void

    @AppStorage(AppPreferenceKey.notesTextSize) private var textSizeRaw = NotesTextSize.medium.rawValue
    @AppStorage(AppPreferenceKey.notesReadingWidth) private var readingWidthRaw = NotesReadingWidth.comfortable.rawValue

    @State private var prepText = ""
    @State private var didLoad = false
    @State private var saveError: String?
    @State private var isDrafting = false
    @State private var draftError: String?

    private static let template = """
    ## Goal


    ## Agenda
    -\u{0020}

    ## Questions
    -\u{0020}

    ## Notes

    """

    private var textSize: NotesTextSize {
        NotesTextSize(rawValue: textSizeRaw) ?? .medium
    }

    private var readingWidth: NotesReadingWidth {
        NotesReadingWidth(rawValue: readingWidthRaw) ?? .comfortable
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            HStack(spacing: 0) {
                editorColumn
                Divider()
                inspector
                    .frame(width: 250)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(Color.backgroundPrimary)
        .onAppear(perform: loadIfNeeded)
        .alert("Couldn't Save Prep", isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert("Draft Failed", isPresented: draftErrorBinding) {
            Button("OK", role: .cancel) { draftError = nil }
        } message: {
            Text(draftError ?? "")
        }
    }

    // MARK: - Top bar (title + primary actions)

    private var toolbar: some View {
        HStack(spacing: CasaSpace.sm) {
            Text("Prepare")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Button("Done") {
                save()
                onDismiss()
            }
            .buttonStyle(SecondaryButtonStyle())

            if let onStartRecording {
                Button {
                    save()
                    onStartRecording()
                    onDismiss()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    save()
                    onDismiss()
                } label: {
                    Label("Save & Close", systemImage: "checkmark")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.md)
        .background(.bar)
    }

    // MARK: - Editor

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, CasaSpace.xl)
                .padding(.top, CasaSpace.lg)

            formatBar
                .padding(.horizontal, CasaSpace.xl)
                .padding(.vertical, CasaSpace.sm)

            Divider()

            ToastMarkdownEditor(
                text: $prepText,
                placeholder: "Write your preparation notes here…"
            )
            .font(.system(size: textSize.pointSize))
            .frame(maxWidth: readingWidth.maxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(CasaSpace.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xs) {
            HStack(spacing: CasaSpace.xs) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)

                Text(eyebrow)
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(Color.accentColor)
            }

            Text(meeting.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)

            Text(metaLine)
                .font(.footnote)
                .foregroundStyle(Color.textSecondary)

            Label("Preparation", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, CasaSpace.sm)
                .padding(.vertical, CasaSpace.xxs)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .padding(.top, CasaSpace.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formatBar: some View {
        HStack(spacing: CasaSpace.xs) {
            MarkdownFormattingToolbar(text: $prepText)

            if prepText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Use template") {
                    prepText = Self.template
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, CasaSpace.xs)
            }

            Spacer()

            draftWithAIButton

            MarkdownAppearanceControl()
        }
    }

    private var draftWithAIButton: some View {
        Button {
            Task { await draftWithAI() }
        } label: {
            HStack(spacing: CasaSpace.xs) {
                if isDrafting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
                Text("Draft with AI")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentSecondary)
            .padding(.horizontal, CasaSpace.sm)
            .padding(.vertical, CasaSpace.xs)
            .background(Color.accentSecondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDrafting)
        .help("Generate a prep draft you can edit")
    }

    // MARK: - Inspector (calendar context)

    private var inspector: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            if !meeting.participants.isEmpty {
                inspectorLabel("Participants")
                ParticipantAvatars(names: meeting.participants)
                VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                    ForEach(meeting.participants.prefix(8), id: \.self) { name in
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                    if meeting.participants.count > 8 {
                        Text("+\(meeting.participants.count - 8) more")
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                }
            }

            inspectorLabel("Schedule")
            Text(metaLine)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            Spacer()

            Label(saveDestinationLabel, systemImage: "tray.and.arrow.down")
                .font(.caption2)
                .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(CasaSpace.lg)
        .background(Color.backgroundTertiary.opacity(0.5))
    }

    private func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .kerning(0.5)
            .foregroundStyle(Color.textTertiary)
    }

    // MARK: - Derived strings

    private var eyebrow: String {
        let now = Date()
        guard meeting.date > now else { return "Upcoming" }
        let minutes = Int(meeting.date.timeIntervalSince(now) / 60)
        if minutes < 60 {
            return "Upcoming · in \(max(minutes, 1)) min"
        }
        let hours = minutes / 60
        return "Upcoming · in \(hours)h \(minutes % 60)m"
    }

    private var metaLine: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM"
        let day = dateFormatter.string(from: meeting.date)
        let count = meeting.participants.count
        let participantLabel = count == 1 ? "1 participant" : "\(count) participants"
        if count > 0 {
            return "\(day) · \(meeting.formattedTime) · \(participantLabel)"
        }
        return "\(day) · \(meeting.formattedTime)"
    }

    private var saveDestinationLabel: String {
        AppPreferences.prepTodoStorage(in: .standard) == .obsidian
            ? "Saves to your vault as “…- Prep.md”"
            : "Saved with the meeting"
    }

    // MARK: - Load / Save / Draft

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        let existing = MeetingPrepService.loadPrepMarkdown(for: meeting)
            ?? (meeting.localPrepNotes.isEmpty ? nil : meeting.localPrepNotes)
        prepText = existing ?? ""
    }

    private func save() {
        do {
            try MeetingPrepService.writePrep(prepText, for: meeting)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func draftWithAI() async {
        isDrafting = true
        defer { isDrafting = false }

        let provider = LLMProviderFactory.current()
        var prompt = Self.draftPrompt(for: meeting)

        let thinkingEnabled = UserDefaults.standard.bool(forKey: AppPreferenceKey.summaryThinkingEnabled)
        if !thinkingEnabled {
            prompt += "\n\n/no_think"
        }

        do {
            let draft = try await provider.generate(
                prompt: prompt,
                temperature: nil,
                maxTokens: thinkingEnabled ? nil : SummarizationService.maxSummaryTokens,
                timeout: 120,
                truncated: nil
            )
            let trimmed = SummarizationService.stripReasoning(draft)
            guard !trimmed.isEmpty else {
                draftError = "\(provider.displayName) returned an empty draft."
                return
            }
            if prepText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prepText = trimmed
            } else {
                prepText += "\n\n" + trimmed
            }
        } catch let error as LLMProviderError {
            draftError = error.localizedDescription
        } catch {
            draftError = error.localizedDescription
        }
    }

    static func draftPrompt(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let participants = meeting.participants.isEmpty
            ? "None listed"
            : meeting.participants.joined(separator: ", ")

        return """
        You are helping prepare for an upcoming meeting. Write concise preparation \
        notes in markdown using these sections: ## Goal, ## Agenda, ## Questions, ## Notes. \
        Keep it brief and practical. Use bullet points under Agenda and Questions. \
        Do not invent facts beyond what is given; leave sections light if information is missing.

        Meeting title: \(meeting.title)
        Scheduled: \(formatter.string(from: meeting.date))
        Participants: \(participants)
        """
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private var draftErrorBinding: Binding<Bool> {
        Binding(get: { draftError != nil }, set: { if !$0 { draftError = nil } })
    }
}
