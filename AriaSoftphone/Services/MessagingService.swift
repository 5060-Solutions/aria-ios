import Foundation
import UIKit

/// The PBX side of texting: what `MessagingService` needs from the REST API,
/// so tests can stand in for it.
protocol MessagingBackend: AnyObject {
    func inboxes() async throws -> [PbxApiClient.MessagingInbox]
    func conversations(didId: String) async throws -> [PbxApiClient.MessagingConversation]
    func thread(didId: String, number: String) async throws -> PbxApiClient.MessagingThread
    func send(didId: String, to: String, body: String, attachmentIds: [String],
              idempotencyKey: String) async throws -> PbxApiClient.MessagingMessage
    func upload(data: Data, filename: String, contentType: String) async throws -> PbxApiClient.MessagingAttachment
    func attachmentData(id: String) async throws -> Data
    /// A request for the event stream's upgrade, nil when not signed in.
    func eventStreamRequest() async throws -> URLRequest?
}

/// The Aria PBX REST API with the stored extension-login JWT, through
/// `PbxSession` (which logs in again once on a 401).
final class PbxMessagingBackend: MessagingBackend {
    private func withClient<T>(
        _ operation: @escaping (PbxApiClient, String, String) async throws -> T
    ) async throws -> T {
        let account = AccountSettings.load()
        let tenantId = UserDefaults.standard.string(forKey: AccountSettings.Key.tenantId) ?? ""
        guard !account.apiUrl.isEmpty, !tenantId.isEmpty, KeychainStore.get(KeychainStore.jwtKey) != nil else {
            throw PbxSessionError.notSignedIn
        }
        let client = PbxApiClient(baseUrl: account.apiUrl)
        return try await PbxSession.shared.authorized { jwt in
            try await operation(client, jwt, tenantId)
        }
    }

    func inboxes() async throws -> [PbxApiClient.MessagingInbox] {
        try await withClient { try await $0.messagingInboxes(jwt: $1, tenantId: $2) }
    }

    func conversations(didId: String) async throws -> [PbxApiClient.MessagingConversation] {
        try await withClient { try await $0.messagingConversations(jwt: $1, tenantId: $2, didId: didId) }
    }

    func thread(didId: String, number: String) async throws -> PbxApiClient.MessagingThread {
        try await withClient { try await $0.messagingThread(jwt: $1, tenantId: $2, didId: didId, number: number) }
    }

    func send(didId: String, to: String, body: String, attachmentIds: [String],
              idempotencyKey: String) async throws -> PbxApiClient.MessagingMessage {
        try await withClient {
            try await $0.sendMessage(jwt: $1, tenantId: $2, didId: didId, to: to, body: body,
                                     attachmentIds: attachmentIds, idempotencyKey: idempotencyKey)
        }
    }

    func upload(data: Data, filename: String, contentType: String) async throws -> PbxApiClient.MessagingAttachment {
        try await withClient {
            try await $0.uploadMessagingAttachment(jwt: $1, tenantId: $2, data: data, filename: filename,
                                                   contentType: contentType)
        }
    }

    func attachmentData(id: String) async throws -> Data {
        try await withClient { try await $0.messagingAttachmentData(jwt: $1, tenantId: $2, attachmentId: id) }
    }

