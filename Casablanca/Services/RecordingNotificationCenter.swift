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
        Task { @MainActor in
            // Route through the shared, idempotent gate so the system prompt is
            // requested at most once and never races the auto-record path.
            guard await authorization.ensureAuthorized() else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
