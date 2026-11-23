import XCTest
@testable import AriaSoftphone

/// Emergency numbers go to the native dialer, never over VoIP.
final class EmergencyDialerTests: XCTestCase {
    private var opened: [URL] = []
    private var savedOpen: ((URL) -> Void)!

    override func setUp() {
        super.setUp()
        savedOpen = EmergencyDialer.open
        opened = []
        EmergencyDialer.open = { [weak self] in self?.opened.append($0) }
    }

    override func tearDown() {
        EmergencyDialer.open = savedOpen
        super.tearDown()
    }

    func testTheDesktopListIsEmergency() {
        for number in ["911", "112", "999", "000", " 9-1-1 ", "tel:911", "sip:112@pbx.example.com"] {
            XCTAssertTrue(EmergencyDialer.isEmergency(number), number)
        }
        for number in ["9110", "1911", "100", "", "+1911"] {
            XCTAssertFalse(EmergencyDialer.isEmergency(number), number)
        }
    }

    func testTelURLKeepsOnlyTheDigits() {
        XCTAssertEqual(EmergencyDialer.telURL(for: " 9-1-1 ")?.absoluteString, "tel:911")
        XCTAssertEqual(EmergencyDialer.telURL(for: "sip:112@pbx.example.com;user=phone")?.absoluteString, "tel:112")
        XCTAssertNil(EmergencyDialer.telURL(for: "sip:@host"))
    }

    func testHandOffOpensTelOnlyForEmergencyNumbers() {
        XCTAssertTrue(EmergencyDialer.handOff("911"))
        XCTAssertFalse(EmergencyDialer.handOff("1001"))
        XCTAssertEqual(opened.map(\.absoluteString), ["tel:911"])
    }

    func testStartingAnEmergencyCallHandsOffAndPlacesNothing() {
        let manager = CallManager.shared
        let before = manager.registry.count
        XCTAssertEqual(manager.startOutgoingCall(uri: "112"), .emergencyHandoff)
        XCTAssertEqual(manager.registry.count, before, "no VoIP call may be started")
        XCTAssertEqual(opened.map(\.absoluteString), ["tel:112"])
    }

    func testAnEmptyNumberIsRefused() {
        XCTAssertEqual(CallManager.shared.startOutgoingCall(uri: "  "), .refused)
        XCTAssertTrue(opened.isEmpty)
    }
}
