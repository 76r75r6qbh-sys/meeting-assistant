import EventKit
import SwiftUI

enum MeetingEntryAction: String, CaseIterable {
    case startRecording
    case takeNotes
    case viewDetails

    var title: String {
        switch self {
        case .startRecording:
            return "Start Recording"
        case .takeNotes:
            return "Take Notes"
        case .viewDetails:
            return "View Details"
        }
    }

    var systemImage: String {
        switch self {
        case .startRecording:
            return "record.circle"
        case .takeNotes:
            return "pencil.line"
        case .viewDetails:
            return "doc.text"
        }
    }
}

struct MeetingEntryActionLayout {
    let isPast: Bool

    var visibleActions: [MeetingEntryAction] {
        isPast ? [.viewDetails] : [.startRecording, .takeNotes]
    }

    var contextMenuActions: [MeetingEntryAction] {
        isPast ? [.takeNotes, .viewDetails] : [.startRecording, .takeNotes, .viewDetails]
    }
}

/// Presentation model for the dashboard "Up next" hero. Pure value type so the
/// label / timing logic can be unit-tested without a live calendar.
struct DashboardHeroPresentation {
    let title: String
    let timeRange: String
    let participantNames: [String]
    /// True when the meeting is happening right now.
    let isLive: Bool
    /// Whole minutes until the meeting starts (nil when live or already started).
    let minutesUntilStart: Int?

    init(event: EKEvent, referenceDate: Date = Date()) {
        self.title = event.title ?? "Untitled"
        self.participantNames = event.attendees?.compactMap(\.name) ?? []

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        self.timeRange = "\(formatter.string(from: event.startDate)) – \(formatter.string(from: event.endDate))"

        self.isLive = event.startDate <= referenceDate && event.endDate > referenceDate

        if event.startDate > referenceDate {
            let seconds = event.startDate.timeIntervalSince(referenceDate)
            self.minutesUntilStart = max(0, Int(seconds / 60))
        } else {
            self.minutesUntilStart = nil
        }
    }

    /// Uppercase accent eyebrow, e.g. "Live now", "Starting soon", "Up next · in 25 min".
    var eyebrow: String {
        if isLive { return "Live now" }
        guard let minutes = minutesUntilStart else { return "Up next" }
        if minutes <= 1 { return "Starting soon" }
        return "Up next · in \(minutes) min"
    }

    var participantCount: Int { participantNames.count }

    var detailLine: String {
        guard participantCount > 0 else { return timeRange }
        let countLabel = participantCount == 1 ? "1 participant" : "\(participantCount) participants"
        return "\(timeRange) · \(countLabel)"
    }
}

struct MeetingCardView: View {
    let event: EKEvent
    let isNextUpcoming: Bool
    let timeUntil: String?
    let onStartRecording: () -> Void
    let onTakeNotes: () -> Void
    let onViewDetails: () -> Void

    private var isPast: Bool {
        event.endDate < Date()
    }

    private var isHappening: Bool {
        let now = Date()
        return event.startDate <= now && event.endDate > now
    }

    private var actionLayout: MeetingEntryActionLayout {
        MeetingEntryActionLayout(isPast: isPast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack(alignment: .top, spacing: CasaSpace.sm) {
                statusDot

                VStack(alignment: .leading, spacing: CasaSpace.xs) {
                    Text(event.title ?? "Untitled")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(isPast ? Color.textSecondary : Color.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: CasaSpace.sm) {
                        timeLabel

                        if let timeUntil, isNextUpcoming {
                            Text(timeUntil)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Color.textSecondary)
                        }
                    }

                    if let attendeeSummary {
                        Text(attendeeSummary)
                            .font(.footnote)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                ParticipantAvatars(names: attendeeNames)
            }

            actionButtons
        }
        .cardStyle(isHighlighted: isNextUpcoming)
        .opacity(isPast ? 0.7 : 1.0)
        .accessibilityElement(children: .combine)
        .contextMenu {
            ForEach(actionLayout.contextMenuActions, id: \.rawValue) { action in
                Button(action.title, systemImage: action.systemImage) {
                    perform(action)
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: CasaSpace.sm) {
            ForEach(actionLayout.visibleActions, id: \.rawValue) { action in
                if isPrimaryAction(action) {
                    Button {
                        perform(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button {
                        perform(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
            .padding(.top, 2)
    }

    private var dotColor: Color {
        if isHappening { return .stateLive }
        if isPast { return .stateIdle }
        if isNextUpcoming { return .accentColor }
        return .stateIdle.opacity(0.5)
    }

    private var timeLabel: some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return Text(formatter.string(from: event.startDate))
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(isPast ? Color.textTertiary : Color.textSecondary)
    }

    private var attendeeNames: [String] {
        event.attendees?.compactMap(\.name) ?? []
    }

    private var attendeeSummary: String? {
        let names = attendeeNames.prefix(2)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }

    private func isPrimaryAction(_ action: MeetingEntryAction) -> Bool {
        action == .startRecording || action == .viewDetails
    }

    private func perform(_ action: MeetingEntryAction) {
        switch action {
        case .startRecording:
            onStartRecording()
        case .takeNotes:
            onTakeNotes()
        case .viewDetails:
            onViewDetails()
        }
    }
}

/// Overlapping circular avatars with initials, capped at `maxVisible` plus a
/// "+N" overflow chip. Renders nothing when there are no participants.
struct ParticipantAvatars: View {
    let names: [String]
    var maxVisible: Int = 3

    private var visible: [String] {
        Array(names.prefix(maxVisible))
    }

    private var overflow: Int {
        max(0, names.count - maxVisible)
    }

    var body: some View {
        if !names.isEmpty {
            HStack(spacing: -7) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, name in
                    avatar(text: initials(for: name))
                }
                if overflow > 0 {
                    avatar(text: "+\(overflow)")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(participantAccessibilityLabel)
        }
    }

    private func avatar(text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.textSecondary)
            .frame(width: 24, height: 24)
            .background(Color.backgroundActive, in: Circle())
            .overlay(
                Circle().strokeBorder(Color.backgroundTertiary, lineWidth: 2)
            )
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }

    private var participantAccessibilityLabel: String {
        names.count == 1 ? "1 participant" : "\(names.count) participants"
    }
}
