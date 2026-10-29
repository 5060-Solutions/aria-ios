import XCTest
@testable import AriaSoftphone

final class PushGatewayTests: XCTestCase {
    private let configured = "https://push.example.com"

    func testAcceptsTheConfiguredGateway() {
        XCTAssertTrue(isTrustedGatewayURL("https://push.example.com", configured: configured))
        XCTAssertTrue(isTrustedGatewayURL("https://PUSH.example.com/v1/", configured: configured))
        XCTAssertTrue(isTrustedGatewayURL("https://push.example.com:443", configured: configured))
    }

    func testRejectsAnyOtherGateway() {
        XCTAssertFalse(isTrustedGatewayURL("https://evil.example.com", configured: configured))
        XCTAssertFalse(isTrustedGatewayURL("https://push.example.com.evil.net", configured: configured))
        XCTAssertFalse(isTrustedGatewayURL("https://push.example.com:8443", configured: configured))
        XCTAssertFalse(isTrustedGatewayURL("http://push.example.com", configured: configured))
        XCTAssertFalse(isTrustedGatewayURL("https://user@push.example.com", configured: configured))
        XCTAssertFalse(isTrustedGatewayURL("", configured: configured))
    }

    func testRejectsEverythingWhenNoGatewayIsConfigured() {
        XCTAssertFalse(isTrustedGatewayURL("https://push.example.com", configured: ""))
        XCTAssertFalse(isTrustedGatewayURL("https://push.example.com", configured: "http://push.example.com"))
    }
}
