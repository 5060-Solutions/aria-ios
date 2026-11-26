import Foundation
import CryptoKit
import CoreBluetooth

// Device proximity for "continue this call here".
//
// Three signals, all optional on the server side:
//  - the Wi-Fi network this phone is on, as a hash (never the SSID);
//  - leaving that network while another of the user's devices has a call
//    (a `left_network` context event);
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
    /// "192.168.1.0/24" for an address and its mask.
    static func subnetKey(address: UInt32, mask: UInt32) -> String {
        let network = address & mask
        let bytes = [24, 16, 8, 0].map { (network >> UInt32($0)) & 0xff }
        let prefixLength = mask.nonzeroBitCount
        return "\(bytes.map(String.init).joined(separator: "."))/\(prefixLength)"
    }

    /// The call-move contract's `network_hash`, the same on every platform:
    /// `lowercase_hex(sha256("aria-net-v1|" + extension_id + "|" + gateway + "|" + network/prefix))`.
    /// The extension id (lowercased) salts it per user.
    static func hash(extensionId: String, gateway: String, subnetKey: String) -> String {
        let input = "aria-net-v1|\(extensionId.lowercased())|\(gateway)|\(subnetKey)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The hash of the Wi-Fi or Ethernet network now; nil without an IPv4
    /// default route (cellular only, IPv6 only, a full-tunnel VPN) or when
    /// signed out.
    static func current(extensionId: String? = UserDefaults.standard.string(forKey: AccountSettings.Key.extensionId)) -> String? {
        guard let extensionId, !extensionId.isEmpty else { return nil }
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
            // The default route must be on this interface.
            guard let gateway = defaultGateway(interfaceIndex: if_nametoindex(name)) else { continue }
            let g = [24, 16, 8, 0].map { String((gateway >> UInt32($0)) & 0xff) }.joined(separator: ".")
            return hash(extensionId: extensionId, gateway: g, subnetKey: subnetKey(address: address, mask: netmask))
        }
        return nil
    }

    /// The IPv4 default gateway on `interfaceIndex` from the kernel's routing
    /// table (`sysctl` NET_RT_FLAGS), as a host-order address.
    static func defaultGateway(interfaceIndex: UInt32) -> UInt32? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, 2 /* NET_RT_FLAGS */, 2 /* RTF_GATEWAY */]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        return parseDefaultGateway(Array(buffer.prefix(length)), interfaceIndex: interfaceIndex)
    }

    /// Reads `rt_msghdr` records (92-byte header, then sockaddrs for the
    /// RTA_* bits set in `rtm_addrs`, each padded to 4 bytes) and returns the
    /// gateway of the IPv4 default route (destination 0.0.0.0) on the interface.
    static func parseDefaultGateway(_ bytes: [UInt8], interfaceIndex: UInt32) -> UInt32? {
        let headerSize = 92
        var offset = 0
        while offset + headerSize <= bytes.count {
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard length >= headerSize, offset + length <= bytes.count else { return nil }
            let index = UInt32(bytes[offset + 4]) | UInt32(bytes[offset + 5]) << 8
            let addrs = Int32(bytes[offset + 12]) | Int32(bytes[offset + 13]) << 8
            var cursor = offset + headerSize
            var destination: UInt32?
            var gateway: UInt32?
            for bit in 0..<8 where addrs & (1 << Int32(bit)) != 0 {
                guard cursor < offset + length else { break }
                let saLength = Int(bytes[cursor])
                let family = cursor + 1 < bytes.count ? Int32(bytes[cursor + 1]) : 0
                if family == AF_INET, saLength >= 8, cursor + 8 <= bytes.count {
                    let value = UInt32(bytes[cursor + 4]) << 24 | UInt32(bytes[cursor + 5]) << 16
                        | UInt32(bytes[cursor + 6]) << 8 | UInt32(bytes[cursor + 7])
                    if bit == 0 { destination = value } else if bit == 1 { gateway = value }
                } else if bit == 0, saLength <= 8 {
                    // A default route's destination may be a zero-length sockaddr.
                    destination = 0
                }
                cursor += saLength == 0 ? 4 : (saLength + 3) & ~3
            }
            if index == interfaceIndex, destination == 0, let gateway { return gateway }
            offset += length
        }
        return nil
    }
}

