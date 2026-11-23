import XCTest
@testable import AriaSoftphone

/// A path monitor the test drives by hand.
private final class FakePathMonitor: PathMonitoring {
    var pathUpdateHandler: ((NetworkPath) -> Void)?
    private(set) var started = 0
    private(set) var cancelled = 0

    func start() { started += 1 }
    func cancel() { cancelled += 1 }
    func send(_ path: NetworkPath) { pathUpdateHandler?(path) }
}

final class NetworkMonitorTests: XCTestCase {
    private let wifi = NetworkPath(isSatisfied: true, interfaces: ["en0"], addresses: ["192.168.1.20"])
    private let wifiNewAddress = NetworkPath(isSatisfied: true, interfaces: ["en0"], addresses: ["10.0.0.7"])
    private let cellular = NetworkPath(isSatisfied: true, interfaces: ["pdp_ip0"], addresses: ["100.64.3.9"])

    private var fake: FakePathMonitor!
    private var changes: [NetworkChange] = []
    private var monitor: NetworkMonitor!

    override func setUp() {
        super.setUp()
        fake = FakePathMonitor()
        changes = []
        monitor = NetworkMonitor(monitor: fake) { [unowned self] change, _ in self.changes.append(change) }
        monitor.start()
    }

    func testTheFirstPathIsTheBaselineNotAChange() {
        fake.send(wifi)
        XCTAssertEqual(changes, [])
        XCTAssertEqual(monitor.current, wifi)
    }

    func testEveryKindOfChangeIsReported() {
        fake.send(wifi)
        fake.send(cellular)            // Wi-Fi -> cellular
        fake.send(.unsatisfied)        // lost
        fake.send(wifi)                // back
        fake.send(wifiNewAddress)      // same interface, new address
        XCTAssertEqual(changes, [.interfaceChanged, .becameUnreachable, .becameReachable, .addressChanged])
    }

    func testRepeatedIdenticalPathsAreDropped() {
        fake.send(wifi)
        fake.send(wifi)
        fake.send(wifi)
        XCTAssertEqual(changes, [])
    }

    func testStartIsIdempotentAndStopResetsTheBaseline() {
        monitor.start()
        XCTAssertEqual(fake.started, 1)
        fake.send(wifi)
        monitor.stop()
        XCTAssertEqual(fake.cancelled, 1)
        XCTAssertNil(monitor.current)
        monitor.start()
        fake.send(cellular)
        XCTAssertEqual(changes, [], "after a restart the first path is a new baseline")
    }

    func testChangeBetweenPaths() {
        XCTAssertNil(NetworkChange.between(wifi, wifi))
        XCTAssertEqual(NetworkChange.between(.unsatisfied, wifi), .becameReachable)
        XCTAssertEqual(NetworkChange.between(cellular, .unsatisfied), .becameUnreachable)
        // Both Wi-Fi and cellular up, then Wi-Fi drops: an interface change.
        let both = NetworkPath(isSatisfied: true, interfaces: ["en0", "pdp_ip0"], addresses: ["192.168.1.20", "100.64.3.9"])
        XCTAssertEqual(NetworkChange.between(both, cellular), .interfaceChanged)
    }

    func testTheSystemSnapshotOfLocalAddressesIgnoresOtherInterfaces() {
        XCTAssertEqual(SystemPathMonitor.localAddresses(on: []), [])
        // lo0 always has 127.0.0.1 on the simulator host.
        XCTAssertTrue(SystemPathMonitor.localAddresses(on: ["lo0"]).contains("127.0.0.1"))
    }
}

final class ConnectionStateTests: XCTestCase {
    private func derive(provisioned: Bool = true, network: Bool = true, registered: Bool = false,
                        connecting: Bool = false, error: String? = nil) -> ConnectionState {
        ConnectionState.derive(isProvisioned: provisioned, isNetworkAvailable: network,
                               isRegistered: registered, isConnecting: connecting, error: error)
    }

    func testOfflineWithoutAnAccountOrANetwork() {
        XCTAssertEqual(derive(provisioned: false, registered: true), .offline)
        XCTAssertEqual(derive(network: false, registered: true), .offline)
    }

    func testRegisteredWinsAndDoesNotFlickerDuringAReCheck() {
        XCTAssertEqual(derive(registered: true), .registered)
        XCTAssertEqual(derive(registered: true, connecting: true), .registered)
    }

    func testConnectingThenError() {
        XCTAssertEqual(derive(connecting: true, error: "old"), .connecting)
        XCTAssertEqual(derive(error: "gateway: timeout"), .error("gateway: timeout"))
        XCTAssertEqual(derive(), .connecting)
    }

    func testEveryStateHasALabel() {
        for state in [ConnectionState.offline, .connecting, .registered, .error("x")] {
            XCTAssertFalse(state.label.isEmpty)
        }
    }

    func testNetworkChangesUpdateAvailability() {
        let engine = SipEngineManager.shared
        engine.networkChanged(.becameUnreachable)
        let gone = expectation(description: "unavailable")
        DispatchQueue.main.async {
            XCTAssertFalse(engine.isNetworkAvailable)
            engine.networkChanged(.interfaceChanged)
            DispatchQueue.main.async {
                XCTAssertTrue(engine.isNetworkAvailable)
                gone.fulfill()
            }
        }
        wait(for: [gone], timeout: 2)
    }
}
