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
        engine?.setAudioBridge(bridge: iOSAudioBridge())
        startRemoteHangupPolling()
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

    /// Get media stats.
    func getMediaStats(callId: String) -> MediaStats? {
        return engine?.getMediaStats(callId: callId)
    }

    /// Get RX audio level.
    func getRxAudioLevel(callId: String) -> Float {
        return engine?.getRxAudioLevel(callId: callId) ?? 0.0
    }

    /// Get TX audio level.
    func getTxAudioLevel(callId: String) -> Float {
        return engine?.getTxAudioLevel(callId: callId) ?? 0.0
    }

    // MARK: - On-device AI
    //
    // Wrapped here like everything else so `engine` stays private: callers get
    // a nil-safe surface and no way to hold the engine past its lifetime.

    /// True when this build has the models compiled in. The simulator slice is
    /// built without them, so this is false there and true on device.
    func aiAvailable() -> Bool {
        return engine?.aiAvailable() ?? false
    }

    func aiInit(storageDir: String, insightKey: [UInt8]?) throws {
        try engine?.aiInit(storageDir: storageDir, insightKey: insightKey)
    }

    func aiModels() -> [AiModel] {
        return engine?.aiModels() ?? []
    }

    func aiStartDownload(modelId: String) throws {
        try engine?.aiStartDownload(modelId: modelId)
    }

    func aiDownloadProgress(modelId: String) -> AiDownloadProgress? {
        return engine?.aiDownloadProgress(modelId: modelId)
    }

    func aiCancelDownload(modelId: String) {
        engine?.aiCancelDownload(modelId: modelId)
    }

    func aiDeleteModel(modelId: String) throws {
        try engine?.aiDeleteModel(modelId: modelId)
    }

    func aiStartCapture(callId: String) throws {
        try engine?.aiStartCapture(callId: callId)
    }

    func aiStopCapture(callId: String) {
        engine?.aiStopCapture(callId: callId)
    }

    /// Runs inference, so this blocks for seconds to minutes. Never call it on
    /// the main queue.
    func aiTranscribe(callId: String) throws -> AiCallInsight? {
        return try engine?.aiTranscribe(callId: callId)
    }

    func aiDiscardCapture(callId: String) {
        engine?.aiDiscardCapture(callId: callId)
    }

    func aiInsights(limit: UInt32, offset: UInt32) -> [AiInsightSummary] {
        return engine?.aiInsights(limit: limit, offset: offset) ?? []
    }

    func aiInsight(callId: String) -> AiCallInsight? {
        return engine?.aiInsight(callId: callId)
    }

    func aiDeleteInsight(callId: String) -> Bool {
        return engine?.aiDeleteInsight(callId: callId) ?? false
    }

    func aiClearInsights() -> UInt64 {
        return engine?.aiClearInsights() ?? 0
    }

    /// Check if remote party hung up.
    func checkRemoteHangup() -> String? {
        return engine?.checkRemoteHangup()
    }

    /// Start polling for remote hangup. Call once when engine is configured.
    func startRemoteHangupPolling() {
        remoteHangupTimer?.invalidate()
        remoteHangupTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let callId = self.checkRemoteHangup() {
                print("Remote hangup detected: \(callId)")
                DispatchQueue.main.async {
                    CallManager.shared.handleRemoteHangup()
                }
            }
        }
    }

    private var remoteHangupTimer: Timer?
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
