import Foundation
import UIKit

// Hold for me: the PBX waits on hold on the user's behalf and rings them
// when a person answers. Wire shapes are the shared contract's C2 and C3.
// Every Hold for me surface is hidden unless `GET /api/v1/me` lists
// "hold_for_me" in `features` (C1).

// MARK: - Wire types

/// What the far party hears when they pick up before the user is back.
enum HoldGreeting: String, CaseIterable, Codable {
    case silence, line, assistant

    /// Lenient: a greeting this app does not know yet (from a newer PBX)
    /// reads as the short message, so one unknown value never fails a whole
    /// list of waits.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HoldGreeting(rawValue: raw) ?? .line
    }
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

    /// Whether the card and the Live Activity show this wait: not once the
    /// user has joined, nor once it has ended (`HoldWaitPresentation`).
    var isShown: Bool { HoldWaitPresentation.shownState(state) != nil }

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

/// The alert push for a wait that ended (C5): `data.type == "hold_wait"`.
enum HoldWaitNotification {
    /// Nil unless this is a `hold_wait` payload with a number to call.
    static func parse(userInfo: [AnyHashable: Any]) -> (event: String, remoteNumber: String, remoteName: String)? {
        guard userInfo["type"] as? String == "hold_wait",
              let number = userInfo["remote_number"] as? String, !number.isEmpty else { return nil }
        return (userInfo["event"] as? String ?? "", number, userInfo["remote_name"] as? String ?? "")
    }
}

/// What the banner shows after a tapped `hold_wait` notification.
struct HoldWaitNotice: Equatable {
    let event: String
    let remoteNumber: String
    /// May be empty.
    let remoteName: String

    /// What to call them: the name, else the number.
    var displayName: String { remoteName.isEmpty ? remoteNumber : remoteName }