// MARK: - Settings and events

/// The user's `/me/call-handoff` settings. `suggest_nearby` defaults to true
/// on the server, the rest to false.
struct CallHandoffSettings: Codable, Equatable {
    /// Offer to continue a call here when this phone is near it.
    var suggestNearby: Bool
    /// Move a call here without asking when the user leaves with it.
    var autoMoveOnLeave: Bool
    /// Bluetooth LE proximity between the user's devices.
    var ble: Bool

    static let off = CallHandoffSettings(suggestNearby: false, autoMoveOnLeave: false, ble: false)

    init(suggestNearby: Bool, autoMoveOnLeave: Bool, ble: Bool) {
        self.suggestNearby = suggestNearby
        self.autoMoveOnLeave = autoMoveOnLeave
        self.ble = ble
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestNearby = try c.decodeIfPresent(Bool.self, forKey: .suggestNearby) ?? true
        autoMoveOnLeave = try c.decodeIfPresent(Bool.self, forKey: .autoMoveOnLeave) ?? false
        ble = try c.decodeIfPresent(Bool.self, forKey: .ble) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case suggestNearby = "suggest_nearby"
        case autoMoveOnLeave = "auto_move_on_leave"
        case ble = "ble_opt_in"
    }
}

/// A server-issued rotating Bluetooth token (`GET .../ble-token`).
struct BleToken: Decodable, Equatable {
    /// Lowercase hex, 32 characters (16 bytes).
    let token: String
    let rotatesAt: Date?

    enum CodingKeys: String, CodingKey {
        case token
        case rotatesAt = "rotates_at"
    }

    init(token: String, rotatesAt: Date?) {
        self.token = token
        self.rotatesAt = rotatesAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        // `rotates_at` is RFC 3339, with or without fractional seconds.
        if let text = try c.decodeIfPresent(String.self, forKey: .rotatesAt) {
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            rotatesAt = plain.date(from: text) ?? fractional.date(from: text)
        } else {
            rotatesAt = nil
        }
    }
}

/// One token heard over Bluetooth, with its signal strength.
struct BleSighting: Equatable {
    /// The most tokens one report may carry.
    static let maxPerReport = 32
    let token: String
    let rssi: Int
}

/// What `POST .../context` answered.
struct ContextResult: Decodable, Equatable {
    /// `moved`, `suggested` or `none`.
    let action: String
    let callId: String?
    let moveId: String?

    enum CodingKeys: String, CodingKey {
        case action
        case callId = "call_id"
        case moveId = "move_id"
    }
}

enum ProximityEvent: Equatable {
    /// The server suggests moving `callId` to `toRegistrationId`
    /// (`reason`: `nearby`, `left_network` or `desktop_locked`).
    case handoffSuggested(callId: String, toRegistrationId: String, reason: String)

    static func parse(_ text: String) -> ProximityEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "handoff_suggested",
              let callId = object["call_id"] as? String, !callId.isEmpty,
              let target = object["to_registration_id"] as? String, !target.isEmpty
        else { return nil }
        return .handoffSuggested(callId: callId, toRegistrationId: target, reason: object["reason"] as? String ?? "")
    }
}

// MARK: - Bluetooth token encoding

/// A token travels as the advertised service UUID: the server's 16 bytes
/// (32 hex digits) are exactly one 128-bit UUID. iOS apps cannot advertise
/// service data, so the UUID is the whole message.
enum BleTokenCoding {
    static func serviceUUID(forToken token: String) -> CBUUID? {
        guard token.count == 32, let bytes = bytes(fromHex: token) else { return nil }
        return CBUUID(data: Data(bytes))
    }

