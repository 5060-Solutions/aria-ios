import Foundation

// Moving a call between the user's own devices (PBX `/api/v1/me/calls/...`).
//
// The far party's leg stays up on the PBX; only this user's device leg is
// swapped. The app speaks REST with its extension JWT and never sends SIP
// `Replaces`.

// MARK: - Wire types

/// A call of the user's, live on one of their devices (`GET /me/calls/active`).
struct UserCall: Decodable, Identifiable, Equatable {
    struct Remote: Decodable, Equatable {
        let number: String?
        let name: String?
    }

    struct Device: Decodable, Equatable {
        let registrationId: String
        let label: String?
        let userAgent: String?
        let transport: String?

        enum CodingKeys: String, CodingKey {
            case registrationId = "registration_id"
            case label
            case userAgent = "user_agent"
            case transport
        }
    }

    let id: String
    /// `active` or `held`.
    let state: String
    /// `inbound` or `outbound`.
    let direction: String
    let remote: Remote
    let startedAt: Date
    let device: Device
    /// The Call-ID of that device's leg.
    let sipCallId: String?

    enum CodingKeys: String, CodingKey {
        case id, state, direction, remote, device
        case startedAt = "started_at"
        case sipCallId = "sip_call_id"
    }

    /// The far party as shown: name, else number, else a placeholder.
    var remoteDisplay: String {
        if let name = remote.name, !name.isEmpty { return name }
        if let number = remote.number, !number.isEmpty { return number }
        return String(localized: "Unknown caller")
    }

    var deviceLabel: String {
        if let label = device.label, !label.isEmpty { return label }
        return String(localized: "another device")
    }
}

/// One of the user's registered devices (`GET /me/devices`).
struct UserDevice: Decodable, Identifiable, Equatable {
    let registrationId: String
    let label: String?
    let userAgent: String?
    let transport: String?
    let online: Bool

    var id: String { registrationId }

    var displayName: String {
        if let label, !label.isEmpty { return label }
        if let userAgent, !userAgent.isEmpty { return userAgent }
        return String(localized: "Device")
    }

    enum CodingKeys: String, CodingKey {
        case registrationId = "registration_id"
        case label
        case userAgent = "user_agent"
        case transport
        case online
    }
}

/// What the PBX's WebSocket says about calls on the user's devices.
enum CallMoveEvent: Equatable {
    case activeElsewhere(UserCall)
    case moved(callId: String, from: String, to: String)
    case ended(callId: String)

    /// Parse one text frame; nil for any other event.
    static func parse(_ text: String) -> CallMoveEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "call_active_elsewhere":
            guard let call = object["call"],
                  let callData = try? JSONSerialization.data(withJSONObject: call),
                  let decoded = try? PbxApiClient.jsonDecoder.decode(UserCall.self, from: callData) else { return nil }
            return .activeElsewhere(decoded)
        case "call_moved":
            guard let callId = object["call_id"] as? String,
                  let from = object["from_registration_id"] as? String,
                  let to = object["to_registration_id"] as? String else { return nil }
            return .moved(callId: callId, from: from, to: to)
        case "call_ended":
            guard let callId = object["call_id"] as? String else { return nil }
            return .ended(callId: callId)
        default:
            return nil
        }
    }
}

// MARK: - Rules

enum CallMoveRules {
    /// The `+sip.instance` URN this install is known by. The gateway registers
    /// the phone with the PBX, so it is derived from the device id the PBX
    /// issued at `devices/register`.
    static func sipInstance(deviceId: String) -> String {
        let id = deviceId.lowercased()
        return UUID(uuidString: id) != nil ? "urn:uuid:\(id)" : id
    }

    /// The call to offer in the banner: a call of the user's that is not on
    /// this phone. Ours is one registered by this device, or one whose leg
    /// Call-ID is in `ownCallIds`. While a call is up here nothing is offered.
    static func elsewhereCall(
        in calls: [UserCall],
        ownRegistrationId: String?,
        ownCallIds: Set<String> = [],
        dismissed: Set<String> = [],
        hasLocalCall: Bool
    ) -> UserCall? {
        guard !hasLocalCall else { return nil }
        let others = calls.filter { call in
            if dismissed.contains(call.id) { return false }
            if let own = ownRegistrationId, call.device.registrationId == own { return false }
            if let sip = call.sipCallId, ownCallIds.contains(sip) { return false }
            return true
        }
        // A talking call before a held one, then the oldest.
        return others.sorted {
            if ($0.state == "active") != ($1.state == "active") { return $0.state == "active" }
            return $0.startedAt < $1.startedAt
        }.first
    }

