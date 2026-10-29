import XCTest
@testable import AriaSoftphone

final class TransferTests: XCTestCase {

    func testMapsCoreErrors() {
        XCTAssertEqual(TransferError(MobileError.InvalidTarget(message: "bad")), .invalidTarget)
        XCTAssertEqual(TransferError(MobileError.InvalidState(message: "ringing")), .notActive)
        XCTAssertEqual(TransferError(MobileError.CallFailed(message: "the PBX refused the transfer")),
                       .refused("the PBX refused the transfer"))
        XCTAssertEqual(TransferError(MobileError.Timeout(message: "504")), .timedOut)
        XCTAssertEqual(TransferError(MobileError.GatewayError(message: "502")), .unavailable)
        XCTAssertEqual(TransferError(MobileError.NetworkError(message: "offline")), .unavailable)
        XCTAssertEqual(TransferError(SipError.notConfigured), .unavailable)
    }

    func testEveryErrorHasAMessage() {
        for error in [TransferError.invalidTarget, .notActive, .refused(""), .timedOut, .unavailable, .unsupported] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testShowsTheCoreMessageForAFailedTransfer() {
        XCTAssertEqual(
            TransferError(MobileError.CallFailed(message: "the transfer failed (SIP 486); the call is still up"))
                .localizedDescription,
            "The transfer failed (SIP 486); the call is still up. That line is busy."
        )
        XCTAssertEqual(
            TransferError.refused("the PBX refused the transfer").localizedDescription,
            "The PBX refused the transfer."
        )
        XCTAssertEqual(
            TransferError.refused("the transfer failed (SIP 499); the call is still up").localizedDescription,
            "The transfer failed (SIP 499); the call is still up."
        )
        XCTAssertTrue(TransferError.refused("").localizedDescription.contains("still on the call"))
    }

    func testAcceptOutcomeUnknownOnlyForTimeoutAndNetwork() {
        XCTAssertTrue(CallManager.acceptOutcomeUnknown(MobileError.Timeout(message: "")))
        XCTAssertTrue(CallManager.acceptOutcomeUnknown(MobileError.NetworkError(message: "")))
        XCTAssertFalse(CallManager.acceptOutcomeUnknown(MobileError.CallFailed(message: "accept refused (HTTP 409)")))
        XCTAssertFalse(CallManager.acceptOutcomeUnknown(MobileError.GatewayError(message: "")))
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
