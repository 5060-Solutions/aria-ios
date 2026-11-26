import XCTest
@testable import AriaSoftphone

final class CallScreenTests: XCTestCase {
    func testClockFormats() {
        XCTAssertEqual(CallClock.format(0), "00:00")
        XCTAssertEqual(CallClock.format(207.9), "03:27")
        XCTAssertEqual(CallClock.format(3723), "1:02:03")
        XCTAssertEqual(CallClock.format(-5), "00:00")
    }

    func testQualityFromStats() {
        XCTAssertEqual(CallQuality(packetsReceived: 1000, packetLoss: 2, jitterMs: 12, rttMs: 80), .good)
        XCTAssertEqual(CallQuality(packetsReceived: 1000, packetLoss: 30, jitterMs: 12, rttMs: 80), .fair)
        XCTAssertEqual(CallQuality(packetsReceived: 1000, packetLoss: 120, jitterMs: 12, rttMs: 80), .poor)
        XCTAssertEqual(CallQuality(packetsReceived: 1000, packetLoss: 0, jitterMs: 45, rttMs: 80), .fair)
        XCTAssertEqual(CallQuality(packetsReceived: 1000, packetLoss: 0, jitterMs: 10, rttMs: 650), .poor)
        XCTAssertEqual(CallQuality(packetsReceived: 0, packetLoss: 0, jitterMs: 0, rttMs: 0), .good)
    }

    func testQualityAlwaysHasALabel() {
        for quality in [CallQuality.good, .fair, .poor] {
            XCTAssertFalse(quality.label.isEmpty)
            XCTAssert((0...1).contains(quality.barValue))
        }
    }

    @MainActor
    func testNoCallNoLinkStatus() {
        XCTAssertEqual(CallLinkStatus.current(call: nil, engine: .shared), CallLinkStatus())
    }

    func testCallMeshIsThreeByThree() {
        XCTAssertEqual(AriaColor.callMesh.count, 9)
    }
}

final class CallEncryptionTests: XCTestCase {
    func testConnectedCallsMapToWhatTheCoreReports() {
        XCTAssertEqual(CallEncryption(isConnected: true, isEncrypted: true), .encrypted)
        XCTAssertEqual(CallEncryption(isConnected: true, isEncrypted: false), .unencrypted)
    }

    func testNothingIsClaimedBeforeTheCallConnectsOrTheCoreSays() {
        XCTAssertEqual(CallEncryption(isConnected: false, isEncrypted: false), .unknown)
        XCTAssertEqual(CallEncryption(isConnected: false, isEncrypted: true), .unknown)
        XCTAssertEqual(CallEncryption(isConnected: true, isEncrypted: nil), .unknown)
    }

    func testCallStateEventsCarryEncryptionOnceConnected() {
        // CallInfo.encrypted, both values, on Connected and on later events
        // (a hold, or a re-send with the state unchanged when it changes).
        XCTAssertEqual(CallEncryption.reported(state: .connected, encrypted: true), true)
        XCTAssertEqual(CallEncryption.reported(state: .connected, encrypted: false), false)
        XCTAssertEqual(CallEncryption.reported(state: .onHold, encrypted: false), false)
        XCTAssertEqual(CallEncryption.reported(state: .onHold, encrypted: true), true)
        // Before Connected the core says false: nothing negotiated yet.
        for state in [CallState.ringing, .connecting, .incoming, .ended] {
            XCTAssertNil(CallEncryption.reported(state: state, encrypted: false), "\(state)")
        }
    }

    private func call(connected: Bool, encrypted: Bool?) -> ActiveCall {
        var call = ActiveCall(uuid: UUID(), callToken: nil, remoteUri: "1001", remoteName: nil,
                              direction: .outbound, state: connected ? .connected : .connecting)
        if connected { call.callId = "c1"; call.connectedAt = Date() }
        call.isEncrypted = encrypted
        return call
    }

    func testACallMapsFromItsLastEvent() {
        XCTAssertEqual(CallEncryption(call(connected: true, encrypted: true)), .encrypted)
        XCTAssertEqual(CallEncryption(call(connected: true, encrypted: false)), .unencrypted)
        XCTAssertEqual(CallEncryption(call(connected: true, encrypted: nil)), .unknown)
        XCTAssertEqual(CallEncryption(call(connected: false, encrypted: nil)), .unknown)
    }

