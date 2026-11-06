import Foundation
import Observation

/// One request to show a moment of a meeting. `token` makes every click a
/// new request, also a repeat click on the same label.
struct TimestampJump: Equatable, Sendable {
    let token: UUID
    let meetingID: UUID
    let seconds: Double
}

/// Carries timestamp-link clicks (summary, to-dos, transcript lines, Ask
/// citations) to whoever shows the meeting:
/// - ContentView selects the meeting;
/// - RecordedMeetingView switches to the transcript tab, which scrolls to the
///   nearest line at or before `seconds` and plays the recording from there,
///   then calls ``complete(_:)``.
/// A meeting that is not completed (recording, transcribing) has no
/// transcript tab, so ContentView only selects it and completes the jump.
@MainActor
@Observable
final class MeetingDetailNavigator {
    static let shared = MeetingDetailNavigator()

    /// The jump not yet carried out, if any. A newer jump replaces it.
    private(set) var pendingJump: TimestampJump?

    init() {}

    /// Requests a jump to `seconds` (clamped to ≥ 0; non-finite counts as 0)
    /// in `meetingID`.
    func jump(to meetingID: UUID, seconds: Double) {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        pendingJump = TimestampJump(token: UUID(), meetingID: meetingID, seconds: clamped)
    }

    /// Marks `jump` as carried out. A stale jump (a newer one is pending)
    /// leaves the newer one in place.
    func complete(_ jump: TimestampJump) {
        if pendingJump?.token == jump.token {
            pendingJump = nil
        }
    }
}

/// Pure rules for carrying out a jump.
enum TimestampJumpPlan {
    /// Index of the last line starting at or before `seconds` (the first of
    /// equal starts); the first line when `seconds` precedes every line;
    /// `nil` without lines. `starts` are in transcript order.
    static func lineIndex(atOrBefore seconds: Double, starts: [Double]) -> Int? {
        guard !starts.isEmpty else { return nil }
        var best: Int?
        for (index, start) in starts.enumerated() where start <= seconds {
            if let current = best, starts[current] == start { continue }
            best = index
        }
        return best ?? 0
    }

    /// Playback only for a completed meeting that is not being
    /// (re)transcribed and whose recording file is on disk. Otherwise a jump
    /// still scrolls, silently.
    static func shouldPlay(status: MeetingStatus, isTranscribing: Bool, hasRecordingFile: Bool) -> Bool {
        status == .completed && !isTranscribing && hasRecordingFile
    }

    /// The meeting's mixed recording when its file exists.
    static func recordingURL(path: String?, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL? {
        guard let path, !path.isEmpty, fileExists(path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Whether `url` is one of the meeting's audio files (mixed recording or
    /// a speaker track), so playback of it belongs to that meeting.
    static func isAudio(_ url: URL, ofPaths paths: [String?]) -> Bool {
        paths.compactMap { $0 }.contains { URL(fileURLWithPath: $0).standardizedFileURL == url.standardizedFileURL }
    }
}
