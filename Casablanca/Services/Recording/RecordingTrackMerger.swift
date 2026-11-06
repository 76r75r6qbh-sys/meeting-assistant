import Foundation
import OSLog

/// The per-source speaker tracks merged beside a recording. A source that
/// captured nothing (a mic-only meeting has no system audio) stays `nil`.
struct SpeakerTrackFiles: Equatable {
    var microphone: URL?
    var system: URL?
}

/// Merges the kept per-segment temp tracks (`segment-NNN.mic.kept.pcm`,
/// `segment-NNN.system.kept.pcm`, float32) into one 16 kHz mono 16-bit WAV per
/// source beside the merged recording, aligned sample for sample with it.
///
/// Alignment: for each segment WAV, in the order given (the same order Stop
/// merges the mix in), the authoritative length is the segment's mix length,
/// `(wavBytes − 44) / 2` frames. Each track writes at most that many converted
/// samples of its kept PCM and zero-pads the rest; a missing kept file is all
/// silence. Both tracks are therefore exactly as long as the merged mix, and
/// sample *n* of a track is sample *n* of the mix, across pauses, recovered
/// segments and uneven track lengths. A track whose kept PCM totals 0 bytes
/// over every segment is not written.
enum RecordingTrackMerger {
    /// The merge `AudioRecordingService` runs by default. `nonisolated async`,
    /// so it runs off the main actor, like `RecordingSegmentMerger`. Never
    /// throws: a failed merge is logged, leaves no partial or half-merged track
    /// behind, and returns no tracks, because the speaker tracks are an
    /// enhancement and must never fail the Stop.
    static func mergeInBackground(segmentWAVs: [URL], recordingURL: URL) async -> SpeakerTrackFiles {
        await mergeInBackground(
            segmentWAVs: segmentWAVs,
            recordingURL: recordingURL,
            availableCapacity: RecordingDiskSpace.systemCapacity
        )
    }

    /// `mergeInBackground` with an injectable free-space provider (tests).
    static func mergeInBackground(
        segmentWAVs: [URL],
        recordingURL: URL,
        availableCapacity: RecordingDiskSpace.CapacityProvider
    ) async -> SpeakerTrackFiles {
        do {
            return try merge(segmentWAVs: segmentWAVs, recordingURL: recordingURL, availableCapacity: availableCapacity)
        } catch {
            Log.recording.error(
                "Speaker track merge failed for \(recordingURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public); continuing without speaker tracks"
            )
            return SpeakerTrackFiles()
        }
    }

