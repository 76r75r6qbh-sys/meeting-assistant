import AVFoundation
import Foundation
import OSLog

/// Launch-time sweep over the recording-session directories that a crash, a
/// force quit or a failed merge left behind.
///
/// Nine such directories accumulated on the author's Mac before this existed:
/// seven held nothing but an empty `session.json`, one held 130 MB of raw
/// `segment-001.mic.pcm` / `segment-001.system.pcm` that was never mixed down,
/// and one held a finalized `segment-001.wav` the manifest knew about but no
/// merge ever consumed. `scan` names each of those states and
/// `renderOrphanedTracks` / `adoptOrphanedSegments` repair them; the caller
/// (Task 16) reconciles meeting statuses on top.
///
/// The one inviolable rule: **captured audio is never destroyed here.** The
/// only deletions in this file's reach are the two temporary PCM files that
/// `RecordingMixdownRenderer` removes on its own success path, and whatever
/// `RecordingResumeSessionStore.deleteSessionIfEmpty` decides to remove for a
/// `.disposable` finding — a decision it re-verifies against the filesystem.
struct RecordingSessionRecovery {
    enum Finding: Equatable {
        /// Nothing but a manifest (or an empty directory): safe to delete via
        /// `deleteSessionIfEmpty`, and the only finding that may be deleted.
        case disposable(UUID)
        /// Raw PCM tracks whose segment number the manifest does not know.
        /// `renderOrphanedTracks` mixes them into `segment-NNN.wav`.
        ///
        /// `strandedPCM` names segment numbers this sweep can neither render
        /// nor delete, because their `segment-NNN.wav` already carries
        /// samples. They are reported rather than silently dropped so the
        /// caller can surface them for a human to look at.
        case orphanedPCM(UUID, segmentNumbers: [Int], strandedPCM: [Int])
        /// Finalized WAV segments are present — in the manifest, or on disk
        /// waiting for `adoptOrphanedSegments` to put them there.
        /// `strandedPCM` carries the same meaning as above.
        case resumable(UUID, segmentCount: Int, strandedPCM: [Int])
    }

    // MARK: - Scanning

    /// Classifies every session directory. Never mutates anything on disk.
    static func scan(store: RecordingResumeSessionStore) throws -> [Finding] {
        let meetingIDs = try store.meetingIDs()
        Log.recording.notice(
            "Recording recovery scan: \(meetingIDs.count, privacy: .public) session director(ies) to classify"
        )

        // One unreadable directory must not cost us the other eight. The
        // store takes the same stance one level down ("assuming audio is
        // present"): a directory we cannot inspect is reported as resumable
        // with nothing resumable *found*, never as disposable, so the caller
        // keeps it and a human can look.
        var findings: [Finding] = []
        for meetingID in meetingIDs {
            do {
                let inventory = try inventory(for: meetingID, store: store)
                let finding = classify(meetingID: meetingID, inventory: inventory, store: store)
                log(finding, inventory: inventory)
                findings.append(finding)
            } catch {
                Log.recording.notice(
                    "Recording recovery: could not inspect meeting \(meetingID.uuidString, privacy: .public) (\(error.localizedDescription, privacy: .public)); assuming audio is present and keeping the directory"
                )
                findings.append(.resumable(meetingID, segmentCount: 0, strandedPCM: []))
            }
        }
        return findings
    }

