import XCTest
@testable import AriaSoftphone

/// Counts calls from concurrently running tasks.
private final class Counter {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    @discardableResult func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
        return _value
    }
}

private struct StubError: Error {}

final class GatewayTokenRenewerTests: XCTestCase {

    func testConcurrentRenewalsShareOneFetch() async throws {
        let fetches = Counter()
        let applied = Counter()
        let renewer = GatewayTokenRenewer(dependencies: .init(
            fetchToken: {
                let n = fetches.increment()
                try await Task.sleep(nanoseconds: 100_000_000)
                return "token-\(n)"
            },
            apply: { _ in applied.increment() }
        ))

        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<8 {
                group.addTask { try await renewer.renew() }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(fetches.value, 1)
        XCTAssertEqual(applied.value, 1)
        XCTAssertEqual(Set(tokens), ["token-1"])
    }

    func testRenewsAgainOnceTheFirstHasFinished() async throws {
        let fetches = Counter()
        let renewer = GatewayTokenRenewer(dependencies: .init(
            fetchToken: { "token-\(fetches.increment())" },
            apply: { _ in }
        ))
        let first = try await renewer.renew()
        let second = try await renewer.renew()
        XCTAssertEqual(first, "token-1")
        XCTAssertEqual(second, "token-2")
    }

    func testAFailedFetchAppliesNothingAndDoesNotStick() async throws {
        let fetches = Counter()
        let applied = Counter()
        let renewer = GatewayTokenRenewer(dependencies: .init(
            fetchToken: {
                if fetches.increment() == 1 { throw StubError() }
                return "ok"
            },
            apply: { _ in applied.increment() }
        ))

        do {
            try await renewer.renew()
            XCTFail("expected the first renewal to fail")
        } catch {}
        XCTAssertEqual(applied.value, 0)

        let token = try await renewer.renew()
        XCTAssertEqual(token, "ok")
        XCTAssertEqual(applied.value, 1)
    }

    func testBlockingRenewalReportsTheOutcome() throws {
        let ok = GatewayTokenRenewer(dependencies: .init(fetchToken: { "t" }, apply: { _ in }))
        let failing = GatewayTokenRenewer(dependencies: .init(fetchToken: { throw StubError() }, apply: { _ in }))

        let done = expectation(description: "background")
        let results = Counter()
        DispatchQueue.global().async {
            if (try? ok.renewBlocking()) != nil { results.increment() }
            if (try? failing.renewBlocking()) == nil { results.increment() }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(results.value, 2)
    }
}

final class PbxSessionTests: XCTestCase {
    private let unauthorized = PbxApiClient.ApiError.httpError(statusCode: 401, message: "expired")

    func testUsesTheStoredTokenWithoutLoggingIn() async throws {
        let logins = Counter()
        let session = PbxSession(dependencies: .init(
            storedToken: { "stored" },
            login: { logins.increment(); return "fresh" }
        ))
        let used = try await session.authorized { $0 }
        XCTAssertEqual(used, "stored")
        XCTAssertEqual(logins.value, 0)
    }

    func testLogsInAgainOnA401AndRetriesOnce() async throws {
        let logins = Counter()
        let attempts = Counter()
        let session = PbxSession(dependencies: .init(
            storedToken: { "expired" },
            login: { logins.increment(); return "fresh" }
        ))
        let unauthorized = self.unauthorized

        let used = try await session.authorized { jwt -> String in
            attempts.increment()
            if jwt == "expired" { throw unauthorized }
            return jwt
        }
        XCTAssertEqual(used, "fresh")
        XCTAssertEqual(logins.value, 1)
        XCTAssertEqual(attempts.value, 2)
    }

    func testGivesUpAfterOneRetry() async {
        let attempts = Counter()
        let session = PbxSession(dependencies: .init(storedToken: { "a" }, login: { "b" }))
        let unauthorized = self.unauthorized
        do {
            _ = try await session.authorized { _ -> Int in
                attempts.increment()
                throw unauthorized
            }
            XCTFail("expected a 401")
        } catch {
            XCTAssertTrue(PbxSession.isUnauthorized(error))
        }
        XCTAssertEqual(attempts.value, 2)
    }

    func testOtherErrorsAreNotRetried() async {
        let attempts = Counter()
        let logins = Counter()
        let session = PbxSession(dependencies: .init(
            storedToken: { "a" },
            login: { logins.increment(); return "b" }
        ))
        do {
            _ = try await session.authorized { _ -> Int in
                attempts.increment()
                throw PbxApiClient.ApiError.httpError(statusCode: 503, message: "down")
            }
            XCTFail("expected a 503")
        } catch {}
        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(logins.value, 0)
    }

    func testLogsInWhenNoTokenIsStored() async throws {
        let session = PbxSession(dependencies: .init(storedToken: { nil }, login: { "fresh" }))
        let used = try await session.authorized { $0 }
        XCTAssertEqual(used, "fresh")
    }

    func testConcurrentExpiriesShareOneLogin() async throws {
        let logins = Counter()
        let session = PbxSession(dependencies: .init(
            storedToken: { "expired" },
            login: {
                logins.increment()
                try await Task.sleep(nanoseconds: 100_000_000)
                return "fresh"
            }
        ))
        let unauthorized = self.unauthorized

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await session.authorized { jwt -> String in
                        if jwt == "expired" { throw unauthorized }
                        return jwt
                    }
                }
            }
            for try await jwt in group {
                XCTAssertEqual(jwt, "fresh")
            }
        }
        XCTAssertEqual(logins.value, 1)
    }
}

