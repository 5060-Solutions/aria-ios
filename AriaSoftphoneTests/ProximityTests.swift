import XCTest
import CoreBluetooth
@testable import AriaSoftphone

final class ProximityTests: XCTestCase {
    // MARK: Network identity

    func testSubnetKeyMasksTheHostBits() {
        // 192.168.1.77 / 255.255.255.0
        XCTAssertEqual(NetworkIdentity.subnetKey(address: 0xC0A8_014D, mask: 0xFFFF_FF00), "192.168.1.0/24")
        XCTAssertEqual(NetworkIdentity.subnetKey(address: 0x0A00_0507, mask: 0xFFFF_0000), "10.0.0.0/16")
    }

    func testTheHashIsStableHexAndHidesTheNetwork() {
        let hash = NetworkIdentity.hash(subnetKey: "192.168.1.0/24")
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, NetworkIdentity.hash(subnetKey: "192.168.1.0/24"))
        XCTAssertNotEqual(hash, NetworkIdentity.hash(subnetKey: "192.168.2.0/24"))
        XCTAssertFalse(hash.contains("192"))
        XCTAssertNotNil(hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }

    // MARK: Bluetooth token

    func testATokenRoundTripsThroughAServiceUUID() throws {
        // The server's 16 bytes are exactly one 128-bit UUID.
        let token = "00112233445566778899aabbccddeeff"
        let uuid = try XCTUnwrap(BleTokenCoding.serviceUUID(forToken: token))
        XCTAssertEqual(uuid.data.count, 16)
        XCTAssertEqual(BleTokenCoding.token(from: uuid), token)
    }

    func testOnlyTokensAreRecognised() {
        XCTAssertNil(BleTokenCoding.token(from: CBUUID(string: "180D")))
        XCTAssertNil(BleTokenCoding.token(from: CBUUID(string: "0000FEAA-0000-1000-8000-00805F9B34FB")))
        XCTAssertNil(BleTokenCoding.serviceUUID(forToken: "short"))
        XCTAssertNil(BleTokenCoding.serviceUUID(forToken: String(repeating: "z", count: 32)))
        XCTAssertNil(BleTokenCoding.serviceUUID(forToken: "0123456789abcdef01234567"), "24 hex digits is not a token")
    }

    // MARK: Settings and events

    func testSettingsDecodeTheServersKeys() throws {
        let json = #"{"suggest_nearby":true,"auto_move_on_leave":false,"ble_opt_in":true,"auto_move_on_desktop_lock":true}"#
        let settings = try JSONDecoder().decode(CallHandoffSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings, CallHandoffSettings(suggestNearby: true, autoMoveOnLeave: false, ble: true))
    }

    func testBleIsOffByDefault() throws {
        XCTAssertFalse(CallHandoffSettings.off.ble)
        let empty = try JSONDecoder().decode(CallHandoffSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, CallHandoffSettings(suggestNearby: true, autoMoveOnLeave: false, ble: false))
    }