    /// The call of ours on the PBX: the one this device holds the leg of.
    static func ownCall(in calls: [UserCall], ownRegistrationId: String?, ownCallIds: Set<String> = []) -> UserCall? {
        calls.first { call in
            if let own = ownRegistrationId, call.device.registrationId == own { return true }
            if let sip = call.sipCallId { return ownCallIds.contains(sip) }
            return false
        }
    }

    /// Devices a call can be moved to: online, and not this one.
    static func targets(_ devices: [UserDevice], ownRegistrationId: String?) -> [UserDevice] {
        devices.filter { $0.online && $0.registrationId != ownRegistrationId }
    }
}

// MARK: - Pending moves

/// Moves this phone started and is waiting for the PBX's INVITE of.
///
/// The INVITE carries `X-Aria-Move: <move_id>`; one this phone did not start
/// rings like any call. Thread-safe: the PushKit callback reads it
/// synchronously.
final class PendingMoveStore {
    struct Entry: Equatable {
        /// When the call started on the device it is leaving.
        let callStartedAt: Date
        let fromLabel: String
        let registeredAt: Date
    }

    static let shared = PendingMoveStore()
    /// The PBX gives up on a move after 20 s.
    static let lifetime: TimeInterval = 60

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func register(moveId: String, callStartedAt: Date, fromLabel: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { now.timeIntervalSince($0.value.registeredAt) < Self.lifetime }
        entries[moveId] = Entry(callStartedAt: callStartedAt, fromLabel: fromLabel, registeredAt: now)
    }

    /// The move, once: a replay of the same push finds nothing.
    func consume(moveId: String, now: Date = Date()) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.removeValue(forKey: moveId),
              now.timeIntervalSince(entry.registeredAt) < Self.lifetime else { return nil }
        return entry
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
    }
}

// MARK: - Backend

protocol CallMoveBackend {
    func activeCalls() async throws -> [UserCall]
    func devices() async throws -> [UserDevice]
    func currentDevice(sipInstance: String) async throws -> UserDevice
    /// POST /me/calls/{id}/move → the move id.
    func move(callId: String, to registrationId: String) async throws -> String
    func eventStreamRequest() async throws -> URLRequest?
}

struct LiveCallMoveBackend: CallMoveBackend {
    private func withClient<T>(_ operation: @escaping (PbxApiClient, String) async throws -> T) async throws -> T {
        let apiUrl = AccountSettings.load().apiUrl
        guard !apiUrl.isEmpty else { throw PbxSessionError.notSignedIn }
        let client = PbxApiClient(baseUrl: apiUrl)
        return try await PbxSession.shared.authorized { try await operation(client, $0) }
    }

    func activeCalls() async throws -> [UserCall] {
        try await withClient { try await $0.activeCalls(jwt: $1) }
    }

    func devices() async throws -> [UserDevice] {
        try await withClient { try await $0.userDevices(jwt: $1) }
    }

    func currentDevice(sipInstance: String) async throws -> UserDevice {
        try await withClient { try await $0.currentDevice(jwt: $1, sipInstance: sipInstance) }
    }

    func move(callId: String, to registrationId: String) async throws -> String {
        try await withClient { try await $0.moveCall(jwt: $1, callId: callId, toRegistrationId: registrationId) }
    }

