import Foundation
import CryptoKit
import CoreBluetooth

// Device proximity for "continue this call here".
//
// Three signals, all optional on the server side:
//  - the Wi-Fi network this phone is on, as a hash (never the SSID);
//  - leaving that network while another of the user's devices has a call;
//  - with the user's opt-in, a Bluetooth LE token seen from another device.
//
// The server decides when to suggest a handoff (`handoff_suggested`); the app
// only reports and shows the prompt.

// MARK: - Network identity

/// What identifies "the same network" without the SSID.
///
/// Reading the SSID needs the Location permission and the Access Wi-Fi
/// Information entitlement, a prompt a phone-call app should not need. The
/// IPv4 subnet of the Wi-Fi (or Ethernet) interface says the same thing for
/// this purpose: two devices of one user on one network share it. It is
/// hashed with SHA-256 so no address leaves the phone, and read from the
/// interface, so it needs no permission. The server only ever compares the
/// hashes of one user's own devices, which keeps the common 192.168.x.0/24
/// subnets of unrelated homes from meeting.
enum NetworkIdentity {
    static let prefix = "aria-network-v1:"

    /// "192.168.1.0/24" for an address and its mask.
    static func subnetKey(address: UInt32, mask: UInt32) -> String {
        let network = address & mask
        let bytes = [24, 16, 8, 0].map { (network >> UInt32($0)) & 0xff }
        let prefixLength = mask.nonzeroBitCount
        return "\(bytes.map(String.init).joined(separator: "."))/\(prefixLength)"
    }

    /// Lowercase hex SHA-256 of the subnet key.
    static func hash(subnetKey: String) -> String {
        SHA256.hash(data: Data((prefix + subnetKey).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The hash of the Wi-Fi or Ethernet subnet now, nil on cellular only.
    static func current() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let name = String(cString: entry.ifa_name)
            // en0 is Wi-Fi on iPhone and iPad; other enN are Ethernet adapters.
            // pdp_ip (cellular), utun (VPN) and awdl (AirDrop) are not a network
            // the user's other devices share.
            guard name.hasPrefix("en"),
                  Int32(entry.ifa_flags) & IFF_UP != 0,
                  let addr = entry.ifa_addr, let mask = entry.ifa_netmask,
                  Int32(addr.pointee.sa_family) == AF_INET else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Link-local (no DHCP lease) says nothing about a network.
            if address >> 16 == 0xA9FE { continue }
            return hash(subnetKey: subnetKey(address: address, mask: netmask))
        }
        return nil
    }
}

// MARK: - Settings and events

/// The user's `/me/call-handoff` settings.
struct CallHandoffSettings: Codable, Equatable {
    /// Offer to continue a call here when this phone is near it.
    var suggestNearby: Bool
    /// Move a call here without asking when the user leaves with it.
    var autoMoveOnLeave: Bool
    /// Bluetooth LE proximity between the user's devices.
    var ble: Bool

    static let off = CallHandoffSettings(suggestNearby: false, autoMoveOnLeave: false, ble: false)

    enum CodingKeys: String, CodingKey {
        case suggestNearby = "suggest_nearby"
        case autoMoveOnLeave = "auto_move_on_leave"
        case ble = "ble_enabled"
    }
}

/// A server-issued rotating Bluetooth token (`GET .../ble-token`).
struct BleToken: Decodable, Equatable {
    /// Lowercase hex, 24 characters (12 bytes).
    let token: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

enum ProximityEvent: Equatable {
    /// The server suggests continuing `call` on this phone.
    case handoffSuggested(UserCall)

    static func parse(_ text: String) -> ProximityEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "handoff_suggested",
              let call = object["call"],
              let callData = try? JSONSerialization.data(withJSONObject: call),
              let decoded = try? PbxApiClient.jsonDecoder.decode(UserCall.self, from: callData)
        else { return nil }
        return .handoffSuggested(decoded)
    }
}

// MARK: - Bluetooth token encoding

/// A token travels as the advertised service UUID: 4 magic bytes ("ARIA")
/// then the token's 12 bytes. iOS apps cannot advertise service data, and a
/// scanner that sees a UUID with the magic prefix knows it is Aria's.
enum BleTokenCoding {
    static let magic: [UInt8] = [0x41, 0x52, 0x49, 0x41]

    static func serviceUUID(forToken token: String) -> CBUUID? {
        guard token.count == 24, let bytes = bytes(fromHex: token) else { return nil }
        return CBUUID(data: Data(magic + bytes))
    }

