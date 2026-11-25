import CryptoKit
import Security
import XCTest
@testable import Casablanca

/// Runs against the real (file-based login) keychain, under a service unique
/// to this run, so it never touches `com.casablanca.app.voiceprofiles`.
final class VoiceProfileKeyStoreTests: XCTestCase {
    private var keyStore: KeychainSymmetricKeyStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        keyStore = KeychainSymmetricKeyStore(service: "com.casablanca.tests.voiceprofiles.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? keyStore?.deleteKey()
        try super.tearDownWithError()
    }

    func testLoadOrCreateIsStable() throws {
        XCTAssertNotEqual(keyStore.service, KeychainSymmetricKeyStore.defaultService)
        let first: SymmetricKey
        do {
            first = try keyStore.loadOrCreateKey()
        } catch KeychainSymmetricKeyStore.KeychainError.unexpectedStatus(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("The test host has no keychain access (errSecMissingEntitlement)")
        }
        let second = try keyStore.loadOrCreateKey()

        XCTAssertEqual(first.bitCount, 256)
        XCTAssertEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })

        try keyStore.deleteKey()
        let third = try keyStore.loadOrCreateKey()
        XCTAssertNotEqual(first.withUnsafeBytes { Data($0) }, third.withUnsafeBytes { Data($0) }, "deleteKey forgets the key")
    }

    func testDefaultAttributesArePinned() {
        let store = KeychainSymmetricKeyStore()
        XCTAssertEqual(store.service, "com.casablanca.app.voiceprofiles")
        XCTAssertEqual(store.account, "aes-gcm-256")
    }
}
