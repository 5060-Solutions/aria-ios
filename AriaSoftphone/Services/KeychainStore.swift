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
    /// The outcome of a read, telling "not there" apart from "there but
    /// unreadable right now".
    enum ReadResult: Equatable {
        case value(String)
        case notFound
        /// The item exists but cannot be read yet — typically
        /// `errSecInteractionNotAllowed` before the first unlock after a
        /// reboot, when PushKit can still launch the app. Not a reason to
        /// treat the account as gone.
        case unavailable(OSStatus)

        var value: String? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

    /// Read the string value for the given key, or `nil` if absent or
    /// unreadable. Use `read(_:)` where the difference matters.
    static func get(_ key: String) -> String? {
        read(key).value
    }

    static func read(_ key: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .notFound
            }
            return .value(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
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
    static let legacySipPasswordDefaultsKey = "sipPassword_temp"

    /// Migrate any secrets left in `UserDefaults` by older builds into the
    /// Keychain, then scrub them from `UserDefaults`. Safe to call on every
    /// launch — it is a no-op once migration has completed.
    static func migrateLegacyDefaultsIfNeeded() {
        migrateLegacyDefaults(
            defaults: .standard,
            read: { read($0) },
            write: { set($0, forKey: $1) }
        )
    }

    /// The migration with its storage injected, for tests.
    ///
    /// A legacy value is scrubbed from `UserDefaults` only once the Keychain
    /// is known to hold the secret: the write succeeded, or the item was
    /// already there. On a locked first launch the Keychain can be neither
    /// read nor written, and scrubbing then deleted the only copy of the
    /// password. Now the migration just runs again on a later launch.
    static func migrateLegacyDefaults(
        defaults: UserDefaults,
        read: (String) -> ReadResult,
        write: (String, String) -> Bool
    ) {
        func migrate(defaultsKey: String, to key: String) {
            guard let legacy = defaults.string(forKey: defaultsKey), !legacy.isEmpty else { return }
            let safelyStored: Bool
            switch read(key) {
            case .value:
                safelyStored = true
            case .notFound:
                safelyStored = write(legacy, key)
            case .unavailable:
                safelyStored = false
            }
            if safelyStored {
                defaults.removeObject(forKey: defaultsKey)
            }
        }

        // SIP password previously stored under "sipPassword_temp".
        migrate(defaultsKey: legacySipPasswordDefaultsKey, to: sipPasswordKey)
        // JWT previously stored via @AppStorage("jwt") (backed by UserDefaults).
        migrate(defaultsKey: jwtKey, to: jwtKey)

        // Older builds stored every item `WhenUnlocked`. Rewriting a readable
        // item moves it to the class `accessibility(for:)` now assigns; when
        // the device is locked the read fails and this simply runs next time.
        for key in backgroundReadableKeys {
            if case .value(let value) = read(key) {
                _ = write(value, key)
            }
        }
    }
}