    func eventStreamRequest() async throws -> URLRequest? {
        let apiUrl = AccountSettings.load().apiUrl
        guard !apiUrl.isEmpty, KeychainStore.get(KeychainStore.jwtKey) != nil else { return nil }
        let client = PbxApiClient(baseUrl: apiUrl)
        let jwt = try await PbxSession.shared.authorized { $0 }
        var request = URLRequest(url: try client.eventStreamURL())
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Business texting for the signed-in seat: its inboxes, their conversations
/// and the open thread, kept fresh while the app is in the foreground.
///
/// Live refresh is the API's WebSocket (`sms_received`, ids only) with a poll
/// every 15 s underneath it, so a dropped socket costs seconds, not messages.
@MainActor
final class MessagingService: ObservableObject {
    static let shared = MessagingService(backend: PbxMessagingBackend())
    static let pollInterval: TimeInterval = 15

    typealias Inbox = PbxApiClient.MessagingInbox
    typealias Conversation = PbxApiClient.MessagingConversation
    typealias Message = PbxApiClient.MessagingMessage
    typealias Thread = PbxApiClient.MessagingThread

    /// Where one conversation lives: the inbox's number and the other party.
    struct ThreadKey: Hashable {
        let didId: String
        let remoteNumber: String
    }

    @Published private(set) var inboxes: [Inbox] = []
    @Published private(set) var conversations: [String: [Conversation]] = [:]
    @Published private(set) var threads: [ThreadKey: Thread] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Set by a notification tap; the Messages tab opens it and clears it.
    @Published var pendingThread: ThreadKey?
    /// Conversations with text the person has not opened.
    @Published private(set) var unreadCount = 0

    private let backend: MessagingBackend
    private let readMarks: MessageReadMarks
    private var openThread: ThreadKey?
    private var timer: Timer?
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var isActive = false
    private var attachmentCache: [String: Data] = [:]

    init(backend: MessagingBackend, readMarks: MessageReadMarks = MessageReadMarks()) {
        self.backend = backend
        self.readMarks = readMarks
    }

    /// The seat has somewhere to text from.
    var hasInbox: Bool { !inboxes.isEmpty }
    /// Inboxes a message can be sent from.
    var sendableInboxes: [Inbox] { inboxes.filter(\.enabled) }

    func inbox(_ didId: String) -> Inbox? { inboxes.first { $0.didId == didId } }

    func isUnread(didId: String, _ conversation: Conversation) -> Bool {
        readMarks.isUnread(didId: didId, conversation: conversation)
    }

    // MARK: - Loading

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await backend.inboxes()
            inboxes = loaded
            var all: [String: [Conversation]] = [:]
            for inbox in loaded {
                all[inbox.didId] = try await backend.conversations(didId: inbox.didId)
            }
            conversations = all
            if let open = openThread {
                threads[open] = try await backend.thread(didId: open.didId, number: open.remoteNumber)
                markOpenThreadRead()
            }
            recount()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadThread(_ key: ThreadKey) async {
        do {
            threads[key] = try await backend.thread(didId: key.didId, number: key.remoteNumber)
            markRead(key)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A thread is on screen: keep it fresh and count it read.
    func opened(_ key: ThreadKey) {
        openThread = key
        markRead(key)
    }

    func closed(_ key: ThreadKey) {
        if openThread == key { openThread = nil }
    }

    private func markOpenThreadRead() {
        if let open = openThread { markRead(open) }
    }

    private func markRead(_ key: ThreadKey) {
        let latest = threads[key]?.messages.map(\.createdAt).max() ?? Date.distantPast
        readMarks.markRead(didId: key.didId, number: key.remoteNumber, at: max(Date(), latest))
        recount()
    }

    private func recount() {
        unreadCount = conversations.reduce(0) { total, entry in
            total + entry.value.filter { readMarks.isUnread(didId: entry.key, conversation: $0) }.count
        }
    }

    // MARK: - Sending

    /// Send a text, with an attachment if given. A retry that reuses `key`
    /// does not send twice; the caller makes a new key after any answer from
    /// the server and keeps it only across a request that got none.
    /// A message the carrier refused stays in the thread as `failed` with the
    /// server's reason, so the thread is reloaded either way.
    @discardableResult
    func send(didId: String, to: String, body: String, attachment: PbxApiClient.MessagingAttachment?,
              key: String) async throws -> Message {
        defer { Task { await self.refreshAfterSend(ThreadKey(didId: didId, remoteNumber: to)) } }
        return try await backend.send(didId: didId, to: to, body: body,
                                      attachmentIds: attachment.map { [$0.id] } ?? [], idempotencyKey: key)
    }

    private func refreshAfterSend(_ key: ThreadKey) async {
        if let thread = try? await backend.thread(didId: key.didId, number: key.remoteNumber) {
            threads[key] = thread
        }
        if let list = try? await backend.conversations(didId: key.didId) {
            conversations[key.didId] = list
        }
        markRead(key)
    }

    func upload(imageData: Data, filename: String, contentType: String) async throws -> PbxApiClient.MessagingAttachment {
        try await backend.upload(data: imageData, filename: filename, contentType: contentType)
    }

    func attachmentData(_ attachment: PbxApiClient.MessagingAttachment) async throws -> Data {
        if let cached = attachmentCache[attachment.id] { return cached }
        let data = try await backend.attachmentData(id: attachment.id)
        attachmentCache[attachment.id] = data
        return data
    }

    // MARK: - Live refresh

    /// Foregrounded: refresh now, then every 15 s, and listen for events.
    func becameActive() {
        guard !isActive else { return }
        isActive = true
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refresh() } }
        }
        startListening()
    }

    func resignedActive() {
        isActive = false
        timer?.invalidate()
        timer = nil
        socketTask?.cancel()
        socketTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func startListening() {
        socketTask?.cancel()
        socketTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let ended = await self.listenOnce()
                failures = ended == .heard ? 0 : failures + 1
                // Back off; the poll covers the gap.
                let delay = min(60.0, 2.0 * Double(1 << min(failures, 5)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private enum SocketEnd { case heard, failed }

    /// One socket's life. Heard means it opened and delivered at least one frame.
    private func listenOnce() async -> SocketEnd {
        guard isActive, let request = try? await backend.eventStreamRequest() else { return .failed }
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        var heard = false
        while !Task.isCancelled {
            do {
                let frame = try await task.receive()
                heard = true
                if case .string(let text) = frame, SmsReceivedEvent.parse(text) != nil {
                    await refresh()
                }
            } catch {
                break
            }
        }
        task.cancel(with: .goingAway, reason: nil)
        return heard ? .heard : .failed
    }

    // MARK: - Sign-out

    func reset() {
        resignedActive()
        inboxes = []
        conversations = [:]
        threads = [:]
        pendingThread = nil
        openThread = nil
        attachmentCache = [:]
        unreadCount = 0
        errorMessage = nil
        readMarks.reset()
    }
}

// MARK: - Images

enum MessageImage {
    /// A picked photo as JPEG under the 5 MB the server accepts, scaled down
    /// and re-compressed as needed. Nil when it cannot be decoded.
    static func jpegForUpload(_ data: Data, limit: Int = 5_000_000 - 4_096) -> Data? {
        guard var image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        if longest > 2048 {
            let scale = 2048 / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        for quality in [0.85, 0.7, 0.5, 0.3] as [CGFloat] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= limit { return jpeg }
        }
        return nil
    }
}
