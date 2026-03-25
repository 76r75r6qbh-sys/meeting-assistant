import EventKit
import SwiftUI

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

            Button(action: primaryAction) {
                Label(primaryActionTitle, systemImage: primaryActionIcon)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .cardStyle(isHighlighted: isNextUpcoming)
        .opacity(isPast ? 0.7 : 1.0)
        .accessibilityElement(children: .combine)
        .contextMenu {
            if !isPast {
                Button("Start Recording", systemImage: "record.circle") {
                    onStartRecording()
                }
            }

            Button("Take Notes Only", systemImage: "pencil.line") {
                onTakeNotes()
            }

            Button("View Details", systemImage: "doc.text") {
                onViewDetails()
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

    private var primaryActionTitle: String {
        if isPast {
            return "View Details"
        }
        return "Start Recording"
    }

    private var primaryActionIcon: String {
        if isPast {
            return "doc.text"
        }
        return "record.circle"
    }

    private func primaryAction() {
        if isPast {
            onViewDetails()
        } else {
            onStartRecording()
        }
    }
}
