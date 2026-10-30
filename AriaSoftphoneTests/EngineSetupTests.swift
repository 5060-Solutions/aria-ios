import XCTest
@testable import AriaSoftphone

final class EngineSetupTests: XCTestCase {
    private let url = "https://push.example.com"

    private func step(hasEngine: Bool = true, builtFor: String? = "https://push.example.com",
                      rebuildPending: Bool = false, hasCall: Bool = false, registered: Bool = true) -> SipEngineManager.SetupStep {
        SipEngineManager.setupStep(hasEngine: hasEngine, builtFor: builtFor, gatewayUrl: url,
                                   rebuildPending: rebuildPending, hasCall: hasCall, registered: registered)
    }

    func testARegisteredEngineForTheRightGatewayIsReady() {
        XCTAssertEqual(step(), .ready)
    }

    func testAnUnregisteredEngineIsRegisteredNotRebuilt() {
        XCTAssertEqual(step(registered: false), .register)
    }

    func testNoEngineIsBuilt() {
        XCTAssertEqual(step(hasEngine: false, builtFor: nil, registered: false), .rebuild)
    }

    func testAGatewayChangeRebuildsBetweenCalls() {
        XCTAssertEqual(step(builtFor: "https://old.example.com"), .rebuild)
        XCTAssertEqual(step(rebuildPending: true), .rebuild)
    }

    func testNeverRebuildsUnderACall() {
        XCTAssertEqual(step(builtFor: "https://old.example.com", hasCall: true), .ready)
        XCTAssertEqual(step(rebuildPending: true, hasCall: true), .ready)
        XCTAssertEqual(step(rebuildPending: true, hasCall: true, registered: false), .register)
    }
}
