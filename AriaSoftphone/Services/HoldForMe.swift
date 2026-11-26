import Foundation

// Hold for me: the PBX waits on hold on the user's behalf and rings them
// when a person answers. Wire shapes are the shared contract's C2 and C3.
// Every Hold for me surface is hidden unless `GET /api/v1/me` lists
// "hold_for_me" in `features` (C1).

// MARK: - Wire types

/// What the far party hears when they pick up before the user is back.
enum HoldGreeting: String, CaseIterable, Codable {
    case silence, line, assistant
}

/// A Hold for me wait (C2 `HoldWait`).
struct HoldWait: Decodable, Equatable {
    let holdWaitId: String
    let callId: String
    /// `requested`, `waiting`, `human_detected`, `ringing`, `joined` or `ended`.
    let state: String
    let greeting: HoldGreeting
    let startedAt: Date
    let stateSince: Date
    let maxWaitSecs: Int
    let falseAlarms: Int
    let remote: UserCall.Remote
    /// `human`, `rejoin` or `max_wait`, while ringing or joined.
    let ringReason: String?
    /// Why it ended, once `state` is `ended`.
    let endedReason: String?

    var isOpen: Bool { state != "ended" }

    enum CodingKeys: String, CodingKey {
        case holdWaitId = "hold_wait_id"
        case callId = "call_id"
        case state, greeting
        case startedAt = "started_at"
        case stateSince = "state_since"
        case maxWaitSecs = "max_wait_secs"
        case falseAlarms = "false_alarms"
        case remote
        case ringReason = "ring_reason"
        case endedReason = "ended_reason"
    }
}

struct TranscriptLine: Decodable, Equatable {
    /// `assistant` or `caller`.
    let speaker: String
    let text: String
}

/// `GET /me/hold-for-me/settings`.
struct HoldSettings: Decodable, Equatable {
    let greeting: HoldGreeting
    let assistantAvailable: Bool
    let maxWaitSecs: Int

    enum CodingKeys: String, CodingKey {
        case greeting
        case assistantAvailable = "assistant_available"
        case maxWaitSecs = "max_wait_secs"
    }
}

/// A `hold_wait_state` socket event (C3). The transcript is always the whole
/// transcript so far: the latest event replaces any earlier one.
enum HoldWaitEvent: Equatable {
    case state(HoldWait, transcript: [TranscriptLine])

    private struct Envelope: Decodable {
        let type: String
        let holdWait: HoldWait?
        let transcript: [TranscriptLine]?

        enum CodingKeys: String, CodingKey {
            case type
            case holdWait = "hold_wait"
            case transcript
        }
    }

    static func parse(_ text: String) -> HoldWaitEvent? {
        guard let envelope = try? PbxApiClient.jsonDecoder.decode(Envelope.self, from: Data(text.utf8)),
              envelope.type == "hold_wait_state", let wait = envelope.holdWait else { return nil }
        return .state(wait, transcript: envelope.transcript ?? [])
    }
}

/// A non-2xx answer from a Hold for me route, with the 409's `reason`.
struct HoldRequestError: Error, Equatable {
    let status: Int
    let reason: String?
}

/// Why the PBX would not start a wait, and the copy for it. The call is never
/// touched by a refusal.
enum HoldRefusal: Equatable {
    case emergency, busy, already, other

    init(status: Int, reason: String?) {
        guard status == 409 else { self = .other; return }
        switch reason {
        case "emergency": self = .emergency
        case "conference", "transfer": self = .busy
        case "already_holding": self = .already
        default: self = .other
        }
    }

    init(error: Error) {
        if let error = error as? HoldRequestError {
            self.init(status: error.status, reason: error.reason)
        } else {
            self = .other
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .emergency: return "Not available on emergency calls."
        case .busy: return "Not available while a transfer or merge is in progress."
        case .already: return "Already holding this call."
        case .other: return "Couldn't start Hold for me."
        }
    }
}

// MARK: - Backend

protocol HoldForMeBackend {
    func start(callId: String, greeting: HoldGreeting?, displayName: String?) async throws -> HoldWait
    /// `action` is `rejoin` or `hang_up`.
    func cancel(callId: String, action: String) async throws -> HoldWait
    func stillOnHold(callId: String) async throws -> HoldWait
    func openWaits() async throws -> [HoldWait]
    func settings() async throws -> HoldSettings
    func setGreeting(_ greeting: HoldGreeting) async throws -> HoldSettings
}

struct LiveHoldForMeBackend: HoldForMeBackend {
    private func withClient<T>(_ operation: @escaping (PbxApiClient, String) async throws -> T) async throws -> T {
        let apiUrl = AccountSettings.load().apiUrl
        guard !apiUrl.isEmpty else { throw PbxSessionError.notSignedIn }
        let client = PbxApiClient(baseUrl: apiUrl)
        return try await PbxSession.shared.authorized { try await operation(client, $0) }
    }

    func start(callId: String, greeting: HoldGreeting?, displayName: String?) async throws -> HoldWait {
        try await withClient {
            try await $0.startHoldForMe(jwt: $1, callId: callId, greeting: greeting, displayName: displayName)
        }
    }

