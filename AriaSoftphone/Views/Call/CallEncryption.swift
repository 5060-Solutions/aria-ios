import Foundation

/// Whether a call's media is encrypted, as the call screen, its one-time
/// notice and the connection sheet show it.
///
/// Aria calls are secure by default. A call whose media is not encrypted is
/// acceptable only when the user is told, so `.unencrypted` always shows: an
/// amber open lock on the call screen for the whole call, a notice once per
/// call, and "None (unencrypted)" in the connection sheet.
enum CallEncryption: Equatable {
    /// Not connected yet, or the core has not said: nothing is shown.
    case unknown
    case encrypted
    case unencrypted

    /// `isEncrypted` is the core's answer for the call, nil when it has none.
    /// Before a call connects nothing has been negotiated, so it is unknown
    /// whatever the core says.
    init(isConnected: Bool, isEncrypted: Bool?) {
        guard isConnected, let isEncrypted else {
            self = .unknown
            return
        }
        self = isEncrypted ? .encrypted : .unencrypted
    }

    /// The call's encryption as its last event left it.
    init(_ call: ActiveCall) {
        self.init(isConnected: call.isConnected, isEncrypted: call.isEncrypted)
    }

    /// What a call-state event says about encryption, for
    /// `ActiveCall.isEncrypted`: `CallInfo.encrypted` once the call is
    /// connected (the core sets it on `Connected`, carries it on every later
    /// event, and re-sends the call with the same state when it changes, as
    /// when a media re-offer after a network change drops the crypto). Nil
    /// for other states: before `Connected` the core says false because
    /// nothing has been negotiated, which is not "unencrypted".
    static func reported(state: CallState, encrypted: Bool) -> Bool? {
        switch state {
        case .connected, .onHold: return encrypted
        default: return nil
        }
    }

    /// "This call isn't encrypted…": the notice, the capsule's explanation
    /// and the spoken announcement.
    static var unencryptedExplanation: String {
        String(localized: "This call isn't encrypted. The phone system didn't accept a secure connection.")
    }
}

/// Which calls have had the "not encrypted" notice, so each call gets it
/// once: when it connects unencrypted, or the first time it drops to
/// unencrypted later. Kept outside the call screen so closing and reopening
/// the screen does not repeat it.
@MainActor
final class CallEncryptionNotices {
    static let shared = CallEncryptionNotices()

    private var notified: Set<UUID> = []

    /// Whether to show the notice for `call` now that it is `encryption`.
    /// True at most once per call.
    func shouldNotify(call: UUID, encryption: CallEncryption) -> Bool {
        guard encryption == .unencrypted else { return false }
        return notified.insert(call).inserted
    }

    /// Forget calls that have ended.
    func retain(only live: Set<UUID>) {
        notified.formIntersection(live)
    }
}