    /// The token a service UUID carries; nil for a standard Bluetooth
    /// service (a 16-bit number or the base UUID widened).
    static func token(from uuid: CBUUID) -> String? {
        let data = [UInt8](uuid.data)
        guard data.count == 16 else { return nil }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard !hex.hasSuffix("00001000800000805f9b34fb") else { return nil }
        return hex
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
    /// Report where this phone is: its network hash, and the tokens it heard.
    func reportProximity(sipInstance: String, networkHash: String?, bleSeen: [BleSighting]) async throws
    /// Report a context event (`left_network`).
    func reportContext(sipInstance: String, event: String) async throws -> ContextResult
    func bleToken(sipInstance: String) async throws -> BleToken
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

    func reportProximity(sipInstance: String, networkHash: String?, bleSeen: [BleSighting]) async throws {
        try await withClient {
            try await $0.postProximity(jwt: $1, sipInstance: sipInstance, networkHash: networkHash, bleSeen: bleSeen)
        }
    }

    func reportContext(sipInstance: String, event: String) async throws -> ContextResult {
        try await withClient { try await $0.postContext(jwt: $1, sipInstance: sipInstance, event: event) }
    }

    func bleToken(sipInstance: String) async throws -> BleToken {
        try await withClient { try await $0.bleToken(jwt: $1, sipInstance: sipInstance) }
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
    static let reportInterval: TimeInterval = 60
    private var reportTimer: Timer?

    init(backend: ProximityBackend, moves: CallMoveModel, ble: BleProximity = BleProximity()) {
        self.backend = backend
        self.moves = moves
        self.ble = ble
        ble.onSeen = { [weak self] seen in
            Task { @MainActor in await self?.reportBleSeen(seen) }
        }
    }

    // MARK: Lifecycle

    func becameActive() async {
        guard moves.isSignedIn() else { return }
        if let loaded = try? await backend.settings() { settings = loaded }
        await reportNetworkNow()
        await updateBle()
        // About every minute while the app is visible.
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: Self.reportInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.reportNetworkNow() } }
        }
    }

    func resignedActive() {
        reportTimer?.invalidate()
        reportTimer = nil
        // The token's rotation would start BLE again in the background.
        rotation?.cancel()
        rotation = nil
        ble.stop()
    }

    func reset() {
        settings = nil
        suggestion = nil
        lastHash = nil
        hasReportedOnce = false
        reportTimer?.invalidate()
        reportTimer = nil
        rotation?.cancel()
        rotation = nil
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
        guard !hasReportedOnce || hash != lastHash else { return }
        await sendNetwork(hash)
    }

    /// Report the network hash again whatever it is: on the foreground and
    /// about every minute while the app is visible.
    func reportNetworkNow() async {
        guard moves.isSignedIn() else { return }
        await sendNetwork(readNetworkHash())
    }

    private func sendNetwork(_ hash: String?) async {
        guard await moves.ownRegistration() != nil, let instance = moves.ownSipInstance() else { return }
        hasReportedOnce = true
        lastHash = hash
        try? await backend.reportProximity(sipInstance: instance, networkHash: hash, bleSeen: [])
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
        guard otherDeviceHasCall, settings?.suggestNearby != false,
              await moves.ownRegistration() != nil, let instance = moves.ownSipInstance(),
              let answer = try? await backend.reportContext(sipInstance: instance, event: "left_network")
        else { return }
        // `moved`: the PBX is already moving the call here, and its INVITE
        // is answered without ringing because this phone started it.
        if answer.action == "moved", let callId = answer.callId, let moveId = answer.moveId {
            moves.registerMove(moveId: moveId, callId: callId)
        }
    }

    /// Leaving is a network we were on that is no longer the one we are on,
    /// while the user has a call on another device.
    nonisolated static func shouldReportLeaving(previous: String?, now: String?, otherDeviceHasCall: Bool) -> Bool {
        otherDeviceHasCall && previous != nil && previous != now
    }

    // MARK: Events

    func handle(_ event: ProximityEvent) {
        Task { @MainActor in await handleSuggestion(event) }
    }

    /// Shows the call for a suggestion to move it to this phone. A
    /// suggestion naming another device is that device's to show.
    func handleSuggestion(_ event: ProximityEvent) async {
        switch event {
        case .handoffSuggested(let callId, let target, _):
            // Only while this phone has no call and the user wants them.
            guard settings?.suggestNearby != false, !moves.hasLocalCall(),
                  await moves.ownRegistration() == target else { return }
            var call = moves.call(withId: callId)
            if call == nil {
                await moves.refresh()
                call = moves.call(withId: callId)
            }
            if let call { suggestion = call }
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
        guard settings?.ble == true, await moves.ownRegistration() != nil, let instance = moves.ownSipInstance() else {
            ble.stop()
            return
        }
        guard let token = try? await backend.bleToken(sipInstance: instance),
              let uuid = BleTokenCoding.serviceUUID(forToken: token.token) else { return }
        ble.start(advertising: uuid)
        // Rotate before it expires.
        let lifetime = token.rotatesAt.map { max(30, $0.timeIntervalSinceNow - 10) } ?? 300
        rotation?.cancel()
        rotation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            if !Task.isCancelled { await self?.rotateIfActive() }
        }
    }

    private var rotation: Task<Void, Never>?
    var hasScheduledRotation: Bool { rotation != nil }

    /// A token rotation: only while the app is visible (a cancelled task, or
    /// BLE already stopped, restarts nothing).
    private func rotateIfActive() async {
        guard ble.isRunning else { return }
        await updateBle()
    }

    private func reportBleSeen(_ seen: [BleSighting]) async {
        guard !seen.isEmpty, await moves.ownRegistration() != nil, let instance = moves.ownSipInstance() else { return }
        try? await backend.reportProximity(sipInstance: instance, networkHash: lastHash, bleSeen: seen)
    }
}

