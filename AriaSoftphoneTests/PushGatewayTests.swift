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

    // MARK: - Payload parsing

    /// What push-gateway's `ApnsPayload` actually sends: camelCase, no gateway URL.
    func testParsesTheGatewayPayload() {
        let payload: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Incoming Call", "body": "Bob is calling"], "content-available": 1],
            "callToken": "tok-1",
            "callerUri": "sip:1002@pbx.example.com",
            "callerName": "Bob",
        ]
        XCTAssertEqual(
            IncomingPush.parse(payload, configuredGateway: configured),
            .success(IncomingPush(callToken: "tok-1", callerUri: "sip:1002@pbx.example.com",
                                  callerName: "Bob", gatewayUrl: configured))
        )
    }

    func testCallerNameIsOptional() {
        let payload: [AnyHashable: Any] = ["callToken": "tok-1", "callerUri": "1002"]
        XCTAssertEqual(try? IncomingPush.parse(payload, configuredGateway: configured).get().callerName, nil)
    }

    func testParsesSnakeCaseWithATrustedGateway() {
        let payload: [AnyHashable: Any] = [
            "call_token": "tok-2",
            "caller_uri": "1003",
            "caller_name": "Carol",
            "gateway_url": "https://push.example.com/",
        ]
        XCTAssertEqual(
            IncomingPush.parse(payload, configuredGateway: configured),
            .success(IncomingPush(callToken: "tok-2", callerUri: "1003",
                                  callerName: "Carol", gatewayUrl: "https://push.example.com/"))
        )
    }

    func testCamelCaseWinsOverSnakeCase() {
        let payload: [AnyHashable: Any] = ["callToken": "camel", "call_token": "snake", "callerUri": "1"]
        XCTAssertEqual(try? IncomingPush.parse(payload, configuredGateway: configured).get().callToken, "camel")
    }

    func testRejectsAnUntrustedGatewayInEitherStyle() {
        for key in ["gatewayUrl", "gateway_url"] {
            let payload: [AnyHashable: Any] = ["callToken": "tok", "callerUri": "1", key: "https://evil.example.com"]
            XCTAssertEqual(IncomingPush.parse(payload, configuredGateway: configured), .failure(.untrustedGateway))
        }
    }

    func testRejectsAPayloadWithoutACallToken() {
        XCTAssertEqual(IncomingPush.parse(["callerUri": "1"], configuredGateway: configured), .failure(.missingCallToken))
        XCTAssertEqual(IncomingPush.parse(["callToken": "", "callerUri": "1"], configuredGateway: configured),
                       .failure(.missingCallToken))
    }

    func testRejectsWhenSignedOut() {
        XCTAssertEqual(IncomingPush.parse(["callToken": "tok"], configuredGateway: ""), .failure(.noConfiguredGateway))
    }

    func testMissingCallerUriIsUnknown() {
        XCTAssertEqual(try? IncomingPush.parse(["callToken": "tok"], configuredGateway: configured).get().callerUri,
                       "Unknown")
    }
}
