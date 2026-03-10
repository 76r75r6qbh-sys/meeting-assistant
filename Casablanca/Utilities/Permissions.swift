import AVFoundation
import EventKit
import ScreenCaptureKit

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
        do {
            // Attempting to get shareable content triggers the permission prompt
            // if not yet authorized, and succeeds silently if already authorized
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await MainActor.run {
                screenCaptureAuthorized = true
            }
        } catch {
            await MainActor.run {
                screenCaptureAuthorized = false
            }
        }
    }

    var allGranted: Bool {
        calendarAuthorized && microphoneAuthorized && screenCaptureAuthorized
    }
}
