import Foundation
import Combine

/// Manages the connection to aria-mobile-core Rust library.
/// Bridges UniFFI callbacks to SwiftUI-observable state.
class SipEngineManager: ObservableObject {
    static let shared = SipEngineManager()

    @Published var isRegistered = false
    @Published var registrationError: String?
    @Published var deviceId: String?

    /// Guarded by `stateLock`: the engine is rebuilt on the setup queue and
    /// read from the main queue, call-action queues and push handling alike.
    private var _engine: AriaMobileEngine?
    /// Gateway device id from the last successful registration. Kept beside
    /// the engine because a rebuilt engine has not registered yet.
    private var _registeredDeviceId: String?
    /// What the current engine was built with, so a restore can tell whether
    /// the stored account still matches it.
    private var configuredWith: (gatewayUrl: String, apiKey: String)?
    private let stateLock = NSLock()

    /// Serialises configure/register so a launch-time restore, a VoIP push
    /// and a login cannot build two engines at once.
    private let setupQueue = DispatchQueue(label: "com.5060.aria.engine-setup")

    private let eventHandler = SwiftEventHandler()

    /// The one audio bridge, shared by every engine instance. CallKit owns the
    /// audio session, so the call manager starts and stops this from the
    /// provider's activation callbacks.
    let audioBridge = iOSAudioBridge()

