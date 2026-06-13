import SwiftUI

/// Pure presentation model for the onboarding permissions step's capture banner.
///
/// Encodes the graceful-degradation rule: microphone is the only hard
/// requirement to record. Screen Recording (which backs system-audio capture)
/// is optional — without it, Casablanca records microphone-only, so it captures
/// your own voice but not the other participants. Onboarding never blocks on a
/// denied Screen Recording grant.
struct OnboardingCaptureStatus: Equatable {
    let microphoneGranted: Bool
    let screenCaptureGranted: Bool

    /// True when a recording can be started at all (microphone is mandatory).
    var canRecord: Bool { microphoneGranted }

    /// True when only the microphone is available, so the other side of the
    /// conversation will not be captured.
    var isMicrophoneOnly: Bool { microphoneGranted && !screenCaptureGranted }

    /// True when both your voice and the other participants will be captured.
    var capturesAllParticipants: Bool { microphoneGranted && screenCaptureGranted }

    var title: String {
        if !microphoneGranted {
            return "Microphone needed to record"
        }
        if screenCaptureGranted {
            return "Full capture ready"
        }
        return "Microphone-only recording"
    }

    var detail: String {
        if !microphoneGranted {
            return "Grant Microphone above to record meetings. The other permissions are optional."
        }
        if screenCaptureGranted {
            return "Both your microphone and the other participants' audio will be recorded."
        }
        return "You can record now — but without Screen Recording, only your own microphone is captured, not the other participants. Grant it above for full meeting audio."
    }

    var symbol: String {
        if !microphoneGranted { return "exclamationmark.triangle.fill" }
        if screenCaptureGranted { return "checkmark.circle.fill" }
        return "info.circle.fill"
    }

    var tint: Color {
        if !microphoneGranted { return .accentWarning }
        if screenCaptureGranted { return .accentSuccess }
        return .accentPrimary
    }
}
