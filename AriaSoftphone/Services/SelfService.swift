import Foundation

/// The signed-in extension's own PBX settings: Do Not Disturb, call
/// forwarding, and the server's record of its calls.
///
/// Talks to the PBX through a `SelfServiceBackend`: the PBX in the app,
/// canned data in fixture mode.
@MainActor
final class SelfService: ObservableObject {
    static let shared = SelfService(backend: SelfServiceBackends.current)

    typealias Forward = PbxApiClient.CallForward
    typealias ForwardType = PbxApiClient.ForwardType

    /// Nil until loaded.
    @Published private(set) var doNotDisturb: Bool?
    @Published private(set) var forwards: [Forward] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let backend: SelfServiceBackend

    init(backend: SelfServiceBackend) {
        self.backend = backend
    }

    /// The forward of `type`, if one is set up (enabled or not).
    func forward(_ type: ForwardType) -> Forward? {
        forwards.first { $0.forwardType == type }
    }

    /// An "always" forward is on: every call goes elsewhere. The status chip
    /// shows an arrow for it.
    var isForwardingAll: Bool {
        forward(.unconditional)?.enabled == true
    }

    // MARK: - Loading

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let dnd = backend.doNotDisturb()
            async let list = backend.forwards()
            doNotDisturb = try await dnd
            forwards = try await list
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Do Not Disturb

