import Foundation

enum ReviewPrimaryAction: Equatable {
    case transcribe
    case summarize
    case export
}

/// Pure decision for which primary action the review toolbar should surface.
/// Mirrors `RecordedMeetingView.primaryToolbarAction` ordering exactly.
func reviewPrimaryAction(
    hasTranscript: Bool,
    hasRecording: Bool,
    hasSummary: Bool,
    canSummarize: Bool,
    canExport: Bool
) -> ReviewPrimaryAction? {
    if !hasTranscript, hasRecording {
        return .transcribe
    }

    if !hasSummary, canSummarize {
        return .summarize
    }

    if canExport {
        return .export
    }

    return nil
}

extension TimeInterval {
    var formattedRecordingDuration: String {
        let totalSeconds = max(Int(rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }
}
