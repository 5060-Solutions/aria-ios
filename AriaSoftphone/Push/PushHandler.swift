import Foundation
import PushKit

/// Handles VoIP push notifications via PushKit.
///
/// When a push arrives, iOS wakes the app and we must immediately
/// report an incoming call to CallKit (iOS 13+ requirement).
/// Whether a push's `gateway_url` names the gateway this device registered
/// with: HTTPS, and the same host and port as the configured URL.
func isTrustedGatewayURL(_ pushed: String, configured: String) -> Bool {
    guard let pushedURL = URLComponents(string: pushed),
          let configuredURL = URLComponents(string: configured),
          pushedURL.scheme?.lowercased() == "https",
          configuredURL.scheme?.lowercased() == "https",
          let pushedHost = pushedURL.host?.lowercased(), !pushedHost.isEmpty,
          let configuredHost = configuredURL.host?.lowercased(), !configuredHost.isEmpty,
          pushedURL.user == nil, pushedURL.password == nil else {
        return false
    }
    return pushedHost == configuredHost && (pushedURL.port ?? 443) == (configuredURL.port ?? 443)
}

/// The call a VoIP push announces.
struct IncomingPush: Equatable {
    let callToken: String
    let callerUri: String
    let callerName: String?
    let gatewayUrl: String

    enum Rejection: Error, Equatable {
        /// No call token: there is no call to fetch.
        case missingCallToken
        /// Not signed in, so there is no gateway to fetch it from.
        case noConfiguredGateway
        /// The payload names a gateway other than the one registered with.
        case untrustedGateway
    }

    /// Parse a push payload.
    ///
    /// The push gateway sends camelCase keys (`callToken`, `callerUri`,
    /// `callerName`) and no gateway URL; snake_case is accepted as a fallback,
    /// as the Android client does. A missing gateway URL means the configured
    /// gateway. A payload that does name one must name the configured one —
    /// anything else is not fetched.
    static func parse(_ payload: [AnyHashable: Any], configuredGateway: String) -> Result<IncomingPush, Rejection> {
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = payload[key] as? String, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        guard let callToken = string("callToken", "call_token") else {
            return .failure(.missingCallToken)
        }
        guard !configuredGateway.isEmpty else {
            return .failure(.noConfiguredGateway)
        }

        let gatewayUrl: String
        if let pushed = string("gatewayUrl", "gateway_url") {
            guard isTrustedGatewayURL(pushed, configured: configuredGateway) else {
                return .failure(.untrustedGateway)
            }
            gatewayUrl = pushed
        } else {
            gatewayUrl = configuredGateway
        }

        return .success(IncomingPush(
            callToken: callToken,
            callerUri: string("callerUri", "caller_uri") ?? "Unknown",
            callerName: string("callerName", "caller_name"),
            gatewayUrl: gatewayUrl
        ))
    }
}

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
        let configuredGateway = UserDefaults.standard.string(forKey: AccountSettings.Key.gatewayUrl) ?? ""
        let parsed: IncomingPush
        switch IncomingPush.parse(payload.dictionaryPayload, configuredGateway: configuredGateway) {
        case .success(let push):
            parsed = push
        case .failure(let rejection):
            print("Rejected VoIP push: \(rejection)")
            // MUST report a call to CallKit even on failure (iOS 13+)
            CallManager.shared.reportAndEndInvalidPush(completion: completion)
            return
        }

        let callToken = parsed.callToken
        let callerUri = parsed.callerUri
        let callerName = parsed.callerName
        let gatewayUrl = parsed.gatewayUrl

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
