import Foundation
import Combine

/// Everything the connection sheet and Diagnostics show about the link to
/// the phone system, as one observable snapshot.
///
/// Apps never speak SIP: the app talks HTTPS to the push gateway, which
/// speaks SIP to the PBX. So "transport" here is the account's SIP transport
/// as the gateway uses it, and the gateway is the app's server.
@MainActor
final class ConnectionDetails: ObservableObject {
    static let shared = ConnectionDetails(source: .current)

    struct Snapshot: Equatable {
        var state: ConnectionState = .offline
        /// `1001@acme.ariaroute.com`
        var account: String = ""
        var deviceId: String?
        var gatewayUrl: String = ""
        /// The gateway instance holding the registration, as `host:port`
        /// (`current_gateway()`); it changes on failover and failback. The
        /// configured host until the device has registered.
        var gatewayNode: String = ""
        /// The account's SIP transport and port, e.g. `TLS : 5061`. The
        /// app-to-gateway hop is always HTTPS; this is the SIP side.
        var sipTransport: String = ""
        var lastError: String?
        var network: String = ""
        /// The codec negotiated for the current call, when the core reports
        /// it; nil otherwise (see `preferredCodecs`).
        var codec: String?
        var preferredCodecs: [String] = []
        /// Whether the current call's media is encrypted (SRTP), nil with no
        /// call.
        var srtp: Bool?
        var stats: MediaStats?
        var callId: String?
    }

    /// Where the snapshot comes from. Replaced in tests and fixture mode.
    struct Source {
        var state: () -> ConnectionState
        var account: () -> AccountSettings
        var deviceId: () -> String?
        var lastError: () -> String?
        var network: () -> NetworkPath?
        var activeCallId: () -> String?
        var isEncrypted: (String) -> Bool
        var mediaStats: (String) -> MediaStats?
        /// The gateway instance in use, when known; nil means the
        /// configured host.
        var gatewayNode: () -> String? = { nil }
        /// The call's negotiated codec, when known.
        var codec: (String) -> String? = { _ in nil }
    }

    @Published private(set) var snapshot = Snapshot()

    private let source: Source
    private var timer: Timer?

    init(source: Source) {
        self.source = source
    }

    func refresh() {
        let account = source.account()
        var next = Snapshot()
        next.state = source.state()
        next.account = account.isProvisioned ? "\(account.username)@\(account.domain)" : ""
        next.deviceId = source.deviceId()
        next.gatewayUrl = account.gatewayUrl
        next.gatewayNode = source.gatewayNode() ?? URLComponents(string: account.gatewayUrl)?.host ?? ""
        next.sipTransport = account.isProvisioned
            ? "\(account.effectiveTransport.uppercased()) : \(account.effectivePort)" : ""
        next.lastError = source.lastError()
        next.network = Self.describe(source.network())
        next.preferredCodecs = CodecPreferences.load().ordered.map(CodecPreferences.name)
        if let callId = source.activeCallId() {
            next.callId = callId
            next.srtp = source.isEncrypted(callId)
            next.codec = source.codec(callId)
            next.stats = source.mediaStats(callId)
        }
        if next != snapshot { snapshot = next }
    }

    /// Refresh now and every second while a screen shows the details.
    func startLiveUpdates() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopLiveUpdates() {
        timer?.invalidate()
        timer = nil
    }

    /// The connection sheet's Reconnect.
    func reconnect() {
        AppLog.shared.log("connection", "Reconnect requested")
        SipEngineManager.shared.reconnect()
        refresh()
    }

    /// The whole picture as text, for "Copy log": details first, then the
    /// event log.
    func reportText(log: AppLog = .shared) -> String {
        let s = snapshot
        var lines = [
            "Aria \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))",
            "State: \(s.state.label)\(s.lastError.map { " — \($0)" } ?? "")",
            "Account: \(s.account)",
            "Device: \(s.deviceId ?? "-")",
            "Gateway: \(s.gatewayUrl) (node \(s.gatewayNode))",
            "SIP transport: \(s.sipTransport)",
            "Network: \(s.network)",
            "Codecs: \(s.codec ?? "not reported") (preferred \(s.preferredCodecs.joined(separator: ", ")))",
        ]
        if let callId = s.callId {
            lines.append("Call: \(callId) SRTP \(s.srtp == true ? "on" : "off")")
            if let st = s.stats {
                lines.append(String(format: "Media: sent %llu / received %llu packets, loss %u, jitter %.1f ms, RTT %.1f ms",
                                    st.packetsSent, st.packetsReceived, st.packetLoss, st.jitterMs, st.rttMs))
            }
        }
        lines.append("")
        lines.append(log.text())
        return lines.joined(separator: "\n")
    }

    static func describe(_ path: NetworkPath?) -> String {
        guard let path = path else { return String(localized: "Unknown") }
        guard path.isSatisfied else { return String(localized: "No connection") }
        let kinds = path.interfaces.map { name -> String in
            if name.hasPrefix("en") { return "Wi-Fi" }
            if name.hasPrefix("pdp_ip") { return String(localized: "Cellular") }
            return name
        }
        var seen = Set<String>()
        return kinds.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}

extension ConnectionDetails.Source {
    /// Fixtures in fixture mode, else the live engine.
    static var current: ConnectionDetails.Source {
        #if DEBUG
        if FixtureMode.isActive { return .fixture }
        #endif
        return .live
    }

    static let live = ConnectionDetails.Source(
        state: { SipEngineManager.shared.connectionState },
        account: { AccountSettings.load() },
        deviceId: { SipEngineManager.shared.deviceId },
        lastError: { SipEngineManager.shared.registrationError },
        network: { SipEngineManager.shared.currentNetworkPath },
        activeCallId: { CallManager.shared.activeCall?.callId },
        isEncrypted: { SipEngineManager.shared.callIsEncrypted(callId: $0) },
        mediaStats: { SipEngineManager.shared.getMediaStats(callId: $0) },
        gatewayNode: { SipEngineManager.shared.currentGateway() },
        codec: { callId in
            CallManager.shared.registry.call(engineCallId: callId)?.codec
                .map(CodecPreferences.displayName(sdpName:))
        }
    )
}
