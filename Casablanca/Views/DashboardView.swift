import EventKit
import SwiftUI

struct DashboardView: View {
    @Bindable var viewModel: MeetingListViewModel
    @State private var selectedDay: Date?

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
        .onAppear {
            syncSelectedDay()
        }
        .onChange(of: dayIdentifiers) { _, _ in
            syncSelectedDay()
        }
        .task {
            if viewModel.calendarAuthorized {
                await viewModel.refreshEvents()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.beginManualMeeting()
                } label: {
                    Label("Start Manual Meeting", systemImage: "plus")
                }
            }
        }
    }

    private var meetingListView: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxl) {
            dayNavigator

            if let activeDay = selectedDay,
               let group = groupedEvents.first(where: { Calendar.current.isDate($0.date, inSameDayAs: activeDay) }) {
                dayPage(date: group.date, events: group.events)
                    .animation(CasaAnimation.standard, value: activeDay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(CasaSpace.xl)
    }

    private var groupedEvents: [(date: Date, events: [EKEvent])] {
        viewModel.groupedEvents
    }

    private var dayIdentifiers: [Date] {
        groupedEvents.map(\.date)
    }

    private var dayNavigator: some View {
        HStack(spacing: CasaSpace.md) {
            Button {
                stepDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(previousDay == nil)

            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text(selectedDayTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)

                Text(selectedDaySubtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            Button {
                stepDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(nextDay == nil)
        }
    }

    private func dayPage(date _: Date, events: [EventKit.EKEvent]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CasaSpace.lg) {
                ForEach(events, id: \.eventIdentifier) { event in
                    MeetingCardView(
                        event: event,
                        isNextUpcoming: viewModel.isNextUpcoming(event),
                        timeUntil: viewModel.timeUntil(event),
                        onStartRecording: {
                            viewModel.beginRecording(for: event)
                        },
                        onTakeNotes: {
                            viewModel.beginNotes(for: event)
                        },
                        onViewDetails: {
                            viewModel.openMeetingDetails(for: event)
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.vertical, CasaSpace.xs)
        }
    }

    private var previousDay: Date? {
        guard let selectedDay,
              let selectedIndex = dayIdentifiers.firstIndex(of: selectedDay),
              selectedIndex > 0
        else {
            return nil
        }
        return dayIdentifiers[selectedIndex - 1]
    }

    private var nextDay: Date? {
        guard let selectedDay,
              let selectedIndex = dayIdentifiers.firstIndex(of: selectedDay),
              selectedIndex < dayIdentifiers.count - 1
        else {
            return nil
        }
        return dayIdentifiers[selectedIndex + 1]
    }

    private func stepDay(by offset: Int) {
        if offset < 0 {
            selectedDay = previousDay ?? selectedDay
        } else {
            selectedDay = nextDay ?? selectedDay
        }
    }

    private func syncSelectedDay() {
        guard let firstDay = dayIdentifiers.first else {
            selectedDay = nil
            return
        }

        guard let selectedDay, dayIdentifiers.contains(selectedDay) else {
            self.selectedDay = firstDay
            return
        }
    }

    private var selectedDayTitle: String {
        guard let selectedDay else { return "" }
        return dayChipTitle(for: selectedDay)
    }

    private var selectedDaySubtitle: String {
        guard let selectedDay,
              let group = groupedEvents.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selectedDay) })
        else {
            return ""
        }

        return "\(dayChipSubtitle(for: selectedDay)) · \(meetingCountLabel(for: group.events.count))"
    }

    private func dayChipTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func dayChipSubtitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    private func meetingCountLabel(for count: Int) -> String {
        count == 1 ? "1 meeting" : "\(count) meetings"
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Upcoming Meetings", systemImage: "calendar")
        } description: {
            Text("Your calendar is clear. Start a manual meeting or check back later.")
        } actions: {
            Button {
                viewModel.beginManualMeeting()
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