    private var engine: AriaMobileEngine? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _engine
    }

    private var registeredDeviceId: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _registeredDeviceId
    }

    private init() {
        eventHandler.manager = self
    }

    /// Configure and connect to the push gateway.
    func configure(gatewayUrl: String, apiKey: String) {
        let config = GatewayConfig(
            baseUrl: gatewayUrl,
            apiKey: apiKey
        )
        let newEngine = AriaMobileEngine(gatewayConfig: config)
        newEngine.setEventHandler(handler: eventHandler)
        newEngine.setAudioBridge(bridge: audioBridge)

        stateLock.lock()
        _engine = newEngine
        _registeredDeviceId = nil
        configuredWith = (gatewayUrl, apiKey)
        stateLock.unlock()
    }

    // MARK: - Session restore

    /// Bring the engine up from the stored account and register it with the
    /// gateway, unless that has already happened.
    ///
    /// The engine used to be built only by an interactive login, so after a
    /// relaunch — and in particular when PushKit cold-launches the app for an
    /// incoming call — there was no engine and the call offer could not be
    /// fetched. The engine also needs a registration before it holds a
    /// gateway auth token, so configuring alone is not enough.
    ///
    /// Blocks on the network. Never call it on the main queue.
    func ensureReady() throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try setupQueue.sync {
            let account = AccountSettings.load()
            guard account.isProvisioned, !account.gatewayUrl.isEmpty else {
                throw SipError.notConfigured
            }
            // Only a PBX-issued gateway token will do. With none stored (an
            // older install, or one cleared after a failed renewal), get one.
            if KeychainStore.get(KeychainStore.gatewayTokenKey) == nil {
                try GatewayTokenRenewer.shared.renewBlocking()
            }
            guard let apiKey = KeychainStore.get(KeychainStore.gatewayTokenKey) else {
                throw SipError.notConfigured
            }

            stateLock.lock()
            let current = configuredWith
            let alreadyRegistered = _engine != nil && _registeredDeviceId != nil
            stateLock.unlock()

            let sameConfig = current?.gatewayUrl == account.gatewayUrl && current?.apiKey == apiKey
            if sameConfig && alreadyRegistered { return }
            if !sameConfig {
                configure(gatewayUrl: account.gatewayUrl, apiKey: apiKey)
            }

            guard let password = KeychainStore.get(KeychainStore.sipPasswordKey),
                  !password.isEmpty else {
                throw SipError.missingCredentials
            }
            // An expired token is renewed and the registration retried once;
            // this is what lets a cold-start push survive a stale token.
            try withAuthRetry {
                try registerDevice(
                    pushToken: KeychainStore.get(KeychainStore.pushTokenKey) ?? "",
                    bundleId: Bundle.main.bundleIdentifier,
                    sip: account.sipCredentials(password: password)
                )
            }
        }
    }

    // MARK: - Gateway token

    /// Hand the engine a renewed gateway token. Safe mid-call: the engine
    /// does not re-register, and its background polls pick the token up.
    func setGatewayToken(_ token: String) {
        stateLock.lock()
        let engine = _engine
        if let current = configuredWith {
            configuredWith = (current.gatewayUrl, token)
        }
        stateLock.unlock()
        engine?.setGatewayToken(token: token)
    }

    /// Run an engine call; if the gateway rejected the token, renew it and
    /// run the call once more.
    private func withAuthRetry<T>(_ operation: () throws -> T) throws -> T {
        try Self.retryingOnAuthFailure(
            renew: { try GatewayTokenRenewer.shared.renewBlocking() },
            operation
        )
    }

    /// `operation`, retried once after `renew` if it failed with
    /// `AuthenticationError`. Any other error, or a second auth failure, is
    /// thrown as is.
    static func retryingOnAuthFailure<T>(renew: () throws -> Void, _ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch where isAuthFailure(error) {
            try renew()
            return try operation()
        }
    }

    /// The gateway answered 401: the token is missing, expired or revoked.
    static func isAuthFailure(_ error: Error) -> Bool {
        if case MobileError.AuthenticationError = error {
            return true
        }
        return false
    }

    /// `ensureReady()` off the caller's queue.
    func ensureReadyAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.ensureReady()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Restore the session in the background, e.g. at launch. Failures are
    /// surfaced as a registration error rather than thrown.
    func restoreSessionInBackground() {
        guard AccountSettings.load().isProvisioned else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try self.ensureReady()
            } catch {
                print("Session restore failed: \(error)")
                DispatchQueue.main.async {
                    self.registrationError = error.localizedDescription
                }
            }
        }
    }

    /// Drop the engine so the next `ensureReady()` builds it from the stored
    /// account — used when a login changes it.
    func reset() {
        setupQueue.sync {
            stateLock.lock()
            _engine = nil
            _registeredDeviceId = nil
            configuredWith = nil
            stateLock.unlock()
        }
        DispatchQueue.main.async {
            self.isRegistered = false
            self.deviceId = nil
        }
    }

    // MARK: - Push token

    /// Tell the gateway about a rotated VoIP push token.
    ///
    /// Without this a token rotation left the gateway pushing to a dead token
    /// and incoming calls silently stopped. The token is persisted first, so
    /// an engine that is not registered yet picks it up when it registers.
    func updatePushToken(_ token: String) {
        let previous = KeychainStore.get(KeychainStore.pushTokenKey)
        KeychainStore.set(token, forKey: KeychainStore.pushTokenKey)
        guard AccountSettings.load().isProvisioned else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                if previous == token, self.registeredDeviceId != nil {
                    // PushKit redelivers the same token on every launch.
                    return
                }
                if let engine = self.engine, let deviceId = self.registeredDeviceId {
                    try self.withAuthRetry {
                        try engine.updatePushToken(deviceId: deviceId, newToken: token)
                    }
                } else {
                    // Registers with the token just stored.
                    try self.ensureReady()
                }
            } catch {
                print("Push token update failed: \(error)")
            }
        }
        // The PBX keeps its own copy of the push token for the device.
        Task {
            await Self.updatePbxPushToken(token)
        }
    }

    /// `PUT /api/v1/devices/{id}/push-token`. A 409 (the token is already
    /// bound to another device record) is logged, not fatal: the gateway
    /// registration above is what delivers pushes.
    private static func updatePbxPushToken(_ token: String) async {
        let defaults = UserDefaults.standard
        guard let apiUrl = defaults.string(forKey: AccountSettings.Key.apiUrl), !apiUrl.isEmpty,
              let deviceId = defaults.string(forKey: AccountSettings.Key.pbxDeviceId), !deviceId.isEmpty else {
            return
        }
        do {
            try await PbxSession.shared.authorized { jwt in
                try await PbxApiClient(baseUrl: apiUrl)
                    .updatePushToken(jwt: jwt, deviceId: deviceId, pushToken: token)
            }
        } catch PbxApiClient.ApiError.httpError(let code, let message) where code == 409 {
            print("PBX kept its push token (409): \(message)")
        } catch {
            print("PBX push token update failed: \(error)")
        }
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
        stateLock.lock()
        if _engine === engine {
            _registeredDeviceId = response.deviceId
        }
        stateLock.unlock()
        DispatchQueue.main.async {
            self.deviceId = response.deviceId
            self.isRegistered = true
            self.registrationError = nil
        }
    }

    /// Unregister from the push gateway and drop the engine. Blocks on the
    /// network, so it runs on the setup queue rather than the caller's.
    func signOut() {
        setupQueue.async {
            self.stateLock.lock()
            let engine = self._engine
            let deviceId = self._registeredDeviceId
            self._engine = nil
            self._registeredDeviceId = nil
            self.configuredWith = nil
            self.stateLock.unlock()

            if let engine = engine, let deviceId = deviceId {
                try? engine.unregisterDevice(deviceId: deviceId)
            }
        }
        DispatchQueue.main.async {
            self.isRegistered = false
            self.deviceId = nil
            self.registrationError = nil
        }
    }

    /// Handle an incoming push notification.
    func handlePushNotification(payload: PushCallPayload) throws -> CallOffer {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        return try withAuthRetry { try engine.handlePushNotification(payload: payload) }
    }

    /// Accept an incoming call.
    func acceptCall(callToken: String, codecs: [AudioCodec] = []) throws -> CallInfo {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        return try withAuthRetry {
            try engine.acceptIncomingCall(callToken: callToken, preferredCodecs: codecs)
        }
    }

    /// Reject an incoming call.
    func rejectCall(callToken: String) throws {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        try withAuthRetry { try engine.rejectIncomingCall(callToken: callToken) }
    }

    /// Make an outgoing call.
    func makeCall(uri: String, credentials: SipCredentials, codecs: [AudioCodec] = []) throws -> CallInfo {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        // Not retried: by the time a 401 comes back the engine has reported
        // Ringing and Ended for the attempt, so a retry would be a new call
        // behind the user's back. Renew so the next attempt works.
        do {
            return try engine.makeCall(uri: uri, credentials: credentials, preferredCodecs: codecs)
        } catch where Self.isAuthFailure(error) {
            GatewayTokenRenewer.shared.renewInBackground()
            throw error
        }
    }

    /// Hang up an active call.
    func hangup(callId: String) throws {
        guard let engine = engine else { return }
        do {
            try engine.hangup(callId: callId)
        } catch where Self.isAuthFailure(error) {
            // The call has already ended locally; renew so the core's
            // fallback hangup and later calls can reach the gateway.
            GatewayTokenRenewer.shared.renewInBackground()
            throw error
        }
    }

    /// Blind-transfer an active call. Blocks for up to about 8 s. On success
    /// the engine reports `.ended` for the call; on failure the call stays up.
    func transferCall(callId: String, target: String) throws {
        guard let engine = engine else {
            throw SipError.notConfigured
        }
        try withAuthRetry { try engine.transferCall(callId: callId, target: target) }
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

    /// Whether the call's media is encrypted, as negotiated.
    func callIsEncrypted(callId: String) -> Bool {
        return engine?.callIsEncrypted(callId: callId) ?? false
    }
}

// MARK: - UniFFI Event Handler Bridge

/// Receives the core's events. Callbacks arrive on arbitrary threads (the
/// core's poll threads included), so each one hops to the main queue.
///
/// Call state follows the core's event contract: every call id that has been
/// reported gets exactly one `.ended`, whether from a local hangup, a remote
/// BYE, a caller cancelling before answer, a failed `makeCall` or a transfer.
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
        // Read on the calling thread: makeCall reports Ringing on the thread
        // it runs on, which has its attempt's UUID parked.
        if info.direction == .outbound, info.state == .ringing,
           let uuid = OutgoingAttempts.shared.current {
            DispatchQueue.main.async {
                CallManager.shared.outgoingCallRinging(uuid: uuid, info: info)
            }
            return
        }
        DispatchQueue.main.async {
            CallManager.shared.updateCallState(info: info)
        }
    }

    /// Background work (status polls, the caller-cancel watch) had its token
    /// rejected. Fetch a new one; the engine uses it from then on.
    func onAuthRequired() {
        GatewayTokenRenewer.shared.renewInBackground()
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
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "SIP engine not configured. Set up gateway connection first."
        case .missingCredentials:
            return "The SIP password is not available. Scan your provisioning QR code again."
        }
    }
}
