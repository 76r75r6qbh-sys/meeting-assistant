@preconcurrency import AVFoundation
import Foundation

/// Combines microphone and system-audio peak levels into the single normalized
/// value the UI meter consumes.
///
/// Phase 1c extraction from `RecordingSession`: the level fields and the
/// `publishCombinedLevelLocked`/`normalizedLevel` logic moved here verbatim.
/// All mutable state is confined to a single serial queue (the caller never
/// touches the fields directly), so this type is `@unchecked Sendable`: the
/// queue provides the synchronization, not the compiler.
final class AudioLevelAggregator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.casablanca.recording.level")
    private let onLevelUpdate: (Double) -> Void
    private let levelPublishInterval = 1.0 / 15.0

    private var latestMicrophoneLevel = 0.0
    private var latestSystemLevel = 0.0
    private var latestDisplayedLevel = 0.0
    private var lastMicrophoneLevelAt = 0.0
    private var lastSystemLevelAt = 0.0
    private var lastLevelPublishAt = 0.0

    init(onLevelUpdate: @escaping (Double) -> Void) {
        self.onLevelUpdate = onLevelUpdate
    }

    func publishMicrophoneLevel(from buffer: AVAudioPCMBuffer) {
        let level = Self.normalizedLevel(from: buffer)
        queue.async { [weak self] in
            guard let self else { return }
            self.latestMicrophoneLevel = level
            self.lastMicrophoneLevelAt = Date().timeIntervalSinceReferenceDate
            self.publishCombinedLevelLocked()
        }
    }

    func publishSystemLevel(from buffer: AVAudioPCMBuffer) {
        let level = Self.normalizedLevel(from: buffer)
        queue.async { [weak self] in
            guard let self else { return }
            self.latestSystemLevel = level
            self.lastSystemLevelAt = Date().timeIntervalSinceReferenceDate
            self.publishCombinedLevelLocked()
        }
    }

    /// Resets the system-audio contribution to silence and republishes. Used
    /// when system audio is toggled off mid-recording.
    func resetSystemLevel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestSystemLevel = 0
            self.lastSystemLevelAt = 0
            self.publishCombinedLevelLocked()
        }
    }

    private func publishCombinedLevelLocked() {
        let now = Date().timeIntervalSinceReferenceDate
        let activeMicrophoneLevel = now - lastMicrophoneLevelAt < 0.25 ? latestMicrophoneLevel : 0
        let activeSystemLevel = now - lastSystemLevelAt < 0.25 ? latestSystemLevel : 0
        let combinedLevel = max(activeMicrophoneLevel, activeSystemLevel)

        // Smooth the decay so the bars stay readable between adjacent buffers.
        latestDisplayedLevel = max(combinedLevel, latestDisplayedLevel * 0.8)
        if latestDisplayedLevel < 0.02 {
            latestDisplayedLevel = 0
        }

        guard now - lastLevelPublishAt >= levelPublishInterval else {
            return
        }

        lastLevelPublishAt = now
        onLevelUpdate(latestDisplayedLevel)
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.frameLength > 0 else {
            return 0
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData?.pointee else {
                return 0
            }
            return normalizedPeakLevel(
                from: UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
            )
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData?.pointee else {
                return 0
            }
            let peak = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
                .reduce(0.0) { current, sample in
                    max(current, Double(Int(sample).magnitude) / Double(Int16.max))
                }
            return normalizedPeakLevel(fromUnitPeak: peak)
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData?.pointee else {
                return 0
            }
            let peak = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
                .reduce(0.0) { current, sample in
                    max(current, Double(sample.magnitude) / Double(Int32.max))
                }
            return normalizedPeakLevel(fromUnitPeak: peak)
        default:
            return 0
        }
    }

    private static func normalizedPeakLevel<T: BinaryFloatingPoint>(from samples: UnsafeBufferPointer<T>) -> Double {
        let peak = samples.reduce(0.0) { current, sample in
            max(current, Double(abs(sample)))
        }
        return normalizedPeakLevel(fromUnitPeak: peak)
    }

    private static func normalizedPeakLevel(fromUnitPeak peak: Double) -> Double {
        guard peak > 0 else {
            return 0
        }

        let decibels = 20 * log10(peak)
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
