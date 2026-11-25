import Foundation

protocol SafeToQuitProbe: AnyObject {
    @MainActor func reasonInstallShouldWait() -> String?
}

@MainActor
final class ClosureSafeToQuitProbe: SafeToQuitProbe {
    private let isRecordingActive: () -> Bool
    private let isTranscriptionActive: () -> Bool
    private let isSummarizationActive: () -> Bool

    init(
        isRecordingActive: @escaping () -> Bool,
        isTranscriptionActive: @escaping () -> Bool,
        isSummarizationActive: @escaping () -> Bool
    ) {
        self.isRecordingActive = isRecordingActive
        self.isTranscriptionActive = isTranscriptionActive
        self.isSummarizationActive = isSummarizationActive
    }

    func reasonInstallShouldWait() -> String? {
        if isRecordingActive() { return "an active recording" }
        if isTranscriptionActive() { return "an in-flight transcription" }
        if isSummarizationActive() { return "an in-flight summary" }
        return nil
    }
}
