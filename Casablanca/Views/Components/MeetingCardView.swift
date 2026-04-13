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

    private var attendeeSummary: String? {
        guard let attendees = event.attendees else { return nil }
        let names = attendees.compactMap(\.name).prefix(2)
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