    /// A directory holding several kinds of leftovers gets the single most
    /// urgent finding: unrendered PCM first (it is the state that loses audio
    /// if ignored), then finalized segments, and only a directory with no
    /// recoverable byte at all is disposable. Re-scanning after
    /// `renderOrphanedTracks` reports the same directory as `.resumable`.
    private static func classify(
        meetingID: UUID,
        inventory: Inventory,
        store: RecordingResumeSessionStore
    ) -> Finding {
        let strandedSegmentNumbers = inventory.strandedPCMSegmentNumbers
        let orphanedSegmentNumbers = inventory.orphanedPCMSegmentNumbers
        if !orphanedSegmentNumbers.isEmpty {
            return .orphanedPCM(
                meetingID,
                segmentNumbers: orphanedSegmentNumbers,
                strandedPCM: strandedSegmentNumbers
            )
        }

        let segmentCount = inventory.manifestSegmentCount + inventory.adoptableWAVs.count
        if segmentCount > 0 {
            return .resumable(meetingID, segmentCount: segmentCount, strandedPCM: strandedSegmentNumbers)
        }

        // Last line of defence. `hasRecoverableAudio` is deliberately more
        // paranoid than this inventory — it counts a file whose size it cannot
        // even read as audio — so anything it flags is reported as resumable
        // (with nothing to resume yet) rather than handed to the deleter.
        if store.hasRecoverableAudio(for: meetingID) {
            Log.recording.notice(
                "Recording recovery: meeting \(meetingID.uuidString, privacy: .public) holds audio this sweep could not classify; keeping it"
            )
            return .resumable(meetingID, segmentCount: 0, strandedPCM: strandedSegmentNumbers)
        }

        return .disposable(meetingID)
    }

    // MARK: - Repairing

    /// Mixes every orphaned `.mic.pcm` / `.system.pcm` pair into its
    /// `segment-NNN.wav` and records it in the manifest. Returns how many
    /// segments were rendered.
    ///
    /// A missing or system-audio-free track is a valid microphone-only render;
    /// the renderer deletes the two PCM files only after it has written the
    /// WAV, and a segment number whose WAV already carries samples is skipped
    /// rather than overwritten.
    @discardableResult
    static func renderOrphanedTracks(meetingID: UUID, store: RecordingResumeSessionStore) throws -> Int {
        let inventory = try inventory(for: meetingID, store: store)

        // Named before the early return: PCM sitting next to a WAV that
        // already carries samples is skipped by design, and saying nothing
        // about it would let 130 MB of audio go unmentioned forever.
        for segmentNumber in inventory.strandedPCMSegmentNumbers {
            let stem = String(format: "segment-%03d", segmentNumber)
            let wavByteCount = inventory.slots[segmentNumber]?.wavByteCount ?? 0
            Log.recording.notice(
                "Recording recovery: \(stem, privacy: .public).wav already exists with \(wavByteCount, privacy: .public) bytes for meeting \(meetingID.uuidString, privacy: .public); leaving \(stem, privacy: .public).mic.pcm/.system.pcm in place"
            )
        }

        let segmentNumbers = inventory.orphanedPCMSegmentNumbers
        guard !segmentNumbers.isEmpty else {
            Log.recording.notice(
                "Recording recovery: no renderable orphaned PCM tracks for meeting \(meetingID.uuidString, privacy: .public)"
            )
            return 0
        }

        // Before the first render, so a rebuilt manifest can never be the
        // reason an already-rendered WAV fails to be recorded.
        try ensureManifestExists(meetingID: meetingID, inventory: inventory, store: store)

        var renderedCount = 0
        for segmentNumber in segmentNumbers {
            guard let slot = inventory.slots[segmentNumber] else { continue }
            if try renderSegment(segmentNumber: segmentNumber, for: meetingID, slot: slot, store: store) {
                renderedCount += 1
            }
        }

        return renderedCount
    }

