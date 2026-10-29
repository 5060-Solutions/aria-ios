import XCTest
@testable import AriaSoftphone

final class ProvisioningTests: XCTestCase {

    private func uri(_ params: [String: String]) -> String {
        var components = URLComponents()
        components.scheme = "aria"
        components.host = "provision"
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.string!
    }

    private var base: [String: String] {
        [
            "server": "sip.example.com",
            "user": "1001",
            "pass": Data("s3cret".utf8).base64EncodedString(),
            "api": "https://api.example.com",
            "tenant": "acme.example.com",
            "vm": "*97",
        ]
    }

    // MARK: - Parsing

    func testParsesAFullCode() throws {
        var params = base
        params["name"] = "Ada"
        params["transport"] = "TCP"
        params["port"] = "5070"

        let creds = try XCTUnwrap(parseProvisioningURI(uri(params)))
        XCTAssertEqual(creds.server, "sip.example.com")
        XCTAssertEqual(creds.username, "1001")
        XCTAssertEqual(creds.password, "s3cret")
        XCTAssertEqual(creds.displayName, "Ada")
        XCTAssertEqual(creds.transport, "tcp")
        XCTAssertEqual(creds.port, 5070)
        XCTAssertEqual(creds.voicemail, "*97")
        XCTAssertEqual(creds.apiUrl, "https://api.example.com")
        XCTAssertEqual(creds.tenantDomain, "acme.example.com")
    }

    func testMissingTransportDefaultsToTLSOn5061() throws {
        let creds = try XCTUnwrap(parseProvisioningURI(uri(base)))
        XCTAssertEqual(creds.transport, "tls")
        XCTAssertEqual(creds.port, 5061)
    }

    func testExplicitUDPIsHonouredWithItsDefaultPort() throws {
        var params = base
        params["transport"] = "udp"
        let creds = try XCTUnwrap(parseProvisioningURI(uri(params)))
        XCTAssertEqual(creds.transport, "udp")
        XCTAssertEqual(creds.port, 5060)
    }

    func testDisplayNameDefaultsToUser() throws {
        let creds = try XCTUnwrap(parseProvisioningURI(uri(base)))
        XCTAssertEqual(creds.displayName, "1001")
    }

    func testRejectsWrongSchemeOrHost() {
        XCTAssertNil(parseProvisioningURI(uri(base).replacingOccurrences(of: "aria://", with: "https://")))
        XCTAssertNil(parseProvisioningURI(uri(base).replacingOccurrences(of: "provision", with: "other")))
        XCTAssertNil(parseProvisioningURI("not a url"))
    }

    func testRejectsMissingRequiredFields() {
        for key in ["server", "user", "pass"] {
            var params = base
            params.removeValue(forKey: key)
            XCTAssertNil(parseProvisioningURI(uri(params)), "accepted a code without \(key)")
        }
    }

    func testRejectsPasswordThatIsNotBase64() {
        var params = base
        params["pass"] = "%%%not-base64%%%"
        XCTAssertNil(parseProvisioningURI(uri(params)))
    }

    // MARK: - Validation

    func testTransportAllowList() {
        XCTAssertTrue(isValidTransport("udp"))
        XCTAssertTrue(isValidTransport("TCP"))
        XCTAssertTrue(isValidTransport("tls"))
        XCTAssertFalse(isValidTransport("sctp"))
        XCTAssertFalse(isValidTransport(""))
        XCTAssertFalse(isValidTransport("tls "))
    }

    func testDestinationRequiresHTTPSAndValidHosts() {
        XCTAssertTrue(isValidProvisioningDestination(apiUrl: "https://api.example.com", server: "sip.example.com"))
        XCTAssertTrue(isValidProvisioningDestination(apiUrl: "https://api.example.com:8443/base", server: "10.0.0.1"))
        XCTAssertFalse(isValidProvisioningDestination(apiUrl: "http://api.example.com", server: "sip.example.com"))
        XCTAssertFalse(isValidProvisioningDestination(apiUrl: "", server: "sip.example.com"))
        XCTAssertFalse(isValidProvisioningDestination(apiUrl: "https://", server: "sip.example.com"))
        XCTAssertFalse(isValidProvisioningDestination(apiUrl: "https://api.example.com", server: ""))
        XCTAssertFalse(isValidProvisioningDestination(apiUrl: "https://api.example.com", server: "sip.example.com/path"))
        XCTAssertFalse(isValidProvisioningDestination(apiUrl: "https://api.example.com", server: " sip.example.com"))
        XCTAssertFalse(isValidProvisioningDestination(apiUrl: "https://api.example.com", server: "..."))
    }

    // MARK: - Stored account

    func testAccountFromProvisioningUsesTenantAsDomain() throws {
        let creds = try XCTUnwrap(parseProvisioningURI(uri(base)))
        let account = AccountSettings(provisioning: creds)
        XCTAssertEqual(account.domain, "acme.example.com")
        XCTAssertEqual(account.registrar, "sip.example.com")
        XCTAssertEqual(account.voicemailNumber, "*97")
    }

    func testAccountFallsBackToServerWithoutTenant() throws {
        var params = base
        params.removeValue(forKey: "tenant")
        let creds = try XCTUnwrap(parseProvisioningURI(uri(params)))
        XCTAssertEqual(AccountSettings(provisioning: creds).domain, "sip.example.com")
    }

    func testEffectiveTransportNeverFallsBackToCleartext() {
        var account = AccountSettings(
            username: "1001", domain: "d", registrar: "", port: 0, transport: "",
            displayName: "", apiUrl: "", gatewayUrl: "", voicemailNumber: ""
        )
        XCTAssertEqual(account.effectiveTransport, "tls")
        XCTAssertEqual(account.effectivePort, 5061)

        account.transport = "bogus"
        XCTAssertEqual(account.effectiveTransport, "tls")

        account.transport = "UDP"
        XCTAssertEqual(account.effectiveTransport, "udp")
        XCTAssertEqual(account.effectivePort, 5060)

        account.port = 7000
        XCTAssertEqual(account.effectivePort, 7000)
        XCTAssertEqual(account.sipCredentials(password: "p").port, 7000)
        XCTAssertNil(account.sipCredentials(password: "p").registrar)
    }

    func testAccountRoundTripsThroughDefaults() throws {
        let suite = "ProvisioningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let account = AccountSettings(
            username: "1001", domain: "acme", registrar: "sip", port: 5061, transport: "tls",
            displayName: "Ada", apiUrl: "https://api", gatewayUrl: "https://gw", voicemailNumber: "*97"
        )
        account.save(to: defaults)
        XCTAssertEqual(AccountSettings.load(from: defaults), account)

        AccountSettings.clear(from: defaults)
        XCTAssertFalse(AccountSettings.load(from: defaults).isProvisioned)
    }
}
