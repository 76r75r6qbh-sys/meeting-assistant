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
    }

    private var meetingListView: some View {
        VStack(alignment: .leading, spacing: CasaSpace.lg) {
            dayNavigator

            if !groupedEvents.isEmpty {
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: CasaSpace.lg) {
                            ForEach(groupedEvents, id: \.date) { group in
                                dayPage(date: group.date, events: group.events)
                                    .frame(width: proxy.size.width)
                                    .tag(group.date)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: Binding(
                        get: { selectedDay ?? dayIdentifiers.first },
                        set: { selectedDay = $0 }
                    ))
                }
                .animation(.easeInOut(duration: CasaDuration.standard), value: selectedDay)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Spacer()
                manualMeetingButton
                Spacer()
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CasaSpace.sm) {
                    ForEach(dayIdentifiers, id: \.self) { date in
                        Button {
                            selectedDay = date
                        } label: {
                            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                                Text(dayChipTitle(for: date))
                                    .font(.headline)
                                Text(dayChipSubtitle(for: date))
                                    .font(.caption)
                                    .foregroundStyle(isSelectedDay(date) ? Color.white.opacity(0.75) : Color.textTertiary)
                            }
                            .frame(minWidth: 96, alignment: .leading)
                            .padding(.vertical, CasaSpace.sm)
                            .padding(.horizontal, CasaSpace.md)
                            .background(isSelectedDay(date) ? Color.accentPrimary : Color.backgroundTertiary)
                            .foregroundStyle(isSelectedDay(date) ? Color.white : Color.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.lg))
                            .overlay {
                                RoundedRectangle(cornerRadius: CasaRadius.lg)
                                    .strokeBorder(isSelectedDay(date) ? Color.clear : Color.borderSubtle, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                stepDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(nextDay == nil)
        }
    }

    private func dayPage(date: Date, events: [EventKit.EKEvent]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.lg) {
                VStack(alignment: .leading, spacing: CasaSpace.xs) {
                    Text(viewModel.dayLabel(for: date))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text(meetingCountLabel(for: events.count))
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                }

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
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(CasaSpace.lg)
        }
        .cardStyle()
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

    private func isSelectedDay(_ date: Date) -> Bool {
        Calendar.current.isDate(selectedDay ?? date, inSameDayAs: date)
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

    private var manualMeetingButton: some View {
        Button {
            viewModel.beginManualMeeting()
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