    /// Renders one orphaned PCM pair into `segment-NNN.wav` and records it in
    /// the manifest, which must already exist. Returns whether it rendered.
    ///
    /// `internal` rather than private so the never-overwrite guard can be
    /// exercised head-on: reached through `renderOrphanedTracks` the guard is
    /// unreachable by construction (the inventory already filters such
    /// segments out), and a safety guard nothing can test is a safety guard
    /// nobody can trust. It stays in place for the race the inventory cannot
    /// see — a WAV that appears between the listing and the render.
    @discardableResult
    static func renderSegment(
        segmentNumber: Int,
        for meetingID: UUID,
        slot: SegmentSlot,
        store: RecordingResumeSessionStore
    ) throws -> Bool {
        let microphoneFrames = AVAudioFramePosition(slot.microphonePCMByteCount / bytesPerFloatSample)
        let systemAudioFrames = AVAudioFramePosition(slot.systemAudioPCMByteCount / bytesPerFloatSample)
        guard microphoneFrames > 0 || systemAudioFrames > 0 else { return false }

        let directory = try store.sessionDirectory(for: meetingID)
        let outputURL = try store.nextSegmentURL(for: meetingID, segmentNumber: segmentNumber)
        // The renderer starts by removing its output file, so this guard is
        // what stands between a finished recording and deletion. The size is
        // read fresh here, not taken from the inventory.
        if let existingByteCount = fileByteCount(of: outputURL), existingByteCount > wavHeaderByteCount {
            Log.recording.notice(
                "Recording recovery: \(outputURL.lastPathComponent, privacy: .public) already exists with \(existingByteCount, privacy: .public) bytes for meeting \(meetingID.uuidString, privacy: .public); leaving its raw PCM in place"
            )
            return false
        }

        let renderer = RecordingMixdownRenderer(
            microphoneURL: slot.microphonePCM ?? directory.appendingPathComponent(
                String(format: "segment-%03d%@", segmentNumber, Self.microphonePCMSuffix)
            ),
            systemAudioURL: slot.systemAudioPCM ?? directory.appendingPathComponent(
                String(format: "segment-%03d%@", segmentNumber, Self.systemAudioPCMSuffix)
            ),
            microphoneFrames: microphoneFrames,
            systemAudioFrames: systemAudioFrames,
            outputURL: outputURL,
            expectedOutputFrames: max(microphoneFrames, systemAudioFrames)
        )
        try renderer.render()

        let duration = Double(max(microphoneFrames, systemAudioFrames)) / sampleRate
        try store.appendSegment(for: meetingID, segmentURL: outputURL, duration: duration)

        Log.recording.notice(
            "Recording recovery: rendered segment \(segmentNumber, privacy: .public) (\(duration, privacy: .public)s) for meeting \(meetingID.uuidString, privacy: .public)"
        )
        return true
    }

    /// Records finalized WAVs that are on disk but absent from the manifest.
    ///
    /// Leaving such a WAV alone would strand it: resuming and merging both
    /// read the manifest, so a segment the manifest never learned about would
    /// never reach a transcript even though its audio survived. Adoption is
    /// pure bookkeeping — it appends a manifest entry and touches no bytes —
    /// and it is idempotent, because an adopted WAV is no longer orphaned.
    @discardableResult
    static func adoptOrphanedSegments(meetingID: UUID, store: RecordingResumeSessionStore) throws -> Int {
        let inventory = try inventory(for: meetingID, store: store)
        guard !inventory.adoptableWAVs.isEmpty else {
            return 0
        }

        try ensureManifestExists(meetingID: meetingID, inventory: inventory, store: store)

        var adoptedCount = 0
        for wavURL in inventory.adoptableWAVs {
            let byteCount = fileByteCount(of: wavURL) ?? 0
            guard byteCount > wavHeaderByteCount else { continue }
            // Our WAVs are always 16 kHz mono Int16 (see `WAVCodec.header`).
            let duration = Double(byteCount - wavHeaderByteCount) / Double(bytesPerInt16Sample) / sampleRate
            try store.appendSegment(for: meetingID, segmentURL: wavURL, duration: duration)
            adoptedCount += 1
            Log.recording.notice(
                "Recording recovery: adopted \(wavURL.lastPathComponent, privacy: .public) (\(duration, privacy: .public)s) into the manifest of meeting \(meetingID.uuidString, privacy: .public)"
            )
        }
        return adoptedCount
    }

    // MARK: - Inventory

    /// One segment number's files. `internal` so `renderSegment` can be
    /// called head-on from tests.
    struct SegmentSlot {
        var microphonePCM: URL?
        var microphonePCMByteCount = 0
        var systemAudioPCM: URL?
        var systemAudioPCMByteCount = 0
        var wavByteCount = 0

