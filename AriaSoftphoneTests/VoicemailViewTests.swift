import XCTest
@testable import AriaSoftphone

final class VoicemailViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set("US", forKey: DefaultCountry.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultCountry.defaultsKey)
        super.tearDown()
    }

    func testCallerWithNameAndNumber() {
        let caller = VoicemailCaller("Priya Raman <+14155550142>")
        XCTAssertEqual(caller.name, "Priya Raman")
        XCTAssertEqual(caller.number, "+14155550142")
        XCTAssertEqual(caller.title, "Priya Raman")
        XCTAssertEqual(caller.subtitle, "(415) 555-0142")
    }

    func testQuotedName() {
        XCTAssertEqual(VoicemailCaller("\"Front Desk\" <1000>").name, "Front Desk")
    }

    func testBareNumberIsFormattedOrMatched() {
        let bare = VoicemailCaller("+15035550111")
        XCTAssertNil(bare.name)
        XCTAssertEqual(bare.title, "(503) 555-0111")
        XCTAssertNil(bare.subtitle)

        let matcher = ContactMatcher(entries: [.init(name: "Dr. Lee's Office", number: "(503) 555-0111")])
        XCTAssertEqual(VoicemailCaller("+15035550111", matcher: matcher).title, "Dr. Lee's Office")
    }

    func testEmptyCallerId() {
        let caller = VoicemailCaller("")
        XCTAssertNil(caller.number)
        XCTAssertEqual(caller.title, "Unknown caller")
    }

    @MainActor
    func testRatesCycle() {
        XCTAssertEqual(VoicemailPlayer.next(after: 1), 1.5)
        XCTAssertEqual(VoicemailPlayer.next(after: 1.5), 2)
        XCTAssertEqual(VoicemailPlayer.next(after: 2), 1)
        XCTAssertEqual(VoicemailPlayer.label(for: 1), "1×")
        XCTAssertEqual(VoicemailPlayer.label(for: 2), "2×")
        XCTAssertTrue(VoicemailPlayer.label(for: 1.5).hasPrefix("1"))
        XCTAssertTrue(VoicemailPlayer.label(for: 1.5).hasSuffix("5×"))
    }
}