    /// The banner's line. "picked up while you were away" is only true of a
    /// `missed` wait; the other events show who it was.
    var title: String {
        event == "missed" ? String(localized: "\(displayName) picked up while you were away") : displayName
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
    static let shared = HoldForMeModel(
        backend: LiveHoldForMeBackend(),
        activities: HoldActivityController(facade: LiveActivityFacade())
    )

    /// The PBX offers Hold for me to this credential (C1).
    @Published private(set) var available = false {
        didSet { if available != oldValue { syncActivities() } }
    }
    /// Open and just-ended waits, by `hold_wait_id`.
    @Published private(set) var waits: [String: HoldWait] = [:] {
        didSet { syncActivities() }
    }
    @Published private(set) var transcripts: [String: [TranscriptLine]] = [:]
    /// The latest refusal, to show as a banner and then clear.
    @Published var banner: HoldRefusal?
    @Published private(set) var settings: HoldSettings?
    /// Why the last greeting save failed; cleared by the next save.
    @Published var settingsError: String?
    /// A tapped `hold_wait` notification: shown whether or not the flag has
    /// been read yet.
    @Published private(set) var notice: HoldWaitNotice?
    /// The wait the user asked to cancel (the card's Cancel, or the Live
    /// Activity's link); the card asks Rejoin now or Hang up.
    @Published var cancelRequest: String?

    var backend: HoldForMeBackend
    /// The Live Activities; nil in tests that do not look at them.
    var activities: HoldActivityController?
    /// `GET /me`, to know whether Hold for me is offered.
    var fetchIdentity: () async throws -> PbxApiClient.Identity = HoldForMeModel.liveIdentity
    /// The PBX's id for this phone's own call; nil when it is not listed.
    var resolveCallId: (ActiveCall) async -> String? = HoldForMeModel.resolveLive
    var isInConference: () -> Bool = { CallManager.shared.isInConference }
    /// Starts the call-move socket when it is not running (it carries
    /// `hold_wait_state`).
    var startSocket: () -> Void = { CallMoveModel.shared.ensureListening() }
    /// Places a call through the app's one dial path.
    var dial: (String) -> Void = { CallManager.shared.startOutgoingCall(uri: $0) }
    private var isStarting = false
    private var stillOnHoldInFlight: Set<String> = []

    init(backend: HoldForMeBackend, activities: HoldActivityController? = nil) {
        self.backend = backend
        self.activities = activities
    }

    /// The waits the card and the activities show, oldest first: open and
    /// not joined (`HoldWaitPresentation`). `waits` keeps a joined wait, for
    /// Still on hold. Nothing at all while the feature is off.
    var openWaits: [HoldWait] {
        guard available else { return [] }
        return waits.values.filter(\.isShown).sorted { ($0.startedAt, $0.holdWaitId) < ($1.startedAt, $1.holdWaitId) }
    }

    /// Whether the PBX's answer (open waits, or "not offered") has been seen
    /// since launch. Until then an activity this model does not know of may
    /// belong to a wait that is still live, so none is ended.
    private var hasReconciled = false

    private func syncActivities() {
        activities?.sync(openWaits, endUnknown: hasReconciled)
    }

    /// Everything the account had; for sign-out.
    func reset() {
        hasReconciled = true
        available = false
        waits = [:]
        transcripts = [:]
        banner = nil
        settings = nil
        settingsError = nil
        notice = nil
        cancelRequest = nil
        isStarting = false
        stillOnHoldInFlight = []
    }

    // MARK: Availability

    /// Called wherever the app reads `GET /me`. An absent `features` is off.
    func refreshAvailability(identity: PbxApiClient.Identity) {
        setAvailable(identity.holdForMe)
    }

    func setAvailable(_ on: Bool) {
        if available != on { available = on }
    }

    /// The app came to the foreground: re-read `/me`, then take the PBX's
    /// open waits (the socket runs only in the foreground, so a wait may have
    /// ended meanwhile). A failed `/me` leaves the last known answer.
    func becameActive() async {
        var heardFromPbx = false
        if let identity = try? await fetchIdentity() {
            refreshAvailability(identity: identity)
            heardFromPbx = true
        }
        if available {
            await reconcile()
        } else if heardFromPbx {
            // Not offered: no activity may stay.
            hasReconciled = true
            syncActivities()
        }
    }

    static func liveIdentity() async throws -> PbxApiClient.Identity {
        let settings = AccountSettings.load()
        guard !settings.apiUrl.isEmpty, KeychainStore.get(KeychainStore.jwtKey) != nil else {
            throw PbxSessionError.notSignedIn
        }
        let client = PbxApiClient(baseUrl: settings.apiUrl)
        return try await PbxSession.shared.authorized { try await client.identity(jwt: $0) }
    }

    /// Hold for me for `call`: the flag, an outgoing call that has been
    /// answered, and no local conference. Whether the PBX lists the call is
    /// found out when it starts.
    ///
    /// A rejoined call (the far party came back) rings in here, but on the
    /// PBX it is still the original outgoing call, so it qualifies too; the
    /// PBX's 409 `not_outgoing` stays the last word.
    func canHoldForMe(_ call: ActiveCall) -> Bool {
        available && (call.direction == .outbound || call.holdReturnId != nil)
            && call.isConnected && !isInConference()
    }

    // MARK: Settings

    func loadSettings() async {
        if let loaded = try? await backend.settings() { settings = loaded }
    }

    func applySettings(_ new: HoldSettings) { settings = new }

    /// Save the default greeting. The change shows at once and is put back
    /// when the PBX refuses it, like `Proximity.update`. The assistant is
    /// not sent when the account has none.
    func setGreeting(_ greeting: HoldGreeting) async {
        guard let previous = settings else { return }
        guard greeting != .assistant || previous.assistantAvailable else { return }
        settingsError = nil
        settings = HoldSettings(
            greeting: greeting, assistantAvailable: previous.assistantAvailable, maxWaitSecs: previous.maxWaitSecs)
        do {
            settings = try await backend.setGreeting(greeting)
        } catch {
            settings = previous
            settingsError = String(localized: "Couldn't save. Try again.")
        }
    }

    // MARK: Notifications

    func showNotice(_ hold: HoldWaitNotice) { notice = hold }
    func dismissNotice() { notice = nil }

    /// Redial a wait's far party: the one path for the CALL_AGAIN action and
    /// the banner's button. Emergency numbers are handled by the dialer.
    func callAgain(_ number: String) {
        dial(number)
        notice = nil
    }

    // MARK: Actions

    /// The name the PBX shows for the business: the call's displayed name,
    /// at most 64 characters; nil when there is none.
    static func displayName(_ call: ActiveCall) -> String? {
        guard let name = call.remoteName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(64))
    }

