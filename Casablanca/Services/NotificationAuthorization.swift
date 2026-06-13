import Foundation
@preconcurrency import UserNotifications

/// Process-wide, idempotent gate for `UNUserNotificationCenter` authorization.
///
/// Both notification producers — `RecordingNotificationCenter` (ad-hoc
/// pause/resume) and the Phase 9c auto-record `MeetingStartNotifier` path — route
/// their authorization through here so the system prompt is requested at most
/// once and two concurrent `requestAuthorization` calls can never race.
///
/// `requestAuthorization` is itself idempotent (the OS only ever prompts the user
/// once), but funnelling through a single in-flight task also coalesces concurrent
/// callers and lets us cache the granted result for cheap re-queries.
@MainActor
final class NotificationAuthorization {
    static let shared = NotificationAuthorization()

    private let center: UNUserNotificationCenter
    private var inFlight: Task<Bool, Never>?
    private var cachedGranted: Bool?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Request `[.alert, .sound]` authorization, coalescing concurrent and repeat
    /// callers. Returns whether notifications are authorized. Safe to call
    /// fire-and-forget; never throws.
    @discardableResult
    func ensureAuthorized() async -> Bool {
        if let cachedGranted { return cachedGranted }
        if let inFlight { return await inFlight.value }

        let center = self.center
        let task = Task<Bool, Never> { @MainActor in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return granted
        }
        inFlight = task
        let granted = await task.value
        cachedGranted = granted
        inFlight = nil
        return granted
    }

    /// Current system-level authorization status, for surfacing a "notifications
    /// are disabled" hint in Settings. Reflects the OS state (incl. the user
    /// later toggling it off in System Settings), independent of our cache.
    func currentStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
}