    func cancel(callId: String, action: String) async throws -> HoldWait {
        try await withClient { try await $0.cancelHoldForMe(jwt: $1, callId: callId, action: action) }
    }

    func stillOnHold(callId: String) async throws -> HoldWait {
        try await withClient { try await $0.stillOnHold(jwt: $1, callId: callId) }
    }

    func openWaits() async throws -> [HoldWait] {
        try await withClient { try await $0.holdWaits(jwt: $1) }
    }

    func settings() async throws -> HoldSettings {
        try await withClient { try await $0.holdForMeSettings(jwt: $1) }
    }

    func setGreeting(_ greeting: HoldGreeting) async throws -> HoldSettings {
        try await withClient { try await $0.setHoldForMeGreeting(jwt: $1, greeting) }
    }
}

// MARK: - Model

@MainActor
final class HoldForMeModel: ObservableObject {
    static let shared = HoldForMeModel(backend: LiveHoldForMeBackend())

    /// The PBX offers Hold for me to this credential (C1).
    @Published private(set) var available = false
    /// Open and just-ended waits, by `hold_wait_id`.
    @Published private(set) var waits: [String: HoldWait] = [:]
    @Published private(set) var transcripts: [String: [TranscriptLine]] = [:]
    /// The latest refusal, to show as a banner and then clear.
    @Published var banner: HoldRefusal?
    @Published private(set) var settings: HoldSettings?

    var backend: HoldForMeBackend
    /// The PBX's id for this phone's own call; nil when it is not listed.
    var resolveCallId: (ActiveCall) async -> String? = HoldForMeModel.resolveLive
    var isInConference: () -> Bool = { CallManager.shared.isInConference }
    private var isStarting = false

    init(backend: HoldForMeBackend) {
        self.backend = backend
    }

    /// Everything the account had; for sign-out.
    func reset() {
        available = false
        waits = [:]
        transcripts = [:]
        banner = nil
        settings = nil
        isStarting = false
    }

    // MARK: Availability

    /// Called wherever the app reads `GET /me`. An absent `features` is off.
    func refreshAvailability(identity: PbxApiClient.Identity) {
        setAvailable(identity.holdForMe)
    }

    func setAvailable(_ on: Bool) {
        if available != on { available = on }
    }

    /// Hold for me for `call`: the flag, an outgoing call that has been
    /// answered, and no local conference. Whether the PBX lists the call is
    /// found out when it starts.
    func canHoldForMe(_ call: ActiveCall) -> Bool {
        available && call.direction == .outbound && call.isConnected && !isInConference()
    }

    // MARK: Settings

    func loadSettings() async {
        if let loaded = try? await backend.settings() { settings = loaded }
    }

    // MARK: Actions

    /// The name the PBX shows for the business: the call's displayed name,
    /// at most 64 characters; nil when there is none.
    static func displayName(_ call: ActiveCall) -> String? {
        guard let name = call.remoteName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(64))
    }

    func start(call: ActiveCall, greeting: HoldGreeting) async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            guard let pbxId = await resolveCallId(call) else { throw HoldRequestError(status: 0, reason: nil) }
            let wait = try await backend.start(callId: pbxId, greeting: greeting, displayName: Self.displayName(call))
            waits[wait.holdWaitId] = wait
        } catch {
            banner = HoldRefusal(error: error)
        }
    }

    /// Cancel a wait: ring the user to rejoin, or hang up on the far party.
    func cancel(_ id: String, rejoin: Bool) async {
        guard let wait = waits[id] else { return }
        if let updated = try? await backend.cancel(callId: wait.callId, action: rejoin ? "rejoin" : "hang_up") {
            waits[id] = updated
        }
    }

    /// "Still on hold" after joining: the person is not there yet.
    func stillOnHold(_ id: String) async {
        guard let wait = waits[id] else { return }
        if let updated = try? await backend.stillOnHold(callId: wait.callId) {
            waits[id] = updated
        }
    }

    /// Replace what is known with the PBX's open waits (the socket runs only
    /// in the foreground); a wait it no longer lists is dropped.
    func reconcile() async {
        guard let open = try? await backend.openWaits() else { return }
        let fresh = Dictionary(open.map { ($0.holdWaitId, $0) }, uniquingKeysWith: { _, latest in latest })
        waits = fresh
        transcripts = transcripts.filter { fresh[$0.key] != nil }
    }

    func handle(_ event: HoldWaitEvent) {
        switch event {
        case .state(let wait, let transcript):
            waits[wait.holdWaitId] = wait
            transcripts[wait.holdWaitId] = transcript
        }
    }

    // MARK: Resolving the PBX call

    /// The PBX's call this phone holds the leg of, as moving a call finds it.
    static func resolveLive(_ call: ActiveCall) async -> String? {
        guard let calls = try? await LiveCallMoveBackend().activeCalls() else { return nil }
        let moves = CallMoveModel.shared
        return CallMoveRules.ownCall(
            in: calls, ownRegistrationId: await moves.ownRegistration(), ownCallIds: moves.ownCallIds()
        )?.id
    }
}
