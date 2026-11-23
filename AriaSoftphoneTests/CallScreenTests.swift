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
