import SwiftUI
import SwiftData

struct MeetingDetailInspector: View {
    let meeting: Meeting
    let canExport: Bool
    /// Navigate to another meeting (used by the recurring-series prev/next links).
    /// When nil the series links are hidden.
    var onSelectMeeting: ((Meeting) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var tagDraft: String = ""
    /// All distinct tags across the store, gathered in memory for autocomplete.
    @State private var allKnownTags: [String] = []
    @State private var previousOccurrence: Meeting?
    @State private var nextOccurrence: Meeting?

    private var recordingURL: URL? {
        guard let path = meeting.recordingFileURL else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                if onSelectMeeting != nil && (previousOccurrence != nil || nextOccurrence != nil) {
                    seriesInspectorSection
                }

                recordingInspectorSection

                tagsInspectorSection

                if !meeting.participants.isEmpty {
                    participantsInspectorSection
                }

                exportInspectorSection
            }
            .padding(CasaSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundSecondary)
        .onAppear {
            refreshKnownTags()
            refreshSeriesLinks()
        }
        .onChange(of: meeting.id) { _, _ in
            refreshSeriesLinks()
        }
    }

    // MARK: - Recurring series links

    @ViewBuilder
    private var seriesInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Series")

            if let previousOccurrence {
                seriesLink(label: "Previous", meeting: previousOccurrence, systemImage: "chevron.backward")
            }
            if let nextOccurrence {
                seriesLink(label: "Next", meeting: nextOccurrence, systemImage: "chevron.forward")
            }
        }
    }

    private func seriesLink(label: String, meeting: Meeting, systemImage: String) -> some View {
        Button {
            onSelectMeeting?(meeting)
        } label: {
            HStack(spacing: CasaSpace.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.textTertiary)
                    Text(seriesDateLabel(meeting.date))
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(CasaSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.md))
        }
        .buttonStyle(.plain)
        .help("Go to the \(label.lowercased()) meeting in this series")
    }

    private func seriesDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    private func refreshSeriesLinks() {
        guard onSelectMeeting != nil else { return }
        previousOccurrence = MeetingSeriesResolver.previousOccurrence(of: meeting, in: modelContext)
        nextOccurrence = MeetingSeriesResolver.nextOccurrence(of: meeting, in: modelContext)
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagsInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Tags")

            if !meeting.tags.isEmpty {
                FlowLayout(spacing: CasaSpace.xs) {
                    ForEach(meeting.tags, id: \.self) { tag in
                        TagChip(text: tag, onRemove: { removeTag(tag) })
                    }
                }
                .casaAnimation(CasaAnimation.fast, value: meeting.tags)
            }

            TextField("Add tag…", text: $tagDraft)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .onSubmit(commitDraft)
                .onChange(of: tagDraft) { _, new in
                    // Comma commits the tag-so-far (token-field behaviour).
                    if new.contains(",") {
                        let parts = new.split(separator: ",", omittingEmptySubsequences: false)
                        for part in parts.dropLast() { addTag(String(part)) }
                        tagDraft = String(parts.last ?? "")
                    }
                }

            if !tagSuggestions.isEmpty {
                FlowLayout(spacing: CasaSpace.xs) {
                    ForEach(tagSuggestions, id: \.self) { suggestion in
                        TagChip(text: suggestion, onTap: { addTag(suggestion) })
                    }
                }
            }
        }
    }

    /// Existing tags (across the store) that match the current draft and aren't
    /// already on this meeting. Empty draft surfaces a few not-yet-applied tags.
    private var tagSuggestions: [String] {
        let draft = Meeting.normalizeTag(tagDraft)
        let applied = Set(meeting.tags)
        let candidates = allKnownTags.filter { !applied.contains($0) }
        guard let draft else { return Array(candidates.prefix(6)) }
        return candidates.filter { $0.contains(draft) }.prefix(6).map { $0 }
    }

    private func commitDraft() {
        addTag(tagDraft)
        tagDraft = ""
    }

    private func addTag(_ raw: String) {
        guard meeting.addTag(raw) else { return }
        meeting.setTags(meeting.tags) // re-normalize/dedupe defensively
        persist()
        refreshKnownTags()
    }

    private func removeTag(_ tag: String) {
        meeting.removeTag(tag)
        persist()
    }

    private func persist() {
        do { try modelContext.save() } catch {
            Log.persistence.error("Failed to save meeting tags: \(error.localizedDescription)")
        }
    }

    /// Gather the distinct tag set across the store IN MEMORY (no SQL DISTINCT
    /// over an array column). Bounded fetch keeps this cheap.
    private func refreshKnownTags() {
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        descriptor.propertiesToFetch = [\.tags]
        let meetings = (try? modelContext.fetch(descriptor)) ?? []
        allKnownTags = SidebarMeetingsProvider.distinctTags(in: meetings)
    }

    @ViewBuilder
    private var recordingInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Recording")

            if recordingURL != nil {
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved locally")
                            .font(.subheadline)
                            .foregroundStyle(Color.textPrimary)
                        if let duration = meeting.recordingDuration {
                            Text(duration.formattedRecordingDuration)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer()
                }
                .padding(CasaSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.md))

                // NOTE: A full inline audio player (waveform + scrubber) is deferred
                // to a later polish pass; "Show in Finder" is available in the ⋯ menu.
            } else {
                Text("No recording saved for this meeting.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var participantsInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Participants")

            ForEach(Array(meeting.participants.enumerated()), id: \.offset) { _, name in
                HStack(spacing: CasaSpace.sm) {
                    Text(initials(for: name))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.backgroundTertiary, in: Circle())
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var exportInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Export")

            if meeting.appleNotesSummaryNoteID != nil || meeting.appleNotesRawNotesNoteID != nil {
                Label("Exported to Apple Notes", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentSuccess)
                    .symbolRenderingMode(.hierarchical)
            } else if canExport {
                Text("Not exported yet. Use the Export action to save to your configured destination.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            } else {
                Text("Generate a summary or transcript to enable export.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private func inspectorLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Color.textTertiary)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
