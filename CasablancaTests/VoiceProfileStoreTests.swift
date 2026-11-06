import CryptoKit
import XCTest
@testable import Casablanca

/// A key store that never touches the keychain: one random key per instance,
/// and a record of `deleteKey` calls.
final class InMemoryKeyStore: SymmetricKeyStoring {
    private var key: SymmetricKey?
    private(set) var deleteKeyCalls = 0

    func loadOrCreateKey() throws -> SymmetricKey {
        if let key { return key }
        let created = SymmetricKey(size: .bits256)
        key = created
        return created
    }

    func deleteKey() throws {
        deleteKeyCalls += 1
        key = nil
    }
}

final class VoiceProfileStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("VoiceProfiles/profiles.sealed")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSaveRequiresConsent() throws {
        let store = VoiceProfileStore(fileURL: fileURL, keyStore: InMemoryKeyStore())

        XCTAssertThrowsError(try store.save(name: "Kim", embedding: [1, 0], consentGiven: false, now: now)) { error in
            XCTAssertEqual(error as? VoiceProfileStore.StoreError, .consentRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Nothing is written without consent")
    }

    func testRoundTrip() throws {
        let keyStore = InMemoryKeyStore()
        let store = VoiceProfileStore(fileURL: fileURL, keyStore: keyStore)

        let saved = try store.save(name: "Kim Owen-Jones", embedding: [3, 4], consentGiven: true, now: now)

        XCTAssertEqual(saved.name, "Kim Owen-Jones")
        XCTAssertEqual(saved.centroid, [0.6, 0.8], "The centroid is L2-normalised")
        XCTAssertEqual(saved.sampleCount, 1)
        XCTAssertEqual(saved.consentedAt, now)
        XCTAssertEqual(saved.createdAt, now)
        let reopened = VoiceProfileStore(fileURL: fileURL, keyStore: keyStore)
        XCTAssertEqual(try reopened.all(), [saved])
    }

    func testAllIsEmptyWithoutAFile() throws {
        let keyStore = InMemoryKeyStore()
        XCTAssertEqual(try VoiceProfileStore(fileURL: fileURL, keyStore: keyStore).all(), [])
    }

    func testFileIsEncrypted() throws {
        let store = VoiceProfileStore(fileURL: fileURL, keyStore: InMemoryKeyStore())
        _ = try store.save(name: "Jeroen van Dijk", embedding: [0.1, 0.2, 0.3], consentGiven: true, now: now)

        let raw = try Data(contentsOf: fileURL)
        XCTAssertFalse(raw.isEmpty)
        XCTAssertNil(raw.range(of: Data("Jeroen van Dijk".utf8)), "The name must not be readable on disk")
        XCTAssertNil(raw.range(of: Data("centroid".utf8)), "The JSON must not be readable on disk")
    }

    func testWrongKeyFailsToOpen() throws {
        let store = VoiceProfileStore(fileURL: fileURL, keyStore: InMemoryKeyStore())
        _ = try store.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)

        let other = VoiceProfileStore(fileURL: fileURL, keyStore: InMemoryKeyStore())
        XCTAssertThrowsError(try other.all())
    }

    func testSameNameUpdatesNormalisedRunningMean() throws {
        let store = VoiceProfileStore(fileURL: fileURL, keyStore: InMemoryKeyStore())
        let first = try store.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)
        let later = now.addingTimeInterval(60)

        let second = try store.save(name: "kim", embedding: [0, 1], consentGiven: true, now: later)

        XCTAssertEqual(second.id, first.id, "A case-insensitive name match updates the profile")
        XCTAssertEqual(second.name, "Kim")
        XCTAssertEqual(second.sampleCount, 2)
        XCTAssertEqual(second.centroid[0], Float(0.5).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(second.centroid[1], Float(0.5).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(second.createdAt, now)
        XCTAssertEqual(second.consentedAt, later)

        let third = try store.save(name: "KIM", embedding: [0, 1], consentGiven: true, now: later)
        // The stored centroid (normalised) weighs `sampleCount`:
        // (2 · [s, s] + [0, 1]) / 3, normalised, with s = √½.
        let s = Float(0.5).squareRoot()
        let mean = [2 * s / 3, (2 * s + 1) / 3]
        let norm = (mean[0] * mean[0] + mean[1] * mean[1]).squareRoot()
        XCTAssertEqual(third.sampleCount, 3)
        XCTAssertEqual(third.centroid[0], mean[0] / norm, accuracy: 1e-5)
        XCTAssertEqual(third.centroid[1], mean[1] / norm, accuracy: 1e-5)
        XCTAssertEqual(try store.all().count, 1)
    }

    func testDeleteOne() throws {
        let store = VoiceProfileStore(fileURL: fileURL, keyStore: InMemoryKeyStore())
        let kim = try store.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)
        let jeroen = try store.save(name: "Jeroen", embedding: [0, 1], consentGiven: true, now: now)

        try store.delete(id: kim.id)

        XCTAssertEqual(try store.all(), [jeroen])
    }

    func testDeleteAllRemovesFileAndKey() throws {
        let keyStore = InMemoryKeyStore()
        let store = VoiceProfileStore(fileURL: fileURL, keyStore: keyStore)
        _ = try store.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)

        try store.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(keyStore.deleteKeyCalls, 1)
        XCTAssertEqual(try store.all(), [])
    }

    func testEmptyEmbeddingRejected() throws {
        let store = VoiceProfileStore(fileURL: fileURL, keyStore: InMemoryKeyStore())

        for embedding: [Float] in [[], [0, 0]] {
            XCTAssertThrowsError(try store.save(name: "Kim", embedding: embedding, consentGiven: true, now: now)) { error in
                XCTAssertEqual(error as? VoiceProfileStore.StoreError, .emptyEmbedding)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
