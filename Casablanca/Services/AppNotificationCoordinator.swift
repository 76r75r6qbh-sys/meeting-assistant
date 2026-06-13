import AppKit
import Foundation
import OSLog
import UserNotifications

/// The single, process-wide `UNUserNotificationCenterDelegate`. It owns the
/// app's notification categories and routes actionable-notification responses.
///
/// It deliberately GOVERNS ALL notifications — including the ad-hoc pause/resume
/// notifications `RecordingNotificationCenter` posts. To coexist with those:
///   - `willPresent` presents every notification (banner + sound) so foreground
///     notifications still show, regardless of category. The pause/resume
///     notifications carry no `categoryIdentifier`, so they fall through here
///     unchanged.
///   - `didReceive` only special-cases the `MEETING_START` "Start Recording"
///     action; any other category/action is just completed (no routing).
@MainActor
final class AppNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let meetingStartCategoryID = "MEETING_START"
    static let startRecordingActionID = "START_RECORDING"
    static let dismissActionID = "DISMISS"
    static let eventIdentifierKey = "eventIdentifier"

    /// Invoked with the EKEvent identifier when the user taps "Start Recording".
    /// Wired from `AppModel` to resolve the event and begin recording.
    var onStartRecording: ((String) -> Void)?

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    /// Install as the process-wide delegate and register the meeting-start
    /// category. Call once at launch.
    func install() {
        center.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let startRecording = UNNotificationAction(
            identifier: Self.startRecordingActionID,
            title: "Start Recording",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: Self.dismissActionID,
            title: "Dismiss",
            options: []
        )
        let meetingStart = UNNotificationCategory(
            identifier: Self.meetingStartCategoryID,
            actions: [startRecording, dismiss],
            intentIdentifiers: [],
            options: []
        )
        // Merge with any already-registered categories rather than clobbering.
        center.getNotificationCategories { [center] existing in
            var merged = existing.filter { $0.identifier != Self.meetingStartCategoryID }
            merged.insert(meetingStart)
            center.setNotificationCategories(merged)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Present every notification (including pause/resume, which carry no
        // category) so foreground notifications still appear.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let categoryID = response.notification.request.content.categoryIdentifier
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // Only the MEETING_START "Start Recording" action (or tapping the
        // notification body) routes anywhere. The default-tap (open the app) on a
        // meeting-start notification also starts recording.
        let isMeetingStart = categoryID == Self.meetingStartCategoryID
        let isStartAction = actionID == Self.startRecordingActionID
            || actionID == UNNotificationDefaultActionIdentifier

        guard isMeetingStart, isStartAction,
              let eventIdentifier = userInfo[Self.eventIdentifierKey] as? String else {
            completionHandler()
            return
        }

        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.onStartRecording?(eventIdentifier)
            completionHandler()
        }
    }
}
