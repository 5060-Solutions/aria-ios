import XCTest
@testable import AriaSoftphone

/// Moving a call between the user's devices, against the contract's shapes.
final class CallMoveTests: XCTestCase {
    private let activeJSON = """
    [{"id":"c1","state":"active","direction":"inbound",
      "remote":{"number":"+13035550100","name":null},
      "started_at":"2026-11-25T22:00:00Z",
      "device":{"registration_id":"r-desk","label":"Desk phone","user_agent":"Yealink","transport":"tls"},
      "sip_call_id":"abc@pbx"}]
    """

    private func call(id: String = "c1", reg: String = "r-desk", sip: String? = "abc@pbx",
                      state: String = "active", started: TimeInterval = 0) -> UserCall {
        UserCall(id: id, state: state, direction: "inbound",
                 remote: .init(number: "+13035550100", name: "Ada"),
                 startedAt: Date(timeIntervalSince1970: started),
                 device: .init(registrationId: reg, label: "Desk phone", userAgent: nil, transport: nil),
                 sipCallId: sip)
    }

    // MARK: Wire

    func testActiveCallsDecodeAndPostsToTheRightPath() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(200, activeJSON)
        let client = PbxApiClient(baseUrl: "https://api.example.com", session: StubURLProtocol.session())
        let calls = try await client.activeCalls(jwt: "jwt")
        XCTAssertEqual(calls.first?.id, "c1")
        XCTAssertEqual(calls.first?.device.label, "Desk phone")
        XCTAssertEqual(calls.first?.remoteDisplay, "+13035550100")
        XCTAssertEqual(calls.first?.startedAt, ISO8601DateFormatter().date(from: "2026-11-25T22:00:00Z"))
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/v1/me/calls/active")
    }

    func testCurrentDeviceSendsTheSipInstance() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(200, #"{"registration_id":"r-me","label":"Aria iOS","user_agent":"x","transport":"tls","online":true}"#)
        let client = PbxApiClient(baseUrl: "https://api.example.com", session: StubURLProtocol.session())
        let device = try await client.currentDevice(jwt: "jwt", sipInstance: "urn:uuid:1234")
        XCTAssertEqual(device.registrationId, "r-me")
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.path, "/api/v1/me/devices/current")
        XCTAssertTrue(sent.url.absoluteString.contains("sip_instance=urn:uuid:1234") ||
                      sent.url.absoluteString.contains("sip_instance=urn%3Auuid%3A1234"))
    }

    func testMoveReturnsTheMoveIdAndSendsTheTarget() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(202, #"{"move_id":"m-1"}"#)
        let client = PbxApiClient(baseUrl: "https://api.example.com", session: StubURLProtocol.session())
        let moveId = try await client.moveCall(jwt: "jwt", callId: "c1", toRegistrationId: "r-me")
        XCTAssertEqual(moveId, "m-1")
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.path, "/api/v1/me/calls/c1/move")
        XCTAssertEqual(sent.body?["to_registration_id"] as? String, "r-me")
    }

    func testMoveRefusalsSurfaceTheirStatus() async {
        for status in [404, 409, 422] {
            StubURLProtocol.reset()
            StubURLProtocol.respond(status, #"{"error":"no"}"#)
            let client = PbxApiClient(baseUrl: "https://api.example.com", session: StubURLProtocol.session())
            do {
                _ = try await client.moveCall(jwt: "jwt", callId: "c1", toRegistrationId: "r")
                XCTFail("expected \(status)")
            } catch {
                guard case PbxApiClient.ApiError.httpError(let code, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(code, status)
                XCTAssertFalse(CallMoveModel.describe(error).isEmpty)
            }
        }
    }

    // MARK: Events

    func testParsesTheThreeEvents() {
        let active = #"{"type":"call_active_elsewhere","call":{"id":"c1","state":"held","direction":"outbound","remote":{"number":"1","name":"A"},"started_at":"2026-11-25T22:00:00.5Z","device":{"registration_id":"r1","label":"Desk"},"sip_call_id":null}}"#
        guard case .activeElsewhere(let parsed)? = CallMoveEvent.parse(active) else { return XCTFail("active") }
        XCTAssertEqual(parsed.state, "held")
        XCTAssertEqual(CallMoveEvent.parse(#"{"type":"call_moved","call_id":"c1","from_registration_id":"a","to_registration_id":"b"}"#),
                       .moved(callId: "c1", from: "a", to: "b"))
        XCTAssertEqual(CallMoveEvent.parse(#"{"type":"call_ended","call_id":"c1"}"#), .ended(callId: "c1"))
        XCTAssertNil(CallMoveEvent.parse(#"{"type":"sms_received"}"#))
        XCTAssertNil(CallMoveEvent.parse("not json"))
    }

    // MARK: Rules

    func testBannerIgnoresTheAppsOwnCallByRegistration() {
        let own = call(reg: "r-me", sip: nil)
        XCTAssertNil(CallMoveRules.elsewhereCall(in: [own], ownRegistrationId: "r-me", hasLocalCall: false))
        let other = call(id: "c2", reg: "r-desk")
        XCTAssertEqual(CallMoveRules.elsewhereCall(in: [own, other], ownRegistrationId: "r-me", hasLocalCall: false)?.id, "c2")
    }

    func testBannerIgnoresTheAppsOwnCallBySipCallId() {
        let mine = call(reg: "r-desk", sip: "leg-1")
        XCTAssertNil(CallMoveRules.elsewhereCall(in: [mine], ownRegistrationId: nil, ownCallIds: ["leg-1"], hasLocalCall: false))
    }

    func testNoBannerWhileACallIsUpHere() {
        XCTAssertNil(CallMoveRules.elsewhereCall(in: [call()], ownRegistrationId: "r-me", hasLocalCall: true))
    }

    func testBannerPrefersATalkingCall() {
        let held = call(id: "held", state: "held", started: 1)
        let active = call(id: "act", state: "active", started: 2)
        XCTAssertEqual(CallMoveRules.elsewhereCall(in: [held, active], ownRegistrationId: "r-me", hasLocalCall: false)?.id, "act")
    }

    func testMoveTargetsAreOtherOnlineDevices() {
        func device(_ id: String, online: Bool) -> UserDevice {
            UserDevice(registrationId: id, label: id, userAgent: nil, transport: nil, online: online)
        }
        let targets = CallMoveRules.targets([device("me", online: true), device("a", online: true), device("b", online: false)],
                                            ownRegistrationId: "me")
        XCTAssertEqual(targets.map(\.registrationId), ["a"])
    }

    func testSipInstanceIsAUuidUrn() {
        XCTAssertEqual(CallMoveRules.sipInstance(deviceId: "6F1C2A9E-1111-4222-8333-944455556666"),
                       "urn:uuid:6f1c2a9e-1111-4222-8333-944455556666")
        XCTAssertEqual(CallMoveRules.sipInstance(deviceId: "dev-1"), "dev-1")
    }

    // MARK: Pending moves

    func testAMoveIsConsumedOnce() {
        let store = PendingMoveStore()
        let began = Date(timeIntervalSince1970: 100)
        store.register(moveId: "m1", callStartedAt: began, fromLabel: "Desk")
        XCTAssertEqual(store.consume(moveId: "m1")?.callStartedAt, began)
        XCTAssertNil(store.consume(moveId: "m1"), "a replayed push is an ordinary call")
        XCTAssertNil(store.consume(moveId: "other"))
    }

    func testAMoveExpires() {
        let store = PendingMoveStore()
        let t0 = Date()
        store.register(moveId: "m1", callStartedAt: t0, fromLabel: "Desk", now: t0)
        XCTAssertEqual(PendingMoveStore.lifetime, 30)
        XCTAssertNil(store.consume(moveId: "m1", now: t0.addingTimeInterval(PendingMoveStore.lifetime + 1)))
    }

    // MARK: Push

    func testPushCarriesTheMoveId() throws {
        let configured = "https://push.example.com"
        for (key, from) in [("moveId", "moveFrom"), ("move_id", "move_from")] {
            let payload: [AnyHashable: Any] = ["callToken": "t", "callerUri": "1", key: "m-9", from: "Desk"]
            let push = try IncomingPush.parse(payload, configuredGateway: configured).get()
            XCTAssertEqual(push.moveId, "m-9")
            XCTAssertEqual(push.moveFrom, "Desk")
        }
        XCTAssertNil(try IncomingPush.parse(["callToken": "t"], configuredGateway: configured).get().moveId)
    }

    func testAnUnrequestedMoveRingsLabelledWithItsSource() {
        XCTAssertEqual(CallMoveLabel.unrequested(name: "Ada", from: "Desk"), "Ada · Moving call from Desk")
    }

    // MARK: Call

    func testAMovedCallCountsFromTheOriginalStart() {
        var moved = ActiveCall(uuid: UUID(), callToken: "t", remoteUri: "1", remoteName: nil, direction: .inbound, state: .connected)
        moved.connectedAt = Date()
        XCTAssertLessThan(moved.duration, 2)
        moved.originalStartedAt = Date().addingTimeInterval(-600)
        XCTAssertGreaterThan(moved.duration, 599)
    }

    // MARK: Model

    private final class FakeBackend: CallMoveBackend {
        var calls: [UserCall] = []
        var all: [UserDevice] = []
        var own = UserDevice(registrationId: "r-me", label: "Aria iOS", userAgent: nil, transport: nil, online: true)
        var moveResult: Result<String, Error> = .success("m-1")
        var moved: [(String, String)] = []
        var instances: [String] = []

        func activeCalls() async throws -> [UserCall] { calls }
        func devices() async throws -> [UserDevice] { all }
        func currentDevice(sipInstance: String) async throws -> UserDevice { instances.append(sipInstance); return own }
        func move(callId: String, to registrationId: String) async throws -> String {
            moved.append((callId, registrationId))
            return try moveResult.get()
        }
        func eventStreamRequest() async throws -> URLRequest? { nil }
    }

    @MainActor private func model(_ backend: FakeBackend, store: PendingMoveStore) -> CallMoveModel {
        let model = CallMoveModel(backend: backend, pending: store)
        model.hasLocalCall = { false }
        model.deviceId = { "6f1c2a9e-1111-4222-8333-944455556666" }
        model.isSignedIn = { true }
        return model
    }

    @MainActor func testRefreshOffersOnlyOtherDevicesCalls() async {
        let backend = FakeBackend()
        backend.calls = [call(id: "mine", reg: "r-me", sip: nil), call(id: "theirs", reg: "r-desk")]
        let model = model(backend, store: PendingMoveStore())
        await model.refresh()
        XCTAssertEqual(model.elsewhere?.id, "theirs")
        XCTAssertEqual(backend.instances, ["urn:uuid:6f1c2a9e-1111-4222-8333-944455556666"])
    }

    @MainActor func testMoveHereKeepsTheMoveId() async {
        let backend = FakeBackend()
        let store = PendingMoveStore()
        let model = model(backend, store: store)
        let target = call(id: "c9", started: 500)
        await model.moveHere(target)
        XCTAssertEqual(backend.moved.first?.0, "c9")
        XCTAssertEqual(backend.moved.first?.1, "r-me")
        let entry = store.consume(moveId: "m-1")
        XCTAssertEqual(entry?.callStartedAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(entry?.fromLabel, "Desk phone")
    }

    @MainActor func testAFailedMoveRegistersNothingAndSaysWhy() async {
        let backend = FakeBackend()
        backend.moveResult = .failure(PbxApiClient.ApiError.httpError(statusCode: 409, message: ""))
        let store = PendingMoveStore()
        let model = model(backend, store: store)
        await model.moveHere(call())
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(store.consume(moveId: "m-1"))
    }

    @MainActor func testMoveToSendsThisPhonesCallToTheChosenDevice() async {
        let backend = FakeBackend()
        backend.calls = [call(id: "mine", reg: "r-me", sip: nil)]
        let model = model(backend, store: PendingMoveStore())
        let tablet = UserDevice(registrationId: "r-tab", label: "iPad", userAgent: nil, transport: nil, online: true)
        let ok = await model.moveOwnCall(to: tablet)
        XCTAssertTrue(ok)
        XCTAssertEqual(backend.moved.first?.0, "mine")
        XCTAssertEqual(backend.moved.first?.1, "r-tab")
        XCTAssertEqual(model.takeMovedAway(), "iPad")
        XCTAssertNil(model.takeMovedAway(), "once")
    }

    @MainActor func testMoveToWithoutAPbxCallDoesNothing() async {
        let backend = FakeBackend()
        let model = model(backend, store: PendingMoveStore())
        let ok = await model.moveOwnCall(to: UserDevice(registrationId: "x", label: nil, userAgent: nil, transport: nil, online: true))
        XCTAssertFalse(ok)
        XCTAssertTrue(backend.moved.isEmpty)
    }

    @MainActor func testEventsUpdateTheBanner() async {
        let backend = FakeBackend()
        let model = model(backend, store: PendingMoveStore())
        _ = await model.ownRegistration()
        model.handle(.activeElsewhere(call(id: "c1")))
        XCTAssertEqual(model.elsewhere?.id, "c1")
        model.handle(.ended(callId: "c1"))
        XCTAssertNil(model.elsewhere)
    }

    @MainActor func testDismissingHidesThatCallOnly() async {
        let model = model(FakeBackend(), store: PendingMoveStore())
        model.handle(.activeElsewhere(call(id: "c1")))
        model.dismissBanner()
        XCTAssertNil(model.elsewhere)
        model.handle(.activeElsewhere(call(id: "c1")))
        XCTAssertNil(model.elsewhere)
        model.handle(.activeElsewhere(call(id: "c2")))
        XCTAssertEqual(model.elsewhere?.id, "c2")
    }

    @MainActor func testMovedNoticeNamesTheDevice() {
        let model = model(FakeBackend(), store: PendingMoveStore())
        model.showMoved(to: "iPad")
        XCTAssertEqual(model.notice?.message, "Moved to iPad")
    }
}
