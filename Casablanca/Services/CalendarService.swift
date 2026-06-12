import EventKit
import OSLog
import SwiftUI

@Observable
final class CalendarService {
    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var events: [EKEvent] = []
    var isLoading = false

    private var refreshTimer: Timer?

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            await MainActor.run {
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            }
            if granted {
                await fetchUpcomingEvents()
                startAutoRefresh()
            }
            return granted
        } catch {
            Log.calendar.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func fetchUpcomingEvents() async {
        guard authorizationStatus == .fullAccess else { return }

        await MainActor.run { isLoading = true }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        // Fetch today + next 7 days
        guard let endDate = calendar.date(byAdding: .day, value: 7, to: startOfToday) else { return }

        let predicate = store.predicateForEvents(withStart: startOfToday, end: endDate, calendars: nil)
        let fetchedEvents = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        await MainActor.run {
            events = fetchedEvents
            isLoading = false
        }
    }

    func eventsGroupedByDay() -> [(date: Date, events: [EKEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { event in
            calendar.startOfDay(for: event.startDate)
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (date: $0.key, events: $0.value) }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.fetchUpcomingEvents()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
