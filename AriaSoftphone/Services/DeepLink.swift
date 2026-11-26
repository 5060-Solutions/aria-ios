import Foundation
import Intents

/// Something the app was asked to do from outside: a URL it was opened with
/// or a call-back from the system's Recents.
enum DeepLink: Equatable {
    /// `aria://provision?v=1&url=...`: preview, confirm, then redeem.
    case setupLink(String)
    /// A legacy QR link (`aria://provision?server=...`), already parsed.
    case legacyProvisioning(ProvisioningCredentials)
    /// A number or SIP address to call, after the user confirms.
    case dial(String)
    /// `aria://hold-for-me/<id>?action=cancel`: the Live Activity's Cancel.
    case holdCancel(String)
    /// `aria://hold-for-me/<id>`: a tap on the Live Activity; it only opens
    /// the app.
    case holdOpen(String)

    /// The deep link a URL stands for, or nil for anything the app does not
    /// handle.
    ///
    /// - `aria://provision?...` (setup links, versioned or legacy)
    /// - `aria://call?to=<number>` / `aria://dial?to=<number>`
    /// - `sip:` / `sips:` URIs
    /// - `tel:` URLs handed over by another app
    static func parse(_ url: URL) -> DeepLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "aria":
            let host = url.host?.lowercased()
            if host == "provision" {
                if SetupLinkService.isVersionedLink(url.absoluteString) {
                    return .setupLink(url.absoluteString)
                }
                return parseProvisioningURI(url.absoluteString).map(DeepLink.legacyProvisioning)
            }
            if host == "call" || host == "dial" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let target = items.first { $0.name == "to" || $0.name == "number" }?.value
                return dialTarget(target)
            }
            if host == "hold-for-me" {
                let id = url.path.split(separator: "/").first.map(String.init) ?? ""
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard !id.isEmpty else { return nil }
                guard let action = items.first(where: { $0.name == "action" }) else { return .holdOpen(id) }
                return action.value == "cancel" ? .holdCancel(id) : nil
            }
            return nil
        case "sip", "sips", "tel":
            // `sip:1001@pbx.example.com` → dial "1001@pbx.example.com"; the
            // gateway resolves a bare user against the account's domain.
            let raw = url.absoluteString
            let rest = String(raw.dropFirst(scheme.count + 1)).removingPercentEncoding ?? ""
            let withoutParams = rest.split(separator: ";", maxSplits: 1).first.map(String.init) ?? rest
            let withoutQuery = withoutParams.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutParams
            return dialTarget(withoutQuery.hasPrefix("//") ? String(withoutQuery.dropFirst(2)) : withoutQuery)
        default:
            return nil
        }
    }

    /// The number a CallKit Recents / Siri call-back asks for.
    static func parse(_ activity: NSUserActivity) -> DeepLink? {
        guard let intent = activity.interaction?.intent as? INStartCallIntent else { return nil }
        return parse(intent)
    }

    static func parse(_ intent: INStartCallIntent) -> DeepLink? {
        dialTarget(intent.contacts?.first?.personHandle?.value)
    }

    private static func dialTarget(_ value: String?) -> DeepLink? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              TransferError.isAcceptableTarget(value) else { return nil }
        return .dial(value)
    }
}

extension ProvisioningCredentials: Equatable {
    static func == (lhs: ProvisioningCredentials, rhs: ProvisioningCredentials) -> Bool {
        lhs.server == rhs.server && lhs.port == rhs.port && lhs.username == rhs.username
            && lhs.password == rhs.password && lhs.displayName == rhs.displayName
            && lhs.transport == rhs.transport && lhs.voicemail == rhs.voicemail
            && lhs.apiUrl == rhs.apiUrl && lhs.tenantDomain == rhs.tenantDomain
    }
}

/// Holds the deep link waiting for the user, for the views that confirm it.
@MainActor
final class DeepLinkCoordinator: ObservableObject {
    static let shared = DeepLinkCoordinator()

    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let link: DeepLink
    }

    @Published var pending: Pending?

    /// Whether an account is set up; dialing needs one.
    var isSignedIn: () -> Bool = { AccountSettings.load().isProvisioned }

    func handle(_ url: URL) {
        guard let link = DeepLink.parse(url) else { return }
        accept(link)
    }

    func handle(_ activity: NSUserActivity) {
        guard let link = DeepLink.parse(activity) else { return }
        // A Recents / Siri call-back is the user's own tap on a call entry:
        // place it straight away, as the Phone app does. Emergency numbers
        // are diverted inside startOutgoingCall.
        if case .dial(let number) = link, isSignedIn() {
            CallManager.shared.startOutgoingCall(uri: number)
            return
        }
        accept(link)
    }

    private func accept(_ link: DeepLink) {
        // Cancelling a Hold for me wait needs no confirmation sheet of its
        // own: the waiting card asks Rejoin now or Hang up.
        if case .holdCancel(let id) = link {
            Task { await HoldForMeModel.shared.requestCancel(id) }
            return
        }
        // Opening the app was all a tap on the activity asked for; the
        // foreground reconcile brings the card up to date.
        if case .holdOpen = link { return }
        // A dial link is only useful with an account; an emergency number
        // still goes to the native dialer without one.
        if case .dial(let number) = link, !isSignedIn() {
            EmergencyDialer.handOff(number)
            return
        }
        pending = Pending(link: link)
    }

    func dismiss() {
        pending = nil
    }
}
