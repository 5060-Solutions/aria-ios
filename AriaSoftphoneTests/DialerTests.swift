import XCTest
@testable import AriaSoftphone

final class DialerTests: XCTestCase {
    // MARK: Formatting

    func testNorthAmericanNumbersGroupAsTyped() {
        XCTAssertEqual(DialFormatter.format(""), "")
        XCTAssertEqual(DialFormatter.format("4"), "4")
        XCTAssertEqual(DialFormatter.format("1042"), "1042", "extensions stay as typed")
        XCTAssertEqual(DialFormatter.format("55501"), "555-01")
        XCTAssertEqual(DialFormatter.format("5550142"), "555-0142")
        XCTAssertEqual(DialFormatter.format("41555501"), "(415) 555-01")
        XCTAssertEqual(DialFormatter.format("4155550142"), "(415) 555-0142")
        XCTAssertEqual(DialFormatter.format("14155550142"), "1 (415) 555-0142")
    }

    func testInternationalAndSpecialStringsStayAsTyped() {
        XCTAssertEqual(DialFormatter.format("+14155550142"), "+1 415 555 0142")
        XCTAssertEqual(DialFormatter.format("+1415"), "+1 415")
        XCTAssertEqual(DialFormatter.format("+33155500127"), "+33155500127")
        XCTAssertEqual(DialFormatter.format("*97"), "*97")
        XCTAssertEqual(DialFormatter.format("4155550142#"), "4155550142#")
        XCTAssertEqual(DialFormatter.format("011441234567890"), "011441234567890")
    }

    // MARK: Matching

    func testMatchesAcrossFormats() {
        let matcher = ContactMatcher(entries: [.init(name: "Priya Raman", number: "+1 (415) 555-0142")])
        XCTAssertEqual(matcher.name(for: "4155550142"), "Priya Raman")
        XCTAssertEqual(matcher.name(for: "+14155550142"), "Priya Raman")
        XCTAssertEqual(matcher.name(for: "sip:4155550142@northwind.ariaroute.com"), "Priya Raman")
        XCTAssertNil(matcher.name(for: "415555014"))
        XCTAssertNil(matcher.name(for: "41"))
    }

    func testContactsWinOverHistory() {
        let contact = ContactEntry(name: "Front Desk", phoneNumbers: ["1000"], hasImage: false, thumbnailData: nil)
        let record = CallRecord(direction: .inbound, remoteUri: "1000", remoteName: "Reception",
                                startedAt: Date(), duration: 0, outcome: .missed)
        let matcher = ContactMatcher(contacts: [contact], history: [record])
        XCTAssertEqual(matcher.name(for: "1000"), "Front Desk")
    }

    func testHistoryNamesFillGaps() {
        let matcher = ContactMatcher(contacts: [], history: FixtureData.history())
        XCTAssertEqual(matcher.name(for: "1023"), "Sam Patel")
        XCTAssertNil(matcher.name(for: "5035550111"), "a number with no name")
    }

    // MARK: Connection sheet

    func testEveryStateHasADetail() {
        for state in [ConnectionState.registered, .connecting, .offline, .error("x")] {
            XCTAssertFalse(ConnectionSheet.detail(for: state).isEmpty)
        }
    }
}
