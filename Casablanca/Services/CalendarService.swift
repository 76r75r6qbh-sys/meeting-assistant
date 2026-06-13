import EventKit
import OSLog
import SwiftUI

@MainActor
@Observable
final class CalendarService {
    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var events: [EKEvent] = []
    var isLoading = false

    /// Coalesces the bursts of `.EKEventStoreChanged` notifications EventKit
    /// fires for a single edit before we refresh. Cancellable, so a newer
    /// notification supersedes a pending refresh.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Token for the `.EKEventStoreChanged` observer so we can remove it on teardown.
    @ObservationIgnored private var storeChangeObserver: (any NSObjectProtocol)?
    /// Long-interval safety net for notifications missed across system sleep.
    @ObservationIgnored private var fallbackTimer: Timer?

    /// How long to coalesce `.EKEventStoreChanged` events before refreshing.
    /// EventKit emits these in quick bursts for a single edit.
    @ObservationIgnored private let debounceInterval: Duration
    /// Cheap insurance against missed change notifications (e.g. across sleep).
    @ObservationIgnored private let fallbackInterval: TimeInterval

    /// Called after each successful refresh once `events` has been updated, so
    /// dependents (e.g. `MeetingStartNotifier`) can react to a settled change
    /// without polling. Set by `AppModel` at bootstrap.
    @ObservationIgnored var onEventsRefreshed: (() -> Void)?

    init(debounceInterval: Duration = .seconds(2), fallbackInterval: TimeInterval = 15 * 60) {
        self.debounceInterval = debounceInterval
        self.fallbackInterval = fallbackInterval
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                await fetchUpcomingEvents()
                startObservingChanges()
            }
            return granted
        } catch {
            Log.calendar.error("Calendar access request failed: \(error.localizedDescription)")
            return false
        }
    }

    func fetchUpcomingEvents() async {
        guard authorizationStatus == .fullAccess else { return }

        isLoading = true

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        // Fetch today + next 7 days
        guard let endDate = calendar.date(byAdding: .day, value: 7, to: startOfToday) else {
            isLoading = false
            return
        }

        let predicate = store.predicateForEvents(withStart: startOfToday, end: endDate, calendars: nil)
        let fetchedEvents = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        events = fetchedEvents
        isLoading = false
        onEventsRefreshed?()
    }

    /// Begin event-driven refresh when access was already granted on a previous
    /// launch (the `requestAccess()` grant path is not taken on those launches).
    /// No-op without full access. Idempotent.
    func startMonitoringIfAuthorized() {
        guard authorizationStatus == .fullAccess else { return }
        startObservingChanges()
    }

    /// Re-resolve an `EKEvent` from a stored identifier. Prefers the currently
    /// loaded `events` (cheap, no store hit), falling back to the EventKit store
    /// for events outside the loaded window.
    func event(withIdentifier identifier: String) -> EKEvent? {
        if let cached = events.first(where: { $0.eventIdentifier == identifier }) {
            return cached
        }
        guard authorizationStatus == .fullAccess else { return nil }
        return store.event(withIdentifier: identifier)
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

    /// Start event-driven refresh: observe `.EKEventStoreChanged` (debounced) and
    /// arm a long-interval fallback timer. Idempotent — a prior observer/timer is
    /// torn down first so a second `requestAccess()` can't double-subscribe.
    private func startObservingChanges() {
        stopObservingChanges()

        // EKEventStoreChanged can arrive on any thread; the observer hops onto the
        // MainActor (this class is @MainActor) before touching state.
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleDebouncedRefresh() }
        }

        let timer = Timer.scheduledTimer(withTimeInterval: fallbackInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetchUpcomingEvents() }
        }
        fallbackTimer = timer
    }

    private func stopObservingChanges() {
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
            self.storeChangeObserver = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    /// Debounce the burst of `.EKEventStoreChanged` events, then refresh. A newer
    /// notification cancels a pending refresh so we fetch once per settled change.
    /// Returns the scheduled task so a test can `await` it deterministically.
    @discardableResult
    func scheduleDebouncedRefresh() -> Task<Void, Never> {
        debounceTask?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self.fetchUpcomingEvents()
        }
        debounceTask = task
        return task
    }

    deinit {
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
        }
        debounceTask?.cancel()
        fallbackTimer?.invalidate()
    }
}
