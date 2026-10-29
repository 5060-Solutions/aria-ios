import Foundation
import CallKit
import AVFoundation
import UIKit

/// Manages CallKit integration and call lifecycle.
///
/// Up to two calls at once (call waiting): at most one is connected and off
/// hold, which the core enforces by holding the others whenever a call
/// connects or is resumed. Each call is tracked under its CallKit UUID, and
/// engine events are routed to it by the engine's call id.
///
/// All state is mutated on the main queue: the provider delegate runs there,
/// and engine callbacks and background work hop back to it.
class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    /// Every call this phone has, oldest first.
    @Published private(set) var registry = CallRegistry()
    /// Whether audio is currently going to the built-in speaker. Follows the
    /// actual route, so it is also right after a change from Control Centre
    /// or a Bluetooth device connecting.
    @Published private(set) var isSpeakerOn = false

    /// The call the call screen shows; see `CallRegistry.foreground`.
    var activeCall: ActiveCall? { registry.foreground }

    /// The calls other than `activeCall`, oldest first.
    var otherCalls: [ActiveCall] { registry.background }

    private let provider: CXProvider
    private let callController = CXCallController()

    /// Tokens of incoming calls that have ended here (declined, missed,
    /// answered and hung up, refused as busy). A repeat push or a late
    /// `onIncomingCall` for one of these is stale and must not ring again.
    private var finishedTokens = RecentTokens(capacity: 64)

    /// The calls CallKit believes are on hold: those whose last fulfilled
    /// `CXSetHeldCallAction` held them. When the core holds or resumes a call
    /// on its own, this differs from the call's state until CallKit is told.
    private var callKitHeld: Set<UUID> = []
    private var holdSyncScheduled = false

    /// An accept whose result is unknown: the core reports Ended and then
    /// hangs up or rejects the call itself.
    static func acceptOutcomeUnknown(_ error: Error) -> Bool {
        switch error as? MobileError {
        case .Timeout, .NetworkError: return true
        default: return false
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if case MobileError.Cancelled = error { return true }
        return false
    }

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        // Two calls in separate groups: one talking, one held. Calls are
        // never merged, so each group holds a single call.
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = CallRegistry.maximumCalls
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
    /// not taken (CallKit refused it, it duplicates a known call, or there is
    /// no room for it: two calls, or one still ringing or being set up);
    /// only on `nil` should the offer be fetched.
    ///
    /// A call that arrives while another is up is reported like any other:
    /// CallKit offers the user Hold & Accept, End & Accept or Decline.
    func reportPushIncomingCall(
        uuid: UUID,
        callToken: String,
        callerUri: String,
        callerName: String?,
        completion: @escaping (Error?) -> Void
    ) {
        switch IncomingPushTriage.decide(
            callToken: callToken,
            calls: registry.calls,
            finishedTokens: finishedTokens
        ) {
        case .duplicate:
            // A redelivered push for a call already ringing (or one that
            // has ended). PushKit still needs a report, so report a call and
            // end it at once — without touching the real one or history.
            reportIncomingCall(uuid: uuid, callerUri: callerUri, callerName: callerName) { [weak self] error in
                if error == nil {
                    self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                }
                completion(CallManagerError.duplicate)
            }

        case .busy:
            // Two calls already (the core refuses a third), or one still
            // being set up: decline it rather than ring a call that cannot
            // be answered properly. It is still reported first, as PushKit
            // requires, then ended.
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
            registry.add(ActiveCall(
                uuid: uuid,
                callToken: callToken,
                remoteUri: callerUri,
                remoteName: callerName,
                direction: .inbound,
                state: .incoming
            ))
            reportIncomingCall(uuid: uuid, callerUri: callerUri, callerName: callerName) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    // CallKit refused it (Do Not Disturb, blocked caller):
                    // the call is not ours to ring.
                    self.registry.remove(uuid: uuid)
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
        guard let call = registry.call(callToken: offer.callToken) else { return }
        registry.modify(uuid: call.uuid) { $0.offer = offer }
    }

    /// The offer for a pushed call could not be fetched: end it in CallKit.
    /// Only a call that is still ringing — answering does not need the offer,
    /// so a late failure must not end a call the user has picked up.
    func failIncomingCall(uuid: UUID) {
        guard let call = registry[uuid], call.state == .incoming else { return }
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
        guard registry.call(callToken: offer.callToken) != nil else {
            print("Ignoring an offer for a call that is not ringing")
            return
        }
        offerReceived(offer)
    }

    // MARK: - Outgoing Call

    /// Whether another call can be placed now: fewer than two calls, and none
    /// still ringing or connecting.
    var canAddCall: Bool { registry.canAddCall }

    /// Place a call. While another call is up it becomes the second call:
    /// the call in progress is put on hold first, through CallKit, so the
    /// system call UI shows it held.
    func startOutgoingCall(uri: String) {
        guard registry.canAddCall else { return }

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

        var actions: [CXAction] = []
        if let talking = registry.talking {
            actions.append(CXSetHeldCallAction(call: talking.uuid, onHold: true))
        }
        registry.add(call)

        let handle = CXHandle(type: .generic, value: uri)
        let startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.isVideo = false
        actions.append(startCallAction)

        callController.request(CXTransaction(actions: actions)) { error in
            guard let error = error else { return }
            print("Failed to start call: \(error)")
            DispatchQueue.main.async {
                // CallKit refused the call outright (e.g. during a cellular
                // call); it was never placed, so it is not history.
                self.registry.remove(uuid: uuid)
            }
        }
    }

    // MARK: - Call Actions

    /// What happens to the other call when answering a second one.
    enum AnswerMode {
        /// Hold the call in progress, as CallKit's "Hold & Accept".
        case holdOthers
        /// Hang up the call in progress, as CallKit's "End & Accept".
        case endOthers
    }

    /// Answer the ringing call `uuid` from the in-app UI. Goes through
    /// CallKit so the system call UI and audio session follow; the other call
    /// is held or ended in the same transaction, ahead of the answer, as
    /// CallKit's own buttons do.
    ///
    /// Every in-app action names the call it was shown for, not whichever
    /// call is on screen by the time it runs: a second call can take the
    /// screen between the two.
    func answerCall(uuid: UUID, _ mode: AnswerMode = .holdOthers) {
        guard let call = registry[uuid], call.state == .incoming else { return }
        var actions: [CXAction] = []
        for other in registry.calls where other.uuid != call.uuid {
            switch mode {
            case .holdOthers:
                if other.isConnected && !other.isOnHold {
                    actions.append(CXSetHeldCallAction(call: other.uuid, onHold: true))
                }
            case .endOthers:
                actions.append(CXEndCallAction(call: other.uuid))
            }
        }
        actions.append(CXAnswerCallAction(call: call.uuid))
        callController.request(CXTransaction(actions: actions)) { error in
            if let error = error {
                print("Failed to answer call: \(error)")
            }
        }
    }

    /// End the call `uuid`. Another call stays as it was: a held call stays
    /// held until the user resumes it.
    func endCall(uuid: UUID) {
        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)
        callController.request(transaction) { error in
            if let error = error {
                print("Failed to end call: \(error)")
            }
        }
    }

    /// Blind-transfer the connected call `uuid` to `target`.
    ///
    /// The engine blocks for up to about 45 s, so this runs off the main
    /// queue and reports back there: `nil` once the PBX has taken the call
    /// (the engine's `.ended` then ends it here and records it as
    /// transferred), or an error to show, with the call still up.
    func transferCall(uuid: UUID, to target: String, completion: @escaping (TransferError?) -> Void) {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let call = registry[uuid], let callId = call.callId else {
            completion(.notActive)
            return
        }
        guard TransferError.isAcceptableTarget(target) else {
            completion(.invalidTarget)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SipEngineManager.shared.transferCall(callId: callId, target: target)
                // The call's Ended(Transferred) ends and records it.
                DispatchQueue.main.async { completion(nil) }
            } catch {
                print("Transfer failed: \(error)")
                DispatchQueue.main.async { completion(TransferError(error)) }
            }
        }
    }

    /// The two calls an attended transfer would join, if there are such:
    /// see `CallRegistry.attendedTransferPair`.
    var attendedTransferPair: (transferred: ActiveCall, consult: ActiveCall)? {
        registry.attendedTransferPair
    }

    /// Attended transfer: connect the caller of the incoming call to the
    /// party of the outgoing (consult) call and drop out of both.
    ///
    /// Blocks for up to about 45 s off the main queue, then reports there:
    /// `nil` on success (each call's Ended(Transferred) then ends it here and
    /// records it as transferred), or an error to show, with both calls up.
    /// `transferred` and `consult` are the calls the user was shown; if they
    /// are no longer the pair (one ended, another connected) nothing is sent.
    func completeAttendedTransfer(
        transferred: UUID,
        consult: UUID,
        completion: @escaping (TransferError?) -> Void
    ) {
        guard let pair = registry.attendedTransferPair,
              pair.transferred.uuid == transferred, pair.consult.uuid == consult,
              let callId = pair.transferred.callId,
              let consultCallId = pair.consult.callId else {
            completion(.notActive)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SipEngineManager.shared.transferAttended(callId: callId, consultCallId: consultCallId)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                print("Attended transfer failed: \(error)")
                DispatchQueue.main.async { completion(TransferError(error)) }
            }
        }
    }

    /// Hold the talking call `active` and resume the held call `held`.
    ///
    /// Done in the engine with `swapCalls`; the hold changes it reports are
    /// then passed on to CallKit (see `syncHoldWithCallKit`). Nothing happens
    /// unless the two are still talking and held.
    func swapCalls(active: UUID, held: UUID) {
        guard registry.canSwap(active: active, held: held),
              let talking = registry[active], let activeId = talking.callId,
              let held = registry[held], let heldId = held.callId else { return }
        do {
            try SipEngineManager.shared.swapCalls(activeCallId: activeId, heldCallId: heldId)
            registry.modify(uuid: talking.uuid) { $0.setHeld(true) }
            registry.modify(uuid: held.uuid) { $0.setHeld(false) }
            scheduleHoldSync()
        } catch {
            print("Failed to swap calls: \(error)")
        }
    }

    func setMuted(uuid: UUID, _ muted: Bool) {
        guard registry[uuid] != nil else { return }
        let muteAction = CXSetMutedCallAction(call: uuid, muted: muted)
        let transaction = CXTransaction(action: muteAction)
        callController.request(transaction) { _ in }
    }

    /// Hold or resume the call `uuid`. Resuming it holds the other call.
    func setHeld(uuid: UUID, _ held: Bool) {
        guard registry[uuid] != nil else { return }
        let holdAction = CXSetHeldCallAction(call: uuid, onHold: held)
        let transaction = CXTransaction(action: holdAction)
        callController.request(transaction) { error in
            if let error = error {
                print("Failed to change hold: \(error)")
            }
        }
    }

    func sendDTMF(uuid: UUID, _ digits: String) {
        guard registry[uuid] != nil else { return }
        let dtmfAction = CXPlayDTMFCallAction(
            call: uuid,
            digits: digits,
            type: .singleTone
        )
        let transaction = CXTransaction(action: dtmfAction)
        callController.request(transaction) { _ in }
    }

    // MARK: - Hold sync

    /// Tell CallKit about hold changes the core made by itself: holding the
    /// other calls when one connects or is resumed. CallKit has no update
    /// field for hold, so it is told the way it learns any hold: a
    /// `CXSetHeldCallAction`, which `perform` then finds already done.
    ///
    /// Coalesced onto the next main-queue turn, so the hold of one call and
    /// the resume of another go to CallKit as one transaction, hold first.
    private func scheduleHoldSync() {
        guard !holdSyncScheduled else { return }
        holdSyncScheduled = true
        DispatchQueue.main.async {
            self.holdSyncScheduled = false
            self.syncHoldWithCallKit()
        }
    }

    private func syncHoldWithCallKit() {
        let changes = CallRegistry.holdChanges(calls: registry.calls, callKitHeld: callKitHeld)
        guard !changes.isEmpty else { return }
        let actions = changes.map { CXSetHeldCallAction(call: $0.uuid, onHold: $0.onHold) }
        callController.request(CXTransaction(actions: actions)) { error in
            if let error = error {
                print("Failed to report hold to CallKit: \(error)")
            }
        }
    }

    // MARK: - Lifecycle

    /// The engine has a media session up for the call: mark it connected.
    ///
    /// Both directions come through here, so transcription capture starts for
    /// inbound calls as well as outbound ones.
    ///
    /// Reached from the `Connected` event or from makeCallWithId / accept
    /// returning, in whichever order they arrive; the second is a no-op.
    private func callDidConnect(uuid: UUID, callId: String) {
        guard let call = registry[uuid], call.connectedAt == nil else { return }
        let now = Date()
        registry.modify(uuid: uuid) {
            $0.callId = callId
            $0.state = $0.isOnHold ? .onHold : .connected
            $0.connectedAt = now
        }

        if call.direction == .outbound {
            provider.reportOutgoingCall(with: uuid, connectedAt: now)
        }
        // A no-op unless transcription is on and a speech model is present.
        CallTranscription.shared.onCallStarted(callId: callId)
    }

    /// Tear down local state for a call that has ended, however it ended.
    /// CallKit must already have been told (by an action or `reportCall`).
    /// Any other call is left as it was; a held call stays held.
    private func finishCall(_ call: ActiveCall, outcome: CallOutcome) {
        CallHistoryStore.shared.add(CallRecord(call: call, outcome: outcome))

        // Runs on its own queue and only if the user opted in, so a slow
        // transcription cannot hold up tearing the call down.
        if let callId = call.callId {
            CallTranscription.shared.onCallEnded(callId: callId)
        }
        if call.direction == .inbound, let token = call.callToken {
            finishedTokens.insert(token)
        }
        registry.remove(uuid: call.uuid)
        callKitHeld.remove(call.uuid)

        // Normally CallKit's deactivation already did this; stopping here too
        // means a call never inherits the last one's engine or buffers. Only
        // once the last call is gone: the other call is still using it.
        if registry.isEmpty {
            SipEngineManager.shared.audioBridge.stop()
        }
    }

    /// Record an incoming call that never became one of ours.
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

    /// Call-state events from the engine, routed to the call by its engine id.
    ///
    /// Connects are also handled where `makeCall` / `acceptCall` return. From
    /// this path come hold/mute changes (including the core holding one call
    /// when another connects or is resumed), and the end of a call the user
    /// did not end here: a remote hangup, a caller cancelling before answer,
    /// a failed outgoing call, or a completed transfer. A local hangup's
    /// `.ended` arrives after the call is already gone and matches nothing.
    func updateCallState(info: CallInfo) {
        guard let call = registry.call(engineCallId: info.callId) else { return }

        switch info.state {
        case .ended:
            let ending = CallEnding.resolve(for: call, reason: info.endReason)
            if let reason = ending.callKitReason {
                provider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
            }
            finishCall(call, outcome: ending.outcome)
            return
        case .connected, .onHold:
            if call.connectedAt == nil {
                // Events are the source of truth; the method's return may
                // arrive before or after this.
                callDidConnect(uuid: call.uuid, callId: info.callId)
            }
        default:
            break
        }

        registry.modify(uuid: call.uuid) {
            $0.isMuted = info.muted
            if $0.isConnected {
                $0.setHeld(info.onHold || info.state == .onHold)
            }
        }
        scheduleHoldSync()
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        // CallKit has dropped every call. Release ours in the engine too.
        for call in registry.calls {
            finishCall(call, outcome: CallOutcome.resolve(for: call, endedLocally: true))
            hangUpInEngine(call)
        }
        callKitHeld.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let call = registry[action.callUUID] else {
            action.fail()
            return
        }

        let account = AccountSettings.load()
        guard account.isProvisioned,
              let password = KeychainStore.get(KeychainStore.sipPasswordKey),
              !password.isEmpty else {
            print("Cannot place call: no account configured")
            action.fail()
            registry.remove(uuid: call.uuid)
            return
        }

        configureAudioSessionForFirstCall(except: call.uuid)

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
                let stillWanted = DispatchQueue.main.sync { self.registry[uuid] != nil }
                guard stillWanted else {
                    throw MobileError.Cancelled(message: "ended before dialling")
                }
                let info = try SipEngineManager.shared.makeCall(
                    callId: callId,
                    uri: uri,
                    credentials: credentials
                )
                DispatchQueue.main.async {
                    guard self.registry[uuid] != nil else {
                        // Hung up while it was connecting: drop the leg the
                        // gateway has just set up.
                        DispatchQueue.global(qos: .utility).async {
                            try? SipEngineManager.shared.hangup(callId: info.callId)
                        }
                        return
                    }
                    self.callDidConnect(uuid: uuid, callId: info.callId)
                }
            } catch {
                let cancelled = Self.isCancellation(error)
                if !cancelled {
                    print("Failed to make outgoing call: \(error)")
                }
                DispatchQueue.main.async {
                    guard let call = self.registry[uuid] else { return }
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
        guard let call = registry[action.callUUID],
              let callToken = call.callToken else {
            action.fail()
            return
        }

        configureAudioSessionForFirstCall(except: call.uuid)
        let uuid = call.uuid
        registry.modify(uuid: uuid) { $0.state = .connecting }

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
                    guard self.registry[uuid] != nil else {
                        // Hung up while the accept was in flight.
                        DispatchQueue.global(qos: .utility).async {
                            try? SipEngineManager.shared.hangup(callId: info.callId)
                        }
                        return
                    }
                    self.callDidConnect(uuid: uuid, callId: info.callId)
                }
            } catch {
                print("Failed to accept call: \(error)")
                // With an unknown outcome (Timeout, NetworkError) the core
                // reports Ended and cleans the call up itself. A refused
                // accept leaves it offered at the gateway, ringing the caller
                // with nobody here, so reject it.
                if !Self.acceptOutcomeUnknown(error) {
                    DispatchQueue.global(qos: .utility).async {
                        try? SipEngineManager.shared.rejectCall(callToken: callToken)
                    }
                }
                DispatchQueue.main.async {
                    guard let call = self.registry[uuid] else { return }
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
              let call = registry[callAction.callUUID] else { return }
        print("CallKit timed out performing \(type(of: action))")
        provider.reportCall(with: call.uuid, endedAt: Date(), reason: .failed)
        finishCall(call, outcome: call.connectedAt != nil ? .answered : .failed)
        hangUpInEngine(call)
    }

    /// Ends one call. With "End & Accept" CallKit sends this for the call in
    /// progress just ahead of the answer, so ending it must leave the other
    /// call (and the audio engine) alone.
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = registry[action.callUUID] else {
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
        if let callId = registry[action.callUUID]?.callId {
            try? SipEngineManager.shared.setMute(callId: callId, muted: action.isMuted)
        }
        registry.modify(uuid: action.callUUID) { $0.isMuted = action.isMuted }
        action.fulfill()
    }

    /// Hold or resume one call, whether CallKit asks (its Hold, Swap or "Hold
    /// & Accept") or the app does. Resuming a call while another is talking
    /// is a swap in the engine. A request that only reports a hold the core
    /// already made changes nothing in the engine.
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        let uuid = action.callUUID
        let request = CallRegistry.holdRequest(for: uuid, onHold: action.isOnHold, in: registry)
        do {
            switch request {
            case .none:
                break
            case .notConnected:
                action.fail()
                return
            case .hold(let callId):
                try SipEngineManager.shared.setHold(callId: callId, onHold: true)
                registry.modify(uuid: uuid) { $0.setHeld(true) }
            case .resume(let callId):
                try SipEngineManager.shared.setHold(callId: callId, onHold: false)
                registry.modify(uuid: uuid) { $0.setHeld(false) }
            case .swap(let activeCallId, let heldCallId):
                try SipEngineManager.shared.swapCalls(activeCallId: activeCallId, heldCallId: heldCallId)
                if let talking = registry.call(engineCallId: activeCallId) {
                    registry.modify(uuid: talking.uuid) { $0.setHeld(true) }
                }
                registry.modify(uuid: uuid) { $0.setHeld(false) }
            }
        } catch {
            print("Failed to change hold: \(error)")
            action.fail()
            return
        }
        if action.isOnHold {
            callKitHeld.insert(uuid)
        } else {
            callKitHeld.remove(uuid)
        }
        action.fulfill()
        // A swap held the other call too; CallKit has to hear about that.
        scheduleHoldSync()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        if let callId = registry[action.callUUID]?.callId {
            try? SipEngineManager.shared.sendDtmf(callId: callId, digit: action.digits)
        }
        action.fulfill()
    }

    /// CallKit activates the session once for the first call and keeps it
    /// active while any call is up (it may deactivate it while every call is
    /// held, and activate it again on resume). The bridge follows the
    /// session; starting it again while it runs is a no-op.
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

    /// Configure the session for a call, unless another call already has it
    /// running: changing the sample rate under a live session would make the
    /// audio engine rebuild mid-call.
    private func configureAudioSessionForFirstCall(except uuid: UUID) {
        guard !registry.calls.contains(where: { $0.uuid != uuid && $0.isConnected }) else { return }
        configureAudioSession()
    }

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

    var remoteUri: String
    var remoteName: String?
    var direction: CallDirection
    var state: ActiveCallState
    var isMuted: Bool = false
    var isOnHold: Bool = false
    var connectedAt: Date?
    /// The offer fetched for an incoming call, once it has arrived.
    var offer: CallOffer?

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

    /// Whether the call has connected (and not yet ended), held or not.
    var isConnected: Bool { connectedAt != nil }

    /// Record a hold change on a connected call.
    mutating func setHeld(_ held: Bool) {
        isOnHold = held
        if isConnected { state = held ? .onHold : .connected }
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
    /// Connected, then handed to another party by transfer (blind or
    /// attended).
    case transferred
    /// Incoming, picked up on another of the user's devices.
    case answeredElsewhere
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

/// How to report a call the engine ended, to CallKit and to history.
///
/// The core says why in `CallInfo.endReason`. Endings that follow the app's
/// own action (a local hangup, a cancel, our own decline) were already
/// reported to CallKit and recorded by that action, and their `Ended` arrives
/// after the call is gone here; if one does reach a live call it is finished
/// without a second CallKit report.
struct CallEnding: Equatable {
    /// nil: CallKit already knows, from the action that caused it.
    let callKitReason: CXCallEndedReason?
    let outcome: CallOutcome

    static func resolve(for call: ActiveCall, reason: EndReason?) -> CallEnding {
        let connected = call.connectedAt != nil
        switch reason {
        case .remoteHangup:
            return CallEnding(callKitReason: .remoteEnded, outcome: connected ? .answered : unconnectedRemoteEnd(call))
        case .callerCancelled:
            return CallEnding(callKitReason: .unanswered, outcome: .missed)
        case .answeredElsewhere:
            return CallEnding(callKitReason: .answeredElsewhere, outcome: .answeredElsewhere)
        case .rejected:
            // Our own decline is recorded by the end action and its Ended
            // never matches a live call, so this one was declined elsewhere.
            return CallEnding(callKitReason: .declinedElsewhere, outcome: .rejected)
        case .transferred:
            return CallEnding(callKitReason: .remoteEnded, outcome: .transferred)
        case .failed:
            return CallEnding(callKitReason: .failed, outcome: connected ? .answered : .failed)
        case .localHangup, .cancelled:
            return CallEnding(callKitReason: nil, outcome: CallOutcome.resolve(for: call, endedLocally: true))
        case nil:
            // A core without end reasons: infer from the call's state.
            if connected { return CallEnding(callKitReason: .remoteEnded, outcome: .answered) }
            switch call.direction {
            case .inbound: return CallEnding(callKitReason: .unanswered, outcome: .missed)
            case .outbound: return CallEnding(callKitReason: .failed, outcome: .failed)
            }
        }
    }

    private static func unconnectedRemoteEnd(_ call: ActiveCall) -> CallOutcome {
        call.direction == .inbound ? .missed : .failed
    }
}

/// Why a transfer did not happen. In every case the call is still up.
enum TransferError: LocalizedError, Equatable {
    case invalidTarget
    case notActive
    /// The PBX refused the REFER, or reported that the transfer failed. The
    /// core's message says which, with the SIP status when there is one.
    case refused(String)
    case timedOut
    case unavailable
    /// An attended transfer between two calls the PBX cannot join: both
    /// incoming or both outgoing.
    case unsupported

    init(_ error: Error) {
        switch error as? MobileError {
        case .InvalidTarget: self = .invalidTarget
        case .InvalidState: self = .notActive
        case .TransferUnsupported: self = .unsupported
        case .CallFailed(let message): self = .refused(message)
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
        case .refused(let message):
            return Self.describeRefusal(message)
        case .timedOut:
            return "The phone system didn't respond in time. The call has not been transferred."
        case .unavailable:
            return "Couldn't reach the phone system. The call has not been transferred."
        case .unsupported:
            return "These calls can't be joined. The phone system can only transfer a call you answered to a call you placed. Both calls are still up."
        }
    }

    /// The core's `CallFailed` message, as a sentence for the user, with the
    /// common SIP statuses spelled out.
    static func describeRefusal(_ message: String) -> String {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return "The phone system refused the transfer. You're still on the call."
        }
        var sentence = detail.prefix(1).uppercased() + detail.dropFirst()
        if !sentence.hasSuffix(".") { sentence += "." }
        if let reason = sipCode(in: detail).flatMap(sipReason) {
            sentence += " \(reason)"
        }
        return sentence
    }

    private static func sipCode(in message: String) -> Int? {
        guard let range = message.range(of: #"SIP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst(4))
    }

    private static func sipReason(_ code: Int) -> String? {
        switch code {
        case 404, 484: return "That number doesn't exist."
        case 408, 480: return "Nobody answered there."
        case 486, 600: return "That line is busy."
        case 603: return "The call was declined there."
        default: return nil
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
    /// A new call, with room for it: no call, or one connected call (call
    /// waiting).
    case accept
    /// A call already ringing or in progress, or one that has ended.
    case duplicate
    /// A different call while two are in progress, or while one is still
    /// ringing or being set up. Answering a waiting call next to one that
    /// has not connected cannot hold that one, and when it connects the core
    /// would hold the call the user is talking on.
    case busy

    static func decide(callToken: String, calls: [ActiveCall], finishedTokens: RecentTokens) -> IncomingPushTriage {
        if calls.contains(where: { $0.callToken == callToken }) || finishedTokens.contains(callToken) {
            return .duplicate
        }
        return CallRegistry.hasRoom(for: calls) ? .accept : .busy
    }
}

// MARK: - Call Registry

/// The calls this phone has, oldest first, and the rules that pick which one
/// the call screen shows and what hold and transfer can do with them.
struct CallRegistry {
    /// The core refuses a third live call.
    static let maximumCalls = 2

    private(set) var calls: [ActiveCall] = []

    var isEmpty: Bool { calls.isEmpty }
    var count: Int { calls.count }

    subscript(uuid: UUID) -> ActiveCall? {
        calls.first { $0.uuid == uuid }
    }

    /// The call an engine event belongs to.
    func call(engineCallId: String) -> ActiveCall? {
        calls.first { $0.engineCallId == engineCallId }
    }

    func call(callToken: String) -> ActiveCall? {
        calls.first { $0.callToken == callToken }
    }

    mutating func add(_ call: ActiveCall) {
        guard self[call.uuid] == nil else { return }
        calls.append(call)
    }

    /// Change the call `uuid`, if it is still here.
    mutating func modify(uuid: UUID, _ change: (inout ActiveCall) -> Void) {
        guard let index = calls.firstIndex(where: { $0.uuid == uuid }) else { return }
        change(&calls[index])
    }

    @discardableResult
    mutating func remove(uuid: UUID) -> ActiveCall? {
        guard let index = calls.firstIndex(where: { $0.uuid == uuid }) else { return nil }
        return calls.remove(at: index)
    }

    /// The connected call that is off hold, if any.
    var talking: ActiveCall? {
        calls.first { $0.isConnected && !$0.isOnHold }
    }

    /// The call the call screen shows: one that needs answering, then one
    /// being set up, then the call being talked on, then the newest (a held
    /// call left on its own, which the screen offers to resume).
    var foreground: ActiveCall? {
        calls.last { $0.state == .incoming }
            ?? calls.last { $0.state == .connecting }
            ?? talking
            ?? calls.last
    }

    /// Every call but the foreground one, oldest first.
    var background: [ActiveCall] {
        let foregroundId = foreground?.uuid
        return calls.filter { $0.uuid != foregroundId }
    }

    /// Whether `swapCalls` can hold `active` and resume `held`: the first is
    /// the talking call and the second a different connected call on hold.
    /// With both held there is nothing to swap; the screen offers Resume.
    func canSwap(active: UUID, held: UUID) -> Bool {
        guard let talking = talking, talking.uuid == active,
              let other = self[held], other.uuid != active else { return false }
        return other.isConnected && other.isOnHold
    }

    /// Room for another call, and none still ringing or being set up.
    var canAddCall: Bool { Self.hasRoom(for: calls) }

    static func hasRoom(for calls: [ActiveCall]) -> Bool {
        calls.count < maximumCalls
            && !calls.contains { $0.state == .incoming || $0.state == .connecting }
    }

    /// The calls an attended transfer would join: the PBX can only connect
    /// an incoming call this phone answered (`transferred`) to an outgoing
    /// call it placed (`consult`). nil unless there are exactly two connected
    /// calls, one of each.
    var attendedTransferPair: (transferred: ActiveCall, consult: ActiveCall)? {
        let connected = calls.filter { $0.isConnected && $0.callId != nil }
        guard connected.count == 2,
              let inbound = connected.first(where: { $0.direction == .inbound }),
              let outbound = connected.first(where: { $0.direction == .outbound }) else { return nil }
        return (inbound, outbound)
    }

    /// What the engine must do for a `CXSetHeldCallAction`.
    enum HoldRequest: Equatable {
        /// Nothing: the call is already in that state (the action reports a
        /// hold the core made).
        case none
        /// Refuse the action: the call is unknown or has not connected, and
        /// the core holds only connected calls. Fulfilling it would show a
        /// ringing call as held in CallKit.
        case notConnected
        case hold(callId: String)
        case resume(callId: String)
        /// Resume `heldCallId` while `activeCallId` is talking.
        case swap(activeCallId: String, heldCallId: String)
    }

    static func holdRequest(for uuid: UUID, onHold: Bool, in registry: CallRegistry) -> HoldRequest {
        guard let call = registry[uuid], call.isConnected, let callId = call.callId else {
            return .notConnected
        }
        guard call.isOnHold != onHold else { return .none }
        if onHold { return .hold(callId: callId) }
        if let talking = registry.talking, talking.uuid != uuid, let talkingId = talking.callId {
            return .swap(activeCallId: talkingId, heldCallId: callId)
        }
        return .resume(callId: callId)
    }

    struct HoldChange: Equatable {
        let uuid: UUID
        let onHold: Bool
    }

    /// The hold changes CallKit has not been told about, given the calls it
    /// believes are held: holds first, so CallKit never sees two calls
    /// talking at once. Only connected calls are on hold in the core.
    static func holdChanges(calls: [ActiveCall], callKitHeld: Set<UUID>) -> [HoldChange] {
        let connected = calls.filter { $0.isConnected }
        let holds = connected.filter { $0.isOnHold && !callKitHeld.contains($0.uuid) }
        let resumes = connected.filter { !$0.isOnHold && callKitHeld.contains($0.uuid) }
        return holds.map { HoldChange(uuid: $0.uuid, onHold: true) }
            + resumes.map { HoldChange(uuid: $0.uuid, onHold: false) }
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
