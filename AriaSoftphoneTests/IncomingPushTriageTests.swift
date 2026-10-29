import XCTest
@testable import AriaSoftphone

final class IncomingPushTriageTests: XCTestCase {

    private func ringing(_ token: String?) -> ActiveCall {
        ActiveCall(uuid: UUID(), callToken: token, remoteUri: "1", remoteName: nil,
                   direction: token == nil ? .outbound : .inbound, state: .incoming)
    }

    func testANewCallOnAFreeLineIsAccepted() {
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "a", activeCall: nil,
                                                 finishedTokens: RecentTokens(capacity: 4)), .accept)
    }

    func testARepeatPushForTheRingingCallIsADuplicateNotBusy() {
        // The bug: this used to take the busy branch and reject the live call.
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "a", activeCall: ringing("a"),
                                                 finishedTokens: RecentTokens(capacity: 4)), .duplicate)
    }

    func testAPushForAFinishedCallIsADuplicate() {
        var finished = RecentTokens(capacity: 4)
        finished.insert("declined")
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "declined", activeCall: nil,
                                                 finishedTokens: finished), .duplicate)
    }

    func testADifferentCallDuringACallIsBusy() {
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "b", activeCall: ringing("a"),
                                                 finishedTokens: RecentTokens(capacity: 4)), .busy)
        XCTAssertEqual(IncomingPushTriage.decide(callToken: "b", activeCall: ringing(nil),
                                                 finishedTokens: RecentTokens(capacity: 4)), .busy)
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
