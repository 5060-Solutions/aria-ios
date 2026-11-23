import Foundation

/// The signed-in extension's voicemail, from the Aria PBX REST API.
///
/// Talks to the mailbox through a `VoicemailBackend`: the PBX in the app,
/// canned messages in fixture mode.
@MainActor
final class VoicemailService: ObservableObject {
    static let shared = VoicemailService(backend: VoicemailBackends.current)

    typealias Message = PbxApiClient.VoicemailMessage

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// False when the extension has no mailbox.
    @Published private(set) var hasMailbox = true

    private let backend: VoicemailBackend

    init(backend: VoicemailBackend) {
        self.backend = backend
    }

    var unreadCount: Int {
        messages.filter { !$0.read }.count
    }

    // MARK: - Operations

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await backend.messages()
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
            try await backend.markRead(messageId: message.id)
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].read = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ message: Message) async {
        do {
            try await backend.delete(messageId: message.id)
            messages.removeAll { $0.id == message.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Download a message's audio to a temporary file for playback.
    func audioFile(for message: Message) async throws -> URL {
        try await backend.audioFile(messageId: message.id)
    }

    /// Forget the mailbox, e.g. on sign-out.
    func reset() {
        messages = []
        backend.reset()
        hasMailbox = true
        errorMessage = nil
    }
}

// MARK: - Backend

/// Where voicemail comes from. `VoicemailService` owns the state; a backend
/// only fetches and changes messages.
protocol VoicemailBackend: AnyObject {
    /// The mailbox's messages, or nil when the extension has no mailbox.
    func messages() async throws -> [VoicemailService.Message]?
    func markRead(messageId: String) async throws
    func delete(messageId: String) async throws
    /// A local file with the message's audio, for playback.
    func audioFile(messageId: String) async throws -> URL
    /// Forget anything cached for the signed-in account.
    func reset()
}

enum VoicemailBackends {
    /// Fixtures in fixture mode, else the PBX.
    static var current: VoicemailBackend {
        #if DEBUG
        if FixtureMode.isActive { return FixtureVoicemailBackend() }
        #endif
        return PbxVoicemailBackend()
    }
}

/// The Aria PBX REST API. Authenticates with the extension-login JWT
/// `AccountSession` stores, through `PbxSession`, which logs in again and
/// retries once when it has expired.
final class PbxVoicemailBackend: VoicemailBackend {
    private var boxId: String?

    func messages() async throws -> [VoicemailService.Message]? {
        try await authorized { client, jwt -> [VoicemailService.Message]? in
            guard let boxId = try await self.resolveBox(client: client, jwt: jwt) else {
                return nil
            }
            return try await client.voicemailMessages(jwt: jwt, boxId: boxId)
        }
    }

    func markRead(messageId: String) async throws {
        try await authorized { client, jwt in
            try await client.markVoicemailRead(jwt: jwt, messageId: messageId)
        }
    }

    func delete(messageId: String) async throws {
        try await authorized { client, jwt in
            try await client.deleteVoicemail(jwt: jwt, messageId: messageId)
        }
    }

    func audioFile(messageId: String) async throws -> URL {
        try await authorized { client, jwt in
            try await client.downloadVoicemailAudio(jwt: jwt, messageId: messageId)
        }
    }

    func reset() {
        boxId = nil
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
        let apiUrl = AccountSettings.load().apiUrl
        guard !apiUrl.isEmpty, KeychainStore.get(KeychainStore.jwtKey) != nil else {
            throw VoicemailError.notSignedIn
        }
        let client = PbxApiClient(baseUrl: apiUrl)
        return try await PbxSession.shared.authorized { jwt in
            try await operation(client, jwt)
        }
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
