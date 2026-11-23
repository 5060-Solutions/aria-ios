#if DEBUG
import Foundation

extension ConnectionDetails.Source {
    /// A healthy connection for fixture mode and the connection-sheet
    /// screenshot: registered over Wi-Fi, a call on Opus with SRTP and
    /// plausible media stats.
    static let fixture = ConnectionDetails.Source(
        state: { SipEngineManager.shared.connectionState },
        account: { AccountSettings.load() },
        deviceId: { SipEngineManager.shared.deviceId },
        lastError: { nil },
        network: {
            NetworkPath(isSatisfied: true, interfaces: ["en0"], addresses: ["192.168.1.42"])
        },
        activeCallId: { CallManager.shared.activeCall?.callId ?? "fixture-call" },
        isEncrypted: { _ in true },
        mediaStats: { _ in
            // Grows with time so the live view ticks like a real call.
            let seconds = UInt64(Date().timeIntervalSince(fixtureStart))
            let base: UInt64 = 6_120 + seconds * 50
            return MediaStats(packetsSent: base, packetsReceived: base - 7,
                              bytesSent: base * 160, bytesReceived: (base - 7) * 160,
                              jitterMs: 3.4, packetLoss: 7, rttMs: 38.0)
        },
        // As the core reports them: the SRV target as host:port, and the
        // codec by its SDP name.
        gatewayNode: { "gw1.push.ariaroute.com:443" },
        codec: { _ in CodecPreferences.displayName(sdpName: "opus") }
    )

    private static let fixtureStart = Date()
}
#endif
