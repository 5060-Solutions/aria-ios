import XCTest
import CallKit
@testable import AriaSoftphone

/// Hold for me, the parts that arrive with the bindings: the features flag,
/// the hold-return push fields, and the HeldForYou ending.
final class HoldForMeTests: XCTestCase {

    private func identity(_ json: String) throws -> PbxApiClient.Identity {
        try PbxApiClient.jsonDecoder.decode(PbxApiClient.Identity.self, from: Data(json.utf8))
    }

    func testIdentityAdvertisesHoldForMe() throws {
        XCTAssertTrue(try identity(#"{"features":["hold_for_me"]}"#).holdForMe)
        XCTAssertTrue(try identity(#"{"features":["x","hold_for_me"]}"#).holdForMe)
        XCTAssertFalse(try identity(#"{}"#).holdForMe)
        XCTAssertFalse(try identity(#"{"features":[]}"#).holdForMe)
        XCTAssertFalse(try identity(#"{"features":["other"]}"#).holdForMe)
    }

    private func parse(_ payload: [AnyHashable: Any]) throws -> IncomingPush {
        try IncomingPush.parse(payload, configuredGateway: "https://gw.example.com").get()
    }

    func testPushCarriesTheHoldReturn() throws {
        let camel = try parse(["callToken": "t", "holdReturnId": "hw-1", "holdReturnName": "Acme Bank"])
        XCTAssertEqual(camel.holdReturnId, "hw-1")
        XCTAssertEqual(camel.holdReturnName, "Acme Bank")

        let snake = try parse(["call_token": "t", "hold_return_id": "hw-2", "hold_return_name": "Globex"])
        XCTAssertEqual(snake.holdReturnId, "hw-2")
        XCTAssertEqual(snake.holdReturnName, "Globex")

        let none = try parse(["callToken": "t"])
        XCTAssertNil(none.holdReturnId)
        XCTAssertNil(none.holdReturnName)
    }

    func testHeldForYouIsNotADroppedCall() {
        var call = ActiveCall(uuid: UUID(), callToken: "tok", remoteUri: "18005550100", remoteName: "Acme",
                              direction: .outbound, state: .connected)
        call.connectedAt = Date()
        let ending = CallEnding.resolve(for: call, reason: .heldForYou)
        XCTAssertEqual(ending, CallEnding(callKitReason: .remoteEnded, outcome: .heldForYou))
        XCTAssertFalse(CallEnding.isDropped(call, reason: .heldForYou))
        XCTAssertNotEqual(ending.outcome, .failed)
        XCTAssertNotEqual(ending.outcome, .missed)
        XCTAssertFalse(CallRecord(call: call, outcome: ending.outcome).isMissed)
    }

    func testRecentsShowsHoldingForYou() {
        var call = ActiveCall(uuid: UUID(), callToken: "tok", remoteUri: "18005550100", remoteName: "Acme",
                              direction: .outbound, state: .connected)
        call.connectedAt = Date()
        let record = CallRecord(call: call, outcome: .heldForYou)
        XCTAssertEqual(record.summary, "Holding for you")
    }
}
