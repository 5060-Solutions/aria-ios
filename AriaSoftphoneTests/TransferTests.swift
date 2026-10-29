import XCTest
@testable import AriaSoftphone

final class TransferTests: XCTestCase {

    func testMapsCoreErrors() {
        XCTAssertEqual(TransferError(MobileError.InvalidTarget(message: "bad")), .invalidTarget)
        XCTAssertEqual(TransferError(MobileError.InvalidState(message: "ringing")), .notActive)
        XCTAssertEqual(TransferError(MobileError.CallFailed(message: "403")), .refused)
        XCTAssertEqual(TransferError(MobileError.Timeout(message: "504")), .timedOut)
        XCTAssertEqual(TransferError(MobileError.GatewayError(message: "502")), .unavailable)
        XCTAssertEqual(TransferError(MobileError.NetworkError(message: "offline")), .unavailable)
        XCTAssertEqual(TransferError(SipError.notConfigured), .unavailable)
    }

    func testEveryErrorHasAMessage() {
        for error in [TransferError.invalidTarget, .notActive, .refused, .timedOut, .unavailable] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testTargetValidationMatchesTheCore() {
        XCTAssertTrue(TransferError.isAcceptableTarget("1002"))
        XCTAssertTrue(TransferError.isAcceptableTarget("+15551234567"))
        XCTAssertTrue(TransferError.isAcceptableTarget("sip:1002@pbx.example.com"))
        XCTAssertFalse(TransferError.isAcceptableTarget(""))
        XCTAssertFalse(TransferError.isAcceptableTarget("1002\r\nX-Evil: 1"))
        XCTAssertFalse(TransferError.isAcceptableTarget("<sip:1002@x>"))
    }
}
