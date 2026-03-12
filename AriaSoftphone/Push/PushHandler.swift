import Foundation
import PushKit
import CallKit

/// Handles VoIP push notifications via PushKit.
///
/// When a push arrives, iOS wakes the app and we must immediately
/// report an incoming call to CallKit (iOS 13+ requirement).
class PushHandler: NSObject, PKPushRegistryDelegate {
    static let shared = PushHandler()

    /// The current VoIP push token (hex-encoded).
    @Published var pushToken: String?

    private override init() {
        super.init()
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }

        let token = pushCredentials.token
            .map { String(format: "%02x", $0) }
            .joined()

        print("VoIP push token: \(token)")
        pushToken = token

        // If already registered, update the token with the gateway
        if SipEngineManager.shared.deviceId != nil {
            // Token refresh will be handled on next register call
        }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        print("VoIP push token invalidated")
        pushToken = nil
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        print("Received VoIP push: \(payload.dictionaryPayload)")

        // Parse the push payload
        guard let data = payload.dictionaryPayload as? [String: Any],
              let callToken = data["call_token"] as? String,
              let callerUri = data["caller_uri"] as? String,
              let gatewayUrl = data["gateway_url"] as? String else {
            print("Invalid VoIP push payload")
            // MUST report a call to CallKit even on failure (iOS 13+)
            let uuid = UUID()
            CallManager.shared.reportIncomingCall(
                uuid: uuid,
                callerUri: "Unknown",
                callerName: nil
            ) { _ in
                // Immediately cancel the fake call
                let provider = CXProvider(configuration: CXProviderConfiguration())
                provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                completion()
            }
            return
        }

        let callerName = data["caller_name"] as? String

        let pushPayload = PushCallPayload(
            callToken: callToken,
            callerUri: callerUri,
            callerName: callerName,
            gatewayUrl: gatewayUrl
        )

        // Report incoming call to CallKit
        let uuid = UUID()
        CallManager.shared.reportIncomingCall(
            uuid: uuid,
            callerUri: callerUri,
            callerName: callerName
        ) { error in
            guard error == nil else {
                completion()
                return
            }

            // Fetch the full call offer from the gateway
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let offer = try SipEngineManager.shared.handlePushNotification(
                        payload: pushPayload
                    )
                    DispatchQueue.main.async {
                        CallManager.shared.incomingOffer = offer
                        CallManager.shared.activeCall = ActiveCall(
                            uuid: uuid,
                            callToken: callToken,
                            remoteUri: callerUri,
                            remoteName: callerName,
                            direction: .inbound,
                            state: .incoming
                        )
                    }
                } catch {
                    print("Failed to handle push notification: \(error)")
                }
                completion()
            }
        }
    }
}
