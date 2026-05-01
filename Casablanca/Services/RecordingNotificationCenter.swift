import Foundation
import UserNotifications

@MainActor
final class RecordingNotificationCenter: RecordingInterruptionNotifying {
    private let center: UNUserNotificationCenter
    private var didRequestAuthorization = false
    private var isAuthorized = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func post(title: String, body: String) {
        Task { @MainActor in
            await ensureAuthorization()
            guard isAuthorized else { return }

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

    private func ensureAuthorization() async {
        if didRequestAuthorization { return }
        didRequestAuthorization = true
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        isAuthorized = granted
    }
}
