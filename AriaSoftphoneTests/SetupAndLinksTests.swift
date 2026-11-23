import XCTest
import Intents
@testable import AriaSoftphone

final class ManualSetupTests: XCTestCase {
    private func valid() -> ManualSetup {
        var form = ManualSetup()
        form.domain = "acme.ariaroute.com"
        form.extensionNumber = "1001"
        form.password = "s3cret"
        return form
    }

    func testAnEmptyFormNamesTheRequiredFields() {
        let problems = ManualSetup().problems()
        XCTAssertEqual(problems[.domain], .required)
        XCTAssertEqual(problems[.extensionNumber], .required)
        XCTAssertEqual(problems[.password], .required)
        XCTAssertNil(problems[.server])
        XCTAssertNil(problems[.apiUrl], "an empty API address means the default")
    }

    func testAValidFormUsesTheDefaultsForTheOptionalFields() throws {
        let credentials = try XCTUnwrap(valid().credentials())
        XCTAssertEqual(credentials.apiUrl, ManualSetup.defaultApiUrl)
        XCTAssertEqual(credentials.server, "acme.ariaroute.com")
        XCTAssertEqual(credentials.tenantDomain, "acme.ariaroute.com")
        XCTAssertEqual(credentials.username, "1001")
        XCTAssertEqual(credentials.transport, "tls")
    }

    func testTheApiMustBeHttps() {
        var form = valid()
        form.apiUrl = "http://api.acme.example"
        XCTAssertEqual(form.problems()[.apiUrl], .notHttps)
        form.apiUrl = "https://user:pw@api.acme.example"
        XCTAssertEqual(form.problems()[.apiUrl], .invalidUrl)
        form.apiUrl = "api.acme.example"
        XCTAssertNotNil(form.problems()[.apiUrl])
        form.apiUrl = " https://api.acme.example "
        XCTAssertNil(form.problems()[.apiUrl])
        XCTAssertEqual(form.credentials()?.apiUrl, "https://api.acme.example")
    }

    func testHostsAndExtensionsAreChecked() {
        var form = valid()
        form.domain = "acme example"
        XCTAssertEqual(form.problems()[.domain], .invalidHost)
        form = valid()
        form.server = "sip:pbx.example.com"
        XCTAssertEqual(form.problems()[.server], .invalidHost)
        form.server = "10.0.0.5"
        XCTAssertNil(form.problems()[.server])
        form = valid()
        form.extensionNumber = "10 01"
        XCTAssertEqual(form.problems()[.extensionNumber], .invalidExtension)
        XCTAssertNil(form.credentials())
    }
}

final class DeepLinkTests: XCTestCase {
    private func parse(_ string: String) -> DeepLink? {
        DeepLink.parse(URL(string: string)!)
    }

    func testAVersionedSetupLinkIsKeptWhole() {
        let link = "aria://provision?v=1&url=https%3A%2F%2Fapi.example.com%2Fprovision%2Fsoftphone%2Fabc"
        XCTAssertEqual(parse(link), .setupLink(link))
    }

    func testALegacyLinkIsParsedAsBefore() {
        let pass = Data("pw".utf8).base64EncodedString()
        guard case .legacyProvisioning(let credentials)? =
                parse("aria://provision?server=sip.example.com&user=1001&pass=\(pass)&api=https://api.example.com&tenant=acme.example.com") else {
            return XCTFail("expected a legacy link")
        }
        XCTAssertEqual(credentials.username, "1001")
        XCTAssertEqual(credentials.password, "pw")
        XCTAssertNil(parse("aria://provision?server=x"), "incomplete legacy link")
    }

    func testSipTelAndCallLinksDial() {
        XCTAssertEqual(parse("sip:1001@pbx.example.com;transport=tls"), .dial("1001@pbx.example.com"))
        XCTAssertEqual(parse("sips:2002@pbx.example.com"), .dial("2002@pbx.example.com"))
        XCTAssertEqual(parse("tel:+15551234567"), .dial("+15551234567"))
        XCTAssertEqual(parse("aria://call?to=1003"), .dial("1003"))
        XCTAssertNil(parse("aria://call"))
        XCTAssertNil(parse("aria://elsewhere"))
        XCTAssertNil(parse("https://example.com"))
    }

