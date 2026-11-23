import XCTest
@testable import AriaSoftphone

final class AppLogTests: XCTestCase {
    func testTheLogIsBoundedAndOldestFirst() {
        let log = AppLog(capacity: 3)
        for i in 1...5 { log.log("t", "m\(i)") }
        XCTAssertEqual(log.all.map(\.message), ["m3", "m4", "m5"])
        XCTAssertTrue(log.text().hasSuffix("[t] m5"))
    }

    func testTokensAreRedacted() {
        let log = AppLog(capacity: 10)
        log.log("t", "auth Bearer abc.def-123 failed")
        log.log("t", "jwt eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl seen")
        log.log("t", "GET https://api.example.com/provision/softphone/AbC123_- 404")
        let text = log.text()
        XCTAssertFalse(text.contains("abc.def-123"))
        XCTAssertFalse(text.contains("eyJhbGciOi"))
        XCTAssertFalse(text.contains("AbC123_-"))
        XCTAssertEqual(text.components(separatedBy: "[redacted]").count - 1, 3)
    }
}

@MainActor
final class ConnectionDetailsTests: XCTestCase {
    private func source(callId: String? = "c1") -> ConnectionDetails.Source {
        ConnectionDetails.Source(
            state: { .error("gateway: timeout") },
            account: {
                AccountSettings(username: "1001", domain: "acme.example.com", registrar: "", port: 0,
                                transport: "", displayName: "", apiUrl: "https://api.example.com",
                                gatewayUrl: "https://push.example.com", voicemailNumber: "")
            },
            deviceId: { "dev-1" },
            lastError: { "gateway: timeout" },
            network: { NetworkPath(isSatisfied: true, interfaces: ["en0", "pdp_ip0"], addresses: []) },
            activeCallId: { callId },
            isEncrypted: { _ in true },
            mediaStats: { _ in
                MediaStats(packetsSent: 10, packetsReceived: 9, bytesSent: 1600, bytesReceived: 1440,
                           jitterMs: 2.5, packetLoss: 1, rttMs: 40)
            }
        )
    }

    func testTheSnapshotGathersEverything() {
        let details = ConnectionDetails(source: source())
        details.refresh()
        let s = details.snapshot
        XCTAssertEqual(s.state, .error("gateway: timeout"))
        XCTAssertEqual(s.account, "1001@acme.example.com")
        XCTAssertEqual(s.gatewayNode, "push.example.com")
        XCTAssertEqual(s.transport, "TLS : 5061")
        XCTAssertEqual(s.network, "Wi-Fi, Cellular")
        XCTAssertEqual(s.srtp, true)
        XCTAssertEqual(s.stats?.packetsReceived, 9)
        XCTAssertNil(s.codec)
        XCTAssertFalse(s.preferredCodecs.isEmpty)
    }

    func testNoCallMeansNoMedia() {
        let details = ConnectionDetails(source: source(callId: nil))
        details.refresh()
        XCTAssertNil(details.snapshot.srtp)
        XCTAssertNil(details.snapshot.stats)
    }

    func testTheReportHasDetailsThenTheLog() {
        let details = ConnectionDetails(source: source())
        details.refresh()
        let log = AppLog(capacity: 5)
        log.log("call", "ended")
        let report = details.reportText(log: log)
        XCTAssertTrue(report.contains("Gateway: https://push.example.com (node push.example.com)"))
        XCTAssertTrue(report.contains("SRTP on"))
        XCTAssertTrue(report.contains("jitter 2.5 ms"))
        XCTAssertTrue(report.hasSuffix("[call] ended"))
    }

    func testNetworkDescriptions() {
        XCTAssertEqual(ConnectionDetails.describe(nil), "Unknown")
        XCTAssertEqual(ConnectionDetails.describe(.unsatisfied), "No connection")
    }
}
