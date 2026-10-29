import XCTest
import CallKit
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

    // MARK: - Engine events

    func testIncomingCallIdIsKnownBeforeAnswer() {
        XCTAssertEqual(call(.inbound).engineCallId, "incoming-tok")
    }

    func testOutgoingCallIdComesFromTheEngine() {
        var outgoing = ActiveCall(
            uuid: UUID(), callToken: nil, remoteUri: "1002", remoteName: nil,
            direction: .outbound, state: .connecting
        )
        XCTAssertNil(outgoing.engineCallId)
        outgoing.callId = "outgoing-abc"
        XCTAssertEqual(outgoing.engineCallId, "outgoing-abc")
    }

    // MARK: - End reasons

    private func ending(_ c: ActiveCall, _ reason: EndReason?) -> CallEnding {
        CallEnding.resolve(for: c, reason: reason)
    }

    func testCallerCancelledIsMissed() {
        XCTAssertEqual(ending(call(.inbound), .callerCancelled),
                       CallEnding(callKitReason: .unanswered, outcome: .missed))
    }

    func testAnsweredElsewhereIsNotMissed() {
        let e = ending(call(.inbound), .answeredElsewhere)
        XCTAssertEqual(e, CallEnding(callKitReason: .answeredElsewhere, outcome: .answeredElsewhere))
        XCTAssertFalse(CallRecord(call: call(.inbound), outcome: e.outcome).isMissed)
    }

    func testRejectedElsewhere() {
        XCTAssertEqual(ending(call(.inbound), .rejected),
                       CallEnding(callKitReason: .declinedElsewhere, outcome: .rejected))
    }

    func testFailed() {
        XCTAssertEqual(ending(call(.outbound), .failed), CallEnding(callKitReason: .failed, outcome: .failed))
        XCTAssertEqual(ending(call(.inbound), .failed), CallEnding(callKitReason: .failed, outcome: .failed))
    }

    func testRemoteHangup() {
        XCTAssertEqual(ending(call(.inbound, connectedAt: Date()), .remoteHangup),
                       CallEnding(callKitReason: .remoteEnded, outcome: .answered))
    }

    func testTransferredOnlyFromTheTransferredReason() {
        let connected = call(.outbound, connectedAt: Date())
        XCTAssertEqual(ending(connected, .transferred),
                       CallEnding(callKitReason: .remoteEnded, outcome: .transferred))
        // A BYE while a transfer is pending is just a remote hangup.
        XCTAssertEqual(ending(connected, .remoteHangup).outcome, .answered)
    }

    func testOwnActionsAreNotReportedToCallKitAgain() {
        XCTAssertNil(ending(call(.outbound, connectedAt: Date()), .localHangup).callKitReason)
        XCTAssertEqual(ending(call(.outbound), .cancelled),
                       CallEnding(callKitReason: nil, outcome: .cancelled))
    }

    func testWithoutAReasonFallsBackToTheCallState() {
        XCTAssertEqual(ending(call(.inbound), nil), CallEnding(callKitReason: .unanswered, outcome: .missed))
        XCTAssertEqual(ending(call(.outbound), nil), CallEnding(callKitReason: .failed, outcome: .failed))
        XCTAssertEqual(ending(call(.inbound, connectedAt: Date()), nil),
                       CallEnding(callKitReason: .remoteEnded, outcome: .answered))
    }

    // MARK: - Ending a call here

    func testConnectedCallIsHungUpByItsId() {
        var connected = call(.outbound, connectedAt: Date())
        connected.callId = "outgoing-1"
        XCTAssertEqual(connected.releaseOnLocalEnd, .hangup(callId: "outgoing-1"))
    }

    func testOutgoingCallIsHungUpByItsChosenIdAtAnyStage() {
        var dialing = ActiveCall(uuid: UUID(), callToken: nil, remoteUri: "1", remoteName: nil,
                                 direction: .outbound, state: .connecting)
        XCTAssertEqual(dialing.releaseOnLocalEnd, .none)
        dialing.engineCallId = "outgoing-chosen"
        XCTAssertEqual(dialing.releaseOnLocalEnd, .hangup(callId: "outgoing-chosen"))
    }

    func testChosenOutgoingIdsAreWellFormedAndDistinct() {
        let a = newOutgoingCallId()
        let b = newOutgoingCallId()
        XCTAssertTrue(a.hasPrefix("outgoing-"))
        XCTAssertNotEqual(a, b)
    }

    func testUnansweredIncomingCallIsRejected() {
        XCTAssertEqual(call(.inbound).releaseOnLocalEnd, .reject(callToken: "tok"))
    }

    func testCancelledIsTheUserHangingUp() {
        XCTAssertTrue(CallManager.isCancellation(MobileError.Cancelled(message: "hangup")))
        XCTAssertFalse(CallManager.isCancellation(MobileError.CallFailed(message: "busy")))
        // Hung up before connecting: history says cancelled, not failed.
        XCTAssertEqual(CallOutcome.resolve(for: call(.outbound), endedLocally: true), .cancelled)
    }

}
