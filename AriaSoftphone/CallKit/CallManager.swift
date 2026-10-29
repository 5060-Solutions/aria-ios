import Foundation
import CallKit
import AVFoundation
import UIKit

/// Manages CallKit integration and call lifecycle.
///
/// All state is mutated on the main queue: the provider delegate runs there,
/// and engine callbacks and background work hop back to it.
class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published var activeCall: ActiveCall?
    @Published var incomingOffer: CallOffer?
    /// Whether audio is currently going to the built-in speaker. Follows the
    /// actual route, so it is also right after a change from Control Centre
    /// or a Bluetooth device connecting.
    @Published private(set) var isSpeakerOn = false

    private let provider: CXProvider
    private let callController = CXCallController()

    /// Call tokens already reported to CallKit from a VoIP push.
    ///
    /// Fetching the offer for a pushed call makes the engine fire
    /// `onIncomingCall` too; without this the same call was reported to
    /// CallKit a second time under a fresh UUID.
    private var pushReportedTokens: Set<String> = []

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.iconTemplateImageData = UIImage(named: "CallKitIcon")?.pngData()

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: DispatchQueue.main)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    // MARK: - Audio Route

    /// Send call audio to the speaker, or back to the default route.
    func setSpeaker(_ on: Bool) {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            print("Failed to change audio route: \(error)")
        }
        refreshAudioRoute()
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        DispatchQueue.main.async { self.refreshAudioRoute() }
    }

    private func refreshAudioRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        isSpeakerOn = outputs.contains { $0.portType == .builtInSpeaker }
    }

    // MARK: - Incoming Call (from push notification)

    /// Report an incoming call to CallKit.
    private func reportIncomingCall(
        uuid: UUID,
        callerUri: String,
        callerName: String?,
        completion: @escaping (Error?) -> Void
    ) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(
            type: .generic,
            value: callerUri
        )
        update.localizedCallerName = callerName ?? callerUri
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = true
        update.supportsDTMF = true

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("Failed to report incoming call: \(error)")
            }
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// Report a call announced by a VoIP push.
    ///
    /// Call synchronously from the PushKit delegate, before any async work:
    /// PushKit terminates an app that does not report a call for every push.
    /// The completion runs on the main queue with an error if the call was
    /// not taken (CallKit refused it, or another call is in progress).
    func reportPushIncomingCall(
        uuid: UUID,
        callToken: String,
        callerUri: String,
        callerName: String?,
        completion: @escaping (Error?) -> Void
    ) {
        pushReportedTokens.insert(callToken)
        let busy = activeCall != nil

        reportIncomingCall(uuid: uuid, callerUri: callerUri, callerName: callerName) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.pushReportedTokens.remove(callToken)
                completion(error)
                return
            }

            if busy {
                // One call at a time: decline the second rather than let it
                // replace the call in progress.
                self.provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                self.pushReportedTokens.remove(callToken)
                self.recordMissedCall(remoteUri: callerUri, remoteName: callerName)
                DispatchQueue.global(qos: .utility).async {
                    try? SipEngineManager.shared.ensureReady()
                    try? SipEngineManager.shared.rejectCall(callToken: callToken)
                }
                completion(CallManagerError.busy)
                return
            }

            self.activeCall = ActiveCall(
                uuid: uuid,
                callToken: callToken,
                remoteUri: callerUri,
                remoteName: callerName,
                direction: .inbound,
                state: .incoming
            )
            completion(nil)
        }
    }

    /// Attach the offer fetched for a pushed call.
    func offerReceived(_ offer: CallOffer) {
        guard activeCall?.callToken == offer.callToken else { return }
        incomingOffer = offer
    }

    /// The offer for a pushed call could not be fetched: end it in CallKit.
    func failIncomingCall(uuid: UUID) {
        guard let call = activeCall, call.uuid == uuid else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        finishCall(call, outcome: .missed)
    }

    /// Satisfy PushKit for a push that cannot become a call (malformed, or
    /// from a gateway we do not trust): report a call and end it at once.
    ///
    /// Uses the shared provider. Ending the call through a throwaway
    /// `CXProvider` never reached the call the shared one had reported, so it
    /// was left ringing.
    func reportAndEndInvalidPush(completion: @escaping () -> Void) {
        let uuid = UUID()
        reportIncomingCall(uuid: uuid, callerUri: "Unknown", callerName: nil) { [weak self] error in
            if error == nil {
                self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            }
            completion()
        }
    }

    /// Handle an incoming call offer from the Rust core.
    func handleIncomingCall(offer: CallOffer) {
        // Already reported from PushKit: this is the same call, not a new one.
        if pushReportedTokens.contains(offer.callToken) {
            offerReceived(offer)
            return
        }
        guard activeCall == nil else { return }

        let uuid = UUID()
        pushReportedTokens.insert(offer.callToken)
        incomingOffer = offer

        reportIncomingCall(
            uuid: uuid,
            callerUri: offer.callerUri,
            callerName: offer.callerName
        ) { [weak self] error in
            guard let self = self else { return }
            guard error == nil else {
                self.pushReportedTokens.remove(offer.callToken)
                self.incomingOffer = nil
                return
            }
            self.activeCall = ActiveCall(
                uuid: uuid,
                callToken: offer.callToken,
                remoteUri: offer.callerUri,
                remoteName: offer.callerName,
                direction: .inbound,
                state: .incoming
            )
        }
    }

    // MARK: - Outgoing Call

    func startOutgoingCall(uri: String) {
        guard activeCall == nil else { return }

        let uuid = UUID()
        // Set before the request so the start action finds it.
        activeCall = ActiveCall(
            uuid: uuid,
            callToken: nil,
            remoteUri: uri,
            remoteName: nil,
            direction: .outbound,
            state: .connecting
        )

        let handle = CXHandle(type: .generic, value: uri)
        let startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.isVideo = false

        let transaction = CXTransaction(action: startCallAction)
        callController.request(transaction) { error in
            guard let error = error else { return }
            print("Failed to start call: \(error)")
            DispatchQueue.main.async {
                // CallKit refused the call outright (e.g. during a cellular
                // call); it was never placed, so it is not history.
                if self.activeCall?.uuid == uuid {
                    self.activeCall = nil
                }
            }
        }
    }

    // MARK: - Call Actions

    /// Answer the ringing call from the in-app UI. Goes through CallKit so the
    /// system call UI and audio session follow.
    func answerCall() {
        guard let call = activeCall, call.state == .incoming else { return }
        let answerAction = CXAnswerCallAction(call: call.uuid)
        callController.request(CXTransaction(action: answerAction)) { error in
            if let error = error {
                print("Failed to answer call: \(error)")
            }
        }
    }

    func endCall() {
        guard let call = activeCall else { return }
        let endAction = CXEndCallAction(call: call.uuid)
        let transaction = CXTransaction(action: endAction)
        callController.request(transaction) { error in
            if let error = error {
                print("Failed to end call: \(error)")
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let call = activeCall else { return }
        let muteAction = CXSetMutedCallAction(call: call.uuid, muted: muted)
        let transaction = CXTransaction(action: muteAction)
        callController.request(transaction) { _ in }
    }

    func setHeld(_ held: Bool) {
        guard let call = activeCall else { return }
        let holdAction = CXSetHeldCallAction(call: call.uuid, onHold: held)
        let transaction = CXTransaction(action: holdAction)
        callController.request(transaction) { _ in }
    }

    func sendDTMF(_ digits: String) {
        guard let call = activeCall else { return }
        let dtmfAction = CXPlayDTMFCallAction(
            call: call.uuid,
            digits: digits,
            type: .singleTone
        )
        let transaction = CXTransaction(action: dtmfAction)
        callController.request(transaction) { _ in }
    }

    // MARK: - Lifecycle

    /// The engine has a media session up for the call: mark it connected.
    ///
    /// Both directions come through here, so transcription capture starts for
    /// inbound calls as well as outbound ones.
    private func callDidConnect(callId: String) {
        guard var call = activeCall else { return }
        let now = Date()
        call.callId = callId
        call.state = .connected
        call.connectedAt = now
        activeCall = call

        if call.direction == .outbound {
            provider.reportOutgoingCall(with: call.uuid, connectedAt: now)
        }
        // A no-op unless transcription is on and a speech model is present.
        CallTranscription.shared.onCallStarted(callId: callId)
        SipEngineManager.shared.startCallMonitoring()
    }

    /// Tear down local state for a call that has ended, however it ended.
    /// CallKit must already have been told (by an action or `reportCall`).
    private func finishCall(_ call: ActiveCall, outcome: CallOutcome) {
        CallHistoryStore.shared.add(CallRecord(call: call, outcome: outcome))

        // Runs on its own queue and only if the user opted in, so a slow
        // transcription cannot hold up tearing the call down.
        if let callId = call.callId {
            CallTranscription.shared.onCallEnded(callId: callId)
        }
        if let token = call.callToken {
            pushReportedTokens.remove(token)
        }
        SipEngineManager.shared.stopCallMonitoring()
        // Normally CallKit's deactivation already did this; stopping here too
        // means a call never inherits the last one's engine or buffers.
        SipEngineManager.shared.audioBridge.stop()

        if activeCall?.uuid == call.uuid {
            activeCall = nil
            incomingOffer = nil
        }
    }

    /// Record an incoming call that never became the active call.
    private func recordMissedCall(remoteUri: String, remoteName: String?) {
        CallHistoryStore.shared.add(CallRecord(
            direction: .inbound,
            remoteUri: remoteUri,
            remoteName: remoteName,
            startedAt: Date(),
            duration: 0,
            outcome: .missed
        ))
    }

    // MARK: - State Updates

    /// Call-state events from the engine.
    ///
    /// The engine reports connects from inside `makeCall` / `acceptCall`,
    /// before the call id is known here; those are handled when the call
    /// returns. What matters from this path is the end of a call — this is
    /// how a remote hangup arrives — and hold/mute changes.
    func updateCallState(info: CallInfo) {
        guard var call = activeCall, call.callId == info.callId else { return }

        switch info.state {
        case .ended:
            provider.reportCall(with: call.uuid, endedAt: Date(), reason: .remoteEnded)
            finishCall(call, outcome: CallOutcome.resolve(for: call, endedLocally: false))
            return
        case .onHold:
            call.state = .onHold
        case .connected:
            call.state = .connected
        default:
            break
        }

        call.isMuted = info.muted
        call.isOnHold = info.onHold
        activeCall = call
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        // CallKit has dropped every call. Release ours in the engine too.
        guard let call = activeCall else { return }
        finishCall(call, outcome: CallOutcome.resolve(for: call, endedLocally: true))
        let callId = call.callId
        DispatchQueue.global(qos: .utility).async {
            if let callId = callId {
                try? SipEngineManager.shared.hangup(callId: callId)
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let call = activeCall, call.uuid == action.callUUID else {
            action.fail()
            return
        }

        let account = AccountSettings.load()
        guard account.isProvisioned,
              let password = KeychainStore.get(KeychainStore.sipPasswordKey),
              !password.isEmpty else {
            print("Cannot place call: no account configured")
            action.fail()
            activeCall = nil
            return
        }

        // Configure audio session for outgoing call
        configureAudioSession()

        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        // Fulfil now: the engine's makeCall blocks until the far end answers,
        // which can outlast the action's timeout. A failure from here on is
        // reported to CallKit as a failed call instead.
        action.fulfill()

        let uuid = call.uuid
        let uri = action.handle.value
        let credentials = account.sipCredentials(password: password)

        // Make the call via Rust engine on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SipEngineManager.shared.ensureReady()
                let info = try SipEngineManager.shared.makeCall(
                    uri: uri,
                    credentials: credentials
                )
                DispatchQueue.main.async {
                    guard self.activeCall?.uuid == uuid else {
                        // Hung up while it was connecting: drop the leg the
                        // gateway has just set up.
                        DispatchQueue.global(qos: .utility).async {
                            try? SipEngineManager.shared.hangup(callId: info.callId)
                        }
                        return
                    }
                    self.callDidConnect(callId: info.callId)
                }
            } catch {
                print("Failed to make outgoing call: \(error)")
                DispatchQueue.main.async {
                    guard let call = self.activeCall, call.uuid == uuid else { return }
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                    self.finishCall(call, outcome: .failed)
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Answer with the call token from the push, not the fetched offer: the
        // user can answer before the offer arrives, and accepting only needs
        // the token.
        guard let call = activeCall, call.uuid == action.callUUID,
              let callToken = call.callToken else {
            action.fail()
            return
        }

        configureAudioSession()
        activeCall?.state = .connecting
        let uuid = call.uuid

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SipEngineManager.shared.ensureReady()
                let info = try SipEngineManager.shared.acceptCall(callToken: callToken)
                DispatchQueue.main.async {
                    guard self.activeCall?.uuid == uuid else {
                        DispatchQueue.global(qos: .utility).async {
                            try? SipEngineManager.shared.hangup(callId: info.callId)
                        }
                        action.fail()
                        return
                    }
                    self.callDidConnect(callId: info.callId)
                    action.fulfill()
                }
            } catch {
                print("Failed to accept call: \(error)")
                DispatchQueue.main.async {
                    action.fail()
                    guard let call = self.activeCall, call.uuid == uuid else { return }
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                    self.finishCall(call, outcome: .failed)
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = activeCall, call.uuid == action.callUUID else {
            action.fulfill()
            return
        }

        finishCall(call, outcome: CallOutcome.resolve(for: call, endedLocally: true))
        action.fulfill()

        // Hang up via Rust engine — off the main queue, it waits on the network.
        let callId = call.callId
        let callToken = call.direction == .inbound ? call.callToken : nil
        DispatchQueue.global(qos: .userInitiated).async {
            if let callId = callId {
                try? SipEngineManager.shared.hangup(callId: callId)
            } else if let callToken = callToken {
                try? SipEngineManager.shared.ensureReady()
                try? SipEngineManager.shared.rejectCall(callToken: callToken)
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let callId = activeCall?.callId {
            try? SipEngineManager.shared.setMute(callId: callId, muted: action.isMuted)
        }
        activeCall?.isMuted = action.isMuted
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        if let callId = activeCall?.callId {
            try? SipEngineManager.shared.setHold(callId: callId, onHold: action.isOnHold)
        }
        activeCall?.isOnHold = action.isOnHold
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        if let callId = activeCall?.callId {
            try? SipEngineManager.shared.sendDtmf(callId: callId, digit: action.digits)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CallKit has activated the session: the hardware is ours until it
        // deactivates it. Only now may the audio engine start.
        SipEngineManager.shared.audioBridge.start()
        refreshAudioRoute()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        SipEngineManager.shared.audioBridge.stop()
    }

    // MARK: - Audio Session

    /// Set the category for a call. CallKit activates the session itself
    /// (then calls `didActivate`); activating it here as well raced CallKit
    /// and could leave the session at normal priority. Output starts on the
    /// receiver — the speaker is the user's choice, not a default.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .allowBluetoothHFP,
            ])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.02) // 20ms
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
}

// MARK: - Call Model

struct ActiveCall: Identifiable {
    let id = UUID()
    let uuid: UUID
    /// When the call was placed or started ringing.
    let startedAt = Date()
    var callToken: String?
    var callId: String?
    var remoteUri: String
    var remoteName: String?
    var direction: CallDirection
    var state: ActiveCallState
    var isMuted: Bool = false
    var isOnHold: Bool = false
    var connectedAt: Date?

    var duration: TimeInterval {
        guard let connectedAt = connectedAt else { return 0 }
        return Date().timeIntervalSince(connectedAt)
    }

    var displayName: String {
        remoteName ?? remoteUri
    }

    enum CallDirection {
        case inbound, outbound
    }

    enum ActiveCallState {
        case incoming, connecting, connected, onHold, ended
    }
}

// MARK: - Call Outcome

/// How a call ended, from the user's side. Recorded in call history.
enum CallOutcome: String, Codable {
    /// Connected, then ended by either side.
    case answered
    /// Incoming, never answered here: the caller gave up or it could not be
    /// delivered.
    case missed
    /// Incoming, declined by the user.
    case rejected
    /// Outgoing, abandoned by the user before it connected.
    case cancelled
    /// Could not be set up.
    case failed

    static func resolve(for call: ActiveCall, endedLocally: Bool) -> CallOutcome {
        if call.connectedAt != nil { return .answered }
        switch call.direction {
        case .inbound: return endedLocally ? .rejected : .missed
        case .outbound: return endedLocally ? .cancelled : .failed
        }
    }
}

enum CallManagerError: LocalizedError {
    case busy

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Another call is in progress."
        }
    }
}
