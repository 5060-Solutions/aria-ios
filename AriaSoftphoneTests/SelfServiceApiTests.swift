import XCTest
@testable import AriaSoftphone

/// The self-service routes, against a stubbed server, with the request and
/// response shapes of aria-api's handlers.
final class SelfServiceApiTests: XCTestCase {
    private let ext = "6f1c2a9e-1111-4222-8333-944455556666"
    private var client: PbxApiClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = PbxApiClient(baseUrl: "https://api.example.com/", session: StubURLProtocol.session())
    }

    func testFeaturesReadsDoNotDisturb() async throws {
        StubURLProtocol.respond(200, """
        {"id":"a","extension_id":"\(ext)","tenant_id":"t","do_not_disturb":true,
         "music_on_hold_url":null,"max_concurrent_calls":0,"hotdesk_enabled":false,
         "updated_at":"2026-11-23T10:00:00Z"}
        """)
        let features = try await client.features(jwt: "jwt", extensionId: ext)
        XCTAssertTrue(features.doNotDisturb)
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.url.absoluteString, "https://api.example.com/api/v1/extensions/\(ext)/features")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer jwt")
    }

    func testSettingDndSendsOnlyThatField() async throws {
        StubURLProtocol.handler = { _ in (204, Data()) }
        try await client.setDoNotDisturb(jwt: "jwt", extensionId: ext, enabled: false)
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.body?.count, 1, "the PBX refuses unknown fields and admin-only ones")
        XCTAssertEqual(sent.body?["do_not_disturb"] as? Bool, false)
    }

    func testForwardsListDecodes() async throws {
        StubURLProtocol.respond(200, """
        [{"id":"f1","extension_id":"\(ext)","tenant_id":"t","forward_type":"no_answer",
          "destination":"+15551234567","ring_timeout_secs":25,"enabled":true,
          "created_at":"2026-11-20T09:00:00.123Z"}]
        """)
        let forwards = try await client.forwards(jwt: "jwt", extensionId: ext)
        XCTAssertEqual(forwards, [PbxApiClient.CallForward(id: "f1", forwardType: .noAnswer,
                                                           destination: "+15551234567",
                                                           ringTimeoutSecs: 25, enabled: true)])
    }

    func testCreateForwardPostsTheHandlerFields() async throws {
        StubURLProtocol.respond(201, """
        {"id":"f2","extension_id":"\(ext)","tenant_id":"t","forward_type":"busy",
         "destination":"1000","ring_timeout_secs":20,"enabled":true,"created_at":"2026-11-23T10:00:00Z"}
        """)
        let created = try await client.createForward(jwt: "jwt", extensionId: ext, type: .busy,
                                                     destination: "1000", ringTimeoutSecs: 20, enabled: true)
        XCTAssertEqual(created.id, "f2")
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.path, "/api/v1/extensions/\(ext)/forwards")
        XCTAssertEqual(sent.body?["forward_type"] as? String, "busy")
        XCTAssertEqual(sent.body?["destination"] as? String, "1000")
        XCTAssertEqual(sent.body?["ring_timeout_secs"] as? Int, 20)
        XCTAssertEqual(sent.body?["enabled"] as? Bool, true)
    }

    func testUpdateAndDeleteUseTheForwardsRoute() async throws {
        StubURLProtocol.respond(200, """
        {"id":"f1","extension_id":"\(ext)","tenant_id":"t","forward_type":"unconditional",
         "destination":"1001","ring_timeout_secs":20,"enabled":false,"created_at":"2026-11-23T10:00:00Z"}
        """)
        let updated = try await client.updateForward(jwt: "jwt", id: "f1", enabled: false)
        XCTAssertFalse(updated.enabled)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PUT")
        XCTAssertEqual(StubURLProtocol.requests.last?.url.path, "/api/v1/forwards/f1")
        XCTAssertEqual(StubURLProtocol.requests.last?.body?.count, 1)

        StubURLProtocol.handler = { _ in (204, Data()) }
        try await client.deleteForward(jwt: "jwt", id: "f1")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")
    }

    func testARefusedForwardCarriesThePbxReason() async {
        StubURLProtocol.respond(422, #"{"error":"This extension cannot forward there: international calls are off.","status":422,"field":"destination"}"#)
        do {
            _ = try await client.createForward(jwt: "jwt", extensionId: ext, type: .unconditional,
                                               destination: "+44207", ringTimeoutSecs: 20, enabled: true)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(SelfService.describe(error), "This extension cannot forward there: international calls are off.")
        }
    }

    func testCallRecordsDecodeOwnCallsAndClampTheLimit() async throws {
        StubURLProtocol.respond(200, """
        [{"id":"c1","direction":"inbound","from_uri":"sip:+15551234567@carrier","to_uri":"sip:1001@acme",
          "from_number":"+15551234567","from_name":"Ann","to_number":"1001","to_name":null,
          "disposition":"no_answer","started_at":"2026-11-23T09:00:00Z","answered_at":null,
          "ended_at":"2026-11-23T09:00:30Z","duration_secs":0}]
        """)
        let calls = try await client.callRecords(jwt: "jwt", extensionId: ext, limit: 500)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].fromName, "Ann")
        let query = URLComponents(url: StubURLProtocol.requests[0].url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "200")
    }

    func testAPathSegmentThatIsNotAnIdIsRefused() async {
        do {
            _ = try await client.forwards(jwt: "jwt", extensionId: "../tenants")
            XCTFail("expected invalidURL")
        } catch {
            XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        }
    }
}

