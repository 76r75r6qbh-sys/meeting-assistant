import Foundation

/// Produces a small, continuous "still working" creep for a progress value that
/// would otherwise sit frozen between real checkpoints. WhisperKit's VAD
/// segment-discovery callback only fires once per discovered chunk, and a
/// chunk's decode time is not proportional to the audio-time it covers — a
/// single long chunk (or a slow model load) can leave a progress bar looking
/// dead for a long time.
///
/// Bounded well below where the next real checkpoint could land, so it never
/// visually claims progress that hasn't happened: creeps from `current` toward
/// `checkpoint + budget` (capped at `ceiling`), easing a fraction of the
/// remaining distance per call, then holds once it reaches that target. A new,
/// higher `checkpoint` (a real update) immediately raises the target again.
enum ProgressTrickle {
    static func next(
        current: Double,
        checkpoint: Double,
        budget: Double,
        ceiling: Double,
        easing: Double
    ) -> Double {
        let target = min(checkpoint + budget, ceiling)
        guard target > current else { return current }
        return current + (target - current) * easing
    }
}
