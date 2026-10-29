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

    /// Tokens of incoming calls that have ended here (declined, missed,
    /// answered and hung up, refused as busy). A repeat push or a late
    /// `onIncomingCall` for one of these is stale and must not ring again.
    private var finishedTokens = RecentTokens(capacity: 64)

    /// Pairs a transfer's result with its call's end, whichever comes first.
    private var transfers = TransferLedger()

    static func isCancellation(_ error: Error) -> Bool {
        if case MobileError.Cancelled = error { return true }
        return false
    }

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
    /// not taken (CallKit refused it, it duplicates a known call, or another
    /// call is in progress); only on `nil` should the offer be fetched.
    func reportPushIncomingCall(
        uuid: UUID,
        callToken: String,
        callerUri: String,
        callerName: String?,
        completion: @escaping (Error?) -> Void
    ) {
        switch IncomingPushTriage.decide(
            callToken: callToken,
            activeCall: activeCall,
            finishedTokens: finishedTokens
        ) {
        case .duplicate:
            // A redelivered push for the call already ringing (or one that
            // has ended). PushKit still needs a report, so report a call and
            // end it at once — without touching the real one or history.
            reportIncomingCall(uuid: uuid, callerUri: callerUri, callerName: callerName) { [weak self] error in
                if error == nil {
                    self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                }
                completion(CallManagerError.duplicate)
            }

        case .busy:
            // One call at a time: decline the second rather than let it
            // replace the call in progress.
            finishedTokens.insert(callToken)
            reportIncomingCall(uuid: uuid, callerUri: callerUri, callerName: callerName) { [weak self] error in
                guard let self = self else { return }
                if error == nil {
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
                }
                self.recordMissedCall(remoteUri: callerUri, remoteName: callerName)
                DispatchQueue.global(qos: .utility).async {
                    try? SipEngineManager.shared.ensureReady()
                    try? SipEngineManager.shared.rejectCall(callToken: callToken)
                }
                completion(CallManagerError.busy)
            }

        case .accept:
            // Claim the slot now, not in the completion: a second push that
            // arrives before CallKit answers must see this call.
            activeCall = ActiveCall(
                uuid: uuid,
                callToken: callToken,
                remoteUri: callerUri,
                remoteName: callerName,
                direction: .inbound,
                state: .incoming
            )
            reportIncomingCall(uuid: uuid, callerUri: callerUri, callerName: callerName) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    // CallKit refused it (Do Not Disturb, blocked caller):
                    // the call is not ours to ring.
                    if self.activeCall?.uuid == uuid {
                        self.activeCall = nil
                        self.incomingOffer = nil
                    }
                    self.finishedTokens.insert(callToken)
                    completion(error)
                    return
                }
                completion(nil)
            }
        }
    }

    /// Attach the offer fetched for a pushed call.
    func offerReceived(_ offer: CallOffer) {
        guard activeCall?.callToken == offer.callToken else { return }
        incomingOffer = offer
    }

    /// The offer for a pushed call could not be fetched: end it in CallKit.
    /// Only a call that is still ringing — answering does not need the offer,
    /// so a late failure must not end a call the user has picked up.
    func failIncomingCall(uuid: UUID) {
        guard let call = activeCall, call.uuid == uuid, call.state == .incoming else { return }
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

    /// The engine's `onIncomingCall`.
    ///
    /// It only fires from `handlePushNotification`, i.e. for a call PushKit
    /// has already announced and this class has already reported, so it
    /// never reports a call itself. On iOS every incoming call must arrive by
    /// PushKit anyway. An offer for any other token — one that has since been
    /// declined or missed, arriving late — is stale and dropped; reporting it
    /// would ring a call that no longer exists.
    func handleIncomingCall(offer: CallOffer) {
        guard activeCall?.callToken == offer.callToken else {
            print("Ignoring an offer for a call that is not ringing")
            return
        }
        offerReceived(offer)
    }

    // MARK: - Outgoing Call

    func startOutgoingCall(uri: String) {
        guard activeCall == nil else { return }

        let uuid = UUID()
        // Set before the request so the start action finds it. The engine's
        // id is chosen now, before dialing, so the call can be hung up by it
        // at any point — even before makeCallWithId has run.
        var call = ActiveCall(
            uuid: uuid,
            callToken: nil,
            remoteUri: uri,
            remoteName: nil,
            direction: .outbound,
            state: .connecting
        )
        call.engineCallId = newOutgoingCallId()
        activeCall = call

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

    /// Blind-transfer the connected call to `target`.
    ///
    /// The engine blocks for up to about 8 s, so this runs off the main queue
    /// and reports back there: `nil` once the PBX has taken the call (the
    /// engine's `.ended` then ends it here and records it as transferred), or
    /// an error to show, with the call still up.
    func transferCall(to target: String, completion: @escaping (TransferError?) -> Void) {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let call = activeCall, let callId = call.callId else {
            completion(.notActive)
            return
        }
        guard TransferError.isAcceptableTarget(target) else {
            completion(.invalidTarget)
            return
        }

        activeCall?.isTransferring = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SipEngineManager.shared.transferCall(callId: callId, target: target)
                DispatchQueue.main.async {
                    self.transferFinished(uuid: call.uuid, succeeded: true)
                    completion(nil)
                }
            } catch {
                print("Transfer failed: \(error)")
                DispatchQueue.main.async {
                    if self.activeCall?.uuid == call.uuid {
                        self.activeCall?.isTransferring = false
                    }
                    self.transferFinished(uuid: call.uuid, succeeded: false)
                    completion(TransferError(error))
                }
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
    ///
    /// Reached from the `Connected` event or from makeCallWithId / accept
    /// returning, in whichever order they arrive; the second is a no-op.
    private func callDidConnect(callId: String) {
        guard var call = activeCall, call.connectedAt == nil else { return }
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
    }

    /// Tear down local state for a call that has ended, however it ended.
    /// CallKit must already have been told (by an action or `reportCall`).
    /// `outcome` nil defers the history record to whoever learns it later
    /// (a transfer whose result is still pending).
    private func finishCall(_ call: ActiveCall, outcome: CallOutcome?) {
        if let outcome = outcome {
            CallHistoryStore.shared.add(CallRecord(call: call, outcome: outcome))
        }

        // Runs on its own queue and only if the user opted in, so a slow
        // transcription cannot hold up tearing the call down.
        if let callId = call.callId {
            CallTranscription.shared.onCallEnded(callId: callId)
        }
        if call.direction == .inbound, let token = call.callToken {
            finishedTokens.insert(token)
        }
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

    private func transferFinished(uuid: UUID, succeeded: Bool) {
        if let record = transfers.transferFinished(uuid: uuid, succeeded: succeeded) {
            CallHistoryStore.shared.add(record)
        }
    }

    /// Call-state events from the engine, matched to the call by id.
    ///
    /// Connects are handled where `makeCall` / `acceptCall` return, since
    /// those report what the app needs. From this path come the call's id for
    /// an outgoing call (its first `.ringing`), hold/mute changes, and the end
    /// of a call the user did not end here: a remote hangup, a caller
    /// cancelling before answer, a failed outgoing call, or a completed
    /// transfer. A local hangup's `.ended` arrives after the call is already
    /// gone and matches nothing.
    func updateCallState(info: CallInfo) {
        guard var call = activeCall else { return }

        guard call.engineCallId == info.callId else { return }

        switch info.state {
        case .ended:
            let ending = CallEnding.resolve(for: call)
            provider.reportCall(with: call.uuid, endedAt: Date(), reason: ending.reason)
            if call.isTransferring {
                // Either the transfer went through or the far end hung up
                // while it was pending; only the transfer's result can say.
                let record = transfers.callEnded(call, at: Date())
                finishCall(call, outcome: nil)
                if let record = record { CallHistoryStore.shared.add(record) }
            } else {
                finishCall(call, outcome: ending.outcome)
            }
            return
        case .onHold:
            call.state = .onHold
        case .connected:
            if call.connectedAt == nil {
                // Events are the source of truth; the method's return may
                // arrive before or after this.
                callDidConnect(callId: info.callId)
                guard let connected = activeCall, connected.uuid == call.uuid else { return }
                call = connected
            }
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
        hangUpInEngine(call)
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
        guard let callId = call.engineCallId else {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            finishCall(call, outcome: .failed)
            return
        }

        // Make the call via Rust engine on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SipEngineManager.shared.ensureReady()
                // Ended while the engine was being readied, when there may
                // have been no engine to take the hangup: never dial. From
                // here the engine exists, so a hangup by id cancels the call
                // whether it lands before or during makeCallWithId.
                let stillWanted = DispatchQueue.main.sync { self.activeCall?.uuid == uuid }
                guard stillWanted else {
                    throw MobileError.Cancelled(message: "ended before dialling")
                }
                let info = try SipEngineManager.shared.makeCall(
                    callId: callId,
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
                let cancelled = Self.isCancellation(error)
                if !cancelled {
                    print("Failed to make outgoing call: \(error)")
                }
                DispatchQueue.main.async {
                    guard let call = self.activeCall, call.uuid == uuid else { return }
                    if cancelled {
                        // Hung up while ringing. The end action normally got
                        // here first; if not, the user still ended it, so it
                        // is not a failure and not a remote end.
                        self.finishCall(call, outcome: .cancelled)
                    } else {
                        self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                        self.finishCall(call, outcome: .failed)
                    }
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

        // Fulfil now. The accept below waits on the network (and possibly a
        // token renewal), and holding the action that long risks CallKit
        // timing it out with the caller still ringing; fulfilling also lets
        // CallKit activate the audio session while the media comes up. A
        // failure from here on is reported as a failed call.
        action.fulfill()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SipEngineManager.shared.ensureReady()
                let info = try SipEngineManager.shared.acceptCall(callToken: callToken)
                DispatchQueue.main.async {
                    guard self.activeCall?.uuid == uuid else {
                        // Hung up while the accept was in flight.
                        DispatchQueue.global(qos: .utility).async {
                            try? SipEngineManager.shared.hangup(callId: info.callId)
                        }
                        return
                    }
                    self.callDidConnect(callId: info.callId)
                }
            } catch {
                print("Failed to accept call: \(error)")
                DispatchQueue.main.async {
                    guard let call = self.activeCall, call.uuid == uuid else { return }
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                    self.finishCall(call, outcome: .failed)
                }
            }
        }
    }

    /// CallKit gave up waiting for an action. Answer and start are fulfilled
    /// at once, so this should not happen for them, but if it does the call
    /// is dead in CallKit and must not be left up in the engine.
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let callAction = action as? CXCallAction,
              callAction is CXAnswerCallAction || callAction is CXStartCallAction,
              let call = activeCall, call.uuid == callAction.callUUID else { return }
        print("CallKit timed out performing \(type(of: action))")
        provider.reportCall(with: call.uuid, endedAt: Date(), reason: .failed)
        finishCall(call, outcome: call.connectedAt != nil ? .answered : .failed)
        hangUpInEngine(call)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = activeCall, call.uuid == action.callUUID else {
            action.fulfill()
            return
        }

        finishCall(call, outcome: CallOutcome.resolve(for: call, endedLocally: true))
        action.fulfill()
        hangUpInEngine(call)
    }

    /// Release a call the user ended here.
    ///
    /// A connected call, or an outgoing call at any stage, is hung up by its
    /// id: the core cancels a ringing call at the gateway (or never dials
    /// one not yet sent) and `makeCallWithId` throws `Cancelled`. An
    /// incoming call that was never answered is rejected instead. Runs off
    /// the main queue, since it waits on the network.
    private func hangUpInEngine(_ call: ActiveCall) {
        switch call.releaseOnLocalEnd {
        case .hangup(let callId):
            DispatchQueue.global(qos: .userInitiated).async {
                try? SipEngineManager.shared.hangup(callId: callId)
            }
        case .reject(let callToken):
            DispatchQueue.global(qos: .userInitiated).async {
                try? SipEngineManager.shared.ensureReady()
                try? SipEngineManager.shared.rejectCall(callToken: callToken)
            }
        case .none:
            break
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
    var callToken: String? {
        didSet { deriveEngineCallId() }
    }
    /// The engine's id for the call once it has connected.
    var callId: String? {
        didSet { if let callId = callId { engineCallId = callId } }
    }
    /// The id the engine's events carry for this call, known before it
    /// connects: `incoming-<call_token>` for an incoming call, and for an
    /// outgoing one the id from its first `.ringing` event.
    var engineCallId: String?
    /// A blind transfer has been requested and not yet refused.
    var isTransferring = false
    var remoteUri: String
    var remoteName: String?
    var direction: CallDirection
    var state: ActiveCallState
    var isMuted: Bool = false
    var isOnHold: Bool = false
    var connectedAt: Date?

    init(
        uuid: UUID,
        callToken: String?,
        remoteUri: String,
        remoteName: String?,
        direction: CallDirection,
        state: ActiveCallState
    ) {
        self.uuid = uuid
        self.callToken = callToken
        self.remoteUri = remoteUri
        self.remoteName = remoteName
        self.direction = direction
        self.state = state
        deriveEngineCallId()
    }

    private mutating func deriveEngineCallId() {
        if engineCallId == nil, direction == .inbound, let token = callToken {
            engineCallId = "incoming-\(token)"
        }
    }

    /// What the engine must do when the user ends this call here.
    enum EngineRelease: Equatable {
        case hangup(callId: String)
        case reject(callToken: String)
        case none
    }

    var releaseOnLocalEnd: EngineRelease {
        if let callId = callId { return .hangup(callId: callId) }
        switch direction {
        case .outbound:
            // Chosen before dialing, so valid before, during and after it:
            // the core cancels a ringing call at the gateway by this id.
            return engineCallId.map { .hangup(callId: $0) } ?? .none
        case .inbound:
            return callToken.map { .reject(callToken: $0) } ?? .none
        }
    }

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
    /// Connected, then handed to another party by blind transfer.
    case transferred
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

/// Decides whether a call that ended during a transfer was transferred.
///
/// The call's `Ended` and the transfer's result can arrive in either order,
/// and an `Ended` during a pending transfer may be the far end hanging up
/// instead. So the call is recorded as transferred only once the transfer
/// has reported success; if it failed, the call simply ended.
struct TransferLedger {
    private var results: [UUID: Bool] = [:]
    private var ended: [UUID: (call: ActiveCall, endedAt: Date)] = [:]

    /// The call ended while a transfer was pending. Returns its record if the
    /// transfer's result is already known.
    mutating func callEnded(_ call: ActiveCall, at endedAt: Date) -> CallRecord? {
        if let succeeded = results.removeValue(forKey: call.uuid) {
            return Self.record(call, endedAt: endedAt, transferred: succeeded)
        }
        ended[call.uuid] = (call, endedAt)
        return nil
    }

    /// The transfer returned. Returns the call's record if it has already
    /// ended. A failed transfer whose call is still up records nothing.
    mutating func transferFinished(uuid: UUID, succeeded: Bool) -> CallRecord? {
        if let (call, endedAt) = ended.removeValue(forKey: uuid) {
            return Self.record(call, endedAt: endedAt, transferred: succeeded)
        }
        if succeeded {
            results[uuid] = true
        }
        return nil
    }

    private static func record(_ call: ActiveCall, endedAt: Date, transferred: Bool) -> CallRecord {
        CallRecord(call: call, outcome: transferred ? .transferred : .answered, endedAt: endedAt)
    }
}

/// How to report a call the engine ended (rather than one the user ended
/// here) to CallKit and to history.
struct CallEnding: Equatable {
    let reason: CXCallEndedReason
    let outcome: CallOutcome

    static func resolve(for call: ActiveCall) -> CallEnding {
        if call.connectedAt != nil {
            return CallEnding(reason: .remoteEnded, outcome: .answered)
        }
        switch call.direction {
        // The caller gave up before it was answered.
        case .inbound: return CallEnding(reason: .unanswered, outcome: .missed)
        // makeCall failed; it reports Ended and then throws.
        case .outbound: return CallEnding(reason: .failed, outcome: .failed)
        }
    }
}

/// Why a transfer did not happen. In every case the call is still up.
enum TransferError: LocalizedError, Equatable {
    case invalidTarget
    case notActive
    case refused
    case timedOut
    case unavailable

    init(_ error: Error) {
        switch error as? MobileError {
        case .InvalidTarget: self = .invalidTarget
        case .InvalidState: self = .notActive
        case .CallFailed: self = .refused
        case .Timeout: self = .timedOut
        default: self = .unavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "That number can't be transferred to. Check it and try again."
        case .notActive:
            return "This call can't be transferred right now."
        case .refused:
            return "The phone system refused the transfer."
        case .timedOut:
            return "The phone system didn't respond in time. The call has not been transferred."
        case .unavailable:
            return "Couldn't reach the phone system. The call has not been transferred."
        }
    }

    /// What the core would reject locally: empty, or characters that do not
    /// belong in a SIP URI header.
    static func isAcceptableTarget(_ target: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "\r\n<>")
        return !target.isEmpty && target.rangeOfCharacter(from: forbidden) == nil
    }
}

/// A bounded record of recent call tokens, oldest dropped first.
struct RecentTokens {
    let capacity: Int
    private var order: [String] = []
    private var members: Set<String> = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func contains(_ token: String) -> Bool {
        members.contains(token)
    }

    mutating func insert(_ token: String) {
        guard members.insert(token).inserted else { return }
        order.append(token)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
    }
}

/// What to do with a VoIP push, given the calls already known.
enum IncomingPushTriage: Equatable {
    /// A new call, and the line is free.
    case accept
    /// The call already ringing or in progress, or one that has ended.
    case duplicate
    /// A different call while one is in progress.
    case busy

    static func decide(callToken: String, activeCall: ActiveCall?, finishedTokens: RecentTokens) -> IncomingPushTriage {
        if activeCall?.callToken == callToken || finishedTokens.contains(callToken) {
            return .duplicate
        }
        return activeCall == nil ? .accept : .busy
    }
}

enum CallManagerError: LocalizedError {
    case busy
    case duplicate

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Another call is in progress."
        case .duplicate:
            return "This call has already been reported."
        }
    }
}
