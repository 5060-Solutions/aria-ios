import Foundation

/// Fetches a new push-gateway token from the PBX and hands it to the engine.
///
/// The core no longer mints gateway tokens: the PBX issues them, and when
/// one is rejected the engine either throws `AuthenticationError` or calls
/// `onAuthRequired()`. Both land here. Several triggers can fire together —
/// a status poll and a user action, say — so renewal is single-flight: a
/// request made while one is running waits for it and gets the same token.
actor GatewayTokenRenewer {
    struct Dependencies {
        /// Fetch a token from the PBX (re-logging in there if needed).
        var fetchToken: () async throws -> String
        /// Persist the token and give it to the engine.
        var apply: (String) -> Void
    }

    static let shared = GatewayTokenRenewer(dependencies: .live)

    private let dependencies: Dependencies
    private var inFlight: Task<String, Error>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    @discardableResult
    func renew() async throws -> String {
        if let inFlight = inFlight {
            return try await inFlight.value
        }
        let dependencies = self.dependencies
        let task = Task {
            let token = try await dependencies.fetchToken()
            dependencies.apply(token)
            return token
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// `renew()` for the engine's synchronous call paths. Blocks the calling
    /// thread, so never call it on the main queue.
    nonisolated func renewBlocking() throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let outcome = BlockingOutcome()
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                try await self.renew()
                outcome.set(nil)
            } catch {
                outcome.set(error)
            }
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw error }
    }

    /// Renew without waiting, e.g. from `onAuthRequired`.
    nonisolated func renewInBackground() {
        Task {
            do {
                try await self.renew()
            } catch {
                print("Gateway token renewal failed: \(error)")
            }
        }
    }
}

/// Carries a result out of a `Task` to a thread blocked on a semaphore.
private final class BlockingOutcome {
    private let lock = NSLock()
    private var _error: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _error
    }

    func set(_ error: Error?) {
        lock.lock()
        _error = error
        lock.unlock()
    }
}

extension GatewayTokenRenewer.Dependencies {
    static let live = GatewayTokenRenewer.Dependencies(
        fetchToken: {
            let defaults = UserDefaults.standard
            let apiUrl = defaults.string(forKey: AccountSettings.Key.apiUrl) ?? ""
            guard !apiUrl.isEmpty,
                  let deviceId = defaults.string(forKey: AccountSettings.Key.pbxDeviceId),
                  !deviceId.isEmpty else {
                throw PbxSessionError.notSignedIn
            }
            return try await PbxSession.shared.authorized { jwt in
                try await PbxApiClient(baseUrl: apiUrl).renewGatewayToken(jwt: jwt, deviceId: deviceId)
            }
        },
        apply: { token in
            KeychainStore.set(token, forKey: KeychainStore.gatewayTokenKey)
            SipEngineManager.shared.setGatewayToken(token)
        }
    )
}