        init(
            microphonePCM: URL? = nil,
            microphonePCMByteCount: Int = 0,
            systemAudioPCM: URL? = nil,
            systemAudioPCMByteCount: Int = 0,
            wavByteCount: Int = 0
        ) {
            self.microphonePCM = microphonePCM
            self.microphonePCMByteCount = microphonePCMByteCount
            self.systemAudioPCM = systemAudioPCM
            self.systemAudioPCMByteCount = systemAudioPCMByteCount
            self.wavByteCount = wavByteCount
        }

        var holdsPCMAudio: Bool { microphonePCMByteCount > 0 || systemAudioPCMByteCount > 0 }
        var wavHoldsAudio: Bool { wavByteCount > RecordingSessionRecovery.wavHeaderByteCount }
    }

    private struct Inventory {
        var manifest: PersistedRecordingSession?
        var slots: [Int: SegmentSlot] = [:]
        /// Non-empty WAVs the manifest does not mention, ascending by name.
        var adoptableWAVs: [URL] = []

        var manifestSegmentCount: Int { manifest?.segments.count ?? 0 }
        var manifestIndices: Set<Int> { Set(manifest?.segments.map(\.index) ?? []) }

        /// Segment numbers with raw PCM the manifest does not know about, and
        /// whose WAV slot is free — a slot already holding samples is somebody
        /// else's finished audio and is never rendered over.
        var orphanedPCMSegmentNumbers: [Int] {
            let known = manifestIndices
            return slots
                .filter { segmentNumber, slot in
                    guard !known.contains(segmentNumber) else { return false }
                    guard !slot.wavHoldsAudio else { return false }
                    return slot.holdsPCMAudio
                }
                .keys
                .sorted()
        }

        /// Segment numbers holding raw PCM this sweep can neither render (the
        /// WAV slot is occupied by real samples) nor delete (the PCM may be
        /// audio the WAV does not contain). Reported so they cannot go
        /// unnoticed; whether the manifest knows the WAV is irrelevant.
        var strandedPCMSegmentNumbers: [Int] {
            slots
                .filter { _, slot in slot.wavHoldsAudio && slot.holdsPCMAudio }
                .keys
                .sorted()
        }
    }

    /// Reads the manifest and every file in the directory into one picture.
    ///
    /// A file whose size cannot be read counts as 0 bytes here, which only
    /// ever makes this sweep do *less* (no render, no adoption); the
    /// never-delete decision is taken by `hasRecoverableAudio`, which treats
    /// the same file as audio-bearing.
    private static func inventory(
        for meetingID: UUID,
        store: RecordingResumeSessionStore
    ) throws -> Inventory {
        var inventory = Inventory()
        inventory.manifest = manifest(for: meetingID, store: store)

        let manifestIndices = inventory.manifestIndices
        let manifestFileNames = Set(
            (inventory.manifest?.segments ?? []).map { URL(fileURLWithPath: $0.filePath).lastPathComponent }
        )

        for file in try store.sessionFiles(for: meetingID) {
            let fileName = file.lastPathComponent
            let byteCount = fileByteCount(of: file) ?? 0
            let segmentNumber = Self.segmentNumber(inFileName: fileName)

            if fileName.hasSuffix(microphonePCMSuffix), let segmentNumber {
                var slot = inventory.slots[segmentNumber] ?? SegmentSlot()
                slot.microphonePCM = file
                slot.microphonePCMByteCount = byteCount
                inventory.slots[segmentNumber] = slot
            } else if fileName.hasSuffix(systemAudioPCMSuffix), let segmentNumber {
                var slot = inventory.slots[segmentNumber] ?? SegmentSlot()
                slot.systemAudioPCM = file
                slot.systemAudioPCMByteCount = byteCount
                inventory.slots[segmentNumber] = slot
            } else if file.pathExtension.lowercased() == "wav" {
                if let segmentNumber {
                    var slot = inventory.slots[segmentNumber] ?? SegmentSlot()
                    slot.wavByteCount = byteCount
                    inventory.slots[segmentNumber] = slot
                }
                // Matched by name *and* by index: a manifest written before a
                // folder move still points at the segment it recorded.
                let inManifest = manifestFileNames.contains(fileName)
                    || segmentNumber.map(manifestIndices.contains) == true
                if byteCount > wavHeaderByteCount, !inManifest {
                    inventory.adoptableWAVs.append(file)
                }
            }
        }

        inventory.adoptableWAVs.sort { $0.lastPathComponent < $1.lastPathComponent }
        return inventory
    }

