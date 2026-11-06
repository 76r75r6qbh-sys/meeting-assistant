import CryptoKit
import Foundation

/// A saved voice: biometric personal data (GDPR/AVG art. 9). Lives only in
/// the sealed profiles file, never in a meeting or a sidecar.
struct VoiceProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// L2-normalised mean of the embeddings saved under this name.
    var centroid: [Float]
    var sampleCount: Int
    /// When consent was last confirmed (the latest save).
    var consentedAt: Date
    var createdAt: Date
}

/// The opt-in voice profiles, on this Mac only: the whole JSON array is sealed
/// with AES-GCM (key in the keychain, see `KeychainSymmetricKeyStore`) and
/// written atomically with file protection.
///
/// Reading without a file touches no key, so a user who never saved a profile
/// never gets a keychain item.
final class VoiceProfileStore {
    enum StoreError: Error, Equatable {
        case consentRequired, emptyEmbedding
    }

    let fileURL: URL
    private let keyStore: SymmetricKeyStoring

    init(
        fileURL: URL = VoiceProfileStore.defaultFileURL,
        keyStore: SymmetricKeyStoring = KeychainSymmetricKeyStore()
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
    }

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Casablanca/VoiceProfiles/profiles.sealed")
    }

    func all() throws -> [VoiceProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: fileURL))
        let json = try AES.GCM.open(sealed, using: keyStore.loadOrCreateKey())
        return try JSONDecoder().decode([VoiceProfile].self, from: json)
    }

    /// Saves `embedding` under `name`. An existing profile with that name
    /// (case-insensitive) gets the new embedding folded into its centroid as a
    /// normalised running mean; a profile of another dimension (a different
    /// embedding model) starts over from this embedding.
    @discardableResult
    func save(name: String, embedding: [Float], consentGiven: Bool, now: Date = .now) throws -> VoiceProfile {
        guard consentGiven else { throw StoreError.consentRequired }
        guard let normalised = Self.l2Normalised(embedding) else { throw StoreError.emptyEmbedding }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        var profiles = try all()
        let saved: VoiceProfile
        if let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            var profile = profiles[index]
            if profile.centroid.count == normalised.count {
                let count = Float(profile.sampleCount)
                let mean = zip(profile.centroid, normalised).map { ($0 * count + $1) / (count + 1) }
                profile.centroid = Self.l2Normalised(mean) ?? normalised
                profile.sampleCount += 1
            } else {
                profile.centroid = normalised
                profile.sampleCount = 1
            }
            profile.consentedAt = now
            profiles[index] = profile
            saved = profile
        } else {
            saved = VoiceProfile(id: UUID(), name: trimmed, centroid: normalised, sampleCount: 1, consentedAt: now, createdAt: now)
            profiles.append(saved)
        }
        try write(profiles)
        return saved
    }

    func delete(id: UUID) throws {
        var profiles = try all()
        profiles.removeAll { $0.id == id }
        try write(profiles)
    }

    /// Removes the file and the key: nothing of the profiles is left.
    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try keyStore.deleteKey()
    }

    private func write(_ profiles: [VoiceProfile]) throws {
        let json = try JSONEncoder().encode(profiles)
        guard let combined = try AES.GCM.seal(json, using: keyStore.loadOrCreateKey()).combined else {
            // Only nil for a nonce that is not 12 bytes; the default nonce is.
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    static func l2Normalised(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }
}

extension VoiceProfileStore.StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .consentRequired: return "A voice profile needs the person\u{2019}s explicit consent."
        case .emptyEmbedding: return "No usable speech was found for this speaker."
        }
    }
}
