import EventKit
import SwiftData
import SwiftUI

struct MenuBarMeetingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Bindable var viewModel: MeetingListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.lg) {
            header

            if !viewModel.calendarAuthorized {
                permissionState
            } else if let event = viewModel.currentOrNextEvent {
                eventCard(for: event)
            } else {
                emptyState
            }

            Divider()

            Button {
                viewModel.beginManualMeeting()
                openMainWindow()
            } label: {
                Label("Start Manual Meeting", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(CasaSpace.lg)
        .frame(width: 340)
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
        .task {
            if viewModel.calendarAuthorized {
                await viewModel.refreshEvents()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
            Text("Casablanca")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            Text("Quick access to your next meeting")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func eventCard(for event: EKEvent) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                Text(viewModel.isHappeningNow(event) ? "Current meeting" : "Upcoming meeting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.isHappeningNow(event) ? Color.stateRecording : Color.accentColor)

                Text(event.title ?? "Untitled Meeting")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text(eventSubtitle(for: event))
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Button {
                viewModel.beginRecording(for: event)
                openMainWindow()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(CasaSpace.md)
        .cardStyle()
    }

    private var permissionState: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Calendar access is required to show your upcoming meetings here.")
                .font(.callout)
                .foregroundStyle(Color.textPrimary)

            Button("Open Casablanca") {
                openMainWindow()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(CasaSpace.md)
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("No current or upcoming meetings")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            Text("You can still start a manual meeting from here.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(CasaSpace.md)
        .cardStyle()
    }

    private func eventSubtitle(for event: EKEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM · HH:mm"

        if viewModel.isHappeningNow(event) {
            return "Started \(formatter.string(from: event.startDate))"
        }

        if let timeUntil = viewModel.timeUntil(event) {
            return "\(formatter.string(from: event.startDate)) · \(timeUntil)"
        }

        return formatter.string(from: event.startDate)
    }

    private func openMainWindow() {
        openWindow(id: CasablancaApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