    func eventStreamRequest() async throws -> URLRequest? {
        let apiUrl = AccountSettings.load().apiUrl
        guard !apiUrl.isEmpty, KeychainStore.get(KeychainStore.jwtKey) != nil else { return nil }
        let client = PbxApiClient(baseUrl: apiUrl)
        let jwt = try await PbxSession.shared.authorized { $0 }
        var request = URLRequest(url: try client.eventStreamURL())
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - Model

/// "Moved to <device>", shown when the PBX ended this phone's leg after a move.
struct MovedNotice: Identifiable, Equatable {
    let id = UUID()
    let deviceName: String

    var message: String {
        String(localized: "Moved to \(deviceName)")
    }
}

/// The user's calls on their other devices, and moving calls between devices.
///
/// Fresh on the foreground, every 15 s while active, and on the WebSocket's
/// call events.
@MainActor
final class CallMoveModel: ObservableObject {
    static let shared = CallMoveModel(backend: LiveCallMoveBackend())
    static let pollInterval: TimeInterval = 15

    /// The call to offer in the banner.
    @Published private(set) var elsewhere: UserCall?
    /// The other devices a call here could move to.
    @Published private(set) var devices: [UserDevice] = []
    @Published private(set) var isMoving = false
    @Published var errorMessage: String?
    @Published var notice: MovedNotice?

    /// Whether a call is up on this phone (set by the call manager's owner).
    var hasLocalCall: () -> Bool = { CallManager.shared.activeCall != nil }
    /// Leg Call-IDs known to be this phone's, when any are.
    var ownCallIds: () -> Set<String> = { [] }
    /// The device id the PBX issued at registration.
    var deviceId: () -> String = { UserDefaults.standard.string(forKey: AccountSettings.Key.pbxDeviceId) ?? "" }
    var isSignedIn: () -> Bool = { AccountSettings.load().isProvisioned }

    let pending: PendingMoveStore
    private let backend: CallMoveBackend
    private(set) var ownRegistrationId: String?
    private var calls: [UserCall] = []
    private var dismissed: Set<String> = []
    private var timer: Timer?
    private var socketTask: Task<Void, Never>?
    private var isActive = false
    /// A move away from this phone in flight: the device it goes to.
    private var leavingTo: (name: String, since: Date)?

    init(backend: CallMoveBackend, pending: PendingMoveStore = .shared) {
        self.backend = backend
        self.pending = pending
    }

    // MARK: Lifecycle

    func becameActive() {
        guard isSignedIn() else { return }
        isActive = true
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refresh() } }
        }
        startListening()
    }

    func resignedActive() {
        isActive = false
        timer?.invalidate()
        timer = nil
        socketTask?.cancel()
        socketTask = nil
    }

    func reset() {
        resignedActive()
        calls = []
        elsewhere = nil
        devices = []
        ownRegistrationId = nil
        dismissed = []
        notice = nil
        errorMessage = nil
        pending.reset()
    }

    // MARK: Reading

    func refresh() async {
        guard isSignedIn() else { return }
        _ = await ownRegistration()
        if let fresh = try? await backend.activeCalls() {
            calls = fresh
            recompute()
        }
    }

    /// Recompute the banner; called when the local call set changes too.
    func recompute() {
        let candidate = CallMoveRules.elsewhereCall(
            in: calls,
            ownRegistrationId: ownRegistrationId,
            ownCallIds: ownCallIds(),
            dismissed: dismissed,
            hasLocalCall: hasLocalCall()
        )
        elsewhere = candidate
    }

    /// Another of the user's devices has a call, offered or not.
    var hasCallElsewhere: Bool {
        CallMoveRules.elsewhereCall(
            in: calls, ownRegistrationId: ownRegistrationId, ownCallIds: ownCallIds(), hasLocalCall: false
        ) != nil
    }

    func dismissBanner() {
        if let call = elsewhere { dismissed.insert(call.id) }
        elsewhere = nil
    }

    /// This phone's registration at the PBX, cached once found.
    func ownRegistration() async -> String? {
        if let ownRegistrationId { return ownRegistrationId }
        let id = deviceId()
        guard !id.isEmpty,
              let device = try? await backend.currentDevice(sipInstance: CallMoveRules.sipInstance(deviceId: id))
        else { return nil }
        ownRegistrationId = device.registrationId
        return device.registrationId
    }

    /// The `+sip.instance` this phone registers with, nil before it has a device id.
    func ownSipInstance() -> String? {
        let id = deviceId()
        return id.isEmpty ? nil : CallMoveRules.sipInstance(deviceId: id)
    }

    /// A call of the user's from the last read.
    func call(withId id: String) -> UserCall? { calls.first { $0.id == id } }

    /// A move this phone started through the PBX's own trigger (`left_network`
    /// answered `moved`): its INVITE is answered with no ring.
    func registerMove(moveId: String, callId: String) {
        let call = call(withId: callId)
        pending.register(moveId: moveId, callStartedAt: call?.startedAt ?? Date(), fromLabel: call?.deviceLabel ?? "")
    }

    func loadDevices() async {
        guard let all = try? await backend.devices() else { return }
        devices = CallMoveRules.targets(all, ownRegistrationId: await ownRegistration())
    }

    // MARK: Moving

    /// "Move here": ask the PBX to bring `call` to this phone. The PBX's
    /// INVITE follows through the push gateway and is answered on arrival.
    func moveHere(_ call: UserCall) async {
        guard !isMoving else { return }
        isMoving = true
        defer { isMoving = false }
        do {
            guard let own = await ownRegistration() else {
                errorMessage = String(localized: "This phone is not registered with your phone system yet.")
                return
            }
            let moveId = try await backend.move(callId: call.id, to: own)
            pending.register(moveId: moveId, callStartedAt: call.startedAt, fromLabel: call.deviceLabel)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// "Move to…": send the call this phone is on to `device`.
    func moveOwnCall(to device: UserDevice) async -> Bool {
        guard !isMoving else { return false }
        isMoving = true
        defer { isMoving = false }
        do {
            let fresh = try await backend.activeCalls()
            guard let mine = CallMoveRules.ownCall(
                in: fresh, ownRegistrationId: await ownRegistration(), ownCallIds: ownCallIds()
            ) else {
                errorMessage = String(localized: "The phone system does not show this call yet.")
                return false
            }
            _ = try await backend.move(callId: mine.id, to: device.registrationId)
            leavingTo = (device.displayName, Date())
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    /// When the PBX ends this phone's leg right after a move away, the
    /// device it went to; consumed once.
    func takeMovedAway(now: Date = Date()) -> String? {
        defer { leavingTo = nil }
        guard let leavingTo, now.timeIntervalSince(leavingTo.since) < 60 else { return nil }
        return leavingTo.name
    }

    func showMoved(to deviceName: String) {
        notice = MovedNotice(deviceName: deviceName)
    }

    nonisolated static func describe(_ error: Error) -> String {
        if case PbxApiClient.ApiError.httpError(let code, let message) = error {
            switch code {
            case 404: return String(localized: "That call is no longer in progress.")
            case 409: return String(localized: "That call can't be moved right now.")
            case 422: return String(localized: "That device is not available.")
            default: return message.isEmpty ? String(localized: "The call could not be moved.") : message
            }
        }
        return String(localized: "The call could not be moved.")
    }

    // MARK: Events

    func handle(_ event: CallMoveEvent) {
        switch event {
        case .activeElsewhere(let call):
            calls.removeAll { $0.id == call.id }
            calls.append(call)
        case .ended(let callId):
            calls.removeAll { $0.id == callId }
            dismissed.remove(callId)
        case .moved(let callId, let from, let to):
            calls.removeAll { $0.id == callId }
            if from == ownRegistrationId, notice == nil, leavingTo == nil,
               let target = devices.first(where: { $0.registrationId == to }) {
                showMoved(to: target.displayName)
            }
            Task { await refresh() }
        }
        recompute()
    }

    private func startListening() {
        socketTask?.cancel()
        socketTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let heard = await self.listenOnce()
                failures = heard ? 0 : failures + 1
                let delay = min(60.0, 2.0 * Double(1 << min(failures, 5)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// One socket's life; true when it delivered a frame.
    private func listenOnce() async -> Bool {
        guard isActive, let request = try? await backend.eventStreamRequest() else { return false }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        var heard = false
        while !Task.isCancelled {
            do {
                let frame = try await task.receive()
                heard = true
                if case .string(let text) = frame {
                    if let event = CallMoveEvent.parse(text) { handle(event) }
                    if let proximity = ProximityEvent.parse(text) { Proximity.shared.handle(proximity) }
                }
            } catch {
                break
            }
        }
        task.cancel(with: .goingAway, reason: nil)
        return heard
    }
}

enum CallMoveLabel {
    /// How a moved call this phone did not ask for is named when it rings.
    static func unrequested(name: String, from device: String?) -> String {
        let source = device ?? String(localized: "another device")
        return String(localized: "\(name) · Moving call from \(source)")
    }
}