    /// Turn DND on or off. Shown at once; put back if the PBX refuses.
    func setDoNotDisturb(_ enabled: Bool) async {
        let previous = doNotDisturb
        doNotDisturb = enabled
        do {
            try await backend.setDoNotDisturb(enabled)
            errorMessage = nil
        } catch {
            doNotDisturb = previous
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Forwarding

    /// Create or update the forward of `type`. Returns false, with
    /// `errorMessage` set to the PBX's reason, when it was refused.
    @discardableResult
    func saveForward(type: ForwardType, destination: String, ringTimeoutSecs: Int, enabled: Bool) async -> Bool {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else {
            errorMessage = String(localized: "Enter a number or extension to forward to.")
            return false
        }
        guard !EmergencyDialer.isEmergency(destination) else {
            errorMessage = String(localized: "Calls can't be forwarded to an emergency number.")
            return false
        }
        let timeout = min(max(ringTimeoutSecs, 5), 300)
        do {
            let saved: Forward
            if let existing = forward(type) {
                saved = try await backend.updateForward(
                    id: existing.id, destination: destination, ringTimeoutSecs: timeout, enabled: enabled
                )
            } else {
                saved = try await backend.createForward(
                    type: type, destination: destination, ringTimeoutSecs: timeout, enabled: enabled
                )
            }
            forwards.removeAll { $0.forwardType == type }
            forwards.append(saved)
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    /// Switch an existing forward on or off, keeping its destination.
    func setForwardEnabled(_ type: ForwardType, _ enabled: Bool) async {
        guard let existing = forward(type) else { return }
        await saveForward(type: type, destination: existing.destination,
                          ringTimeoutSecs: existing.ringTimeoutSecs, enabled: enabled)
    }

    func removeForward(_ type: ForwardType) async {
        guard let existing = forward(type) else { return }
        do {
            try await backend.deleteForward(id: existing.id)
            forwards.removeAll { $0.id == existing.id }
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Server call history

    /// Fetch the PBX's records of this extension's calls and merge them into
    /// local history, skipping calls history already has. Quiet on failure:
    /// local history stands on its own.
    func syncCallHistory(into store: CallHistoryStore = .shared) async {
        do {
            let calls = try await backend.callRecords(limit: 100)
            store.importServerCalls(calls, ownExtension: AccountSettings.load().username)
        } catch {
            print("Server call history unavailable: \(error)")
        }
    }

    func reset() {
        doNotDisturb = nil
        forwards = []
        errorMessage = nil
        backend.reset()
    }

    /// The PBX's sentence for a refused forward (422/409 carry one).
    nonisolated static func describe(_ error: Error) -> String {
        if case PbxApiClient.ApiError.httpError(let code, let message) = error {
            if code == 409 {
                return String(localized: "A forward of this kind already exists.")
            }
            if !message.isEmpty, !message.hasPrefix("{") {
                return message
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Backend

protocol SelfServiceBackend: AnyObject {
    func doNotDisturb() async throws -> Bool
    func setDoNotDisturb(_ enabled: Bool) async throws
    func forwards() async throws -> [PbxApiClient.CallForward]
    func createForward(type: PbxApiClient.ForwardType, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward
    func updateForward(id: String, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward
    func deleteForward(id: String) async throws
    func callRecords(limit: Int) async throws -> [PbxApiClient.ServerCall]
    /// Forget anything cached for the signed-out account.
    func reset()
}

enum SelfServiceBackends {
    /// Fixtures in fixture mode, else the PBX.
    static var current: SelfServiceBackend {
        #if DEBUG
        if FixtureMode.isActive { return FixtureSelfServiceBackend() }
        #endif
        return PbxSelfServiceBackend()
    }
}

/// The Aria PBX REST API, with the stored extension-login JWT through
/// `PbxSession` (which logs in again once on a 401).
final class PbxSelfServiceBackend: SelfServiceBackend {
    private var extensionId: String?
    private let lock = NSLock()

    func doNotDisturb() async throws -> Bool {
        try await withExtension { client, jwt, ext in
            try await client.features(jwt: jwt, extensionId: ext).doNotDisturb
        }
    }

    func setDoNotDisturb(_ enabled: Bool) async throws {
        try await withExtension { client, jwt, ext in
            try await client.setDoNotDisturb(jwt: jwt, extensionId: ext, enabled: enabled)
        }
    }

    func forwards() async throws -> [PbxApiClient.CallForward] {
        try await withExtension { client, jwt, ext in
            try await client.forwards(jwt: jwt, extensionId: ext)
        }
    }

    func createForward(type: PbxApiClient.ForwardType, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward {
        try await withExtension { client, jwt, ext in
            try await client.createForward(jwt: jwt, extensionId: ext, type: type, destination: destination,
                                           ringTimeoutSecs: ringTimeoutSecs, enabled: enabled)
        }
    }

    func updateForward(id: String, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward {
        try await withExtension { client, jwt, _ in
            try await client.updateForward(jwt: jwt, id: id, destination: destination,
                                           ringTimeoutSecs: ringTimeoutSecs, enabled: enabled)
        }
    }

    func deleteForward(id: String) async throws {
        try await withExtension { client, jwt, _ in
            try await client.deleteForward(jwt: jwt, id: id)
        }
    }

    func callRecords(limit: Int) async throws -> [PbxApiClient.ServerCall] {
        try await withExtension { client, jwt, ext in
            try await client.callRecords(jwt: jwt, extensionId: ext, limit: limit)
        }
    }

    func reset() {
        lock.lock()
        extensionId = nil
        lock.unlock()
    }

    /// Run `operation` with the API client, a valid JWT and this extension's
    /// id: `/me`'s acting extension, else the id stored at login.
    private func withExtension<T>(
        _ operation: @escaping (PbxApiClient, String, String) async throws -> T
    ) async throws -> T {
        let apiUrl = AccountSettings.load().apiUrl
        guard !apiUrl.isEmpty, KeychainStore.get(KeychainStore.jwtKey) != nil else {
            throw PbxSessionError.notSignedIn
        }
        let client = PbxApiClient(baseUrl: apiUrl)
        return try await PbxSession.shared.authorized { jwt in
            let ext = try await self.resolveExtension(client: client, jwt: jwt)
            return try await operation(client, jwt, ext)
        }
    }

    private func resolveExtension(client: PbxApiClient, jwt: String) async throws -> String {
        lock.lock()
        let cached = extensionId
        lock.unlock()
        if let cached = cached { return cached }
        var ext = (try? await client.identity(jwt: jwt))?.actingExtension ?? ""
        if ext.isEmpty {
            ext = UserDefaults.standard.string(forKey: AccountSettings.Key.extensionId) ?? ""
        }
        guard !ext.isEmpty else { throw PbxSessionError.notSignedIn }
        lock.lock()
        extensionId = ext
        lock.unlock()
        return ext
    }
}
