import EventKit
import SwiftUI

struct DashboardView: View {
    @Bindable var viewModel: MeetingListViewModel

    var body: some View {
        Group {
            if !viewModel.calendarAuthorized {
                calendarAccessView
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.hasEvents {
                emptyStateView
            } else {
                meetingListView
            }
        }
        .frame(maxWidth: CasaLayout.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if viewModel.calendarAuthorized {
                await viewModel.refreshEvents()
            }
        }
    }

    private var meetingListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CasaSpace.xl) {
                ForEach(Array(viewModel.groupedEvents.enumerated()), id: \.offset) { _, group in
                    daySection(date: group.date, events: group.events)
                }

                // Manual meeting button at the bottom
                manualMeetingButton
                    .padding(.top, CasaSpace.sm)
            }
            .padding(CasaSpace.xl)
        }
    }

    private func daySection(date: Date, events: [EventKit.EKEvent]) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            Text(viewModel.dayLabel(for: date))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Calendar.current.isDateInToday(date) ? Color.textPrimary : Color.textSecondary)

            ForEach(events, id: \.eventIdentifier) { event in
                MeetingCardView(
                    event: event,
                    isNextUpcoming: viewModel.isNextUpcoming(event),
                    timeUntil: viewModel.timeUntil(event),
                    onStartRecording: {
                        if let meeting = viewModel.findOrCreateMeeting(for: event) {
                            meeting.status = .recording
                            viewModel.selectedMeeting = meeting
                        }
                    },
                    onTakeNotes: {
                        if let meeting = viewModel.findOrCreateMeeting(for: event) {
                            meeting.status = .notesOnly
                            viewModel.selectedMeeting = meeting
                        }
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var manualMeetingButton: some View {
        Button {
            if let meeting = viewModel.createManualMeeting(title: "") {
                viewModel.selectedMeeting = meeting
            }
        } label: {
            Label("Manual Meeting", systemImage: "plus.circle")
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Upcoming Meetings", systemImage: "calendar")
        } description: {
            Text("Your calendar is clear. Start a manual meeting or check back later.")
        } actions: {
            Button {
                if let meeting = viewModel.createManualMeeting(title: "") {
                    viewModel.selectedMeeting = meeting
                }
            } label: {
                Label("Start Manual Meeting", systemImage: "plus.circle")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var calendarAccessView: some View {
        ContentUnavailableView {
            Label("Calendar Access Required", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("Casablanca needs access to your calendar to show upcoming meetings.")
        } actions: {
            Button("Grant Access") {
                Task {
                    await viewModel.requestCalendarAccess()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}
