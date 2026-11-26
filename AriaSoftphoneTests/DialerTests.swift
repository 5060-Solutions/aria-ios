import XCTest
@testable import AriaSoftphone

final class DialerTests: XCTestCase {
    // MARK: Formatting

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

final class ConnectionSheetFormatTests: XCTestCase {
    func testHostAndPort() {
        XCTAssertEqual(ConnectionSheet.splitHostPort("gw1.push.ariaroute.com:443").host, "gw1.push.ariaroute.com")
        XCTAssertEqual(ConnectionSheet.splitHostPort("gw1.push.ariaroute.com:443").port, "443")
        XCTAssertNil(ConnectionSheet.splitHostPort("push.ariaroute.com").port)
        XCTAssertEqual(ConnectionSheet.splitHostPort("[2001:db8::1]:443").host, "[2001:db8::1]")
        XCTAssertNil(ConnectionSheet.splitHostPort("2001:db8::1").port)
        XCTAssertEqual(ConnectionSheet.splitHostPort("").host, "")
    }

    func testTransportLabel() {
        XCTAssertEqual(ConnectionSheet.transportLabel("TLS : 5061"), "TLS · 5061")
        XCTAssertEqual(ConnectionSheet.transportLabel("UDP"), "UDP")
    }
}