    func testTheTokenAndContextAnswersDecode() throws {
        let token = try JSONDecoder().decode(
            BleToken.self,
            from: Data(#"{"token":"00112233445566778899aabbccddeeff","rotates_at":"2026-11-25T22:15:00Z"}"#.utf8)
        )
        XCTAssertEqual(token.token.count, 32)
        XCTAssertEqual(token.rotatesAt, Date(timeIntervalSince1970: 1_795_644_900))
        let moved = try JSONDecoder().decode(
            ContextResult.self, from: Data(#"{"action":"moved","call_id":"c","move_id":"m"}"#.utf8)
        )
        XCTAssertEqual(moved, ContextResult(action: "moved", callId: "c", moveId: "m"))
        let none = try JSONDecoder().decode(
            ContextResult.self, from: Data(#"{"action":"none","call_id":null,"move_id":null}"#.utf8)
        )
        XCTAssertNil(none.moveId)
    }

    func testParsesHandoffSuggested() {
        let json = #"{"type":"handoff_suggested","call_id":"c1","to_registration_id":"r-me","reason":"nearby"}"#
        XCTAssertEqual(ProximityEvent.parse(json), .handoffSuggested(callId: "c1", toRegistrationId: "r-me", reason: "nearby"))
        XCTAssertNil(ProximityEvent.parse(#"{"type":"handoff_suggested","call_id":"c1"}"#))
        XCTAssertNil(ProximityEvent.parse(#"{"type":"call_ended","call_id":"c"}"#))
    }

    func testOnlyLeavingAKnownNetworkWithACallElsewhereIsReported() {
        XCTAssertTrue(Proximity.shouldReportLeaving(previous: "a", now: "b", otherDeviceHasCall: true))
        XCTAssertTrue(Proximity.shouldReportLeaving(previous: "a", now: nil, otherDeviceHasCall: true))
        XCTAssertFalse(Proximity.shouldReportLeaving(previous: "a", now: "a", otherDeviceHasCall: true))
        XCTAssertFalse(Proximity.shouldReportLeaving(previous: nil, now: "b", otherDeviceHasCall: true))
        XCTAssertFalse(Proximity.shouldReportLeaving(previous: "a", now: "b", otherDeviceHasCall: false))
    }

    // MARK: Routes

    func testTheRoutesNameThisPhoneByItsSipInstance() async throws {
        let urn = "urn:uuid:1234"
        let client = PbxApiClient(baseUrl: "https://api.example.com", session: StubURLProtocol.session())

        StubURLProtocol.reset()
        StubURLProtocol.respond(200, #"{"nearby":[]}"#)
        try await client.postProximity(
            jwt: "jwt", sipInstance: urn, networkHash: String(repeating: "a", count: 64),
            bleSeen: (0..<40).map { BleSighting(token: String(format: "%032x", $0), rssi: -60) }
        )
        var sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.path, "/api/v1/me/devices/current/proximity")
        XCTAssertTrue(sent.url.absoluteString.contains("sip_instance=urn%3Auuid%3A1234") || sent.url.absoluteString.contains("sip_instance=urn:uuid:1234"))
        XCTAssertEqual(sent.body?["network_hash"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual((sent.body?["ble_seen"] as? [[String: Any]])?.count, 32)

        StubURLProtocol.reset()
        StubURLProtocol.respond(200, #"{"action":"suggested","call_id":"c","move_id":null}"#)
        let answer = try await client.postContext(jwt: "jwt", sipInstance: urn, event: "left_network")
        XCTAssertEqual(answer.action, "suggested")
        sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.path, "/api/v1/me/devices/current/context")
        XCTAssertEqual(sent.body?["event"] as? String, "left_network")
        XCTAssertTrue(sent.url.absoluteString.contains("sip_instance="))

        StubURLProtocol.reset()
        StubURLProtocol.respond(200, #"{"token":"00112233445566778899aabbccddeeff","rotates_at":"2026-11-25T22:15:00Z"}"#)
        _ = try await client.bleToken(jwt: "jwt", sipInstance: urn)
        sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.path, "/api/v1/me/devices/current/ble-token")
        XCTAssertTrue(sent.url.absoluteString.contains("sip_instance="))
    }

    // MARK: Model

    private final class FakeMoves: CallMoveBackend {
        var calls: [UserCall] = []
        func activeCalls() async throws -> [UserCall] { calls }
        func devices() async throws -> [UserDevice] { [] }
        func currentDevice(sipInstance: String) async throws -> UserDevice {
            UserDevice(registrationId: "r-me", label: nil, userAgent: nil, transport: nil, online: true)
        }
        func move(callId: String, to registrationId: String) async throws -> String { "m" }
        func eventStreamRequest() async throws -> URLRequest? { nil }
    }

    private final class FakeProximity: ProximityBackend {
        var stored = CallHandoffSettings(suggestNearby: true, autoMoveOnLeave: false, ble: false)
        var networks: [String?] = []
        var instances: [String] = []
        var contexts: [String] = []
        var answer = ContextResult(action: "none", callId: nil, moveId: nil)
        var seen: [[BleSighting]] = []
        var failSave = false
        func settings() async throws -> CallHandoffSettings { stored }
        func saveSettings(_ settings: CallHandoffSettings) async throws -> CallHandoffSettings {
            if failSave { throw PbxApiClient.ApiError.httpError(statusCode: 500, message: "") }
            stored = settings
            return settings
        }
        func reportProximity(sipInstance: String, networkHash: String?, bleSeen: [BleSighting]) async throws {
            instances.append(sipInstance)
            if bleSeen.isEmpty { networks.append(networkHash) } else { seen.append(bleSeen) }
        }
        func reportContext(sipInstance: String, event: String) async throws -> ContextResult {
            instances.append(sipInstance)
            contexts.append(event)
            return answer
        }
        func bleToken(sipInstance: String) async throws -> BleToken {
            BleToken(token: "00112233445566778899aabbccddeeff", rotatesAt: nil)
        }
    }

    @MainActor private func make(_ proximity: FakeProximity, _ moves: FakeMoves) -> (Proximity, CallMoveModel) {
        let model = CallMoveModel(backend: moves, pending: PendingMoveStore())
        model.hasLocalCall = { false }
        model.deviceId = { "dev" }
        model.isSignedIn = { true }
        return (Proximity(backend: proximity, moves: model), model)
    }

    private func call() -> UserCall {
        UserCall(id: "c1", state: "active", direction: "inbound", remote: .init(number: "1", name: nil),
                 startedAt: Date(), device: .init(registrationId: "r-desk", label: "Desk", userAgent: nil, transport: nil),
                 sipCallId: nil)
    }

    @MainActor func testLeavingTheNetworkDuringAnotherDevicesCallPostsLeftNetwork() async {
        let backend = FakeProximity()
        let moves = FakeMoves()
        moves.calls = [call()]
        let (proximity, model) = make(backend, moves)
        var hash: String? = "home"
        proximity.readNetworkHash = { hash }
        await model.refresh()
        await proximity.reportNetworkIfChanged()
        hash = "cell"
        await proximity.pathChanged()
        XCTAssertEqual(backend.contexts, ["left_network"])
        XCTAssertEqual(backend.networks, ["home", "cell"])
        XCTAssertTrue(backend.instances.allSatisfy { $0 == "dev" }, "named by its +sip.instance: \(backend.instances)")
    }

    @MainActor func testLeavingWithNoCallElsewhereOnlyReportsTheNetwork() async {
        let backend = FakeProximity()
        let (proximity, _) = make(backend, FakeMoves())
        var hash: String? = "home"
        proximity.readNetworkHash = { hash }
        await proximity.reportNetworkIfChanged()
        hash = nil
        await proximity.pathChanged()
        XCTAssertTrue(backend.contexts.isEmpty)
        XCTAssertEqual(backend.networks.count, 2)
    }

    @MainActor func testAnUnchangedNetworkIsNotReportedTwice() async {
        let backend = FakeProximity()
        let (proximity, _) = make(backend, FakeMoves())
        proximity.readNetworkHash = { "home" }
        await proximity.reportNetworkIfChanged()
        await proximity.reportNetworkIfChanged()
        XCTAssertEqual(backend.networks, ["home"])
    }

    @MainActor func testASuggestionShowsAndContinuingMovesTheCallHere() async {
        let moves = FakeMoves()
        moves.calls = [call()]
        let (proximity, _) = make(FakeProximity(), moves)
        await proximity.becameActive()
        await proximity.handleSuggestion(.handoffSuggested(callId: "c1", toRegistrationId: "r-me", reason: "nearby"))
        XCTAssertEqual(proximity.suggestion?.id, "c1")
        await proximity.acceptSuggestion()
        XCTAssertNil(proximity.suggestion)
    }

    @MainActor func testSuggestionsAreOffWhenTheUserTurnedThemOff() async {
        let backend = FakeProximity()
        backend.stored.suggestNearby = false
        let moves = FakeMoves()
        moves.calls = [call()]
        let (proximity, _) = make(backend, moves)
        await proximity.becameActive()
        await proximity.handleSuggestion(.handoffSuggested(callId: "c1", toRegistrationId: "r-me", reason: "nearby"))
        XCTAssertNil(proximity.suggestion)
    }

    @MainActor func testASuggestionForAnotherDeviceIsNotShownHere() async {
        let moves = FakeMoves()
        moves.calls = [call()]
        let (proximity, _) = make(FakeProximity(), moves)
        await proximity.becameActive()
        await proximity.handleSuggestion(.handoffSuggested(callId: "c1", toRegistrationId: "r-other", reason: "left_network"))
        XCTAssertNil(proximity.suggestion)
    }

    @MainActor func testAMovedAnswerIsRegisteredAsStartedHere() async {
        let backend = FakeProximity()
        backend.answer = ContextResult(action: "moved", callId: "c1", moveId: "M-9")
        let moves = FakeMoves()
        moves.calls = [call()]
        let (proximity, model) = make(backend, moves)
        var hash: String? = "home"
        proximity.readNetworkHash = { hash }
        await model.refresh()
        await proximity.reportNetworkIfChanged()
        hash = nil
        await proximity.pathChanged()
        XCTAssertNotNil(model.pending.consume(moveId: "M-9"))
    }

    @MainActor func testSavingASettingKeepsTheServersAnswer() async {
        let backend = FakeProximity()
        let (proximity, _) = make(backend, FakeMoves())
        await proximity.becameActive()
        await proximity.update { $0.autoMoveOnLeave = true }
        XCTAssertEqual(proximity.settings?.autoMoveOnLeave, true)
        XCTAssertTrue(backend.stored.autoMoveOnLeave)
        XCTAssertFalse(backend.stored.ble, "Bluetooth stays off until asked for")
    }

    @MainActor func testAFailedSaveRestoresTheSetting() async {
        let backend = FakeProximity()
        let (proximity, _) = make(backend, FakeMoves())
        await proximity.becameActive()
        backend.failSave = true
        await proximity.update { $0.ble = true }
        XCTAssertEqual(proximity.settings?.ble, false)
        XCTAssertNotNil(proximity.errorMessage)
    }

    @MainActor func testBleSeenIsReportedWithTheTokens() async {
        let backend = FakeProximity()
        let (proximity, _) = make(backend, FakeMoves())
        let token = String(repeating: "a", count: 32)
        proximity.ble.onSeen?([BleSighting(token: token, rssi: -60)])
        for _ in 0..<20 where backend.seen.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(backend.seen, [[BleSighting(token: token, rssi: -60)]])
    }

    @MainActor func testBluetoothDoesNotStartWhileOff() async {
        let (proximity, _) = make(FakeProximity(), FakeMoves())
        await proximity.becameActive()
        XCTAssertFalse(proximity.ble.isRunning)
    }
}
