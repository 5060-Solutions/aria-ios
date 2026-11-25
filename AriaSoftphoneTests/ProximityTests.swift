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
        let token = "0123456789abcdef01234567"
        let uuid = try XCTUnwrap(BleTokenCoding.serviceUUID(forToken: token))
        XCTAssertEqual(BleTokenCoding.token(from: uuid), token)
    }

    func testOnlyAriaTokensAreRecognised() {
        XCTAssertNil(BleTokenCoding.token(from: CBUUID(string: "180D")))
        XCTAssertNil(BleTokenCoding.token(from: CBUUID(string: "0000FEAA-0000-1000-8000-00805F9B34FB")))
        XCTAssertNil(BleTokenCoding.serviceUUID(forToken: "short"))
        XCTAssertNil(BleTokenCoding.serviceUUID(forToken: String(repeating: "z", count: 24)))
    }

    // MARK: Settings and events

    func testSettingsDecodeTheServersKeys() throws {
        let json = #"{"suggest_nearby":true,"auto_move_on_leave":false,"ble_enabled":true}"#
        let settings = try JSONDecoder().decode(CallHandoffSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings, CallHandoffSettings(suggestNearby: true, autoMoveOnLeave: false, ble: true))
    }

    func testBleIsOffByDefault() {
        XCTAssertFalse(CallHandoffSettings.off.ble)
    }

    func testParsesHandoffSuggested() {
        let json = #"{"type":"handoff_suggested","call":{"id":"c1","state":"active","direction":"inbound","remote":{"number":"1","name":null},"started_at":"2026-11-25T22:00:00Z","device":{"registration_id":"r","label":"Desk"},"sip_call_id":null}}"#
        guard case .handoffSuggested(let call)? = ProximityEvent.parse(json) else { return XCTFail() }
        XCTAssertEqual(call.id, "c1")
        XCTAssertNil(ProximityEvent.parse(#"{"type":"call_ended","call_id":"c"}"#))
    }

    func testOnlyLeavingAKnownNetworkWithACallElsewhereIsReported() {
        XCTAssertTrue(Proximity.shouldReportLeaving(previous: "a", now: "b", otherDeviceHasCall: true))
        XCTAssertTrue(Proximity.shouldReportLeaving(previous: "a", now: nil, otherDeviceHasCall: true))
        XCTAssertFalse(Proximity.shouldReportLeaving(previous: "a", now: "a", otherDeviceHasCall: true))
        XCTAssertFalse(Proximity.shouldReportLeaving(previous: nil, now: "b", otherDeviceHasCall: true))
        XCTAssertFalse(Proximity.shouldReportLeaving(previous: "a", now: "b", otherDeviceHasCall: false))
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
        var left: [String?] = []
        var seen: [[String]] = []
        var failSave = false
        func settings() async throws -> CallHandoffSettings { stored }
        func saveSettings(_ settings: CallHandoffSettings) async throws -> CallHandoffSettings {
            if failSave { throw PbxApiClient.ApiError.httpError(statusCode: 500, message: "") }
            stored = settings
            return settings
        }
        func reportNetwork(registrationId: String, hash: String?) async throws { networks.append(hash) }
        func reportLeftNetwork(registrationId: String, previousHash: String?) async throws { left.append(previousHash) }
        func bleToken(registrationId: String) async throws -> BleToken { BleToken(token: "0123456789abcdef01234567", expiresAt: nil) }
        func reportBleSeen(registrationId: String, tokens: [String]) async throws { seen.append(tokens) }
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
        XCTAssertEqual(backend.left, ["home"])
        XCTAssertEqual(backend.networks, ["home", "cell"])
    }

    @MainActor func testLeavingWithNoCallElsewhereOnlyReportsTheNetwork() async {
        let backend = FakeProximity()
        let (proximity, _) = make(backend, FakeMoves())
        var hash: String? = "home"
        proximity.readNetworkHash = { hash }
        await proximity.reportNetworkIfChanged()
        hash = nil
        await proximity.pathChanged()
        XCTAssertTrue(backend.left.isEmpty)
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
        let (proximity, _) = make(FakeProximity(), FakeMoves())
        await proximity.becameActive()
        proximity.handle(.handoffSuggested(call()))
        XCTAssertEqual(proximity.suggestion?.id, "c1")
        await proximity.acceptSuggestion()
        XCTAssertNil(proximity.suggestion)
    }

    @MainActor func testSuggestionsAreOffWhenTheUserTurnedThemOff() async {
        let backend = FakeProximity()
        backend.stored.suggestNearby = false
        let (proximity, _) = make(backend, FakeMoves())
        await proximity.becameActive()
        proximity.handle(.handoffSuggested(call()))
        XCTAssertNil(proximity.suggestion)
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
        proximity.ble.onSeen?(["aaaaaaaaaaaaaaaaaaaaaaaa"])
        for _ in 0..<20 where backend.seen.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(backend.seen, [["aaaaaaaaaaaaaaaaaaaaaaaa"]])
    }

    @MainActor func testBluetoothDoesNotStartWhileOff() async {
        let (proximity, _) = make(FakeProximity(), FakeMoves())
        await proximity.becameActive()
        XCTAssertFalse(proximity.ble.isRunning)
    }
}
