import XCTest
@testable import AriaSoftphone

/// Two calls at once: routing engine events, which call is on screen, and
/// hold requests and their sync to CallKit.
final class CallWaitingTests: XCTestCase {

    private func inbound(_ token: String, connected: Bool = true, held: Bool = false) -> ActiveCall {
        var call = ActiveCall(uuid: UUID(), callToken: token, remoteUri: "100\(token)", remoteName: nil,
                              direction: .inbound, state: .incoming)
        if connected { connect(&call, id: "incoming-\(token)", held: held) }
        return call
    }

    private func outbound(_ id: String, connected: Bool = true, held: Bool = false) -> ActiveCall {
        var call = ActiveCall(uuid: UUID(), callToken: nil, remoteUri: "2000", remoteName: nil,
                              direction: .outbound, state: .connecting)
        call.engineCallId = id
        if connected { connect(&call, id: id, held: held) }
        return call
    }

    private func connect(_ call: inout ActiveCall, id: String, held: Bool) {
        call.callId = id
        call.connectedAt = Date()
        call.state = .connected
        call.setHeld(held)
    }

    private func registry(_ calls: ActiveCall...) -> CallRegistry {
        var registry = CallRegistry()
        calls.forEach { registry.add($0) }
        return registry
    }

    // MARK: Routing

    func testEventsRouteToTheirCallByEngineId() {
        let first = inbound("a", connected: false)
        let second = outbound("outgoing-x", connected: false)
        let calls = registry(first, second)
        XCTAssertEqual(calls.call(engineCallId: "incoming-a")?.uuid, first.uuid)
        XCTAssertEqual(calls.call(engineCallId: "outgoing-x")?.uuid, second.uuid)
        XCTAssertNil(calls.call(engineCallId: "incoming-gone"))
        XCTAssertEqual(calls.call(callToken: "a")?.uuid, first.uuid)
    }

    func testModifyAndRemoveTouchOnlyTheirCall() {
        let first = inbound("a")
        let second = outbound("outgoing-x")
        var calls = registry(first, second)
        calls.modify(uuid: second.uuid) { $0.isMuted = true }
        XCTAssertFalse(calls[first.uuid]!.isMuted)
        XCTAssertTrue(calls[second.uuid]!.isMuted)
        XCTAssertEqual(calls.remove(uuid: first.uuid)?.uuid, first.uuid)
        XCTAssertNil(calls.remove(uuid: first.uuid))
        XCTAssertEqual(calls.calls.map(\.uuid), [second.uuid])
    }

    func testAddingTheSameCallTwiceKeepsOne() {
        let call = inbound("a")
        var calls = registry(call)
        calls.add(call)
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: Foreground

    func testARingingSecondCallIsOnScreenOverTheCallInProgress() {
        let talking = inbound("a")
        let ringing = inbound("b", connected: false)
        let calls = registry(talking, ringing)
        XCTAssertEqual(calls.foreground?.uuid, ringing.uuid)
        XCTAssertEqual(calls.background.map(\.uuid), [talking.uuid])
    }

    func testTheTalkingCallIsOnScreenOverAHeldOne() {
        let held = inbound("a", held: true)
        let talking = outbound("outgoing-x")
        XCTAssertEqual(registry(talking, held).foreground?.uuid, talking.uuid)
        XCTAssertEqual(registry(held, talking).foreground?.uuid, talking.uuid)
    }

    func testAHeldCallLeftAloneIsOnScreen() {
        var calls = registry(inbound("a", held: true), outbound("outgoing-x"))
        let held = calls.calls[0]
        calls.remove(uuid: calls.calls[1].uuid)
        XCTAssertEqual(calls.foreground?.uuid, held.uuid)
        XCTAssertTrue(calls.foreground!.isOnHold, "ending the other call does not resume it")
        XCTAssertTrue(calls.background.isEmpty)
    }

    func testAddCallNeedsRoomAndNoCallBeingSetUp() {
        XCTAssertTrue(CallRegistry().canAddCall)
        XCTAssertTrue(registry(inbound("a")).canAddCall)
        XCTAssertFalse(registry(inbound("a", connected: false)).canAddCall)
        XCTAssertFalse(registry(outbound("outgoing-x", connected: false)).canAddCall)
        XCTAssertFalse(registry(inbound("a", held: true), outbound("outgoing-x")).canAddCall)
    }

    // MARK: Hold

    func testHoldRequests() {
        let held = inbound("a", held: true)
        let talking = outbound("outgoing-x")
        let calls = registry(held, talking)
        XCTAssertEqual(CallRegistry.holdRequest(for: talking.uuid, onHold: true, in: calls),
                       .hold(callId: "outgoing-x"))
        XCTAssertEqual(CallRegistry.holdRequest(for: held.uuid, onHold: false, in: calls),
                       .swap(activeCallId: "outgoing-x", heldCallId: "incoming-a"))
        // Already so: CallKit is only being told about the core's change.
        XCTAssertEqual(CallRegistry.holdRequest(for: held.uuid, onHold: true, in: calls), .none)
        XCTAssertEqual(CallRegistry.holdRequest(for: talking.uuid, onHold: false, in: calls), .none)
    }

    func testResumingTheOnlyCallIsAPlainResume() {
        let held = inbound("a", held: true)
        XCTAssertEqual(CallRegistry.holdRequest(for: held.uuid, onHold: false, in: registry(held)),
                       .resume(callId: "incoming-a"))
    }

    func testHoldingACallNotYetConnectedDoesNothingInTheEngine() {
        let ringing = outbound("outgoing-x", connected: false)
        XCTAssertEqual(CallRegistry.holdRequest(for: ringing.uuid, onHold: true, in: registry(ringing)), .none)
        XCTAssertEqual(CallRegistry.holdRequest(for: UUID(), onHold: true, in: registry(ringing)), .none)
    }

    func testHoldChangesTellCallKitHoldsBeforeResumes() {
        // After a swap: the core held the outgoing call and resumed the
        // incoming one, and CallKit still has it the other way round.
        let resumed = inbound("a")
        let nowHeld = outbound("outgoing-x", held: true)
        let changes = CallRegistry.holdChanges(calls: [resumed, nowHeld], callKitHeld: [resumed.uuid])
        XCTAssertEqual(changes, [
            .init(uuid: nowHeld.uuid, onHold: true),
            .init(uuid: resumed.uuid, onHold: false),
        ])
        XCTAssertEqual(CallRegistry.holdChanges(calls: [resumed, nowHeld], callKitHeld: [nowHeld.uuid]), [])
    }

    func testHoldChangesIgnoreCallsNotConnected() {
        let ringing = outbound("outgoing-x", connected: false)
        XCTAssertEqual(CallRegistry.holdChanges(calls: [ringing], callKitHeld: [ringing.uuid]), [])
    }
}
