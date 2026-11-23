import XCTest
@testable import AriaSoftphone

final class AppVersionTests: XCTestCase {
    func testVersionAndBuild() {
        XCTAssertEqual(AppVersion.describe(["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "42"]), "1.2.0 (42)")
    }

    func testMissingBuild() {
        XCTAssertEqual(AppVersion.describe(["CFBundleShortVersionString": "1.2.0"]), "1.2.0")
    }

    func testBundleCarriesBuildSettingVersion() {
        // Info.plist takes the version from MARKETING_VERSION; an unexpanded
        // variable would mean the build setting is not applied.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        XCTAssertFalse(version.isEmpty)
        XCTAssertFalse(version.contains("$("))
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String, "Aria")
    }
}

final class DialStringTests: XCTestCase {
    func testFormattedNumber() {
        XCTAssertEqual(DialString.pasteable(" +1 (720) 555-0100 "), "+17205550100")
    }

    func testPlusOnlyLeading() {
        XCTAssertEqual(DialString.pasteable("12+34"), "1234")
    }

    func testKeepsStarAndHash() {
        XCTAssertEqual(DialString.pasteable("*97#123"), "*97#123")
    }

    func testTooShortOrText() {
        XCTAssertNil(DialString.pasteable("hello"))
        XCTAssertNil(DialString.pasteable("12"))
    }
}

final class MissedCallNotificationTests: XCTestCase {
    func testNameAndNumber() {
        let content = LocalNotifications.missedCallContent(remoteUri: "101", remoteName: "Ana")
        XCTAssertEqual(content.body, "Ana (101)")
        XCTAssertEqual(content.categoryIdentifier, LocalNotifications.missedCallCategory)
    }

    func testNumberOnly() {
        XCTAssertEqual(LocalNotifications.missedCallContent(remoteUri: "101", remoteName: nil).body, "101")
        XCTAssertEqual(LocalNotifications.missedCallContent(remoteUri: "101", remoteName: "101").body, "101")
    }
}
