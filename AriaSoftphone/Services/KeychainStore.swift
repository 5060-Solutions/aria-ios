import Foundation
import Security

/// Secure, device-only storage for secrets (SIP password, JWT session token).
///
/// Backed by the iOS Keychain (`kSecClassGenericPassword`) with a
/// `ThisDeviceOnly` accessibility class, so values are encrypted at rest,
/// never synced to iCloud, and excluded from device backups.
///
/// Most items are `WhenUnlocked`. The few the app needs to answer a VoIP push
/// on a locked phone — the SIP password, the gateway token and the push token —
/// are `AfterFirstUnlock`: PushKit can launch the app while the device is
/// locked, and an item it cannot read there means the call is never fetched.
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

    /// Push-gateway credential returned by `POST /api/v1/devices/register`.
    static let gatewayTokenKey = "gatewayToken"

    /// The most recent VoIP push token, so a cold launch can register with
    /// the gateway before PushKit redelivers it.
    static let pushTokenKey = "voipPushToken"

    /// Items read while handling a push, possibly before the user unlocks.
    private static let backgroundReadableKeys: Set<String> = [
        sipPasswordKey, gatewayTokenKey, pushTokenKey,
    ]

    private static func accessibility(for key: String) -> CFString {
        backgroundReadableKeys.contains(key)
            ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

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
            kSecAttrAccessible as String: accessibility(for: key),
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            // Item does not exist yet — add it.
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibility(for: key)
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

        // Older builds stored every item `WhenUnlocked`. Rewriting a readable
        // item moves it to the class `accessibility(for:)` now assigns; when
        // the device is locked the read fails and this simply runs next time.
        for key in backgroundReadableKeys {
            if let value = get(key) {
                set(value, forKey: key)
            }
        }
    }
}
