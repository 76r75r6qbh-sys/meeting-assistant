import Foundation
import UserNotifications

@MainActor
final class RecordingNotificationCenter: RecordingInterruptionNotifying {
    private let center: UNUserNotificationCenter
    private let authorization: NotificationAuthorization

    init(
        center: UNUserNotificationCenter = .current(),
        authorization: NotificationAuthorization = .shared
    ) {
        self.center = center
        self.authorization = authorization
    }

    func post(title: String, body: String) {
        post(title: title, body: body, categoryIdentifier: nil, userInfo: [:])
    }

    /// Same, with a category so the notification can carry actions (the Teams
    /// auto-recording "Stop"). The category must be registered by
    /// `AppNotificationCoordinator`.
    func post(title: String, body: String, categoryIdentifier: String?, userInfo: [String: String]) {
        Task { @MainActor in
            // Route through the shared, idempotent gate so the system prompt is
            // requested at most once and never races the auto-record path.
            guard await authorization.ensureAuthorized() else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let categoryIdentifier {
                content.categoryIdentifier = categoryIdentifier
            }
            content.userInfo = userInfo

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
