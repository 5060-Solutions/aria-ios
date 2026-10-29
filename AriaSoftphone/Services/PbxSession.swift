import Foundation

/// The PBX session JWT, for work that runs without the user present:
/// voicemail, gateway-token renewal, push-token updates.
///
/// `authorized` runs an API call with the stored JWT. When the PBX answers
/// 401 the JWT has expired, so it logs in again with the stored extension
/// credentials and retries the call once. Concurrent callers that all hit a
/// 401 share one login.
actor PbxSession {
    struct Dependencies {
        /// The stored JWT, if any.
        var storedToken: () -> String?
        /// Log in to the PBX, persist the new JWT, and return it.
        var login: () async throws -> String
    }

    static let shared = PbxSession(dependencies: .live)

    private let dependencies: Dependencies
    private var loginInFlight: Task<String, Error>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Run `operation` with a valid JWT, logging in again once on a 401.
    func authorized<T>(_ operation: (String) async throws -> T) async throws -> T {
        let jwt: String
        if let stored = dependencies.storedToken(), !stored.isEmpty {
            jwt = stored
        } else {
            jwt = try await freshToken()
        }

        do {
            return try await operation(jwt)
        } catch where Self.isUnauthorized(error) {
            return try await operation(try await freshToken())
        }
    }

    /// Log in again. A login already under way is joined, not repeated.
    func freshToken() async throws -> String {
        if let inFlight = loginInFlight {
            return try await inFlight.value
        }
        let login = dependencies.login
        let task = Task { try await login() }
        loginInFlight = task
        defer { loginInFlight = nil }
        return try await task.value
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        if case PbxApiClient.ApiError.httpError(let code, _) = error {
            return code == 401
        }
        return false
    }
}

extension PbxSession.Dependencies {
    static let live = PbxSession.Dependencies(
        storedToken: { KeychainStore.get(KeychainStore.jwtKey) },
        login: {
            let account = AccountSettings.load()
            guard !account.apiUrl.isEmpty, account.isProvisioned,
                  let password = KeychainStore.get(KeychainStore.sipPasswordKey),
                  !password.isEmpty else {
                throw PbxSessionError.notSignedIn
            }
            let result = try await PbxApiClient(baseUrl: account.apiUrl).extensionLogin(
                extensionNumber: account.username,
                password: password,
                tenantDomain: account.domain
            )
            KeychainStore.set(result.jwt, forKey: KeychainStore.jwtKey)
            return result.jwt
        }
    )
}

enum PbxSessionError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in. Scan your provisioning QR code to sign in."
        }
    }
}
