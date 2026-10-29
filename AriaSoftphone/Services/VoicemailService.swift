import Foundation

/// The signed-in extension's voicemail, from the Aria PBX REST API.
///
/// Authenticates with the extension-login JWT `AccountSession` stores. When
/// the API answers 401 the JWT has expired, so the service logs in again with
/// the stored SIP credentials — exactly what login did — and retries once.
@MainActor
final class VoicemailService: ObservableObject {
    static let shared = VoicemailService()

    typealias Message = PbxApiClient.VoicemailMessage

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// False when the extension has no mailbox.
    @Published private(set) var hasMailbox = true

    private var boxId: String?

    var unreadCount: Int {
        messages.filter { !$0.read }.count
    }

    // MARK: - Operations

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await authorized { client, jwt -> [Message]? in
                guard let boxId = try await self.resolveBox(client: client, jwt: jwt) else {
                    return nil
                }
                return try await client.voicemailMessages(jwt: jwt, boxId: boxId)
            }
            hasMailbox = loaded != nil
            messages = (loaded ?? []).sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ message: Message) async {
        guard !message.read else { return }
        do {
            try await authorized { client, jwt in
                try await client.markVoicemailRead(jwt: jwt, messageId: message.id)
            }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].read = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ message: Message) async {
        do {
            try await authorized { client, jwt in
                try await client.deleteVoicemail(jwt: jwt, messageId: message.id)
            }
            messages.removeAll { $0.id == message.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Download a message's audio to a temporary file for playback.
    func audioFile(for message: Message) async throws -> URL {
        try await authorized { client, jwt in
            try await client.downloadVoicemailAudio(jwt: jwt, messageId: message.id)
        }
    }

    /// Forget the mailbox, e.g. on sign-out.
    func reset() {
        messages = []
        boxId = nil
        hasMailbox = true
        errorMessage = nil
    }

    // MARK: - Auth

    /// The mailbox for the extension this credential acts as. `/me` is the
    /// authoritative answer; the id stored at login is the fallback.
    private func resolveBox(client: PbxApiClient, jwt: String) async throws -> String? {
        if let boxId = boxId { return boxId }

        var extensionId = (try? await client.identity(jwt: jwt))?.actingExtension ?? ""
        if extensionId.isEmpty {
            extensionId = UserDefaults.standard.string(forKey: AccountSettings.Key.extensionId) ?? ""
        }
        guard !extensionId.isEmpty else { throw VoicemailError.notSignedIn }

        let box = try await client.voicemailBox(jwt: jwt, extensionId: extensionId)
        boxId = box?.id
        return box?.id
    }

    private func authorized<T>(
        _ operation: (PbxApiClient, String) async throws -> T
    ) async throws -> T {
        let account = AccountSettings.load()
        guard !account.apiUrl.isEmpty, let jwt = KeychainStore.get(KeychainStore.jwtKey) else {
            throw VoicemailError.notSignedIn
        }
        let client = PbxApiClient(baseUrl: account.apiUrl)

        do {
            return try await operation(client, jwt)
        } catch PbxApiClient.ApiError.httpError(let code, _) where code == 401 {
            let fresh = try await relogin(client: client, account: account)
            return try await operation(client, fresh)
        }
    }

    private func relogin(client: PbxApiClient, account: AccountSettings) async throws -> String {
        guard let password = KeychainStore.get(KeychainStore.sipPasswordKey), !password.isEmpty else {
            throw VoicemailError.notSignedIn
        }
        let result = try await client.extensionLogin(
            extensionNumber: account.username,
            password: password,
            tenantDomain: account.domain
        )
        KeychainStore.set(result.jwt, forKey: KeychainStore.jwtKey)
        return result.jwt
    }
}

enum VoicemailError: LocalizedError {
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to see your voicemail."
        }
    }
}
