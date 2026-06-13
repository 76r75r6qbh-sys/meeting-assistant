import EventKit
import Foundation
import OSLog
import UserNotifications

/// Lead time before a meeting's start at which to fire the "Start Recording"
/// prompt. Persisted as its raw string via `@AppStorage`.
enum MeetingStartLeadTime: String, CaseIterable, Identifiable {
    case atStart
    case oneMinute
    case fiveMinutes

    var id: String { rawValue }

    /// Seconds before the meeting start the notification should fire.
    var secondsBefore: TimeInterval {
        switch self {
        case .atStart: return 0
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        }
    }

    var displayName: String {
        switch self {
        case .atStart: return "At start time"
        case .oneMinute: return "1 minute before"
        case .fiveMinutes: return "5 minutes before"
        }
    }
}

/// A single meeting-start notification we intend to schedule. Pure value type so
/// the scheduling decision is unit-testable without `UNUserNotificationCenter`.
struct ScheduledMeetingStartNotification: Equatable {
    /// Stable per-event request identifier so re-scheduling replaces rather than
    /// duplicates.
    let requestIdentifier: String
    /// The EKEvent identifier, round-tripped through `userInfo` to the handler.
    let eventIdentifier: String
    let title: String
    /// Wall-clock time the notification should fire (start minus lead time).
    let fireDate: Date
}

/// Pure scheduling-decision logic, isolated from EventKit/UserNotifications so it
/// can be exhaustively unit-tested. Decides, given a set of events + now + horizon
/// + lead time, exactly which notifications to schedule.
enum MeetingStartScheduleDecision {
    /// Prefix for request identifiers so we can target only our notifications when
    /// cancelling (vs. RecordingNotificationCenter's ad-hoc pause/resume ones).
    static let requestIdentifierPrefix = "meeting-start-"

    static func requestIdentifier(forEventIdentifier eventIdentifier: String) -> String {
        requestIdentifierPrefix + eventIdentifier
    }

    /// Decide the notifications to schedule.
    ///
    /// - Parameters:
    ///   - events: tuples of (identifier, title, startDate). Caller flattens
    ///     `EKEvent` to this so the function stays testable without EventKit.
    ///   - now: reference time.
    ///   - horizon: only schedule for meetings starting within `now ... now+horizon`.
    ///   - leadTime: how long before start the notification fires.
    ///   - isEnabled: when false, returns an empty set (caller cancels all).
    /// - Returns: deduped (by event identifier) notifications with future fire dates.
    static func notifications(
        for events: [(identifier: String, title: String, startDate: Date)],
        now: Date,
        horizon: TimeInterval,
        leadTime: MeetingStartLeadTime,
        isEnabled: Bool
    ) -> [ScheduledMeetingStartNotification] {
        guard isEnabled else { return [] }

        let horizonEnd = now.addingTimeInterval(horizon)
        var seen = Set<String>()
        var result: [ScheduledMeetingStartNotification] = []

        for event in events {
            let identifier = event.identifier
            guard !identifier.isEmpty else { continue }
            // Within the horizon window (future, not too far out).
            guard event.startDate > now, event.startDate <= horizonEnd else { continue }
            // Dedupe by event identifier — keep the earliest-seen.
            guard seen.insert(identifier).inserted else { continue }

            let fireDate = event.startDate.addingTimeInterval(-leadTime.secondsBefore)
            // A lead time can push the fire date into the past even though the
            // meeting is still upcoming (e.g. starts in 30s, 5-min lead). Skip
            // those — a notification fired immediately for an already-past trigger
            // is noise, and UNCalendarNotificationTrigger won't fire for the past.
            guard fireDate > now else { continue }

            result.append(
                ScheduledMeetingStartNotification(
                    requestIdentifier: requestIdentifier(forEventIdentifier: identifier),
                    eventIdentifier: identifier,
                    title: "Meeting starting: \(event.title)",
                    fireDate: fireDate
                )
            )
        }

        return result
    }
}

/// Schedules a local "Start Recording" notification at each upcoming meeting's
/// start time (minus a configurable lead time). Re-schedules whenever the
/// calendar changes by re-deriving the desired set and reconciling against what
/// is already pending, so re-scheduling replaces rather than duplicates.
@MainActor
final class MeetingStartNotifier {
    /// Only schedule for meetings within this window to avoid scheduling hundreds.
    static let defaultHorizon: TimeInterval = 24 * 60 * 60

    private let calendarService: CalendarService
    private let center: UNUserNotificationCenter
    private let horizon: TimeInterval
    private let now: () -> Date

    init(
        calendarService: CalendarService,
        center: UNUserNotificationCenter = .current(),
        horizon: TimeInterval = MeetingStartNotifier.defaultHorizon,
        now: @escaping () -> Date = Date.init
    ) {
        self.calendarService = calendarService
        self.center = center
        self.horizon = horizon
        self.now = now
    }

    private var isEnabled: Bool {
        // Default ON: absence of the key means the feature is on.
        UserDefaults.standard.object(forKey: AppPreferenceKey.meetingStartNotificationsEnabled) as? Bool ?? true
    }

    private var leadTime: MeetingStartLeadTime {
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.meetingStartNotificationLeadTime)
        return raw.flatMap(MeetingStartLeadTime.init(rawValue:)) ?? .atStart
    }

    /// Re-derive the desired notifications from the current calendar state and
    /// reconcile: cancel previously-scheduled meeting-start notifications and
    /// schedule the current set. Stable per-event identifiers mean adding a
    /// request with the same id replaces the old one.
    func reschedule() {
        let desired = MeetingStartScheduleDecision.notifications(
            for: calendarService.events.map {
                (identifier: $0.eventIdentifier ?? "", title: $0.title ?? "Untitled Meeting", startDate: $0.startDate)
            },
            now: now(),
            horizon: horizon,
            leadTime: leadTime,
            isEnabled: isEnabled
        )

        // Cancel only OUR previously-scheduled meeting-start notifications, leaving
        // RecordingNotificationCenter's pause/resume notifications untouched.
        center.getPendingNotificationRequests { [center] pending in
            let ours = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(MeetingStartScheduleDecision.requestIdentifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)

            Task { @MainActor in
                for notification in desired {
                    await Self.add(notification, to: center)
                }
            }
        }

        if !isEnabled {
            Log.calendar.debug("Meeting-start notifications disabled; cleared pending.")
        }
    }

    /// Cancel the scheduled notification for a single meeting (e.g. once recording
    /// has started for it, so the prompt doesn't fire redundantly).
    func cancel(eventIdentifier: String) {
        guard !eventIdentifier.isEmpty else { return }
        center.removePendingNotificationRequests(
            withIdentifiers: [MeetingStartScheduleDecision.requestIdentifier(forEventIdentifier: eventIdentifier)]
        )
    }

    private static func add(_ notification: ScheduledMeetingStartNotification, to center: UNUserNotificationCenter) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = "Tap to start recording this meeting."
        content.sound = .default
        content.categoryIdentifier = AppNotificationCoordinator.meetingStartCategoryID
        content.userInfo = [AppNotificationCoordinator.eventIdentifierKey: notification.eventIdentifier]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: notification.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: notification.requestIdentifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }
}
