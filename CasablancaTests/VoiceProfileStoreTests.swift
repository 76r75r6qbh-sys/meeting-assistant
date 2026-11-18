import CryptoKit
import XCTest
@testable import Casablanca

/// A key store that never touches the keychain: one random key per instance,
/// and a record of `deleteKey` calls.
final class InMemoryKeyStore: SymmetricKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var _deleteKeyCalls = 0

    var deleteKeyCalls: Int { lock.withLock { _deleteKeyCalls } }

    func loadOrCreateKey() throws -> SymmetricKey {
        lock.withLock {
            if let key { return key }
            let created = SymmetricKey(size: .bits256)
            key = created
            return created
        }
    }

    func deleteKey() throws {
        lock.withLock {
            _deleteKeyCalls += 1
            key = nil
        }
    }
}

/// A Bool the test flips while a store or an enrollment is running.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
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

    private func makeStore(keyStore: InMemoryKeyStore = InMemoryKeyStore(), enabled: LockedFlag = LockedFlag(true)) -> VoiceProfileStore {
        VoiceProfileStore(fileURL: fileURL, keyStore: keyStore, isEnabled: { enabled.value })
    }

    func testSaveRequiresConsent() throws {
        let store = makeStore()

        XCTAssertThrowsError(try store.save(name: "Kim", embedding: [1, 0], consentGiven: false, now: now)) { error in
            XCTAssertEqual(error as? VoiceProfileStore.StoreError, .consentRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Nothing is written without consent")
    }

    func testRoundTrip() throws {
        let keyStore = InMemoryKeyStore()
        let store = makeStore(keyStore: keyStore)

        let saved = try store.save(name: "Kim Owen-Jones", embedding: [3, 4], consentGiven: true, now: now)

        XCTAssertEqual(saved.name, "Kim Owen-Jones")
        XCTAssertEqual(saved.centroid, [0.6, 0.8], "The centroid is L2-normalised")
        XCTAssertEqual(saved.sampleCount, 1)
        XCTAssertEqual(saved.consentedAt, now)
        XCTAssertEqual(saved.createdAt, now)
        let reopened = makeStore(keyStore: keyStore)
        XCTAssertEqual(try reopened.all(), [saved])
    }

    func testAllIsEmptyWithoutAFile() throws {
        let keyStore = InMemoryKeyStore()
        XCTAssertEqual(try makeStore(keyStore: keyStore).all(), [])
    }

    func testFileIsEncrypted() throws {
        let store = makeStore()
        _ = try store.save(name: "Jeroen van Dijk", embedding: [0.1, 0.2, 0.3], consentGiven: true, now: now)

        let raw = try Data(contentsOf: fileURL)
        XCTAssertFalse(raw.isEmpty)
        XCTAssertNil(raw.range(of: Data("Jeroen van Dijk".utf8)), "The name must not be readable on disk")
        XCTAssertNil(raw.range(of: Data("centroid".utf8)), "The JSON must not be readable on disk")
    }

    func testWrongKeyFailsToOpen() throws {
        let store = makeStore()
        _ = try store.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)

        let other = makeStore()
        XCTAssertThrowsError(try other.all())
    }

    func testSameNameUpdatesNormalisedRunningMean() throws {
        let store = makeStore()
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
        let store = makeStore()
        let kim = try store.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)
        let jeroen = try store.save(name: "Jeroen", embedding: [0, 1], consentGiven: true, now: now)

        try store.delete(id: kim.id)

        XCTAssertEqual(try store.all(), [jeroen])
    }

    func testDeleteAllRemovesFileAndKey() throws {
        let keyStore = InMemoryKeyStore()
        let store = makeStore(keyStore: keyStore)
        _ = try store.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)

        try store.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(keyStore.deleteKeyCalls, 1)
        XCTAssertEqual(try store.all(), [])
    }

    func testEmptyEmbeddingRejected() throws {
        let store = makeStore()

        for embedding: [Float] in [[], [0, 0]] {
            XCTAssertThrowsError(try store.save(name: "Kim", embedding: embedding, consentGiven: true, now: now)) { error in
                XCTAssertEqual(error as? VoiceProfileStore.StoreError, .emptyEmbedding)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveRefusedWhenDisabled() throws {
        let enabled = LockedFlag(true)
        let store = makeStore(enabled: enabled)
        enabled.value = false

        XCTAssertThrowsError(try store.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)) { error in
            XCTAssertEqual(error as? VoiceProfileStore.StoreError, .disabled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEmptyNameRejected() throws {
        let store = makeStore()
        for name in ["", "   \n"] {
            XCTAssertThrowsError(try store.save(name: name, embedding: [1, 0], consentGiven: true, now: now)) { error in
                XCTAssertEqual(error as? VoiceProfileStore.StoreError, .emptyName)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// A file that cannot be opened (another key, damage) is never replaced
    /// by save or delete: that would silently drop every profile in it.
    func testSaveAndDeleteFailClosedOnUnreadableFile() throws {
        let original = makeStore()
        let kim = try original.save(name: "Kim", embedding: [1, 0], consentGiven: true, now: now)
        let before = try Data(contentsOf: fileURL)
        let otherKey = makeStore()

        XCTAssertThrowsError(try otherKey.save(name: "Jeroen", embedding: [0, 1], consentGiven: true, now: now))
        XCTAssertThrowsError(try otherKey.delete(id: kim.id))

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(try original.all(), [kim])
    }
}
