import Foundation
import Combine

/// Manages the connection to aria-mobile-core Rust library.
/// Bridges UniFFI callbacks to SwiftUI-observable state.
class SipEngineManager: ObservableObject {
    static let shared = SipEngineManager()

    @Published var isRegistered = false
    @Published var registrationError: String?
    @Published var deviceId: String?

    private var engine: AriaMobileEngine?
    private let eventHandler = SwiftEventHandler()

    private init() {
        eventHandler.manager = self
    }

    /// Configure and connect to the push gateway.
    func configure(gatewayUrl: String, apiKey: String) {
        let config = GatewayConfig(
            baseUrl: gatewayUrl,
            apiKey: apiKey
        )
        engine = AriaMobileEngine(gatewayConfig: config)
        engine?.setEventHandler(handler: eventHandler)
    }

    /// Register this device with the push gateway.
    func registerDevice(
        platform: String = "ios",
        pushToken: String,
        bundleId: String?,
        sip: SipCredentials
    ) throws {
        guard let engine = engine else {
            throw SipError.notConfigured
        }

        let registration = DeviceRegistration(
            platform: platform,
            pushToken: pushToken,
            bundleId: bundleId,
            sip: sip
        )

        let response = try engine.registerDevice(registration: registration)
        DispatchQueue.main.async {
            self.deviceId = response.deviceId
            self.isRegistered = true
        }
    }

    /// Unregister from the push gateway.
    func unregister() throws {
        guard let engine = engine, let deviceId = deviceId else { return }
        try engine.unregisterDevice(deviceId: deviceId)
        DispatchQueue.main.async {
            self.isRegistered = false
            self.deviceId = nil
        }
    }

    /// Handle an incoming push notification.
    func handlePushNotification(payload: PushCallPayload) throws -> CallOffer {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        return try engine.handlePushNotification(payload: payload)
    }

    /// Accept an incoming call.
    func acceptCall(callToken: String, codecs: [AudioCodec] = []) throws -> CallInfo {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        return try engine.acceptIncomingCall(
            callToken: callToken,
            preferredCodecs: codecs
        )
    }

    /// Reject an incoming call.
    func rejectCall(callToken: String) throws {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        try engine.rejectIncomingCall(callToken: callToken)
    }

    /// Make an outgoing call.
    func makeCall(uri: String, credentials: SipCredentials, codecs: [AudioCodec] = []) throws -> CallInfo {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        return try engine.makeCall(
            uri: uri,
            credentials: credentials,
            preferredCodecs: codecs
        )
    }

    /// Hang up an active call.
    func hangup(callId: String) throws {
        guard let engine = engine else { return }
        try engine.hangup(callId: callId)
    }

    /// Mute/unmute.
    func setMute(callId: String, muted: Bool) throws {
        guard let engine = engine else { return }
        try engine.setMute(callId: callId, muted: muted)
    }

    /// Hold/unhold.
    func setHold(callId: String, onHold: Bool) throws {
        guard let engine = engine else { return }
        try engine.setHold(callId: callId, onHold: onHold)
    }

    /// Send DTMF digit.
    func sendDtmf(callId: String, digit: String) throws {
        guard let engine = engine else { return }
        try engine.sendDtmf(callId: callId, digit: digit)
    }

    /// Get active call info.
    func getActiveCall() -> CallInfo? {
        return engine?.getActiveCall()
    }
}

// MARK: - UniFFI Event Handler Bridge

class SwiftEventHandler: MobileEventHandler {
    weak var manager: SipEngineManager?

    func onRegistrationChanged(deviceId: String, status: String, error: String?) {
        DispatchQueue.main.async {
            self.manager?.isRegistered = (status == "registered")
            self.manager?.registrationError = error
            self.manager?.deviceId = deviceId
        }
    }

    func onIncomingCall(offer: CallOffer) {
        DispatchQueue.main.async {
            CallManager.shared.handleIncomingCall(offer: offer)
        }
    }

    func onCallStateChanged(info: CallInfo) {
        DispatchQueue.main.async {
            CallManager.shared.updateCallState(info: info)
        }
    }

    func onMediaStats(callId: String, stats: MediaStats) {
        // Update stats UI if needed
    }

    func onError(context: String, message: String) {
        print("Aria error [\(context)]: \(message)")
        DispatchQueue.main.async {
            self.manager?.registrationError = "\(context): \(message)"
        }
    }
}

// MARK: - Error Types

enum SipError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "SIP engine not configured. Set up gateway connection first."
        }
    }
}
