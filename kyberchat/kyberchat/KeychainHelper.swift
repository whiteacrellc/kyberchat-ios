import Foundation
import Security

/// A lightweight wrapper around the iOS Security framework for storing,
/// reading, and deleting generic password items in the Keychain.
///
/// All items are stored under the service identifier "kyberchat".
/// Access is synchronous — call from a background Task or actor when used
/// from async contexts to avoid blocking the main thread.
enum KeychainHelper {

    private static let service = "kyberchat"

    // MARK: - String convenience

    /// Saves a UTF-8 string to the Keychain under the given account key.
    /// Overwrites any existing value for the same account.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(data, account: account)
    }

    /// Reads a stored string from the Keychain. Returns `nil` if not found.
    static func read(account: String) -> String? {
        guard let data = readData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Data (raw bytes — for cryptographic key material)

    /// Saves raw `Data` to the Keychain under the given account key.
    /// Overwrites any existing value for the same account.
    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        // Delete any existing item first to ensure clean overwrite
        delete(account: account)

        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account,
            kSecValueData:       data,
            // Accessible after first device unlock — survives app restarts and
            // background wake-ups, but not device wipe or iCloud restore without
            // explicit key migration.
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Reads raw `Data` from the Keychain. Returns `nil` if not found.
    static func readData(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Deletes the Keychain item for the given account. Safe to call even if
    /// the item does not exist.
    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  service,
            kSecAttrAccount:  account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Bulk operations

    /// Removes all kyberchat Keychain items. Called on logout.
    static func deleteAll() {
        for account in KeychainAccount.allCases {
            delete(account: account.rawValue)
        }
    }
}

// MARK: - Well-known Keychain account keys

/// Centralised enum of all Keychain account strings used by the app.
/// Using typed constants prevents typos and makes auditing easy.
enum KeychainAccount: String, CaseIterable {
    /// PASETO auth token — opaque string, 7-day expiry
    case authToken          = "authToken"
    /// The 64-byte BIP39 master seed (raw bytes)
    case masterSeed         = "masterSeed"
    /// X25519 identity private key (32 bytes, raw representation)
    case identityPrivateKey = "identityPrivateKey"
    /// Ed25519 signing private key (32 bytes, raw representation)
    case signingPrivateKey  = "signingPrivateKey"
    /// Current Signed Pre-Key private key (32 bytes)
    case signedPreKeyPrivate = "signedPreKeyPrivate"
    /// Current Signed Pre-Key ID (stored as UTF-8 integer string)
    case signedPreKeyId     = "signedPreKeyId"
    /// ML-KEM-768 private key seed (64 bytes) — pass to MLKem768.PrivateKey(seed:) from swift-crypto 3.3+.
    /// Re-derivable from masterSeed via HKDF(seed, info:"kyberchat-kem-seed"), but cached here for fast access.
    case kemPrivateKeySeed  = "kemPrivateKeySeed"
}
