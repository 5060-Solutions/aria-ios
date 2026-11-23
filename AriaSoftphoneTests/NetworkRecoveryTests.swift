import XCTest
@testable import AriaSoftphone

/// The core's registration statuses after a network change, and the
/// gateway device id moving with failover and failback.
final class RegistrationUpdateTests: XCTestCase {
    private func apply(_ status: String, error: String? = nil, deviceId: String = "gw-1",
                       to state: RegistrationUpdate.State) -> RegistrationUpdate.State {
        var state = state
        RegistrationUpdate(status: status, error: error).apply(to: &state, deviceId: deviceId)
        return state
    }

    private let registered = RegistrationUpdate.State(isRegistered: true, isRecovering: false, error: nil, deviceId: "gw-1")

    func testRecoveringKeepsTheRegistrationAndShowsReconnecting() {
        let state = apply("recovering", to: registered)
        XCTAssertTrue(state.isRecovering)
        XCTAssertTrue(state.isRegistered)
        XCTAssertEqual(ConnectionState.derive(isProvisioned: true, isNetworkAvailable: true,
                                              isRegistered: state.isRegistered, isConnecting: false,
                                              isRecovering: state.isRecovering, error: state.error),
                       .reconnecting)
        XCTAssertEqual(ConnectionState.reconnecting.label, "Reconnecting…")
    }

    func testRegisteredTakesTheNewDeviceIdAndClearsRecovery() {
        var state = apply("recovering", to: registered)
        state.error = "old"
        state = apply("registered", deviceId: "gw-2", to: state)
        XCTAssertEqual(state, RegistrationUpdate.State(isRegistered: true, isRecovering: false, error: nil, deviceId: "gw-2"))
        XCTAssertTrue(RegistrationUpdate(status: "registered", error: nil).replacesDeviceId)
        XCTAssertFalse(RegistrationUpdate(status: "recovering", error: nil).replacesDeviceId)
    }

    func testFailedIsAnErrorWithAReason() {
        let state = apply("failed", error: "no gateway answered", to: registered)
        XCTAssertFalse(state.isRegistered)
        XCTAssertFalse(state.isRecovering)
        XCTAssertEqual(ConnectionState.derive(isProvisioned: true, isNetworkAvailable: true,
                                              isRegistered: false, isConnecting: false,
                                              isRecovering: false, error: state.error),
                       .error("no gateway answered"))
        XCTAssertNotNil(apply("failed", to: registered).error, "a reason even when the core gives none")
    }

    func testAuthRequiredRenewsAndShowsAsRecovering() {
        let update = RegistrationUpdate(status: "auth_required", error: nil)
        XCTAssertTrue(update.needsToken)
        XCTAssertTrue(apply("auth_required", to: registered).isRecovering)
    }

    func testUnregisteredAndUnknownStatuses() {
        let state = apply("unregistered", to: registered)
        XCTAssertFalse(state.isRegistered)
        XCTAssertEqual(apply("something-new", to: registered), registered)
    }
}

/// An engine that records what the app asks of it. Built without a Rust
/// object (`noPointer`); only the overridden methods may be called.
private final class FakeEngine: AriaMobileEngine {
    var pushTokenDeviceIds: [String] = []
    var unregistered: [String] = []
    var networkChanges = 0
    var gateway: String? = "gw2.ariaroute.com:443"
    let unregisteredExpectation: XCTestExpectation?

    init(unregisteredExpectation: XCTestExpectation? = nil) {
        self.unregisteredExpectation = unregisteredExpectation
        super.init(noPointer: NoPointer())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("not used")
    }

    override func updatePushToken(deviceId: String, newToken: String) throws {
        pushTokenDeviceIds.append(deviceId)
    }

    override func unregisterDevice(deviceId: String) throws {
        unregistered.append(deviceId)
        unregisteredExpectation?.fulfill()
    }

    override func notifyNetworkChange() { networkChanges += 1 }
    override func currentGateway() -> String? { gateway }
    override func getActiveCall() -> CallInfo? { nil }
}

final class GatewayDeviceIdTests: XCTestCase {
    override func tearDown() {
        SipEngineManager.shared.installEngineForTesting(nil, registeredDeviceId: nil)
        super.tearDown()
    }

    func testAFailoverDeviceIdIsUsedToUnregister() {
        let done = expectation(description: "unregistered")
        let engine = FakeEngine(unregisteredExpectation: done)
        let manager = SipEngineManager.shared
        manager.installEngineForTesting(engine, registeredDeviceId: "gw-a")

        // The core moved the registration to another instance.
        manager.registrationChanged(deviceId: "gw-b", status: "registered", error: nil)
        XCTAssertEqual(manager.gatewayDeviceId, "gw-b")
        XCTAssertEqual(manager.currentGateway(), "gw2.ariaroute.com:443")

        // A recovering report names no new device and changes nothing.
        manager.registrationChanged(deviceId: "", status: "recovering", error: nil)
        XCTAssertEqual(manager.gatewayDeviceId, "gw-b")

        manager.signOut()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(engine.unregistered, ["gw-b"])
    }

    func testNetworkChangesAreCoalesced() {
        let engine = FakeEngine()
        let manager = SipEngineManager.shared
        manager.installEngineForTesting(engine, registeredDeviceId: "gw-a")
        for _ in 0..<5 { manager.networkChanged(.interfaceChanged) }
        let settled = expectation(description: "debounced")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(engine.networkChanges, 1)
    }

    func testDebouncerRunsOnceAfterTheLastSignal() {
        var runs = 0
        let ran = expectation(description: "ran")
        let debouncer = Debouncer(delay: 0.1, queue: .main) { runs += 1; ran.fulfill() }
        debouncer.signal(); debouncer.signal(); debouncer.signal()
        wait(for: [ran], timeout: 2)
        XCTAssertEqual(runs, 1)
    }
}

final class DroppedCallTests: XCTestCase {
    private func call(connected: Bool) -> ActiveCall {
        var call = ActiveCall(uuid: UUID(), callToken: nil, remoteUri: "1001", remoteName: nil,
                              direction: .outbound, state: .connecting)
        if connected { call.callId = "c"; call.connectedAt = Date() }
        return call
    }

    func testAConnectedCallEndedFailedIsADropReportedAsFailed() {
        let connected = call(connected: true)
        XCTAssertTrue(CallEnding.isDropped(connected, reason: .failed))
        XCTAssertEqual(CallEnding.resolve(for: connected, reason: .failed).callKitReason, .failed)
        XCTAssertFalse(CallEnding.isDropped(connected, reason: .remoteHangup))
        XCTAssertFalse(CallEnding.isDropped(call(connected: false), reason: .failed), "a call that never connected is not a drop")
        XCTAssertEqual(DroppedCallNotice(remote: "x").message, "Call dropped — connection lost")
    }

    func testCodecNamesFromTheCoreAreShownReadably() {
        XCTAssertEqual(CodecPreferences.displayName(sdpName: "opus"), "Opus")
        XCTAssertEqual(CodecPreferences.displayName(sdpName: "PCMU"), "G.711 µ-law (PCMU)")
        XCTAssertEqual(CodecPreferences.displayName(sdpName: "G729"), "G.729")
        XCTAssertEqual(CodecPreferences.displayName(sdpName: "iLBC"), "iLBC")
    }
}
