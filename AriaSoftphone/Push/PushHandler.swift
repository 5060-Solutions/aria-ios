import Foundation
import PushKit

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

        // Do not log the VoIP push token.
        guard token != pushToken else { return }
        pushToken = token

        // Persist it and tell the gateway, so pushes follow the new token.
        SipEngineManager.shared.updatePushToken(token)
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

        // Do not log the full push payload — it contains the call token.
        print("Received VoIP push")

        // Parse the push payload
        guard let data = payload.dictionaryPayload as? [String: Any],
              let callToken = data["call_token"] as? String,
              let callerUri = data["caller_uri"] as? String,
              let gatewayUrl = data["gateway_url"] as? String else {
            print("Invalid VoIP push payload")
            // MUST report a call to CallKit even on failure (iOS 13+)
            CallManager.shared.reportAndEndInvalidPush(completion: completion)
            return
        }

        let callerName = data["caller_name"] as? String

        let pushPayload = PushCallPayload(
            callToken: callToken,
            callerUri: callerUri,
            callerName: callerName,
            gatewayUrl: gatewayUrl
        )

        // Report incoming call to CallKit — synchronously, before any async
        // work, as PushKit requires.
        let uuid = UUID()
        CallManager.shared.reportPushIncomingCall(
            uuid: uuid,
            callToken: callToken,
            callerUri: callerUri,
            callerName: callerName
        ) { error in
            guard error == nil else {
                completion()
                return
            }

            // Fetch the full call offer from the gateway. On a cold launch
            // the engine does not exist yet, so build and register it first —
            // only after CallKit has the call, as PushKit requires.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try SipEngineManager.shared.ensureReady()
                    let offer = try SipEngineManager.shared.handlePushNotification(
                        payload: pushPayload
                    )
                    DispatchQueue.main.async {
                        CallManager.shared.offerReceived(offer)
                        completion()
                    }
                } catch {
                    print("Failed to handle push notification: \(error)")
                    DispatchQueue.main.async {
                        CallManager.shared.failIncomingCall(uuid: uuid)
                        completion()
                    }
                }
            }
        }
    }
}
