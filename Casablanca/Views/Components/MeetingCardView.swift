import EventKit
import SwiftUI

struct MeetingCardView: View {
    let event: EKEvent
    let isNextUpcoming: Bool
    let timeUntil: String?
    let onStartRecording: () -> Void
    let onTakeNotes: () -> Void

    private var isPast: Bool {
        event.endDate < Date()
    }

    private var isHappening: Bool {
        let now = Date()
        return event.startDate <= now && event.endDate > now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            // Top row: time, title, duration
            HStack(alignment: .firstTextBaseline) {
                statusDot
                timeLabel
                Text(event.title ?? "Untitled")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isPast ? Color.textTertiary : Color.textPrimary)
                    .lineLimit(1)

                Spacer()

                if let duration = formattedDuration {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            // Participants
            if let attendees = event.attendees, !attendees.isEmpty {
                HStack(spacing: CasaSpace.xs) {
                    let names = attendees.prefix(3).compactMap { $0.name }
                    let remaining = attendees.count - 3

                    Text(participantText(names: names, remaining: remaining))
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            // Countdown for next upcoming
            if let timeUntil, isNextUpcoming {
                Text(timeUntil)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentPrimary)
            }

            // Action buttons
            HStack(spacing: CasaSpace.sm) {
                if isPast {
                    Button(action: onTakeNotes) {
                        Label("Review", systemImage: "doc.text")
                    }
                    .buttonStyle(GhostButtonStyle())
                } else if isHappening {
                    Button(action: onStartRecording) {
                        Label("Start Recording", systemImage: "record.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button(action: onTakeNotes) {
                        Label("Notes", systemImage: "pencil.line")
                    }
                    .buttonStyle(GhostButtonStyle())
                } else {
                    Button(action: onStartRecording) {
                        Label("Start Recording", systemImage: "record.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button(action: onTakeNotes) {
                        Label("Notes", systemImage: "pencil.line")
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
        }
        .cardStyle(isHighlighted: isNextUpcoming)
        .opacity(isPast ? 0.7 : 1.0)
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
        if isNextUpcoming { return .accentPrimary }
        return .stateIdle.opacity(0.5)
    }

    private var timeLabel: some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return Text(formatter.string(from: event.startDate))
            .font(.title3.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(isPast ? Color.textTertiary : Color.textSecondary)
    }

    private var formattedDuration: String? {
        let minutes = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let remaining = minutes % 60
            return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private func participantText(names: [String], remaining: Int) -> String {
        var text = "with " + names.joined(separator: ", ")
        if remaining > 0 {
            text += " +\(remaining) others"
        }
        return text
    }
}