    /// The manifest, or `nil` when it is missing *or* unreadable. An
    /// unreadable manifest is not a reason to give up on the directory: the
    /// audio files in it are the authority, so recovery classifies by files
    /// and rebuilds the manifest around them.
    private static func manifest(
        for meetingID: UUID,
        store: RecordingResumeSessionStore
    ) -> PersistedRecordingSession? {
        do {
            return try store.loadSession(for: meetingID)
        } catch {
            Log.recording.notice(
                "Recording recovery: unreadable manifest for meeting \(meetingID.uuidString, privacy: .public) (\(error.localizedDescription, privacy: .public)); classifying by files on disk"
            )
            return nil
        }
    }

    private static func ensureManifestExists(
        meetingID: UUID,
        inventory: Inventory,
        store: RecordingResumeSessionStore
    ) throws {
        guard inventory.manifest == nil else { return }

        let systemAudioSeen = inventory.slots.values.contains { $0.systemAudioPCM != nil }
        Log.recording.notice(
            "Recording recovery: rebuilding the missing manifest of meeting \(meetingID.uuidString, privacy: .public)"
        )
        try store.createSession(
            for: meetingID,
            systemAudioEnabled: systemAudioSeen,
            selectedInputDeviceID: nil
        )
    }

    // MARK: - Logging

    private static func log(_ finding: Finding, inventory: Inventory) {
        switch finding {
        case let .disposable(meetingID):
            Log.recording.notice(
                "Recording recovery: meeting \(meetingID.uuidString, privacy: .public) is disposable (no recoverable audio)"
            )
        case let .orphanedPCM(meetingID, segmentNumbers, strandedPCM):
            Log.recording.notice(
                "Recording recovery: meeting \(meetingID.uuidString, privacy: .public) has unrendered PCM for segment(s) \(list(segmentNumbers), privacy: .public), stranded PCM for segment(s) \(list(strandedPCM), privacy: .public)"
            )
        case let .resumable(meetingID, segmentCount, strandedPCM):
            Log.recording.notice(
                "Recording recovery: meeting \(meetingID.uuidString, privacy: .public) is resumable with \(segmentCount, privacy: .public) segment(s), \(inventory.adoptableWAVs.count, privacy: .public) of them not yet in the manifest, stranded PCM for segment(s) \(list(strandedPCM), privacy: .public)"
            )
        }
    }

    private static func list(_ segmentNumbers: [Int]) -> String {
        segmentNumbers.isEmpty ? "none" : segmentNumbers.map(String.init).joined(separator: ",")
    }

    // MARK: - Constants

    /// Matches `WAVCodec.header`: 16 kHz mono, 16-bit.
    private static let sampleRate = 16_000.0
    private static let bytesPerFloatSample = MemoryLayout<Float>.size
    private static let bytesPerInt16Sample = MemoryLayout<Int16>.size
    /// A WAV at or below its canonical 44-byte RIFF header carries no samples.
    private static let wavHeaderByteCount = 44
    private static let microphonePCMSuffix = ".mic.pcm"
    private static let systemAudioPCMSuffix = ".system.pcm"
    private static let segmentFileNamePrefix = "segment-"

    /// Parses the number out of `segment-007.wav`, `segment-007.mic.pcm`, …
    private static func segmentNumber(inFileName fileName: String) -> Int? {
        guard fileName.hasPrefix(segmentFileNamePrefix) else { return nil }
        let digits = fileName
            .dropFirst(segmentFileNamePrefix.count)
            .prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// The file's size in bytes, or `nil` when it cannot be determined.
    private static func fileByteCount(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.size] as? Int
    }
}
