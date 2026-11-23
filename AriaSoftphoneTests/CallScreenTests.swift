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
        XCTAssertEqual(CallLinkStatus.current(callId: nil, engine: .shared), CallLinkStatus())
    }

    func testCallMeshIsThreeByThree() {
        XCTAssertEqual(AriaColor.callMesh.count, 9)
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