// MARK: - CoreBluetooth

/// Advertises this phone's rotating token and scans for others', in the
/// foreground only: iOS does not let a backgrounded app advertise a UUID
/// that other apps can read, and the feature is a nearness hint, not a
/// tracker. Off unless the user turned it on in Settings; the system asks
/// for Bluetooth permission the first time it starts.
final class BleProximity: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    /// Tokens seen (other than our own) with their signal strength, at most
    /// once per `reportInterval`, the strongest 32.
    var onSeen: (([BleSighting]) -> Void)?
    static let reportInterval: TimeInterval = 20

    private var peripheral: CBPeripheralManager?
    private var central: CBCentralManager?
    private var advertised: CBUUID?
    private var seen: [String: Int] = [:]
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
        seen = [:]
    }

    private func flush() {
        guard !seen.isEmpty else { return }
        let sightings = seen.sorted { $0.value > $1.value }.prefix(BleSighting.maxPerReport)
            .map { BleSighting(token: $0.key, rssi: $0.value) }
        seen = [:]
        onSeen?(sightings)
    }

    private func advertiseIfReady() {
        guard isRunning, let peripheral, peripheral.state == .poweredOn, let uuid = advertised else { return }
        peripheral.stopAdvertising()
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]])
    }

    private func scanIfReady() {
        guard isRunning, let central, central.state == .poweredOn else { return }
        // No service filter: a foreground scan may be unfiltered, and the
        // tokens are the 128-bit service UUIDs (the standard
        // 16-bit ones are skipped).
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
            if let token = BleTokenCoding.token(from: uuid) { seen[token] = max(seen[token] ?? Int.min, RSSI.intValue) }
        }
    }
}
