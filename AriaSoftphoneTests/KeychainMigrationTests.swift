import XCTest
@testable import AriaSoftphone

final class KeychainMigrationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "KeychainMigrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("legacy-pass", forKey: KeychainStore.legacySipPasswordDefaultsKey)
        defaults.set("legacy-jwt", forKey: KeychainStore.jwtKey)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testLockedKeychainLeavesTheLegacyCopyAlone() {
        var writes: [String] = []
        KeychainStore.migrateLegacyDefaults(
            defaults: defaults,
            read: { _ in .unavailable(errSecInteractionNotAllowed) },
            write: { _, key in writes.append(key); return false }
        )
        XCTAssertEqual(defaults.string(forKey: KeychainStore.legacySipPasswordDefaultsKey), "legacy-pass")
        XCTAssertEqual(defaults.string(forKey: KeychainStore.jwtKey), "legacy-jwt")
        XCTAssertTrue(writes.isEmpty, "wrote over items it could not read: \(writes)")
    }

    func testAFailedWriteKeepsTheLegacyCopy() {
        KeychainStore.migrateLegacyDefaults(defaults: defaults, read: { _ in .notFound }, write: { _, _ in false })
        XCTAssertEqual(defaults.string(forKey: KeychainStore.legacySipPasswordDefaultsKey), "legacy-pass")
    }

    func testMigratesAndScrubsWhenTheWriteSucceeds() {
        var stored: [String: String] = [:]
        KeychainStore.migrateLegacyDefaults(
            defaults: defaults,
            read: { key in stored[key].map { .value($0) } ?? .notFound },
            write: { value, key in stored[key] = value; return true }
        )
        XCTAssertEqual(stored[KeychainStore.sipPasswordKey], "legacy-pass")
        XCTAssertEqual(stored[KeychainStore.jwtKey], "legacy-jwt")
        XCTAssertNil(defaults.string(forKey: KeychainStore.legacySipPasswordDefaultsKey))
        XCTAssertNil(defaults.string(forKey: KeychainStore.jwtKey))
    }

    func testAnExistingKeychainItemWinsAndTheLegacyCopyIsScrubbed() {
        var stored = [KeychainStore.sipPasswordKey: "current"]
        KeychainStore.migrateLegacyDefaults(
            defaults: defaults,
            read: { key in stored[key].map { .value($0) } ?? .notFound },
            write: { value, key in stored[key] = value; return true }
        )
        XCTAssertEqual(stored[KeychainStore.sipPasswordKey], "current")
        XCTAssertNil(defaults.string(forKey: KeychainStore.legacySipPasswordDefaultsKey))
    }
}
