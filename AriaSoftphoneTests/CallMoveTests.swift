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
        var statuses: [Result<MoveStatus, Error>] = []
        var polls = 0
        func moveStatus(moveId: String) async throws -> MoveStatus {
            polls += 1
            guard !statuses.isEmpty else { return MoveStatus(status: .pending, detail: nil) }
            return try (statuses.count > 1 ? statuses.removeFirst() : statuses[0]).get()
        }
        func eventStreamRequest() async throws -> URLRequest? { nil }
    }

    /// A clock the test advances; sleepers wake when it passes their deadline.
    @MainActor private final class FakeClock {
        private var now: TimeInterval = 0
        private var waiters: [(id: Int, deadline: TimeInterval, cont: CheckedContinuation<Void, Never>)] = []
        private var nextId = 0

        func sleep(_ seconds: TimeInterval) async throws {
            let id = nextId
            nextId += 1
            let deadline = now + seconds
            await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    waiters.append((id, deadline, cont))
                }
            } onCancel: {
                Task { @MainActor in self.wake { $0.id == id } }
            }
            try Task.checkCancellation()
        }

        /// Move time forward 1 s at a time, letting woken tasks run.
        func advance(by seconds: Int) async {
            await settle()
            for _ in 0..<seconds {
                now += 1
                wake { $0.deadline <= self.now }
                await settle()
            }
        }

        func settle() async {
            for _ in 0..<30 { await Task.yield() }
        }

        private func wake(_ matches: ((id: Int, deadline: TimeInterval, cont: CheckedContinuation<Void, Never>)) -> Bool) {
            let due = waiters.filter(matches)
            waiters.removeAll { w in due.contains { $0.id == w.id } }
            for w in due { w.cont.resume() }
        }
    }

    @MainActor private func model(_ backend: FakeBackend, store: PendingMoveStore, clock: FakeClock) -> CallMoveModel {
        let model = CallMoveModel(backend: backend, pending: store, sleeper: { try await clock.sleep($0) })
        model.hasLocalCall = { false }
        model.deviceId = { "6f1c2a9e-1111-4222-8333-944455556666" }
        model.isSignedIn = { true }
        return model
    }

    @MainActor private func model(_ backend: FakeBackend, store: PendingMoveStore) -> CallMoveModel {
        model(backend, store: store, clock: FakeClock())
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

    // MARK: Pending move

    private static let failedText = "Couldn't move the call"

    /// "Move here" accepted with move id m-1 on call c1.
    @MainActor private func movingHere(_ backend: FakeBackend, _ clock: FakeClock, _ store: PendingMoveStore) async -> CallMoveModel {
        let model = model(backend, store: store, clock: clock)
        await model.moveHere(call(id: "c1"))
        XCTAssertEqual(model.pendingMove, .init(moveId: "m-1", callId: "c1"))
        return model
    }

    @MainActor func testPollSeesFailedAndClears() async {
        let backend = FakeBackend()
        backend.statuses = [.success(.init(status: .ringing, detail: nil)),
                            .success(.init(status: .failed, detail: "no answer"))]
        let clock = FakeClock(), store = PendingMoveStore()
        let model = await movingHere(backend, clock, store)
        await clock.advance(by: 2)
        XCTAssertNotNil(model.pendingMove, "ringing is not an outcome")
        XCTAssertNil(model.errorMessage)
        await clock.advance(by: 2)
        XCTAssertNil(model.pendingMove)
        XCTAssertEqual(model.errorMessage, Self.failedText)
        XCTAssertEqual(backend.polls, 2)
        XCTAssertNil(store.consume(moveId: "m-1"), "a late INVITE for it must ring, not auto-answer")
        let polls = backend.polls
        await clock.advance(by: 40)
        XCTAssertEqual(backend.polls, polls, "polling stopped")
    }

    @MainActor func testPollSeesMovedAndClearsQuietly() async {
        let backend = FakeBackend()
        backend.statuses = [.success(.init(status: .moved, detail: nil))]
        let clock = FakeClock()
        let model = await movingHere(backend, clock, PendingMoveStore())
        await clock.advance(by: 2)
        XCTAssertNil(model.pendingMove)
        XCTAssertNil(model.errorMessage)
        await clock.advance(by: 40)
        XCTAssertNil(model.errorMessage, "the timeout was cancelled with the move")
        XCTAssertEqual(backend.polls, 1)
    }

    @MainActor func testWebSocketFailureClearsAndStopsPolling() async {
        let backend = FakeBackend()
        let clock = FakeClock()
        let model = await movingHere(backend, clock, PendingMoveStore())
        await clock.advance(by: 2)
        model.handle(.moveFailed(callId: "c1", moveId: "m-1", detail: "refused"))
        XCTAssertNil(model.pendingMove)
        XCTAssertEqual(model.errorMessage, Self.failedText)
        let polls = backend.polls
        await clock.advance(by: 40)
        XCTAssertEqual(backend.polls, polls)
    }

    @MainActor func testWebSocketFailureOfAnotherMoveIsIgnored() async {
        let clock = FakeClock()
        let model = await movingHere(FakeBackend(), clock, PendingMoveStore())
        model.handle(.moveFailed(callId: "c9", moveId: "m-9", detail: nil))
        XCTAssertNotNil(model.pendingMove)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testCallEndedEndsThePendingMoveWithoutAMessage() async {
        let clock = FakeClock(), store = PendingMoveStore()
        let model = await movingHere(FakeBackend(), clock, store)
        model.handle(.ended(callId: "c1"))
        XCTAssertNil(model.pendingMove)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(store.consume(moveId: "m-1"))
    }

    @MainActor func testTimeoutAfter30SecondsEvenWhenPollsFail() async {
        let backend = FakeBackend()
        backend.statuses = [.failure(PbxApiClient.ApiError.httpError(statusCode: 500, message: "boom"))]
        let clock = FakeClock()
        let model = await movingHere(backend, clock, PendingMoveStore())
        await clock.advance(by: 29)
        XCTAssertNotNil(model.pendingMove)
        XCTAssertNil(model.errorMessage)
        XCTAssertGreaterThan(backend.polls, 5, "kept polling through the errors")
        await clock.advance(by: 1)
        XCTAssertNil(model.pendingMove)
        XCTAssertEqual(model.errorMessage, Self.failedText)
        let polls = backend.polls
        await clock.advance(by: 20)
        XCTAssertEqual(backend.polls, polls)
    }

    @MainActor func testMoveToTracksTheMoveToo() async {
        let backend = FakeBackend()
        backend.calls = [call(id: "c1", reg: "r-me", sip: nil)]
        backend.statuses = [.success(.init(status: .failed, detail: nil))]
        let clock = FakeClock()
        let model = model(backend, store: PendingMoveStore(), clock: clock)
        let target = UserDevice(registrationId: "r-desk", label: "Desk", userAgent: nil, transport: nil, online: true)
        let ok = await model.moveOwnCall(to: target)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.pendingMove?.callId, "c1")
        await clock.advance(by: 2)
        XCTAssertNil(model.pendingMove)
        XCTAssertEqual(model.errorMessage, Self.failedText)
        XCTAssertNil(model.takeMovedAway(), "the call never left, so no 'Moved to' notice")
    }

    @MainActor func testPostErrorsStartNoPendingMove() async {
        let backend = FakeBackend()
        backend.moveResult = .failure(PbxApiClient.ApiError.httpError(statusCode: 422, message: "x"))
        let model = model(backend, store: PendingMoveStore(), clock: FakeClock())
        await model.moveHere(call(id: "c1"))
        XCTAssertNil(model.pendingMove)
        XCTAssertEqual(model.errorMessage, "That device is offline")
    }

    func testPostErrorMapping() {
        func text(_ code: Int) -> String {
            CallMoveModel.describe(PbxApiClient.ApiError.httpError(statusCode: code, message: ""))
        }
        XCTAssertEqual(text(422), "That device is offline")
        XCTAssertEqual(text(409), "The call can't be moved right now")
        XCTAssertEqual(text(404), "That call has ended")
    }

    func testParsesMoveFailedAndStatus() throws {
        XCTAssertEqual(
            CallMoveEvent.parse(#"{"type":"call_move_failed","call_id":"c1","move_id":"m-1","detail":"declined"}"#),
            .moveFailed(callId: "c1", moveId: "m-1", detail: "declined"))
        let status = try PbxApiClient.jsonDecoder.decode(MoveStatus.self, from: Data(#"{"status":"failed","detail":"no answer"}"#.utf8))
        XCTAssertEqual(status, MoveStatus(status: .failed, detail: "no answer"))
    }

    func testMoveStatusRequestPath() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(200, #"{"status":"ringing"}"#)
        let client = PbxApiClient(baseUrl: "https://api.example.com", session: StubURLProtocol.session())
        let status = try await client.moveStatus(jwt: "jwt", moveId: "m-1")
        XCTAssertEqual(status.status, .ringing)
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.url.path, "/api/v1/me/moves/m-1")
    }

    @MainActor func testStaleFailureForAnotherMoveOnTheSameCallIsIgnored() async {
        let model = await movingHere(FakeBackend(), FakeClock(), PendingMoveStore())
        model.handle(.moveFailed(callId: "c1", moveId: "m-0", detail: nil))
        XCTAssertNotNil(model.pendingMove)
        XCTAssertNil(model.errorMessage)
        model.handle(.moveFailed(callId: "c1", moveId: nil, detail: nil))
        XCTAssertNil(model.pendingMove, "without a move id the call id decides")
    }

    @MainActor func testASecondMoveWaitsForThePendingOne() async {
        let backend = FakeBackend()
        let model = await movingHere(backend, FakeClock(), PendingMoveStore())
        XCTAssertTrue(model.isBusy)
        backend.moveResult = .success("m-2")
        await model.moveHere(call(id: "c1"))
        XCTAssertEqual(model.pendingMove?.moveId, "m-1")
        XCTAssertEqual(backend.moved.count, 1)
        let target = UserDevice(registrationId: "r-x", label: nil, userAgent: nil, transport: nil, online: true)
        let ok = await model.moveOwnCall(to: target)
        XCTAssertFalse(ok)
        XCTAssertEqual(backend.moved.count, 1)
    }

    @MainActor func testReplacingAMoveDiscardsTheOldStoreEntry() async {
        let store = PendingMoveStore()
        let model = await movingHere(FakeBackend(), FakeClock(), store)
        model.registerMove(moveId: "m-2", callId: "c1")
        XCTAssertEqual(model.pendingMove?.moveId, "m-2")
        XCTAssertNil(store.consume(moveId: "m-1"))
        XCTAssertNotNil(store.consume(moveId: "m-2"))
    }

    @MainActor func testTimeoutStillCountsAMoveThatFinishedMeanwhile() async {
        let backend = FakeBackend()
        let clock = FakeClock()
        let model = await movingHere(backend, clock, PendingMoveStore())
        await clock.advance(by: 29)
        XCTAssertNotNil(model.pendingMove)
        backend.statuses = [.success(.init(status: .moved, detail: nil))]
        await clock.advance(by: 1)
        XCTAssertNil(model.pendingMove)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testTimeoutFinalLookErrorIsAFailure() async {
        let backend = FakeBackend()
        backend.statuses = [.failure(PbxApiClient.ApiError.httpError(statusCode: 500, message: ""))]
        let clock = FakeClock()
        let model = await movingHere(backend, clock, PendingMoveStore())
        await clock.advance(by: 30)
        XCTAssertEqual(model.errorMessage, Self.failedText)
    }

    @MainActor func testAutoMoveFromTheTriggerIsTrackedAndTimesOut() async {
        let clock = FakeClock()
        let model = model(FakeBackend(), store: PendingMoveStore(), clock: clock)
        model.registerMove(moveId: "m-7", callId: "c1")
        XCTAssertEqual(model.pendingMove, .init(moveId: "m-7", callId: "c1"))
        await clock.advance(by: 30)
        XCTAssertNil(model.pendingMove)
        XCTAssertEqual(model.errorMessage, Self.failedText)
    }
}
