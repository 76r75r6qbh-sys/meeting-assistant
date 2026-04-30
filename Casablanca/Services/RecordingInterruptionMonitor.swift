import Foundation

@MainActor
final class RecordingInterruptionMonitor {
    func setActiveInputDevice(_ deviceID: String?) {}
    func reportStreamFailure(_ error: Error) {}
}
