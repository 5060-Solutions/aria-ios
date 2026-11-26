import XCTest
import CallKit
@testable import AriaSoftphone

/// Hold for me, the parts that arrive with the bindings: the features flag,
/// the hold-return push fields, and the HeldForYou ending.
final class HoldForMeTests: XCTestCase {

    private func identity(_ json: String) throws -> PbxApiClient.Identity {
        try PbxApiClient.jsonDecoder.decode(PbxApiClient.Identity.self, from: Data(json.utf8))
    }

    func testIdentityAdvertisesHoldForMe() throws {
        XCTAssertTrue(try identity(#"{"features":["hold_for_me"]}"#).holdForMe)
        XCTAssertTrue(try identity(#"{"features":["x","hold_for_me"]}"#).holdForMe)
        XCTAssertFalse(try identity(#"{}"#).holdForMe)
        XCTAssertFalse(try identity(#"{"features":[]}"#).holdForMe)
        XCTAssertFalse(try identity(#"{"features":["other"]}"#).holdForMe)
    }

    private func parse(_ payload: [AnyHashable: Any]) throws -> IncomingPush {
        try IncomingPush.parse(payload, configuredGateway: "https://gw.example.com").get()
    }

    func testPushCarriesTheHoldReturn() throws {
        let camel = try parse(["callToken": "t", "holdReturnId": "hw-1", "holdReturnName": "Acme Bank"])
        XCTAssertEqual(camel.holdReturnId, "hw-1")
        XCTAssertEqual(camel.holdReturnName, "Acme Bank")

        let snake = try parse(["call_token": "t", "hold_return_id": "hw-2", "hold_return_name": "Globex"])
        XCTAssertEqual(snake.holdReturnId, "hw-2")
        XCTAssertEqual(snake.holdReturnName, "Globex")

        let none = try parse(["callToken": "t"])
        XCTAssertNil(none.holdReturnId)
        XCTAssertNil(none.holdReturnName)
    }

    // MARK: They're back

    @MainActor
    func testPushNamesTheHoldReturnBeforeTheOffer() {
        let manager = CallManager.shared
        var updates: [CXCallUpdate] = []
        manager.onIncomingReport = { updates.append($0) }
        defer {
            manager.onIncomingReport = nil
            manager.loadFixture(calls: [])
        }
        manager.reportPushIncomingCall(
            uuid: UUID(), callToken: "tok-hr-1", callerUri: "+18005550100", callerName: "Ignored",
            holdReturnId: "hw-1", holdReturnName: "Acme Bank"
        ) { _ in }
        XCTAssertEqual(updates.map(\.localizedCallerName), ["They're back — Acme Bank"], "named with no offer yet")
        let call = manager.registry.call(callToken: "tok-hr-1")
        XCTAssertEqual(call?.holdReturnId, "hw-1")
        XCTAssertEqual(call?.holdReturnName, "Acme Bank")
        XCTAssertNil(call?.offer)
    }

    @MainActor
    func testTheHoldReturnLabelFallsBackToTheCallerThenTheNumber() {
        let manager = CallManager.shared
        var updates: [CXCallUpdate] = []
        manager.onIncomingReport = { updates.append($0) }
        defer {
            manager.onIncomingReport = nil
            manager.loadFixture(calls: [])
        }
        manager.reportPushIncomingCall(
            uuid: UUID(), callToken: "tok-hr-2", callerUri: "+18005550100", callerName: "Acme Bank",
            holdReturnId: "hw-1", holdReturnName: nil
        ) { _ in }
        manager.loadFixture(calls: [])
        manager.reportPushIncomingCall(
            uuid: UUID(), callToken: "tok-hr-3", callerUri: "sip-unknown-xyz", callerName: nil,
            holdReturnId: "hw-1"
        ) { _ in }
        XCTAssertEqual(updates.map(\.localizedCallerName),
                       ["They're back — Acme Bank", "They're back — sip-unknown-xyz"])
    }

    @MainActor
    func testAnOfferConfirmsTheHoldReturn() {
        let manager = CallManager.shared
        defer { manager.loadFixture(calls: []) }
        var call = ActiveCall(uuid: UUID(), callToken: "tok-hr-4", remoteUri: "+18005550100", remoteName: nil,
                              direction: .inbound, state: .incoming)
        call.holdReturnId = "hw-1"
        manager.loadFixture(calls: [call])
        manager.offerReceived(CallOffer(
            callToken: "tok-hr-4", callerUri: "+18005550100", callerName: "Acme", sdpOffer: "",
            moveId: nil, holdReturnId: "hw-2", holdReturnName: "Acme Bank"))
        let updated = manager.registry.call(callToken: "tok-hr-4")
        XCTAssertEqual(updated?.holdReturnId, "hw-2")
        XCTAssertEqual(updated?.holdReturnName, "Acme Bank")
    }

    func testStillOnHoldIsOfferedOnlyForTenSecondsAfterJoining() {
        let now = Date()
        XCTAssertTrue(HoldReturnRules.showsStillOnHold(joinedAt: now.addingTimeInterval(-9), now: now))
        XCTAssertFalse(HoldReturnRules.showsStillOnHold(joinedAt: now.addingTimeInterval(-10), now: now))
        XCTAssertFalse(HoldReturnRules.showsStillOnHold(joinedAt: now.addingTimeInterval(-11), now: now))
        XCTAssertFalse(HoldReturnRules.showsStillOnHold(joinedAt: nil, now: now))
    }

    func testHeldForYouIsNotADroppedCall() {
        var call = ActiveCall(uuid: UUID(), callToken: "tok", remoteUri: "18005550100", remoteName: "Acme",
                              direction: .outbound, state: .connected)
        call.connectedAt = Date()
        let ending = CallEnding.resolve(for: call, reason: .heldForYou)
        XCTAssertEqual(ending, CallEnding(callKitReason: .remoteEnded, outcome: .heldForYou))
        XCTAssertFalse(CallEnding.isDropped(call, reason: .heldForYou))
        XCTAssertNotEqual(ending.outcome, .failed)
        XCTAssertNotEqual(ending.outcome, .missed)
        XCTAssertFalse(CallRecord(call: call, outcome: ending.outcome).isMissed)
    }

    func testReleaseIntoAWaitShowsTheNoticeNotADrop() {
        let manager = CallManager.shared
        var call = ActiveCall(uuid: UUID(), callToken: nil, remoteUri: "18005550100", remoteName: "Acme",
                              direction: .outbound, state: .connected)
        call.callId = "outgoing-hfy"
        call.connectedAt = Date()
        manager.loadFixture(calls: [call])
        manager.droppedCallNotice = nil
        manager.heldForYouNotice = nil

        manager.updateCallState(info: CallInfo(
            callId: "outgoing-hfy", remoteUri: "18005550100", remoteName: "Acme", state: .ended,
            direction: .outbound, muted: false, onHold: false, durationSecs: 60, endReason: .heldForYou))

        XCTAssertEqual(manager.heldForYouNotice?.message, "Holding for you")
        XCTAssertNil(manager.droppedCallNotice)
        XCTAssertNil(manager.registry[call.uuid])
        let record = CallHistoryStore.shared.records.first
        XCTAssertEqual(record?.outcome, .heldForYou)
        XCTAssertEqual(record?.isMissed, false)
        manager.loadFixture(calls: [])
    }

    func testRecentsShowsHoldingForYou() {
        var call = ActiveCall(uuid: UUID(), callToken: "tok", remoteUri: "18005550100", remoteName: "Acme",
                              direction: .outbound, state: .connected)
        call.connectedAt = Date()
        let record = CallRecord(call: call, outcome: .heldForYou)
        XCTAssertEqual(record.summary, "Holding for you")
    }
}

/// Hold for me's wire, events, refusals and availability, against the shared
/// contract's shapes (C2, C3).
@MainActor
final class HoldForMeServiceTests: XCTestCase {
    private let waitJSON = """
    {"hold_wait_id":"hw-1","call_id":"c-1","state":"waiting","greeting":"line",
     "started_at":"2026-11-26T15:04:05Z","state_since":"2026-11-26T15:04:05Z",
     "max_wait_secs":10800,"false_alarms":0,
     "remote":{"number":"+18005550100","name":"Acme Bank"},
     "ring_reason":null,"ended_reason":null}
    """

    private func client() -> PbxApiClient {
        PbxApiClient(baseUrl: "https://api.example.com", session: StubURLProtocol.session())
    }

    private func call(direction: ActiveCall.CallDirection = .outbound, connected: Bool = true,
                      name: String? = "Acme Bank") -> ActiveCall {
        var call = ActiveCall(uuid: UUID(), callToken: nil, remoteUri: "+18005550100", remoteName: name,
                              direction: direction, state: connected ? .connected : .connecting)
        call.callId = "engine-1"
        if connected { call.connectedAt = Date() }
        return call
    }

    private func identity(_ json: String) throws -> PbxApiClient.Identity {
        try PbxApiClient.jsonDecoder.decode(PbxApiClient.Identity.self, from: Data(json.utf8))
    }

    /// A backend that answers, or fails with `error`, and records its calls.
    private final class StubBackend: HoldForMeBackend {
        var error: Error?
        var started: [(callId: String, greeting: HoldGreeting?, name: String?)] = []
        let wait: HoldWait
        /// What the PBX lists as open; the wait by default.
        lazy var open: [HoldWait] = [wait]

        init(wait: HoldWait, error: Error? = nil) { self.wait = wait; self.error = error }

        func start(callId: String, greeting: HoldGreeting?, displayName: String?) async throws -> HoldWait {
            started.append((callId, greeting, displayName))
            if let error { throw error }
            return wait
        }
        func cancel(callId: String, action: String) async throws -> HoldWait { wait }
        var stillOnHoldCalls: [String] = []
        /// When set, Still on hold waits for it to be resumed.
        var stillOnHoldGate: CheckedContinuation<Void, Never>?
        var stillOnHoldEntered: (() -> Void)?
        func stillOnHold(callId: String) async throws -> HoldWait {
            stillOnHoldCalls.append(callId)
            if let entered = stillOnHoldEntered {
                stillOnHoldEntered = nil
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    stillOnHoldGate = c
                    entered()
                }
            }
            if let error { throw error }
            return wait
        }
        func openWaits() async throws -> [HoldWait] { open }
        func settings() async throws -> HoldSettings {
            HoldSettings(greeting: .line, assistantAvailable: true, maxWaitSecs: 10800)
        }
        func setGreeting(_ greeting: HoldGreeting) async throws -> HoldSettings {
            HoldSettings(greeting: greeting, assistantAvailable: true, maxWaitSecs: 10800)
        }
    }

    private func sampleWait() throws -> HoldWait {
        try PbxApiClient.jsonDecoder.decode(HoldWait.self, from: Data(waitJSON.utf8))
    }

    private func model(_ backend: HoldForMeBackend, inConference: Bool = false) -> HoldForMeModel {
        let model = HoldForMeModel(backend: backend)
        model.resolveCallId = { _ in "c-1" }
        model.isInConference = { inConference }
        return model
    }

    // MARK: Still on hold

    func testStillOnHoldIgnoresDoubleTapsWhileOneIsInFlight() async throws {
        let backend = StubBackend(wait: try sampleWait())
        let entered = expectation(description: "first call is at the PBX")
        backend.stillOnHoldEntered = { entered.fulfill() }
        let model = model(backend)
        model.handle(.state(try sampleWait(), transcript: []))
        async let first = model.stillOnHold("hw-1")
        await fulfillment(of: [entered], timeout: 5)
        let second = await model.stillOnHold("hw-1")
        backend.stillOnHoldGate?.resume()
        let ranFirst = await first
        XCTAssertTrue(ranFirst)
        XCTAssertFalse(second, "a tap while one is in flight is ignored")
        XCTAssertEqual(backend.stillOnHoldCalls, ["c-1"])
        let third = await model.stillOnHold("hw-1")
        XCTAssertTrue(third, "a later tap goes through")
        XCTAssertEqual(backend.stillOnHoldCalls.count, 2)
    }

    @MainActor
    func testAnOfferThatArrivesAfterTheAnswerStillStartsTheStillOnHoldWindow() {
        let manager = CallManager.shared
        defer { manager.loadFixture(calls: []) }
        var call = ActiveCall(uuid: UUID(), callToken: "tok-hr-5", remoteUri: "+18005550100", remoteName: nil,
                              direction: .inbound, state: .connected)
        let connected = Date()
        call.connectedAt = connected
        manager.loadFixture(calls: [call])
        manager.offerReceived(CallOffer(
            callToken: "tok-hr-5", callerUri: "+18005550100", callerName: nil, sdpOffer: "",
            moveId: nil, holdReturnId: "hw-1", holdReturnName: nil))
        XCTAssertEqual(manager.registry.call(callToken: "tok-hr-5")?.joinedAt, connected)
    }

    func testStillOnHoldRefusedByThePbxIsQuiet() async throws {
        let backend = StubBackend(wait: try sampleWait(), error: HoldRequestError(status: 409, reason: nil))
        let model = model(backend)
        model.handle(.state(try sampleWait(), transcript: []))
        let ran = await model.stillOnHold("hw-1")
        XCTAssertTrue(ran)
        XCTAssertNil(model.banner, "a 409 shows nothing")
    }

    func testStillOnHoldForAnUnknownWaitDoesNotCallThePbx() async throws {
        let backend = StubBackend(wait: try sampleWait())
        let model = model(backend)
        let ran = await model.stillOnHold("nope")
        XCTAssertTrue(ran)
        XCTAssertTrue(backend.stillOnHoldCalls.isEmpty)
    }

    func testEnsureListeningStartsTheSocketAndFetchesTheOpenWaits() async throws {
        let backend = StubBackend(wait: try sampleWait())
        let model = model(backend)
        model.fetchIdentity = { try self.identity(#"{"features":["hold_for_me"]}"#) }
        var started = 0
        model.startSocket = { started += 1 }
        await model.ensureListening()
        XCTAssertEqual(started, 1)
        XCTAssertEqual(model.waits["hw-1"], try sampleWait())
    }

    func testStartPostsTheGreetingAndName() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(202, waitJSON)
        let wait = try await client().startHoldForMe(jwt: "jwt", callId: "c-1", greeting: .line, displayName: "Acme Bank")
        XCTAssertEqual(wait.holdWaitId, "hw-1")
        XCTAssertEqual(wait.remote.name, "Acme Bank")
        XCTAssertEqual(wait.maxWaitSecs, 10800)
        XCTAssertTrue(wait.isOpen)
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.path, "/api/v1/me/calls/c-1/hold-for-me")
        XCTAssertEqual(sent.body?["greeting"] as? String, "line")
        XCTAssertEqual(sent.body?["display_name"] as? String, "Acme Bank")

        StubURLProtocol.reset()
        StubURLProtocol.respond(202, waitJSON)
        _ = try await client().startHoldForMe(jwt: "jwt", callId: "c-1", greeting: nil, displayName: nil)
        XCTAssertEqual(StubURLProtocol.requests.first?.body?.count, 0, "an empty body takes the user's setting")
    }

    func testCancelUsesTheActionQuery() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(202, waitJSON)
        _ = try await client().cancelHoldForMe(jwt: "jwt", callId: "c-1", action: "rejoin")
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "DELETE")
        XCTAssertEqual(sent.url.path, "/api/v1/me/calls/c-1/hold-for-me")
        XCTAssertEqual(URLComponents(url: sent.url, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "action", value: "rejoin")])

        StubURLProtocol.reset()
        StubURLProtocol.respond(202, waitJSON)
        _ = try await client().stillOnHold(jwt: "jwt", callId: "c-1")
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/v1/me/calls/c-1/hold-for-me/still-on-hold")
        XCTAssertEqual(StubURLProtocol.requests.first?.method, "POST")
    }

    func testTheOtherRoutesUseTheContractPaths() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.respond(200, "[\(waitJSON)]")
        let waits = try await client().holdWaits(jwt: "jwt")
        XCTAssertEqual(waits.map(\.holdWaitId), ["hw-1"])
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/v1/me/hold-waits")

        StubURLProtocol.reset()
        StubURLProtocol.respond(200, #"{"greeting":"assistant","assistant_available":false,"max_wait_secs":600}"#)
        let settings = try await client().holdForMeSettings(jwt: "jwt")
        XCTAssertEqual(settings.greeting, .assistant)
        XCTAssertFalse(settings.assistantAvailable)
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/v1/me/hold-for-me/settings")

        StubURLProtocol.reset()
        StubURLProtocol.respond(200, #"{"greeting":"silence","assistant_available":true,"max_wait_secs":600}"#)
        _ = try await client().setHoldForMeGreeting(jwt: "jwt", .silence)
        XCTAssertEqual(StubURLProtocol.requests.first?.method, "PUT")
        XCTAssertEqual(StubURLProtocol.requests.first?.body?["greeting"] as? String, "silence")
    }

    func testRefusalsMapToCopy() async throws {
        XCTAssertEqual(HoldRefusal(status: 409, reason: "emergency"), .emergency)
        XCTAssertEqual(HoldRefusal(status: 409, reason: "conference"), .busy)
        XCTAssertEqual(HoldRefusal(status: 409, reason: "transfer"), .busy)
        XCTAssertEqual(HoldRefusal(status: 409, reason: "already_holding"), .already)
        for reason in ["not_outgoing", "not_answered", "nonsense", nil] {
            XCTAssertEqual(HoldRefusal(status: 409, reason: reason), .other)
        }
        for status in [403, 404, 422, 500] {
            XCTAssertEqual(HoldRefusal(status: status, reason: "emergency"), .other)
        }
        XCTAssertEqual(String(localized: HoldRefusal.emergency.message), "Not available on emergency calls.")
        XCTAssertEqual(String(localized: HoldRefusal.busy.message), "Not available while a transfer or merge is in progress.")
        XCTAssertEqual(String(localized: HoldRefusal.already.message), "Already holding this call.")
        XCTAssertEqual(String(localized: HoldRefusal.other.message), "Couldn't start Hold for me.")

        // The route's 409 carries its reason; the client keeps it.
        StubURLProtocol.reset()
        StubURLProtocol.respond(409, #"{"error":"refused","reason":"already_holding"}"#)
        do {
            _ = try await client().startHoldForMe(jwt: "jwt", callId: "c-1", greeting: nil, displayName: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(HoldRefusal(error: error), .already)
        }

        // Through the model: the call is untouched, the wait list stays empty,
        // and the banner names the reason. A network failure reads as `.other`.
        let wait = try sampleWait()
        let cases: [(Error, HoldRefusal)] = [
            (HoldRequestError(status: 409, reason: "emergency"), .emergency),
            (HoldRequestError(status: 409, reason: "conference"), .busy),
            (HoldRequestError(status: 409, reason: "transfer"), .busy),
            (HoldRequestError(status: 409, reason: "already_holding"), .already),
            (HoldRequestError(status: 500, reason: nil), .other),
            (URLError(.notConnectedToInternet), .other),
        ]
        for (error, expected) in cases {
            let backend = StubBackend(wait: wait, error: error)
            let model = model(backend)
            let active = call()
            await model.start(call: active, greeting: .line)
            XCTAssertEqual(model.banner, expected, "\(error)")
            XCTAssertTrue(model.waits.isEmpty)
            XCTAssertEqual(active.state, .connected)
        }
    }

    func testStartRecordsTheWaitAndSendsTheDisplayName() async throws {
        let backend = StubBackend(wait: try sampleWait())
        let model = model(backend)
        await model.start(call: call(), greeting: .assistant)
        XCTAssertEqual(backend.started.first?.callId, "c-1")
        XCTAssertEqual(backend.started.first?.greeting, .assistant)
        XCTAssertEqual(backend.started.first?.name, "Acme Bank")
        XCTAssertEqual(model.waits["hw-1"]?.state, "waiting")
        XCTAssertNil(model.banner)

        // No name known: nothing is sent for it.
        await model.start(call: call(name: nil), greeting: .silence)
        XCTAssertNil(backend.started.last?.name)
    }

    func testAnUnresolvableCallIsRefusedWithoutTheNetwork() async throws {
        let backend = StubBackend(wait: try sampleWait())
        let model = model(backend)
        model.resolveCallId = { _ in nil }
        await model.start(call: call(), greeting: .line)
        XCTAssertEqual(model.banner, .other)
        XCTAssertTrue(backend.started.isEmpty)
    }

    func testHoldWaitEventParsesTheContract() throws {
        let json = """
        {"type":"hold_wait_state","tenant_id":"t","extension_id":"e",
         "hold_wait":\(waitJSON),
         "transcript":[{"speaker":"assistant","text":"I'm an automated assistant for Sam."},
                       {"speaker":"caller","text":"Hi, this is Dana from Acme."}]}
        """
        guard case .state(let wait, let transcript)? = HoldWaitEvent.parse(json) else {
            return XCTFail("did not parse")
        }
        XCTAssertEqual(wait.holdWaitId, "hw-1")
        XCTAssertEqual(wait.callId, "c-1")
        XCTAssertEqual(wait.greeting, .line)
        XCTAssertEqual(transcript.count, 2)
        XCTAssertEqual(transcript[1], TranscriptLine(speaker: "caller", text: "Hi, this is Dana from Acme."))

        XCTAssertNil(HoldWaitEvent.parse(#"{"type":"call_ended","call_id":"c"}"#))
        XCTAssertNil(HoldWaitEvent.parse("not json"))
    }

    func testTheModelKeepsTheLatestStateAndTranscript() throws {
        let model = model(StubBackend(wait: try sampleWait()))
        let wait = try sampleWait()
        model.handle(.state(wait, transcript: [TranscriptLine(speaker: "caller", text: "Hi")]))
        model.handle(.state(wait, transcript: []))
        XCTAssertEqual(model.waits["hw-1"], wait)
        XCTAssertEqual(model.transcripts["hw-1"], [])
    }

    func testTheButtonNeedsTheFlagAnOutgoingCallAndNoConference() throws {
        let backend = StubBackend(wait: try sampleWait())
        let model = model(backend)
        XCTAssertFalse(model.canHoldForMe(call()), "no flag")

        model.refreshAvailability(identity: try identity(#"{"features":["hold_for_me"]}"#))
        XCTAssertTrue(model.canHoldForMe(call()))
        XCTAssertFalse(model.canHoldForMe(call(direction: .inbound)), "incoming call")
        XCTAssertFalse(model.canHoldForMe(call(connected: false)), "not answered")

        let inConference = self.model(backend, inConference: true)
        inConference.refreshAvailability(identity: try identity(#"{"features":["hold_for_me"]}"#))
        XCTAssertFalse(inConference.canHoldForMe(call()), "conference")
    }

    func testAvailabilityFollowsTheIdentityAndResets() throws {
        let model = model(StubBackend(wait: try sampleWait()))
        model.refreshAvailability(identity: try identity(#"{}"#))
        XCTAssertFalse(model.available, "an absent features field means off")
        model.refreshAvailability(identity: try identity(#"{"features":["hold_for_me"]}"#))
        XCTAssertTrue(model.available)
        model.handle(.state(try sampleWait(), transcript: []))
        model.reset()
        XCTAssertFalse(model.available)
        XCTAssertTrue(model.waits.isEmpty)
        XCTAssertTrue(model.transcripts.isEmpty)
    }

    func testReconcileReplacesTheWaitsWithThePbxOpenList() async throws {
        let backend = StubBackend(wait: try sampleWait())
        let model = model(backend)
        var stale = try sampleWait()
        stale = HoldWait(holdWaitId: "hw-old", callId: "c-0", state: "waiting", greeting: .line,
                         startedAt: stale.startedAt, stateSince: stale.stateSince, maxWaitSecs: 10800,
                         falseAlarms: 0, remote: stale.remote, ringReason: nil, endedReason: nil)
        model.handle(.state(stale, transcript: []))
        await model.reconcile()
        XCTAssertEqual(Set(model.waits.keys), ["hw-1"])
        XCTAssertNil(model.transcripts["hw-old"])
    }

    // MARK: Live Activity (Task I3)

    /// Records what the controller asks of ActivityKit.
    private final class FakeFacade: ActivityFacade {
        var live: [String: HoldWaitAttributes.ContentState] = [:]
        var started: [HoldWaitAttributes] = []
        var updated: [String] = []
        var ended: [String] = []
        var staleDates: [String: Date] = [:]

        func existingIds() -> [String] { Array(live.keys) }
        func start(_ attributes: HoldWaitAttributes, state: HoldWaitAttributes.ContentState, staleDate: Date) {
            started.append(attributes)
            live[attributes.holdWaitId] = state
            staleDates[attributes.holdWaitId] = staleDate
        }
        func update(id: String, state: HoldWaitAttributes.ContentState, staleDate: Date) {
            updated.append(id)
            live[id] = state
        }
        func end(id: String) {
            ended.append(id)
            live[id] = nil
        }
    }

    private func wait(_ state: String, id: String = "hw-1") throws -> HoldWait {
        let base = try sampleWait()
        return HoldWait(holdWaitId: id, callId: base.callId, state: state, greeting: .line,
                        startedAt: base.startedAt, stateSince: base.stateSince, maxWaitSecs: 10800,
                        falseAlarms: 0, remote: base.remote, ringReason: nil,
                        endedReason: state == "ended" ? "hung_up" : nil)
    }

    func testTheControllerStartsUpdatesAndEndsActivities() throws {
        let facade = FakeFacade()
        let controller = HoldActivityController(facade: facade)

        controller.sync([try wait("waiting")])
        XCTAssertEqual(facade.started.count, 1)
        let attributes = try XCTUnwrap(facade.started.first)
        XCTAssertEqual(attributes.holdWaitId, "hw-1")
        XCTAssertEqual(attributes.callId, "c-1")
        XCTAssertEqual(attributes.remoteName, "Acme Bank")
        XCTAssertEqual(facade.staleDates["hw-1"], attributes.startedAt.addingTimeInterval(10800 + 300))

        controller.sync([try wait("waiting")])
        XCTAssertTrue(facade.updated.isEmpty, "nothing changed")
        XCTAssertEqual(facade.started.count, 1)

        controller.sync([try wait("ringing")])
        XCTAssertEqual(facade.updated, ["hw-1"])
        XCTAssertEqual(facade.live["hw-1"]?.state, "ringing")

        controller.sync([])
        XCTAssertEqual(facade.ended, ["hw-1"])
        XCTAssertTrue(facade.live.isEmpty)
    }

    func testAnEndedWaitEndsItsActivityAndRequestedShowsAsWaiting() throws {
        let facade = FakeFacade()
        let controller = HoldActivityController(facade: facade)
        controller.sync([try wait("requested")])
        XCTAssertEqual(facade.live["hw-1"]?.state, "waiting")
        controller.sync([try wait("ended")])
        XCTAssertEqual(facade.ended, ["hw-1"])
    }

    func testAnActivityTheModelNeverHeardOfIsEnded() throws {
        // The app was killed while waiting: ActivityKit still has the card.
        let facade = FakeFacade()
        facade.live["hw-orphan"] = .init(state: "waiting", stateSince: Date())
        HoldActivityController(facade: facade).sync([])
        XCTAssertEqual(facade.ended, ["hw-orphan"])
    }

    func testAStaleActivityIsEndedOnForeground() async throws {
        let facade = FakeFacade()
        let backend = StubBackend(wait: try wait("waiting"))
        let model = HoldForMeModel(backend: backend, activities: HoldActivityController(facade: facade))
        model.setAvailable(true)
        model.handle(.state(try wait("waiting"), transcript: []))
        XCTAssertEqual(facade.live.keys.sorted(), ["hw-1"])

        // It ended while the app was away; the PBX lists no open wait.
        backend.open = []
        await model.reconcile()
        XCTAssertTrue(model.waits.isEmpty)
        XCTAssertEqual(facade.ended, ["hw-1"])
    }

    func testNoActivityStartsWhileTheFeatureIsOff() throws {
        let facade = FakeFacade()
        let model = HoldForMeModel(backend: StubBackend(wait: try wait("waiting")),
                                   activities: HoldActivityController(facade: facade))
        model.handle(.state(try wait("waiting"), transcript: []))
        XCTAssertTrue(facade.started.isEmpty)
        model.setAvailable(true)
        XCTAssertEqual(facade.started.count, 1)
        model.setAvailable(false)
        XCTAssertEqual(facade.ended, ["hw-1"])
    }

    func testForegroundRereadsTheFlagAndKeepsItOnAFailedMe() async throws {
        let backend = StubBackend(wait: try wait("waiting"))
        let model = model(backend)
        model.fetchIdentity = { try self.identity(#"{"features":["hold_for_me"]}"#) }
        await model.becameActive()
        XCTAssertTrue(model.available)
        XCTAssertEqual(Set(model.waits.keys), ["hw-1"])

        model.fetchIdentity = { throw URLError(.notConnectedToInternet) }
        await model.becameActive()
        XCTAssertTrue(model.available, "a network error does not switch it off")

        model.fetchIdentity = { try self.identity(#"{}"#) }
        await model.becameActive()
        XCTAssertFalse(model.available, "the PBX no longer offers it")
    }

    func testTheCancelLinkIsParsedAndOpensTheChoice() async throws {
        XCTAssertEqual(DeepLink.parse(URL(string: "aria://hold-for-me/hw-1?action=cancel")!), .holdCancel("hw-1"))
        XCTAssertNil(DeepLink.parse(URL(string: "aria://hold-for-me/hw-1")!))
        XCTAssertNil(DeepLink.parse(URL(string: "aria://hold-for-me/hw-1?action=other")!))
        XCTAssertEqual(HoldWaitAttributes.cancelURL("hw-1").absoluteString, "aria://hold-for-me/hw-1?action=cancel")

        let model = model(StubBackend(wait: try wait("waiting")))
        model.setAvailable(true)
        await model.requestCancel("hw-1")
        XCTAssertEqual(model.cancelRequest, "hw-1", "found through the PBX's open list")
        await model.cancel("hw-1", rejoin: true)
        XCTAssertNil(model.cancelRequest)

        let off = self.model(StubBackend(wait: try wait("waiting")))
        await off.requestCancel("hw-1")
        XCTAssertNil(off.cancelRequest, "hidden while the feature is off")
    }

    func testElapsedReadsAsMinutesAndSeconds() {
        XCTAssertEqual(HoldWaitCard.elapsed(754), "12:34")
        XCTAssertEqual(HoldWaitCard.elapsed(5), "0:05")
        XCTAssertEqual(HoldWaitCard.elapsed(3723), "1:02:03")
        XCTAssertEqual(HoldWaitCard.elapsed(-3), "0:00")
    }

    func testAColdLaunchCancelLinkAsksEvenBeforeTheFlagIsKnown() async throws {
        let model = model(StubBackend(wait: try wait("waiting")))
        XCTAssertFalse(model.available)
        model.fetchIdentity = { try self.identity(#"{"features":["hold_for_me"]}"#) }
        await model.requestCancel("hw-1")
        XCTAssertTrue(model.available)
        XCTAssertEqual(model.cancelRequest, "hw-1")
    }

    func testLiveActivitiesSurviveAColdLaunchUntilReconciled() async throws {
        let facade = FakeFacade()
        facade.live["hw-1"] = .init(state: "waiting", stateSince: Date())
        let backend = StubBackend(wait: try wait("ringing"))
        let model = HoldForMeModel(backend: backend, activities: HoldActivityController(facade: facade))

        // /me fails offline: nothing is ended.
        model.fetchIdentity = { throw URLError(.notConnectedToInternet) }
        await model.becameActive()
        XCTAssertTrue(facade.ended.isEmpty)

        // /me answers, the PBX still lists the wait: updated, never ended or restarted.
        model.fetchIdentity = { try self.identity(#"{"features":["hold_for_me"]}"#) }
        await model.becameActive()
        XCTAssertTrue(facade.ended.isEmpty)
        XCTAssertTrue(facade.started.isEmpty)
        XCTAssertEqual(facade.live["hw-1"]?.state, "ringing")
    }

    func testAnActivityIsEndedOnceThePbxSaysNotOffered() async throws {
        let facade = FakeFacade()
        facade.live["hw-1"] = .init(state: "waiting", stateSince: Date())
        let model = HoldForMeModel(backend: StubBackend(wait: try wait("waiting")),
                                   activities: HoldActivityController(facade: facade))
        model.fetchIdentity = { try self.identity(#"{}"#) }
        await model.becameActive()
        XCTAssertEqual(facade.ended, ["hw-1"])
    }
}
