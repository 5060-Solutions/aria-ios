import XCTest
import CallKit
@testable import AriaSoftphone

/// Merging two calls into a local conference and splitting it again, as
/// CallKit group actions map onto the core.
final class ConferenceTests: XCTestCase {

    private func call(_ id: String, connected: Bool = true, held: Bool = false, conferenced: Bool = false) -> ActiveCall {
        var call = ActiveCall(uuid: UUID(), callToken: nil, remoteUri: id, remoteName: nil,
                              direction: .outbound, state: .connecting)
        call.engineCallId = id
        if connected {
            call.callId = id
            call.connectedAt = Date()
            call.state = .connected
            call.setHeld(held)
        }
        call.inConference = conferenced
        return call
    }

    private func registry(_ calls: ActiveCall...) -> CallRegistry {
        var registry = CallRegistry()
        calls.forEach { registry.add($0) }
        return registry
    }

    func testProviderAllowsTwoCallsInOneGroup() {
        XCTAssertEqual(CallRegistry.maximumCalls, 2)
        let update = CallManager.callUpdate(remoteUri: "100", remoteName: nil)
        XCTAssertTrue(update.supportsGrouping)
        XCTAssertTrue(update.supportsUngrouping)
        XCTAssertTrue(update.supportsHolding)
    }

    func testMergePairIsTwoConnectedCallsOldestFirst() {
        let older = call("a", held: true)
        let newer = call("b")
        let pair = registry(older, newer).mergePair
        XCTAssertEqual(pair?.older.uuid, older.uuid)
        XCTAssertEqual(pair?.newer.uuid, newer.uuid)
    }

    func testNoMergeWithOneCallARingingCallOrAConference() {
        XCTAssertNil(registry(call("a")).mergePair)
        XCTAssertNil(registry(call("a"), call("b", connected: false)).mergePair)
        XCTAssertNil(registry(call("a", conferenced: true), call("b", conferenced: true)).mergePair)
    }

    func testGroupingTheTwoCallsMergesThemOlderFirst() {
        let older = call("a", held: true)
        let newer = call("b")
        let calls = registry(older, newer)
        XCTAssertEqual(CallRegistry.groupRequest(for: newer.uuid, groupWith: older.uuid, in: calls),
                       .merge(callA: "a", callB: "b"))
        XCTAssertEqual(CallRegistry.groupRequest(for: older.uuid, groupWith: newer.uuid, in: calls),
                       .merge(callA: "a", callB: "b"))
    }

    func testGroupingUnknownOrUnmixableCallsIsRefused() {
        let older = call("a")
        let ringing = call("b", connected: false)
        let calls = registry(older, ringing)
        XCTAssertEqual(CallRegistry.groupRequest(for: ringing.uuid, groupWith: older.uuid, in: calls), .refuse)
        XCTAssertEqual(CallRegistry.groupRequest(for: UUID(), groupWith: older.uuid, in: calls), .refuse)
        XCTAssertEqual(CallRegistry.groupRequest(for: older.uuid, groupWith: older.uuid, in: calls), .refuse)
    }

    func testUngroupingSplitsOnlyAConference() {
        let a = call("a", conferenced: true)
        let b = call("b", conferenced: true)
        let conferenced = registry(a, b)
        XCTAssertEqual(CallRegistry.groupRequest(for: b.uuid, groupWith: nil, in: conferenced), .split)
        XCTAssertEqual(CallRegistry.groupRequest(for: b.uuid, groupWith: a.uuid, in: conferenced), .none)
        XCTAssertEqual(conferenced.conference.map(\.uuid), [a.uuid, b.uuid])

        let plain = call("c")
        XCTAssertEqual(CallRegistry.groupRequest(for: plain.uuid, groupWith: nil, in: registry(plain)), .none)
    }

    func testNoSwapWhileConferenced() {
        let a = call("a", conferenced: true)
        let b = call("b", held: true, conferenced: true)
        XCTAssertFalse(registry(a, b).canSwap(active: a.uuid, held: b.uuid))
    }

    func testResumingAHeldConferenceIsAResumeNotASwap() {
        // The core holds and resumes a conference as a whole; resuming one
        // call while its partner already reports off hold must not swap.
        let a = call("a", conferenced: true)
        let b = call("b", held: true, conferenced: true)
        XCTAssertEqual(CallRegistry.holdRequest(for: b.uuid, onHold: false, in: registry(a, b)),
                       .resume(callId: "b"))
    }

    func testRecordingErrorsDescribeThemselves() {
        XCTAssertNotNil(RecordingError.disclosureRequired.errorDescription)
        XCTAssertNotNil(RecordingError.notConnected.errorDescription)
    }
}