    static func token(from uuid: CBUUID) -> String? {
        let data = [UInt8](uuid.data)
        guard data.count == 16, Array(data.prefix(4)) == magic else { return nil }
        return data.dropFirst(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

// MARK: - Backend

protocol ProximityBackend {
    func settings() async throws -> CallHandoffSettings
    func saveSettings(_ settings: CallHandoffSettings) async throws -> CallHandoffSettings
    /// Report this phone's network hash.
    func reportNetwork(registrationId: String, hash: String?) async throws
    /// This phone left the network it was on while another device had a call.
    func reportLeftNetwork(registrationId: String, previousHash: String?) async throws
    func bleToken(registrationId: String) async throws -> BleToken
    func reportBleSeen(registrationId: String, tokens: [String]) async throws
}

struct LiveProximityBackend: ProximityBackend {
    private func withClient<T>(_ operation: @escaping (PbxApiClient, String) async throws -> T) async throws -> T {
        let apiUrl = AccountSettings.load().apiUrl
        guard !apiUrl.isEmpty else { throw PbxSessionError.notSignedIn }
        let client = PbxApiClient(baseUrl: apiUrl)
        return try await PbxSession.shared.authorized { try await operation(client, $0) }
    }

    func settings() async throws -> CallHandoffSettings {
        try await withClient { try await $0.callHandoffSettings(jwt: $1) }
    }

    func saveSettings(_ settings: CallHandoffSettings) async throws -> CallHandoffSettings {
        try await withClient { try await $0.setCallHandoffSettings(jwt: $1, settings) }
    }

    func reportNetwork(registrationId: String, hash: String?) async throws {
        try await withClient {
            try await $0.postProximity(jwt: $1, registrationId: registrationId,
                                       body: ["type": "network", "network_hash": hash.map { $0 as Any } ?? NSNull()])
        }
    }

    func reportLeftNetwork(registrationId: String, previousHash: String?) async throws {
        try await withClient {
            try await $0.postProximity(jwt: $1, registrationId: registrationId,
                                       body: ["type": "left_network", "network_hash": previousHash.map { $0 as Any } ?? NSNull()])
        }
    }

    func bleToken(registrationId: String) async throws -> BleToken {
        try await withClient { try await $0.bleToken(jwt: $1, registrationId: registrationId) }
    }

    func reportBleSeen(registrationId: String, tokens: [String]) async throws {
        try await withClient {
            try await $0.postProximity(jwt: $1, registrationId: registrationId,
                                       body: ["type": "ble_seen", "tokens": tokens])
        }
    }
}

// MARK: - Model

/// Proximity reporting and the "Continue this call here" prompt.
@MainActor
final class Proximity: ObservableObject {
    static let shared = Proximity(backend: LiveProximityBackend(), moves: .shared)

    @Published private(set) var settings: CallHandoffSettings?
    /// A call the server suggests continuing here.
    @Published var suggestion: UserCall?
    @Published var errorMessage: String?

    private let backend: ProximityBackend
    private let moves: CallMoveModel
    /// Reads the network hash; replaced in tests.
    var readNetworkHash: () -> String? = { NetworkIdentity.current() }
    private(set) var lastHash: String?
    private var hasReportedOnce = false
    let ble: BleProximity

    init(backend: ProximityBackend, moves: CallMoveModel, ble: BleProximity = BleProximity()) {
        self.backend = backend
        self.moves = moves
        self.ble = ble
        ble.onSeen = { [weak self] tokens in
            Task { @MainActor in await self?.reportBleSeen(tokens) }
        }
    }

    // MARK: Lifecycle

    func becameActive() async {
        guard moves.isSignedIn() else { return }
        if let loaded = try? await backend.settings() { settings = loaded }
        await reportNetworkIfChanged()
        await updateBle()
    }

    func resignedActive() {
        ble.stop()
    }

    func reset() {
        settings = nil
        suggestion = nil
        lastHash = nil
        hasReportedOnce = false
        ble.stop()
    }

    // MARK: Settings

    func update(_ change: (inout CallHandoffSettings) -> Void) async {
        var next = settings ?? .off
        change(&next)
        let previous = settings
        settings = next
        do {
            settings = try await backend.saveSettings(next)
            await updateBle()
        } catch {
            settings = previous
            errorMessage = String(localized: "The setting could not be saved.")
        }
    }

    // MARK: Network

    /// Report the network hash when it differs from the last one reported.
    func reportNetworkIfChanged() async {
        let hash = readNetworkHash()
        guard !hasReportedOnce || hash != lastHash, let registration = await moves.ownRegistration() else { return }
        hasReportedOnce = true
        lastHash = hash
        try? await backend.reportNetwork(registrationId: registration, hash: hash)
    }

    /// A path change. When this phone left the network it was on while
    /// another device has a call, tell the server (`left_network`), which
    /// may answer with `handoff_suggested`.
    func pathChanged() async {
        let previous = lastHash
        let now = readNetworkHash()
        guard now != previous else { return }
        let otherDeviceHasCall = Self.shouldReportLeaving(
            previous: previous, now: now, otherDeviceHasCall: moves.hasCallElsewhere
        )
        await reportNetworkIfChanged()
        guard otherDeviceHasCall, let registration = await moves.ownRegistration() else { return }
        try? await backend.reportLeftNetwork(registrationId: registration, previousHash: previous)
    }

    /// Leaving is a network we were on that is no longer the one we are on,
    /// while the user has a call on another device.
    nonisolated static func shouldReportLeaving(previous: String?, now: String?, otherDeviceHasCall: Bool) -> Bool {
        otherDeviceHasCall && previous != nil && previous != now
    }

    // MARK: Events

    func handle(_ event: ProximityEvent) {
        switch event {
        case .handoffSuggested(let call):
            // Only while this phone has no call and the user wants them.
            guard settings?.suggestNearby != false, !moves.hasLocalCall() else { return }
            suggestion = call
        }
    }

    func acceptSuggestion() async {
        guard let call = suggestion else { return }
        suggestion = nil
        await moves.moveHere(call)
    }

    func dismissSuggestion() { suggestion = nil }

    // MARK: Bluetooth

    func updateBle() async {
        guard settings?.ble == true, let registration = await moves.ownRegistration() else {
            ble.stop()
            return
        }
        guard let token = try? await backend.bleToken(registrationId: registration),
              let uuid = BleTokenCoding.serviceUUID(forToken: token.token) else { return }
        ble.start(advertising: uuid)
        // Rotate before it expires.
        let lifetime = token.expiresAt.map { max(30, $0.timeIntervalSinceNow - 10) } ?? 300
        rotation?.cancel()
        rotation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            if !Task.isCancelled { await self?.updateBle() }
        }
    }

    private var rotation: Task<Void, Never>?

    private func reportBleSeen(_ tokens: [String]) async {
        guard !tokens.isEmpty, let registration = await moves.ownRegistration() else { return }
        try? await backend.reportBleSeen(registrationId: registration, tokens: tokens)
    }
}

// MARK: - CoreBluetooth

/// Advertises this phone's rotating token and scans for others', in the
/// foreground only: iOS does not let a backgrounded app advertise a UUID
/// that other apps can read, and the feature is a nearness hint, not a
/// tracker. Off unless the user turned it on in Settings; the system asks
/// for Bluetooth permission the first time it starts.
final class BleProximity: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    /// Tokens seen (other than our own), at most once per `reportInterval`.
    var onSeen: (([String]) -> Void)?
    static let reportInterval: TimeInterval = 20

    private var peripheral: CBPeripheralManager?
    private var central: CBCentralManager?
    private var advertised: CBUUID?
    private var seen: Set<String> = []
    private var flushTimer: Timer?
    private(set) var isRunning = false

    func start(advertising uuid: CBUUID) {
        advertised = uuid
        isRunning = true
        if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: .main) }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        advertiseIfReady()
        scanIfReady()
        if flushTimer == nil {
            flushTimer = Timer.scheduledTimer(withTimeInterval: Self.reportInterval, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func stop() {
        isRunning = false
        peripheral?.stopAdvertising()
        central?.stopScan()
        flushTimer?.invalidate()
        flushTimer = nil
        seen = []
    }

    private func flush() {
        guard !seen.isEmpty else { return }
        let tokens = Array(seen)
        seen = []
        onSeen?(tokens)
    }

    private func advertiseIfReady() {
        guard isRunning, let peripheral, peripheral.state == .poweredOn, let uuid = advertised else { return }
        peripheral.stopAdvertising()
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]])
    }

    private func scanIfReady() {
        guard isRunning, let central, central.state == .poweredOn else { return }
        // No service filter: a foreground scan may be unfiltered, and the
        // token is only recognised by its prefix.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { advertiseIfReady() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { scanIfReady() }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] else { return }
        for uuid in uuids where uuid != advertised {
            if let token = BleTokenCoding.token(from: uuid) { seen.insert(token) }
        }
    }
}