final class EngineAuthRetryTests: XCTestCase {

    func testRecognisesOnlyAuthenticationErrors() {
        XCTAssertTrue(SipEngineManager.isAuthFailure(MobileError.AuthenticationError(message: "401")))
        XCTAssertFalse(SipEngineManager.isAuthFailure(MobileError.GatewayError(message: "502")))
        XCTAssertFalse(SipEngineManager.isAuthFailure(MobileError.Cancelled(message: "hangup")))
        XCTAssertFalse(SipEngineManager.isAuthFailure(StubError()))
    }

    func testRetriesOnceAfterRenewing() throws {
        let renewals = Counter()
        let attempts = Counter()
        let result = try SipEngineManager.retryingOnAuthFailure(renew: { renewals.increment() }) { () -> String in
            if attempts.increment() == 1 { throw MobileError.AuthenticationError(message: "expired") }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(renewals.value, 1)
        XCTAssertEqual(attempts.value, 2)
    }

    func testDoesNotRetryOtherErrors() {
        let renewals = Counter()
        let attempts = Counter()
        XCTAssertThrowsError(try SipEngineManager.retryingOnAuthFailure(renew: { renewals.increment() }) { () -> Int in
            attempts.increment()
            throw MobileError.CallFailed(message: "busy")
        })
        XCTAssertEqual(renewals.value, 0)
        XCTAssertEqual(attempts.value, 1)
    }

    func testASecondAuthFailureIsThrown() {
        let attempts = Counter()
        XCTAssertThrowsError(try SipEngineManager.retryingOnAuthFailure(renew: {}) { () -> Int in
            attempts.increment()
            throw MobileError.AuthenticationError(message: "still expired")
        }) { error in
            XCTAssertTrue(SipEngineManager.isAuthFailure(error))
        }
        XCTAssertEqual(attempts.value, 2)
    }

    func testAFailedRenewalIsThrownWithoutRetrying() {
        let attempts = Counter()
        XCTAssertThrowsError(try SipEngineManager.retryingOnAuthFailure(renew: { throw StubError() }) { () -> Int in
            attempts.increment()
            throw MobileError.AuthenticationError(message: "expired")
        }) { error in
            XCTAssertTrue(error is StubError)
        }
        XCTAssertEqual(attempts.value, 1)
    }
}

final class DeviceRegistrationDecodingTests: XCTestCase {

    func testReadsTransportAndToken() throws {
        let json = #"{"device_id":"d1","sip_domain":"sip.example.com","sip_port":5061,"sip_transport":"TLS","gateway_url":"https://push.example.com","gateway_token":"gt"}"#
        let response = try PbxApiClient.parseDeviceResponse(Data(json.utf8))
        XCTAssertEqual(response.deviceId, "d1")
        XCTAssertEqual(response.sipTransport, "tls")
        XCTAssertEqual(response.sipPort, 5061)
        XCTAssertEqual(response.gatewayToken, "gt")
    }

    func testOlderPbxWithoutTransport() throws {
        let json = #"{"device_id":"d1","sip_domain":"s","gateway_url":"g","gateway_token":"t"}"#
        let response = try PbxApiClient.parseDeviceResponse(Data(json.utf8))
        XCTAssertEqual(response.sipTransport, "")
        XCTAssertFalse(isValidTransport(response.sipTransport))
    }

    func testRejectsAResponseWithoutADevice() {
        XCTAssertThrowsError(try PbxApiClient.parseDeviceResponse(Data(#"{"gateway_token":"t"}"#.utf8)))
    }
}
