import XCTest
@testable import AriaSoftphone

final class IncomingPushTriageTests: XCTestCase {

    private func ringing(_ token: String?) -> ActiveCall {
        ActiveCall(uuid: UUID(), callToken: token, remoteUri: "1", remoteName: nil,
                   direction: token == nil ? .outbound : .inbound, state: .incoming)
    }

    func testANewCallOnAFreeLineIsAccepted() {
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "a", calls: [],
                                                 finishedTokens: RecentTokens(capacity: 4)), .accept)
    }

    func testARepeatPushForTheRingingCallIsADuplicateNotBusy() {
        // The bug: this used to take the busy branch and reject the live call.
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "a", calls: [ringing("a")],
                                                 finishedTokens: RecentTokens(capacity: 4)), .duplicate)
    }

    func testAPushForAFinishedCallIsADuplicate() {
        var finished = RecentTokens(capacity: 4)
        finished.insert("declined")
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "declined", calls: [],
                                                 finishedTokens: finished), .duplicate)
    }

    func testADifferentCallDuringOneCallIsAcceptedAsCallWaiting() {
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "b", calls: [ringing("a")],
                                                 finishedTokens: RecentTokens(capacity: 4)), .accept)
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "b", calls: [ringing(nil)],
                                                 finishedTokens: RecentTokens(capacity: 4)), .accept)
    }

    func testADifferentCallDuringTwoCallsIsBusy() {
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "c", calls: [ringing("a"), ringing(nil)],
                                                 finishedTokens: RecentTokens(capacity: 4)), .busy)
    }

    func testARepeatPushForTheSecondCallIsADuplicateNotBusy() {
        // With two calls up, a redelivered push for either must not be
        // declined as busy: that would reject a live call.
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "b", calls: [ringing("a"), ringing("b")],
                                                 finishedTokens: RecentTokens(capacity: 4)), .duplicate)
    }

    func testRecentTokensForgetTheOldestBeyondCapacity() {
        var tokens = RecentTokens(capacity: 3)
        ["1", "2", "3", "2", "4"].forEach { tokens.insert($0) }
        XCTAssertFalse(tokens.contains("1"))
        XCTAssertTrue(tokens.contains("2"))
        XCTAssertTrue(tokens.contains("3"))
        XCTAssertTrue(tokens.contains("4"))
    }
}