    func testARecentsCallBackDialsTheHandle() {
        let person = INPerson(personHandle: INPersonHandle(value: "1001", type: .phoneNumber),
                              nameComponents: nil, displayName: nil, image: nil,
                              contactIdentifier: nil, customIdentifier: nil)
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                                       destinationType: .normal, contacts: [person], callCapability: .audioCall)
        XCTAssertEqual(DeepLink.parse(intent), .dial("1001"))
    }

    @MainActor
    func testADialLinkWithoutAnAccountOnlyHandsOffEmergencyNumbers() {
        let coordinator = DeepLinkCoordinator()
        coordinator.isSignedIn = { false }
        var opened: [URL] = []
        let saved = EmergencyDialer.open
        EmergencyDialer.open = { opened.append($0) }
        defer { EmergencyDialer.open = saved }

        coordinator.handle(URL(string: "tel:1001")!)
        XCTAssertNil(coordinator.pending)
        coordinator.handle(URL(string: "tel:911")!)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(opened.map(\.absoluteString), ["tel:911"])
    }

    @MainActor
    func testADialLinkWhileSignedInWaitsForConfirmation() {
        let coordinator = DeepLinkCoordinator()
        coordinator.isSignedIn = { true }
        coordinator.handle(URL(string: "sip:1001@pbx.example.com")!)
        XCTAssertEqual(coordinator.pending?.link, .dial("1001@pbx.example.com"))
        coordinator.dismiss()
        XCTAssertNil(coordinator.pending)
    }
}

final class SetupLinkTests: XCTestCase {
    func testVersionedLinksAreToldApartFromLegacyOnes() {
        XCTAssertTrue(SetupLinkService.isVersionedLink("aria://provision?v=1&url=x"))
        XCTAssertTrue(SetupLinkService.isVersionedLink("ARIA://Provision?v=1&url=x"))
        XCTAssertFalse(SetupLinkService.isVersionedLink("aria://provision?server=x&user=y"))
        XCTAssertFalse(SetupLinkService.isVersionedLink("https://example.com?v=1"))
    }

    func testTheCoreRefusesAPlainHttpLinkBeforeAnyRequest() {
        let link = "aria://provision?v=1&url=http%3A%2F%2Fapi.example.com%2Fprovision%2Fsoftphone%2Fabc"
        XCTAssertThrowsError(try provisionPreview(link: link)) { error in
            guard case ProvisionError.InvalidLink? = error as? ProvisionError else {
                return XCTFail("expected InvalidLink, got \(error)")
            }
        }
    }

    func testARedeemedAccountSignsInAgainstTheSetupServer() {
        let account = ProvisionedAccount(
            username: "1001", authUsername: nil, password: "pw", domain: "acme.example.com",
            transport: "auto", port: 0, outboundProxy: "edge.example.com:5070", voicemail: "*97",
            srtp: nil, tenantName: "Acme", displayName: "Ann", serverHost: "api.example.com:8443"
        )
        let credentials = ProvisioningCredentials(redeemed: account)
        XCTAssertEqual(credentials.apiUrl, "https://api.example.com:8443")
        XCTAssertEqual(credentials.server, "edge.example.com")
        XCTAssertEqual(credentials.tenantDomain, "acme.example.com")
        XCTAssertEqual(credentials.transport, "tls", "auto falls back to TLS")
        XCTAssertEqual(credentials.port, 5061)
        XCTAssertEqual(credentials.voicemail, "*97")
        XCTAssertTrue(isValidProvisioningDestination(apiUrl: credentials.apiUrl, server: credentials.server))
    }

    func testWithoutAProxyTheDomainIsTheServer() {
        let account = ProvisionedAccount(
            username: "1001", authUsername: nil, password: "pw", domain: "acme.example.com",
            transport: "udp", port: 5080, outboundProxy: nil, voicemail: nil,
            srtp: nil, tenantName: "Acme", displayName: "1001", serverHost: "api.example.com"
        )
        let credentials = ProvisioningCredentials(redeemed: account)
        XCTAssertEqual(credentials.server, "acme.example.com")
        XCTAssertEqual(credentials.port, 5080)
        XCTAssertEqual(credentials.transport, "udp")
    }

    func testThePreviewAndRedeemRunOffTheMainThread() async throws {
        let preview = ProvisionPreview(tenantName: "Acme", extension: "1001", displayName: "Ann",
                                       domain: "acme.example.com", expiresAt: nil, serverHost: "api.example.com")
        var previewOnMain: Bool?
        let service = SetupLinkService(
            preview: { _ in previewOnMain = Thread.isMainThread; return preview },
            redeem: { _ in throw ProvisionError.Expired(message: "gone") }
        )
        let fetched = try await service.fetchPreview("aria://provision?v=1&url=x")
        XCTAssertEqual(fetched.serverHost, "api.example.com")
        XCTAssertEqual(previewOnMain, false)
        do {
            _ = try await service.fetchAccount("aria://provision?v=1&url=x")
            XCTFail("expected Expired")
        } catch {
            XCTAssertTrue(SetupLinkService.describe(error).contains("expired"))
        }
    }
}
