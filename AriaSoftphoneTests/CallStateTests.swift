import XCTest
@testable import AriaSoftphone

/// The pure parts of the call lifecycle: how an ended call is classified and
/// what gets written to history.
final class CallStateTests: XCTestCase {

    private func call(_ direction: ActiveCall.CallDirection, connectedAt: Date? = nil) -> ActiveCall {
        var call = ActiveCall(
            uuid: UUID(), callToken: "tok", remoteUri: "1002", remoteName: "Bob",
            direction: direction, state: connectedAt == nil ? .incoming : .connected
        )
        call.connectedAt = connectedAt
        return call
    }

    func testConnectedCallsAreAnsweredWhoeverHangsUp() {
        for direction in [ActiveCall.CallDirection.inbound, .outbound] {
            let connected = call(direction, connectedAt: Date())
            XCTAssertEqual(CallOutcome.resolve(for: connected, endedLocally: true), .answered)
            XCTAssertEqual(CallOutcome.resolve(for: connected, endedLocally: false), .answered)
        }
    }

    func testUnansweredIncoming() {
        XCTAssertEqual(CallOutcome.resolve(for: call(.inbound), endedLocally: true), .rejected)
        XCTAssertEqual(CallOutcome.resolve(for: call(.inbound), endedLocally: false), .missed)
    }

    func testUnconnectedOutgoing() {
        XCTAssertEqual(CallOutcome.resolve(for: call(.outbound), endedLocally: true), .cancelled)
        XCTAssertEqual(CallOutcome.resolve(for: call(.outbound), endedLocally: false), .failed)
    }

    func testRecordTimesTalkFromConnect() {
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        let active = call(.outbound, connectedAt: connectedAt)
        let record = CallRecord(call: active, outcome: .answered, endedAt: connectedAt.addingTimeInterval(65))

        XCTAssertEqual(record.direction, .outbound)
        XCTAssertEqual(record.remoteUri, "1002")
        XCTAssertEqual(record.displayName, "Bob")
        XCTAssertEqual(record.duration, 65, accuracy: 0.001)
        XCTAssertEqual(record.startedAt, active.startedAt)
    }

    func testNeverConnectedCallHasNoDuration() {
        let record = CallRecord(call: call(.inbound), outcome: .missed)
        XCTAssertEqual(record.duration, 0)
        XCTAssertTrue(record.isMissed)
    }
}