/// A backend the test controls.
private final class FakeSelfServiceBackend: SelfServiceBackend {
    var dnd = false
    var failDnd = false
    var stored: [PbxApiClient.CallForward] = []
    var created: [(PbxApiClient.ForwardType, String)] = []
    var updated: [String] = []

    func doNotDisturb() async throws -> Bool { dnd }
    func setDoNotDisturb(_ enabled: Bool) async throws {
        if failDnd { throw PbxApiClient.ApiError.httpError(statusCode: 500, message: "boom") }
        dnd = enabled
    }
    func forwards() async throws -> [PbxApiClient.CallForward] { stored }
    func createForward(type: PbxApiClient.ForwardType, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward {
        created.append((type, destination))
        return .init(id: "new-\(type.rawValue)", forwardType: type, destination: destination,
                     ringTimeoutSecs: ringTimeoutSecs, enabled: enabled)
    }
    func updateForward(id: String, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward {
        updated.append(id)
        let type = stored.first { $0.id == id }!.forwardType
        return .init(id: id, forwardType: type, destination: destination, ringTimeoutSecs: ringTimeoutSecs, enabled: enabled)
    }
    func deleteForward(id: String) async throws { stored.removeAll { $0.id == id } }
    func callRecords(limit: Int) async throws -> [PbxApiClient.ServerCall] { [] }
    func reset() {}
}

@MainActor
final class SelfServiceTests: XCTestCase {
    func testDndIsShownAtOnceAndPutBackWhenRefused() async {
        let backend = FakeSelfServiceBackend()
        let service = SelfService(backend: backend)
        await service.refresh()
        XCTAssertEqual(service.doNotDisturb, false)
        await service.setDoNotDisturb(true)
        XCTAssertEqual(service.doNotDisturb, true)
        backend.failDnd = true
        await service.setDoNotDisturb(false)
        XCTAssertEqual(service.doNotDisturb, true, "a refused change is undone")
        XCTAssertNotNil(service.errorMessage)
    }

    func testSavingCreatesThenUpdates() async {
        let backend = FakeSelfServiceBackend()
        let service = SelfService(backend: backend)
        await service.refresh()
        let ok = await service.saveForward(type: .unconditional, destination: " 1000 ", ringTimeoutSecs: 20, enabled: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(backend.created.map(\.1), ["1000"])
        XCTAssertTrue(service.isForwardingAll)
        backend.stored = service.forwards
        let updatedOk = await service.saveForward(type: .unconditional, destination: "1001", ringTimeoutSecs: 20, enabled: true)
        XCTAssertTrue(updatedOk)
        XCTAssertEqual(backend.updated, ["new-unconditional"])
        XCTAssertEqual(service.forward(.unconditional)?.destination, "1001")
    }

    func testEmptyAndEmergencyDestinationsAreRefusedLocally() async {
        let backend = FakeSelfServiceBackend()
        let service = SelfService(backend: backend)
        let ok = await service.saveForward(type: .busy, destination: "  ", ringTimeoutSecs: 20, enabled: true)
        XCTAssertFalse(ok)
        let emergencyOk = await service.saveForward(type: .busy, destination: "911", ringTimeoutSecs: 20, enabled: true)
        XCTAssertFalse(emergencyOk)
        XCTAssertTrue(backend.created.isEmpty)
    }

    func testRemoveDeletesTheForward() async {
        let backend = FakeSelfServiceBackend()
        backend.stored = [.init(id: "f1", forwardType: .busy, destination: "1000", ringTimeoutSecs: 20, enabled: true)]
        let service = SelfService(backend: backend)
        await service.refresh()
        await service.removeForward(.busy)
        XCTAssertNil(service.forward(.busy))
    }
}

final class ServerCallHistoryTests: XCTestCase {
    private func server(_ id: String, direction: String = "inbound", from: String = "+15551234567",
                        to: String = "1001", disposition: String = "answered", at seconds: TimeInterval,
                        duration: Int = 60) -> PbxApiClient.ServerCall {
        PbxApiClient.ServerCall(
            id: id, direction: direction, fromUri: "sip:\(from)@x", toUri: "sip:\(to)@acme",
            fromNumber: from, fromName: nil, toNumber: to, toName: nil, disposition: disposition,
            startedAt: Date(timeIntervalSince1970: seconds), answeredAt: nil, endedAt: nil, durationSecs: duration
        )
    }

    private func local(_ direction: CallRecord.Direction, _ uri: String, at seconds: TimeInterval,
                       outcome: CallOutcome = .answered) -> CallRecord {
        CallRecord(direction: direction, remoteUri: uri, remoteName: nil,
                   startedAt: Date(timeIntervalSince1970: seconds), duration: 60, outcome: outcome)
    }

    func testMappingFollowsDirectionAndDisposition() {
        let missed = CallRecord(server: server("a", disposition: "no_answer", at: 0), ownExtension: "1001")
        XCTAssertEqual(missed.direction, .inbound)
        XCTAssertEqual(missed.outcome, .missed)
        XCTAssertEqual(missed.remoteUri, "+15551234567")
        XCTAssertEqual(missed.duration, 0)

        let out = CallRecord(server: server("b", direction: "internal", from: "1001", to: "1017", at: 0),
                             ownExtension: "1001")
        XCTAssertEqual(out.direction, .outbound)
        XCTAssertEqual(out.remoteUri, "1017")
        XCTAssertEqual(out.duration, 60)
        XCTAssertEqual(out.serverId, "b")

        let failed = CallRecord(server: server("c", direction: "outbound", from: "1001", to: "+15550000000",
                                               disposition: "busy", at: 0), ownExtension: "1001")
        XCTAssertEqual(failed.outcome, .failed)
    }

    func testTheSameCallIsNotAddedTwice() {
        // The phone saw the call 20 s before the PBX stamped it, without the +1.
        let records = CallHistoryStore.merge(
            local: [local(.inbound, "sip:5551234567@acme", at: 1_000)],
            server: [server("s1", at: 1_020), server("s2", from: "1017", at: 5_000)],
            ownExtension: "1001"
        )
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.serverId), ["s2", "s1"], "newest first; the local copy is tagged")
        // A second sync changes nothing.
        let again = CallHistoryStore.merge(local: records, server: [server("s1", at: 1_020), server("s2", from: "1017", at: 5_000)],
                                           ownExtension: "1001")
        XCTAssertEqual(again, records)
    }

    func testCallsOutsideTheWindowOrToSomeoneElseAreSeparate() {
        let records = CallHistoryStore.merge(
            local: [local(.inbound, "+15551234567", at: 1_000)],
            server: [server("late", at: 1_500), server("other", from: "+15559999999", at: 1_000)],
            ownExtension: "1001"
        )
        XCTAssertEqual(records.count, 3)
    }

    func testSamePartyComparesUserPartsAndTheLastTenDigits() {
        XCTAssertTrue(CallRecord.sameParty("sip:1001@a", "1001"))
        XCTAssertTrue(CallRecord.sameParty("+1 (555) 123-4567", "5551234567"))
        XCTAssertFalse(CallRecord.sameParty("1001", "1002"))
        XCTAssertFalse(CallRecord.sameParty("123", "0123"))
    }

    func testImportPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CallHistoryStore(fileURL: url)
        store.importServerCalls([server("s1", at: 1_000)], ownExtension: "1001")
        XCTAssertEqual(CallHistoryStore(fileURL: url).records.first?.serverId, "s1")
    }
}
