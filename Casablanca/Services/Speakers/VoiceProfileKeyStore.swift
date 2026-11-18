import CryptoKit
import Foundation
import Security

/// Holds the one symmetric key that seals the voice profiles file. Sendable,
/// so the store can run its keychain access off the main actor.
protocol SymmetricKeyStoring: Sendable {
    /// The stored key, or a new random 256-bit key that is stored first.
    func loadOrCreateKey() throws -> SymmetricKey
    /// Forgets the key. Not finding one is not an error.
    func deleteKey() throws
}

/// The voice profiles key as a generic password in the user's login keychain:
/// this Mac only, never synced to iCloud, readable only while unlocked.
///
/// It uses the file-based login keychain (no `kSecUseDataProtectionKeychain`),
/// which needs no keychain-access-group entitlement, so it also works in the
/// unsigned test host. `service` exists so tests can use their own item.
struct KeychainSymmetricKeyStore: SymmetricKeyStoring {
    static let defaultService = "com.casablanca.app.voiceprofiles"
    static let defaultAccount = "aes-gcm-256"

    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case malformedKey
    }

    let service: String
    let account: String

    init(service: String = KeychainSymmetricKeyStore.defaultService, account: String = KeychainSymmetricKeyStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try load() { return existing }
        let key = SymmetricKey(size: .bits256)
        var attributes = baseQuery
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Casablanca voice profiles key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        // Another caller stored one first: use theirs.
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return key
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func load() throws -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, data.count == 32 else { throw KeychainError.malformedKey }
        return SymmetricKey(data: data)
    }
}