    /// Start a wait. `greeting` is the user's explicit pick; nil leaves it out
    /// of the request, and the PBX uses the saved default.
    func start(call: ActiveCall, greeting: HoldGreeting?) async {
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

    /// Ask to cancel `id`: the card opens its Rejoin now / Hang up choice.
    /// A wait this phone has not heard of yet (the app was just opened from
    /// the Live Activity) is looked up first.
    func requestCancel(_ id: String) async {
        if !available || waits[id] == nil { await becameActive() }
        guard available, waits[id]?.isShown == true else { return }
        cancelRequest = id
    }

    /// Cancel a wait: ring the user to rejoin, or hang up on the far party.
    func cancel(_ id: String, rejoin: Bool) async {
        guard let wait = waits[id] else { return }
        cancelRequest = nil
        if let updated = try? await backend.cancel(callId: wait.callId, action: rejoin ? "rejoin" : "hang_up") {
            waits[id] = updated
        }
    }

    /// How long Still on hold waits for each of the PBX's answers (the open
    /// waits, then the request itself) before the ring is ended anyway.
    var stillOnHoldBound: TimeInterval = 3

    /// "Still on hold", on the ring or after joining: the person is not
    /// there yet. False when a tap is ignored because one is still in
    /// flight. A wait this phone has not heard of yet (the push came before
    /// the socket) is looked up first, for at most `stillOnHoldBound`; one
    /// still unknown, a refusal (409) or a network failure are quiet: the
    /// caller ends the ring regardless.
    @discardableResult
    func stillOnHold(_ id: String) async -> Bool {
        guard !stillOnHoldInFlight.contains(id) else { return false }
        stillOnHoldInFlight.insert(id)
        defer { stillOnHoldInFlight.remove(id) }
        if waits[id] == nil {
            await Self.bounded(stillOnHoldBound) { await self.reconcile() }
        }
        guard let wait = waits[id] else { return true }
        await Self.bounded(stillOnHoldBound) {
            if let updated = try? await self.backend.stillOnHold(callId: wait.callId) {
                self.waits[id] = updated
            }
        }
        return true
    }

    /// Run `operation`, waiting for it at most `seconds`. One that takes
    /// longer finishes on its own afterwards.
    static func bounded(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in
                await operation()
                once.resume()
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume()
            }
        }
    }

    /// A hold-return ring ended here without being answered (declined,
    /// missed, or the PBX stopped ringing): bring the card and the Live
    /// Activity up to date, with time granted in the background.
    nonisolated static func reconcileAfterUnansweredRing() {
        Task { @MainActor in
            let task = BackgroundTask(name: "HoldForMe.reconcile")
            await shared.becameActive()
            task.end()
        }
    }

    /// The far party is back (a hold-return push): make sure the socket and
    /// the open waits are coming, so the transcript and ring reason arrive.
    func ensureListening() async {
        startSocket()
        await becameActive()
    }

    /// Replace what is known with the PBX's open waits (the socket runs only
    /// in the foreground); a wait it no longer lists is dropped.
    func reconcile() async {
        guard let open = try? await backend.openWaits() else { return }
        hasReconciled = true
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

    /// The PBX's call for `call`, from its active calls fetched now.
    static func resolveLive(_ call: ActiveCall) async -> String? {
        guard let calls = try? await LiveCallMoveBackend().activeCalls() else { return nil }
        return pbxCall(
            for: call, in: calls, ownRegistrationId: await CallMoveModel.shared.ownRegistration()
        )?.id
    }

    /// The PBX call that is `call`: among this registration's calls (all of
    /// the user's when the registration is not known), the one whose far
    /// party is `call`'s. With two calls here (call waiting) the other one
    /// must never be put on hold, so no match, or more than one, is nil.
    static func pbxCall(for call: ActiveCall, in calls: [UserCall], ownRegistrationId: String?) -> UserCall? {
        let mine = ownRegistrationId.map { own in calls.filter { $0.device.registrationId == own } } ?? calls
        let matches = mine.filter { candidate in
            guard let number = candidate.remote.number, !number.isEmpty else { return false }
            return CallRecord.sameParty(number, call.remoteUri)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Resumes a continuation once, whichever side of a race gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// Background time from `UIApplication`, ended once: when the work is done,
/// or when the system says time is up.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
