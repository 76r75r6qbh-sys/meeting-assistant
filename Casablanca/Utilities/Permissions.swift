import AVFoundation
import CoreGraphics
import EventKit

enum ScreenCapturePermissionState: Equatable {
    case granted
    case grantedRequiresRestart
    case denied

    static func resolve(
        preflight: () -> Bool,
        request: () -> Bool
    ) -> ScreenCapturePermissionState {
        if preflight() {
            return .granted
        }

        return request() ? .grantedRequiresRestart : .denied
    }
}

@Observable
final class PermissionsManager {
    var calendarAuthorized = false
    var microphoneAuthorized = false
    var screenCaptureAuthorized = false

    func checkAll() async {
        await checkCalendar()
        await checkMicrophone()
        await checkScreenCapture()
    }

    func checkCalendar() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        await MainActor.run {
            calendarAuthorized = status == .fullAccess
        }
    }

    func checkMicrophone() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        await MainActor.run {
            microphoneAuthorized = status == .authorized
        }
    }

    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            microphoneAuthorized = granted
        }
        return granted
    }

    func checkScreenCapture() async {
        let isAuthorized = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            screenCaptureAuthorized = isAuthorized
        }
    }

    var allGranted: Bool {
        calendarAuthorized && microphoneAuthorized && screenCaptureAuthorized
    }
}
