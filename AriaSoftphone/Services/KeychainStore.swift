import Foundation
import Security

/// Secure, device-only storage for secrets (SIP password, JWT session token).
///
/// Backed by the iOS Keychain (`kSecClassGenericPassword`) with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so values are encrypted at
/// rest, never synced to iCloud, and excluded from device backups.
///
/// This is the single secure store for the app — all credential paths (setup,
/// settings, outgoing/incoming call) read secrets from here rather than
/// `UserDefaults`.
enum KeychainStore {
    /// Fixed service name namespacing all items owned by this helper.
    private static let service = "com.solutions5060.aria.keychain"

    // MARK: - Well-known keys

    /// SIP account password used to authenticate the extension to the registrar.
    static let sipPasswordKey = "sipPassword"

    /// Bearer JWT returned by `POST /api/v1/auth/extension-login`.
    static let jwtKey = "jwt"

    // MARK: - Public API

    /// Store (or overwrite) a string value for the given key.
    /// Passing an empty string removes the item, keeping the store tidy.
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        guard !value.isEmpty else {
            return remove(key)
        }
        guard let data = value.data(using: .utf8) else { return false }

        // Attributes identifying the item.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Try to update an existing item first.
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            // Item does not exist yet — add it.
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }

        return false
    }

    /// Read the string value for the given key, or `nil` if absent.
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Remove the item for the given key. Succeeds if the item is already absent.
    @discardableResult
    static func remove(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - One-time migration off UserDefaults

    /// UserDefaults key previously used to persist the SIP password in cleartext.
    private static let legacySipPasswordDefaultsKey = "sipPassword_temp"

    /// Migrate any secrets left in `UserDefaults` by older builds into the
    /// Keychain, then scrub them from `UserDefaults`. Safe to call on every
    /// launch — it is a no-op once migration has completed.
    static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard

        // SIP password previously stored under "sipPassword_temp".
        if let legacyPassword = defaults.string(forKey: legacySipPasswordDefaultsKey),
           !legacyPassword.isEmpty {
            if get(sipPasswordKey) == nil {
                set(legacyPassword, forKey: sipPasswordKey)
            }
            defaults.removeObject(forKey: legacySipPasswordDefaultsKey)
        }

        // JWT previously stored via @AppStorage("jwt") (backed by UserDefaults).
        if let legacyJwt = defaults.string(forKey: jwtKey), !legacyJwt.isEmpty {
            if get(jwtKey) == nil {
                set(legacyJwt, forKey: jwtKey)
            }
            defaults.removeObject(forKey: jwtKey)
        }
    }
}
