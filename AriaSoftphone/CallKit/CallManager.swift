import Foundation
import CallKit
import AVFoundation

/// Manages CallKit integration and call lifecycle.
class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published var activeCall: ActiveCall?
    @Published var incomingOffer: CallOffer?

    private let provider: CXProvider
    private let callController = CXCallController()

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.iconTemplateImageData = nil // Set app icon data here

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: DispatchQueue.main)
    }

    // MARK: - Incoming Call (from push notification)

    /// Report an incoming call to CallKit (triggered by PushKit).
    func reportIncomingCall(
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
            completion(error)
        }
    }

    /// Handle incoming call offer from the Rust core.
    func handleIncomingCall(offer: CallOffer) {
        let uuid = UUID()
        incomingOffer = offer

        reportIncomingCall(
            uuid: uuid,
            callerUri: offer.callerUri,
            callerName: offer.callerName
        ) { [weak self] error in
            guard error == nil else { return }
            self?.activeCall = ActiveCall(
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
        let uuid = UUID()
        let handle = CXHandle(type: .generic, value: uri)
        let startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.isVideo = false

        let transaction = CXTransaction(action: startCallAction)
        callController.request(transaction) { error in
            if let error = error {
                print("Failed to start call: \(error)")
                return
            }

            DispatchQueue.main.async {
                self.activeCall = ActiveCall(
                    uuid: uuid,
                    callToken: nil,
                    remoteUri: uri,
                    remoteName: nil,
                    direction: .outbound,
                    state: .connecting
                )
            }
        }
    }

    // MARK: - Call Actions

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

    /// Handle remote hangup detected by polling.
    func handleRemoteHangup() {
        guard let call = activeCall else { return }
        provider.reportCall(with: call.uuid, endedAt: Date(), reason: .remoteEnded)
        activeCall = nil
        incomingOffer = nil
    }

    // MARK: - State Updates

    func updateCallState(info: CallInfo) {
        guard var call = activeCall else { return }

        switch info.state {
        case .connected:
            call.state = .connected
            call.connectedAt = Date()
            provider.reportOutgoingCall(with: call.uuid, connectedAt: call.connectedAt)
        case .ended:
            call.state = .ended
            provider.reportCall(with: call.uuid, endedAt: Date(), reason: .remoteEnded)
            activeCall = nil
            return
        case .onHold:
            call.state = .onHold
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
        // Clean up all calls
        activeCall = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Configure audio session for outgoing call
        configureAudioSession()

        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())

        // Make the call via Rust engine on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let uri = action.handle.value
                // Credentials are loaded from the registered SIP account
                let credentials = SipCredentials(
                    username: UserDefaults.standard.string(forKey: "sipUsername") ?? "",
                    password: KeychainStore.get(KeychainStore.sipPasswordKey) ?? "",
                    domain: UserDefaults.standard.string(forKey: "sipDomain") ?? "",
                    registrar: nil,
                    transport: UserDefaults.standard.string(forKey: "sipTransport") ?? "udp",
                    port: UInt16(UserDefaults.standard.integer(forKey: "sipPort")),
                    authUsername: nil,
                    displayName: UserDefaults.standard.string(forKey: "sipDisplayName") ?? ""
                )
                let info = try SipEngineManager.shared.makeCall(
                    uri: uri,
                    credentials: credentials
                )
                DispatchQueue.main.async {
                    self.activeCall?.callId = info.callId
                    self.activeCall?.state = .connecting
                }
            } catch {
                print("Failed to make outgoing call: \(error)")
            }
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSession()

        // Accept the incoming call via Rust engine
        guard let offer = incomingOffer else {
            action.fail()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try SipEngineManager.shared.acceptCall(callToken: offer.callToken)
                DispatchQueue.main.async {
                    self.activeCall?.state = .connected
                    self.activeCall?.connectedAt = Date()
                    self.activeCall?.callId = info.callId
                    self.incomingOffer = nil
                    action.fulfill()
                }
            } catch {
                print("Failed to accept call: \(error)")
                action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // Hang up via Rust engine
        if let callId = activeCall?.callId {
            try? SipEngineManager.shared.hangup(callId: callId)
        } else if let callToken = activeCall?.callToken {
            try? SipEngineManager.shared.rejectCall(callToken: callToken)
        }

        activeCall = nil
        incomingOffer = nil
        action.fulfill()
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
        // Audio session activated by CallKit — RTP can now use hardware audio
        print("Audio session activated")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("Audio session deactivated")
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .allowBluetoothA2DP,
                .defaultToSpeaker,
            ])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.02) // 20ms
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
}

// MARK: - Call Model

struct ActiveCall: Identifiable {
    let id = UUID()
    let uuid: UUID
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