    /// Writes `<recording>.mic.wav` and `<recording>.system.wav`. Streams in
    /// `chunkFrames` pieces and writes each track to a partial file that is
    /// moved into place, as `RecordingSegmentMerger.merge` does. On failure
    /// every track this call wrote is removed again before rethrowing.
    ///
    /// Free space is checked before each track: below
    /// `RecordingDiskSpace.minimumFreeBytesForSpeakerTracks` no track is
    /// written, any track WAV already beside the recording is removed, and the
    /// result is empty. The mix, already merged, is never touched.
    static func merge(
        segmentWAVs: [URL],
        recordingURL: URL,
        chunkFrames: Int = 65_536,
        availableCapacity: RecordingDiskSpace.CapacityProvider = RecordingDiskSpace.systemCapacity
    ) throws -> SpeakerTrackFiles {
        let mixFrames = try segmentWAVs.map(mixFrameCount(ofSegment:))
        func hasRoom() -> Bool {
            RecordingDiskSpace.allowsSpeakerTracks(at: recordingURL, capacity: availableCapacity)
        }
        guard hasRoom() else { return skipForLowDiskSpace(recordingURL: recordingURL, capacity: availableCapacity) }
        var written: [URL] = []
        do {
            let microphone = try mergeTrack(
                .microphone,
                segmentWAVs: segmentWAVs,
                mixFrames: mixFrames,
                recordingURL: recordingURL,
                chunkFrames: max(1, chunkFrames)
            )
            if let microphone { written.append(microphone) }
            guard hasRoom() else { return skipForLowDiskSpace(recordingURL: recordingURL, capacity: availableCapacity) }
            let system = try mergeTrack(
                .systemAudio,
                segmentWAVs: segmentWAVs,
                mixFrames: mixFrames,
                recordingURL: recordingURL,
                chunkFrames: max(1, chunkFrames)
            )
            return SpeakerTrackFiles(microphone: microphone, system: system)
        } catch {
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// Unity gain, clamped to ±1, scaled by `Int16.max` and rounded: the
    /// mixdown's conversion without its per-source gains. NaN becomes silence.
    static func int16Samples(fromFloat samples: [Float]) -> [Int16] {
        samples.map { sample in
            guard !sample.isNaN else { return 0 }
            let clamped = min(max(sample, -1), 1)
            return Int16((clamped * Float(Int16.max)).rounded())
        }
    }

    // MARK: - Private

    /// Removes every speaker track WAV beside `recordingURL` and returns none.
    private static func skipForLowDiskSpace(
        recordingURL: URL,
        capacity: RecordingDiskSpace.CapacityProvider
    ) -> SpeakerTrackFiles {
        RecordingDiskSpace.noteLowSpace(for: recordingURL.deletingLastPathComponent(), capacity: capacity)
        for kind in [RecordingTrackKind.microphone, .systemAudio] {
            let url = RecordingFiles.speakerTrackURL(forRecording: recordingURL, kind: kind)
            if FileManager.default.fileExists(atPath: url.path) {
                bestEffort("remove speaker track on low disk space", Log.recording) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        return SpeakerTrackFiles()
    }

    private static func mergeTrack(
        _ kind: RecordingTrackKind,
        segmentWAVs: [URL],
        mixFrames: [Int],
        recordingURL: URL,
        chunkFrames: Int
    ) throws -> URL? {
        let fileManager = FileManager.default
        let keptURLs = segmentWAVs.map { keptTrackURL(forSegment: $0, kind: kind) }
        // An unknown size counts as audio: better to try the read and fail
        // loudly than to skip a track that holds speech.
        let holdsAudio = keptURLs.contains { url in
            fileManager.fileExists(atPath: url.path) && (RecordingFiles.byteCount(of: url) ?? 1) > 0
        }
        guard holdsAudio else { return nil }

        let outputURL = RecordingFiles.speakerTrackURL(forRecording: recordingURL, kind: kind)
        let partialURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).partial")
        guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partialURL.path])
        }

        do {
            let output = try FileHandle(forWritingTo: partialURL)
            defer { try? output.close() }

            try output.write(contentsOf: WAVCodec.header(dataByteCount: 0))
            var totalFrames = 0
            for (keptURL, segmentFrames) in zip(keptURLs, mixFrames) {
                totalFrames += try appendSegment(
                    keptURL: keptURL,
                    mixFrames: segmentFrames,
                    to: output,
                    chunkFrames: chunkFrames
                )
            }
            try output.seek(toOffset: 0)
            try output.write(contentsOf: WAVCodec.header(dataByteCount: totalFrames * MemoryLayout<Int16>.size))
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }

        do {
            if fileManager.fileExists(atPath: outputURL.path) {
                _ = try fileManager.replaceItemAt(outputURL, withItemAt: partialURL)
            } else {
                try fileManager.moveItem(at: partialURL, to: outputURL)
            }
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }
        return outputURL
    }

    /// Writes exactly `mixFrames` frames for one segment: the kept track's
    /// samples, truncated to the mix length, then silence. Returns `mixFrames`.
    private static func appendSegment(
        keptURL: URL,
        mixFrames: Int,
        to output: FileHandle,
        chunkFrames: Int
    ) throws -> Int {
        var remaining = mixFrames
        if FileManager.default.fileExists(atPath: keptURL.path) {
            let input = try FileHandle(forReadingFrom: keptURL)
            defer { try? input.close() }

            // An unknown size fails the merge, matching `holdsAudio`, where an
            // unknown size counts as audio: never silently turn speech into
            // silence.
            guard let keptByteCount = RecordingFiles.byteCount(of: keptURL) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: keptURL.path])
            }
            let trackFrames = keptByteCount / MemoryLayout<Float>.size
            var toRead = min(trackFrames, mixFrames)
            while toRead > 0 {
                guard let data = try input.read(upToCount: min(chunkFrames, toRead) * MemoryLayout<Float>.size),
                      !data.isEmpty
                else { break }
                let converted = int16Samples(fromFloat: TemporaryRecordingPCMStorage.samples(from: data))
                guard !converted.isEmpty else { break }
                try output.write(contentsOf: converted.withUnsafeBufferPointer { Data(buffer: $0) })
                toRead -= converted.count
                remaining -= converted.count
            }
        }

        while remaining > 0 {
            let frames = min(chunkFrames, remaining)
            try output.write(contentsOf: Data(count: frames * MemoryLayout<Int16>.size))
            remaining -= frames
        }
        return mixFrames
    }

    /// The segment's length in the merged mix: its whole Int16 samples behind
    /// the canonical header, exactly what `RecordingSegmentMerger` copies.
    private static func mixFrameCount(ofSegment url: URL) throws -> Int {
        guard let byteCount = RecordingFiles.byteCount(of: url) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return max(0, byteCount - WAVCodec.headerByteCount) / MemoryLayout<Int16>.size
    }

    /// `segment-007.wav` → `segment-007.mic.kept.pcm` / `segment-007.system.kept.pcm`.
    private static func keptTrackURL(forSegment segmentURL: URL, kind: RecordingTrackKind) -> URL {
        RecordingFiles.keptTrackURL(
            for: segmentURL
                .deletingPathExtension()
                .appendingPathExtension(RecordingFiles.trackSuffix(for: kind))
                .appendingPathExtension("pcm")
        )
    }
}