    @MainActor
    func testTheLinkStatusShowsTheCallsEncryption() {
        XCTAssertEqual(CallLinkStatus.current(call: call(connected: true, encrypted: false), engine: .shared).encryption,
                       .unencrypted)
        XCTAssertEqual(CallLinkStatus.current(call: call(connected: true, encrypted: true), engine: .shared).encryption,
                       .encrypted)
        XCTAssertEqual(CallLinkStatus.current(call: call(connected: false, encrypted: nil), engine: .shared).encryption,
                       .unknown)
    }

    func testTheExplanationIsTheAgreedWording() {
        XCTAssertEqual(CallEncryption.unencryptedExplanation,
                       "This call isn't encrypted. The phone system didn't accept a secure connection.")
    }

    @MainActor
    func testTheNoticeComesOncePerCall() {
        let notices = CallEncryptionNotices()
        let call = UUID()
        XCTAssertFalse(notices.shouldNotify(call: call, encryption: .unknown))
        XCTAssertFalse(notices.shouldNotify(call: call, encryption: .encrypted))
        // Drops to unencrypted: notified once, not again on later polls or
        // after it recovers and drops again.
        XCTAssertTrue(notices.shouldNotify(call: call, encryption: .unencrypted))
        XCTAssertFalse(notices.shouldNotify(call: call, encryption: .unencrypted))
        XCTAssertFalse(notices.shouldNotify(call: call, encryption: .encrypted))
        XCTAssertFalse(notices.shouldNotify(call: call, encryption: .unencrypted))
        // Another call gets its own notice.
        XCTAssertTrue(notices.shouldNotify(call: UUID(), encryption: .unencrypted))
    }

    @MainActor
    func testEndedCallsAreForgotten() {
        let notices = CallEncryptionNotices()
        let ended = UUID(), live = UUID()
        _ = notices.shouldNotify(call: ended, encryption: .unencrypted)
        _ = notices.shouldNotify(call: live, encryption: .unencrypted)
        notices.retain(only: [live])
        XCTAssertFalse(notices.shouldNotify(call: live, encryption: .unencrypted))
        XCTAssertTrue(notices.shouldNotify(call: ended, encryption: .unencrypted))
    }
}

final class PillLabelFitTests: XCTestCase {
    private let labels = ["Mute", "Keypad", "Speaker", "Hold", "Add call", "Transfer"]

    func testWideColumnsKeepTheLargestStandardSize() {
        XCTAssertEqual(PillLabelFit.cap(labels: labels, columnWidth: 200, current: .accessibility5), .xxxLarge)
    }

    func testNeverLargerThanTheUsersSize() {
        XCTAssertEqual(PillLabelFit.cap(labels: labels, columnWidth: 200, current: .large), .large)
    }

    func testALongGermanWordLowersEveryLabelTogether() {
        let german = ["Stumm", "Tastatur", "Lautsprecher", "Halten", "Anruf hinzufügen", "Übergeben"]
        let column: CGFloat = 165   // iPhone 17e, two columns
        let cap = PillLabelFit.cap(labels: german, columnWidth: column, current: .accessibility5)
        let available = PillLabelFit.textWidth(columnWidth: column)
        for word in german.flatMap({ $0.split(separator: " ").map(String.init) }) {
            XCTAssertLessThanOrEqual(PillLabelFit.width(of: word, at: cap), available, word)
        }
        XCTAssertLessThanOrEqual(cap, PillLabelFit.cap(labels: labels, columnWidth: column, current: .accessibility5))
    }

    func testWordsWidenWithTextSize() {
        XCTAssertGreaterThan(PillLabelFit.width(of: "Lautsprecher", at: .xxxLarge),
                             PillLabelFit.width(of: "Lautsprecher", at: .large))
    }

    func testHostnamesBreakOnlyAtDots() {
        XCTAssertEqual("a.b".breakingAtDots, "a.\u{200B}b")
        XCTAssertEqual("1001@x.com".breakingAtDots, "1001@\u{200B}x.\u{200B}com")
    }
}
