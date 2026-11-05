import AppKit
import Foundation
import OSLog
@preconcurrency import UserNotifications

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
///     action and the `AUTO_RECORDING` "Stop" action; any other category/action
///     is just completed (no routing).
@MainActor
final class AppNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    // Immutable Sendable Strings referenced from the nonisolated delegate methods,
    // so mark them nonisolated to satisfy Swift 6 actor-isolation checking.
    nonisolated static let meetingStartCategoryID = "MEETING_START"
    nonisolated static let startRecordingActionID = "START_RECORDING"
    nonisolated static let dismissActionID = "DISMISS"
    nonisolated static let eventIdentifierKey = "eventIdentifier"
    /// Posted when the Teams monitor started a recording, with a "Stop" action.
    nonisolated static let autoRecordingCategoryID = "AUTO_RECORDING"
    nonisolated static let stopRecordingActionID = "STOP_RECORDING"
    nonisolated static let meetingIDKey = "meetingID"

    /// Invoked with the EKEvent identifier when the user taps "Start Recording".
    /// Wired from `AppModel` to resolve the event and begin recording.
    var onStartRecording: ((String) -> Void)?

    /// Invoked with the meeting ID when the user taps "Stop" on an
    /// auto-recording notification. Wired from `AppModel`.
    var onStopRecording: ((UUID) -> Void)?

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
        // No `.foreground`: stopping must not pull Casablanca in front of the
        // call the user is still looking at.
        let stopRecording = UNNotificationAction(
            identifier: Self.stopRecordingActionID,
            title: "Stop",
            options: []
        )
        let autoRecording = UNNotificationCategory(
            identifier: Self.autoRecordingCategoryID,
            actions: [stopRecording],
            intentIdentifiers: [],
            options: []
        )
        let ours: Set<String> = [Self.meetingStartCategoryID, Self.autoRecordingCategoryID]
        // Merge with any already-registered categories rather than clobbering.
        center.getNotificationCategories { [center] existing in
            var merged = existing.filter { !ours.contains($0.identifier) }
            merged.insert(meetingStart)
            merged.insert(autoRecording)
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

        if categoryID == Self.autoRecordingCategoryID, actionID == Self.stopRecordingActionID,
           let rawMeetingID = userInfo[Self.meetingIDKey] as? String,
           let meetingID = UUID(uuidString: rawMeetingID) {
            let completion = CompletionBox(completionHandler)
            Task { @MainActor in
                // Deliberately no `NSApp.activate`: the user is in a call.
                self.onStopRecording?(meetingID)
                completion.invoke()
            }
            return
        }

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

        // Confine the completion handler in an `@unchecked Sendable` box so it can
        // cross the MainActor hop without tripping the Swift 6 `sending` data-race
        // check. The box is created here and invoked exactly once, on the MainActor.
        let completion = CompletionBox(completionHandler)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.onStartRecording?(eventIdentifier)
            completion.invoke()
        }
    }
}

/// Confines a `UNUserNotificationCenter` completion handler so it can be carried
/// across an actor hop. The handler is only ever invoked once, on the MainActor.
private final class CompletionBox: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func invoke() { handler() }
}
