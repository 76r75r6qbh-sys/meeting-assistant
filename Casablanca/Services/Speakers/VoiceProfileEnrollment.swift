import Foundation

/// "Remember voice…" end to end: consent first, then one embedding of the
/// chosen ranges (cancellable, with a timeout), then the save — off the main
/// actor, since the keychain may prompt. Cancelling the calling task stops
/// the analysis and skips the save.
struct VoiceProfileEnrollment: Sendable {
    static let defaultTimeout: Duration = .seconds(120)

    let diarizer: SpeakerDiarizing
    let store: VoiceProfileStore
    var timeout: Duration = defaultTimeout

    struct TimeoutError: LocalizedError {
        var errorDescription: String? { "Analysing the voice took too long." }
    }

    @discardableResult
    func remember(
        name: String,
        trackURL: URL,
        ranges: [ClosedRange<Double>],
        consentGiven: Bool
    ) async throws -> VoiceProfile {
        // No voice is analysed without consent.
        guard consentGiven else { throw VoiceProfileStore.StoreError.consentRequired }
        let diarizer = self.diarizer
        let timeout = self.timeout
        let embedding = try await withThrowingTaskGroup(of: [Float].self) { group in
            group.addTask { try await diarizer.embedding(trackURL: trackURL, ranges: ranges) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
        try Task.checkCancellation()
        let store = self.store
        return try await Task.detached(priority: .userInitiated) {
            try store.save(name: name, embedding: embedding, consentGiven: consentGiven)
        }.value
    }
}
