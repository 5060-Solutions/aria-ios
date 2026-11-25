import Foundation

/// Client for the Aria Cloud PBX REST API.
///
/// Handles extension login + device registration, replacing the old
/// direct-to-gateway auth flow.
class PbxApiClient {
    let baseUrl: String
    /// `.shared` in the app; a session with a stub `URLProtocol` in tests.
    let session: URLSession

    init(baseUrl: String, session: URLSession = .shared) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.session = session
    }

    // MARK: - Response Types

    struct LoginResponse {
        let jwt: String
        let extensionId: String
        let tenantId: String
    }

    struct DeviceResponse {
        let deviceId: String
        let sipDomain: String
        /// `udp`, `tcp` or `tls` — the transport `sipPort` belongs to. Empty
        /// from a PBX that predates the field.
        let sipTransport: String
        let sipPort: Int
        let gatewayUrl: String
        let gatewayToken: String
    }

    // MARK: - API Errors

    enum ApiError: LocalizedError {
        case invalidURL
        case emptyResponse
        case httpError(statusCode: Int, message: String)
        case decodingError(String)
        /// Device registration stored the device but could not get a gateway
        /// token for it (502/503). Renew one for `deviceId`.
        case gatewayTokenUnavailable(deviceId: String, statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid API URL"
            case .emptyResponse:
                return "Empty response from server"
            case .httpError(let code, let message):
                return "Request failed (\(code)): \(message)"
            case .decodingError(let detail):
                return "Failed to parse response: \(detail)"
            case .gatewayTokenUnavailable(_, let code, let message):
                return "Request failed (\(code)): \(message)"
            }
        }
    }

    // MARK: - POST /api/v1/auth/extension-login

    func extensionLogin(
        extensionNumber: String,
        password: String,
        tenantDomain: String
    ) async throws -> LoginResponse {
        let url = try buildURL(path: "/api/v1/auth/extension-login")

        let body: [String: Any] = [
            "extension_number": extensionNumber,
            "password": password,
            "tenant_domain": tenantDomain,
        ]

        let json = try await post(url: url, body: body, token: nil)

        guard let jwt = json["token"] as? String,
              let extensionId = json["extension_id"] as? String,
              let tenantId = json["tenant_id"] as? String else {
            throw ApiError.decodingError("Missing token, extension_id, or tenant_id")
        }

        return LoginResponse(jwt: jwt, extensionId: extensionId, tenantId: tenantId)
    }

    // MARK: - POST /api/v1/devices/register

    func registerDevice(
        jwt: String,
        pushToken: String,
        platform: String
    ) async throws -> DeviceResponse {
        let body: [String: Any] = [
            "push_token": pushToken,
            "platform": platform,
        ]

        let data: Data
        do {
            data = try await send("POST", path: "/api/v1/devices/register", body: body, token: jwt)
        } catch ApiError.httpError(let code, let message) where code == 502 || code == 503 {
            // The device row exists; only its gateway token is missing. The
            // body names the device so the token can be renewed for it.
            if let deviceId = lastErrorBody?["device_id"] as? String, !deviceId.isEmpty {
                throw ApiError.gatewayTokenUnavailable(deviceId: deviceId, statusCode: code, message: message)
            }
            throw ApiError.httpError(statusCode: code, message: message)
        }
        return try Self.parseDeviceResponse(data)
    }

    static func parseDeviceResponse(_ data: Data) throws -> DeviceResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = json["device_id"] as? String else {
            throw ApiError.decodingError("Missing device_id")
        }

        return DeviceResponse(
            deviceId: deviceId,
            sipDomain: json["sip_domain"] as? String ?? "",
            sipTransport: (json["sip_transport"] as? String ?? "").lowercased(),
            sipPort: json["sip_port"] as? Int ?? 0,
            gatewayUrl: json["gateway_url"] as? String ?? "",
            gatewayToken: json["gateway_token"] as? String ?? ""
        )
    }

    // MARK: - POST /api/v1/devices/{id}/gateway-token

    struct GatewayTokenResponse: Decodable {
        let gatewayToken: String
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case gatewayToken = "gateway_token"
            case expiresIn = "expires_in"
        }
    }

    /// A fresh push-gateway token for this device.
    func renewGatewayToken(jwt: String, deviceId: String) async throws -> String {
        let data = try await send(
            "POST",
            path: "/api/v1/devices/\(try pathSegment(deviceId))/gateway-token",
            token: jwt
        )
        let response = try decode(GatewayTokenResponse.self, from: data)
        guard !response.gatewayToken.isEmpty else {
            throw ApiError.decodingError("Empty gateway_token")
        }
        return response.gatewayToken
    }

    // MARK: - PUT /api/v1/devices/{id}/push-token

    func updatePushToken(jwt: String, deviceId: String, pushToken: String) async throws {
        _ = try await send(
            "PUT",
            path: "/api/v1/devices/\(try pathSegment(deviceId))/push-token",
            body: ["push_token": pushToken],
            token: jwt
        )
    }

    // MARK: - POST /api/v1/devices/unregister

    func unregisterDevice(jwt: String, deviceId: String) async throws {
        let url = try buildURL(path: "/api/v1/devices/unregister")

        let body: [String: Any] = [
            "device_id": deviceId,
        ]

        _ = try await post(url: url, body: body, token: jwt)
    }

    // MARK: - Voicemail
    //
    // Self-service routes: an extension-login JWT may read and manage the
    // mailbox of the extension it was issued for.

    struct Identity: Decodable {
        /// The extension the credential acts as on self-service routes.
        let actingExtension: String?

        enum CodingKeys: String, CodingKey {
            case actingExtension = "acting_extension"
        }
    }

    struct VoicemailBox: Decodable {
        let id: String
    }

    struct VoicemailMessage: Decodable, Identifiable, Equatable {
        let id: String
        let boxId: String
        let callerId: String
        let durationSecs: Int
        var read: Bool
        let createdAt: Date
        let transcription: String?

        enum CodingKeys: String, CodingKey {
            case id
            case boxId = "box_id"
            case callerId = "caller_id"
            case durationSecs = "duration_secs"
            case read
            case createdAt = "created_at"
            case transcription
        }
    }

    struct MediaGrant: Decodable {
        let token: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case token
            case expiresIn = "expires_in"
        }
    }

    /// GET /api/v1/me
    func identity(jwt: String) async throws -> Identity {
        let data = try await send("GET", path: "/api/v1/me", token: jwt)
        return try decode(Identity.self, from: data)
    }

    /// GET /api/v1/extensions/{ext_id}/voicemail — nil when the extension
    /// has no mailbox.
    func voicemailBox(jwt: String, extensionId: String) async throws -> VoicemailBox? {
        do {
            let data = try await send("GET", path: "/api/v1/extensions/\(try pathSegment(extensionId))/voicemail", token: jwt)
            return try decode(VoicemailBox.self, from: data)
        } catch ApiError.httpError(let code, _) where code == 404 {
            return nil
        }
    }

    /// GET /api/v1/voicemail/boxes/{box_id}/messages
    func voicemailMessages(jwt: String, boxId: String, limit: Int = 200) async throws -> [VoicemailMessage] {
        let data = try await send(
            "GET",
            path: "/api/v1/voicemail/boxes/\(try pathSegment(boxId))/messages",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            token: jwt
        )
        return try decode([VoicemailMessage].self, from: data)
    }

    /// PATCH /api/v1/voicemail/messages/{id}/read
    func markVoicemailRead(jwt: String, messageId: String) async throws {
        _ = try await send("PATCH", path: "/api/v1/voicemail/messages/\(try pathSegment(messageId))/read", token: jwt)
    }

    /// DELETE /api/v1/voicemail/messages/{id}
    func deleteVoicemail(jwt: String, messageId: String) async throws {
        _ = try await send("DELETE", path: "/api/v1/voicemail/messages/\(try pathSegment(messageId))", token: jwt)
    }

    /// Fetch a message's audio to a temporary file.
    ///
    /// Uses the server's short-lived, single-object grant in `?token=` rather
    /// than the session JWT: the audio route may redirect to a presigned
    /// object-store URL, and a bearer header must not follow it there.
    func downloadVoicemailAudio(jwt: String, messageId: String) async throws -> URL {
        let segment = try pathSegment(messageId)
        let grantData = try await send("POST", path: "/api/v1/voicemail/messages/\(segment)/audio-grant", token: jwt)
        let grant = try decode(MediaGrant.self, from: grantData)

        let url = try buildURL(
            path: "/api/v1/voicemail/messages/\(segment)/audio",
            query: [URLQueryItem(name: "token", value: grant.token)]
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (tempURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw ApiError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ApiError.httpError(statusCode: http.statusCode, message: "Audio unavailable")
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicemail-\(segment)")
            .appendingPathExtension(Self.audioExtension(for: http.mimeType))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private static func audioExtension(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        default: return "wav"
        }
    }

    // MARK: - Self-service: features, forwards, call records
    //
    // The extension-login JWT may read and change these for its own
    // extension only. `extensionId` is the extension's UUID (`/me`'s
    // `acting_extension`, or `extension_id` from the login).

    struct ExtensionFeatures: Decodable, Equatable {
        let doNotDisturb: Bool

        enum CodingKeys: String, CodingKey {
            case doNotDisturb = "do_not_disturb"
        }
    }

    /// GET /api/v1/extensions/{ext_id}/features. The PBX creates the row
    /// with its defaults on first read.
    func features(jwt: String, extensionId: String) async throws -> ExtensionFeatures {
        let data = try await send("GET", path: "/api/v1/extensions/\(try pathSegment(extensionId))/features", token: jwt)
        return try decode(ExtensionFeatures.self, from: data)
    }

    /// PUT /api/v1/extensions/{ext_id}/features `{do_not_disturb}` → 204.
    /// Only DND: the call limit and hot-desking are the administrator's.
    func setDoNotDisturb(jwt: String, extensionId: String, enabled: Bool) async throws {
        _ = try await send(
            "PUT",
            path: "/api/v1/extensions/\(try pathSegment(extensionId))/features",
            body: ["do_not_disturb": enabled],
            token: jwt
        )
    }

    struct CallForward: Decodable, Identifiable, Equatable {
        let id: String
        let forwardType: ForwardType
        let destination: String
        let ringTimeoutSecs: Int
        let enabled: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case forwardType = "forward_type"
            case destination
            case ringTimeoutSecs = "ring_timeout_secs"
            case enabled
        }
    }

    /// The kinds of forward the PBX acts on; one of each per extension.
    enum ForwardType: String, Codable, CaseIterable, Identifiable {
        case unconditional
        case busy
        case noAnswer = "no_answer"

        var id: String { rawValue }
    }

    /// GET /api/v1/extensions/{ext_id}/forwards
    func forwards(jwt: String, extensionId: String) async throws -> [CallForward] {
        let data = try await send("GET", path: "/api/v1/extensions/\(try pathSegment(extensionId))/forwards", token: jwt)
        return try decode([CallForward].self, from: data)
    }

    /// POST /api/v1/extensions/{ext_id}/forwards → 201 with the forward. A
    /// second forward of the same type is a 409; the PBX refuses feature
    /// codes, emergency numbers and destinations the calling profile cannot
    /// reach with a 422 whose message says why.
    func createForward(
        jwt: String,
        extensionId: String,
        type: ForwardType,
        destination: String,
        ringTimeoutSecs: Int,
        enabled: Bool
    ) async throws -> CallForward {
        let data = try await send(
            "POST",
            path: "/api/v1/extensions/\(try pathSegment(extensionId))/forwards",
            body: [
                "forward_type": type.rawValue,
                "destination": destination,
                "ring_timeout_secs": ringTimeoutSecs,
                "enabled": enabled,
            ],
            token: jwt
        )
        return try decode(CallForward.self, from: data)
    }

    /// PUT /api/v1/forwards/{id}: a partial update; returns the forward.
    func updateForward(
        jwt: String,
        id: String,
        destination: String? = nil,
        ringTimeoutSecs: Int? = nil,
        enabled: Bool? = nil
    ) async throws -> CallForward {
        var body: [String: Any] = [:]
        if let destination = destination { body["destination"] = destination }
        if let ringTimeoutSecs = ringTimeoutSecs { body["ring_timeout_secs"] = ringTimeoutSecs }
        if let enabled = enabled { body["enabled"] = enabled }
        let data = try await send("PUT", path: "/api/v1/forwards/\(try pathSegment(id))", body: body, token: jwt)
        return try decode(CallForward.self, from: data)
    }

    /// DELETE /api/v1/forwards/{id} → 204.
    func deleteForward(jwt: String, id: String) async throws {
        _ = try await send("DELETE", path: "/api/v1/forwards/\(try pathSegment(id))", token: jwt)
    }

    /// One call from the PBX's records (`OwnCall`).
    struct ServerCall: Decodable, Identifiable, Equatable {
        let id: String
        /// `inbound`, `outbound` or `internal`.
        let direction: String
        let fromUri: String
        let toUri: String
        let fromNumber: String?
        let fromName: String?
        let toNumber: String?
        let toName: String?
        /// `answered`, `no_answer`, `busy`, `failed`, `refused`, ...
        let disposition: String
        let startedAt: Date
        let answeredAt: Date?
        let endedAt: Date?
        let durationSecs: Int

        enum CodingKeys: String, CodingKey {
            case id, direction, disposition
            case fromUri = "from_uri"
            case toUri = "to_uri"
            case fromNumber = "from_number"
            case fromName = "from_name"
            case toNumber = "to_number"
            case toName = "to_name"
            case startedAt = "started_at"
            case answeredAt = "answered_at"
            case endedAt = "ended_at"
            case durationSecs = "duration_secs"
        }
    }

    /// GET /api/v1/extensions/{ext_id}/cdrs: the extension's calls, newest
    /// first. At most 200 per page.
    func callRecords(jwt: String, extensionId: String, limit: Int = 100, offset: Int = 0) async throws -> [ServerCall] {
        let data = try await send(
            "GET",
            path: "/api/v1/extensions/\(try pathSegment(extensionId))/cdrs",
            query: [
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))),
                URLQueryItem(name: "offset", value: String(max(offset, 0))),
            ],
            token: jwt
        )
        return try decode([ServerCall].self, from: data)
    }

    // MARK: - Messaging (SMS/MMS)
    //
    // The same extension-login JWT as everything above: the messaging routes
    // take any role in the tenant, and the server limits a seat to the
    // inboxes assigned to it, directly or through a ring group.

    struct MessagingInbox: Decodable, Identifiable, Equatable {
        let didId: String
        let number: String
        let lastInboundAt: Date?
        let enabled: Bool
        var id: String { didId }

        enum CodingKeys: String, CodingKey {
            case didId = "did_id"
            case number
            case lastInboundAt = "last_inbound_at"
            case enabled
        }
    }

    struct MessagingConversation: Decodable, Identifiable, Equatable {
        let remoteNumber: String
        let messageCount: Int
        let lastBody: String
        let lastDirection: String
        let lastStatus: String
        let lastAt: Date
        let lastHasMedia: Bool
        let optedOut: Bool
        var id: String { remoteNumber }

        enum CodingKeys: String, CodingKey {
            case remoteNumber = "remote_number"
            case messageCount = "message_count"
            case lastBody = "last_body"
            case lastDirection = "last_direction"
            case lastStatus = "last_status"
            case lastAt = "last_at"
            case lastHasMedia = "last_has_media"
            case optedOut = "opted_out"
        }
    }

    struct MessagingAttachment: Decodable, Identifiable, Equatable {
        let id: String
        let contentType: String
        let sizeBytes: Int

        enum CodingKeys: String, CodingKey {
            case id
            case contentType = "content_type"
            case sizeBytes = "size_bytes"
        }

        var isImage: Bool { contentType.lowercased().hasPrefix("image/") }
    }

    struct MessagingMessage: Decodable, Identifiable, Equatable {
        let id: String
        let direction: String
        let body: String
        /// `pending`, `sent`, `delivered`, `failed` or `received`.
        let status: String
        let errorMessage: String?
        let createdAt: Date
        let remoteNumber: String
        let attachments: [MessagingAttachment]

        var isOutbound: Bool { direction == "outbound" }

        enum CodingKeys: String, CodingKey {
            case id, direction, body, status, attachments
            case errorMessage = "error_message"
            case createdAt = "created_at"
            case remoteNumber = "remote_number"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            direction = try c.decode(String.self, forKey: .direction)
            body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
            status = try c.decode(String.self, forKey: .status)
            errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            remoteNumber = try c.decodeIfPresent(String.self, forKey: .remoteNumber) ?? ""
            attachments = try c.decodeIfPresent([MessagingAttachment].self, forKey: .attachments) ?? []
        }

        init(id: String, direction: String, body: String, status: String, errorMessage: String? = nil,
             createdAt: Date, remoteNumber: String, attachments: [MessagingAttachment] = []) {
            self.id = id
            self.direction = direction
            self.body = body
            self.status = status
            self.errorMessage = errorMessage
            self.createdAt = createdAt
            self.remoteNumber = remoteNumber
            self.attachments = attachments
        }
    }

    struct MessagingThread: Decodable, Equatable {
        let remoteNumber: String
        let optedOut: Bool
        /// Newest first, as the server sends them.
        let messages: [MessagingMessage]

        enum CodingKeys: String, CodingKey {
            case remoteNumber = "remote_number"
            case optedOut = "opted_out"
            case messages
        }
    }

    /// GET .../messaging/inboxes
    func messagingInboxes(jwt: String, tenantId: String) async throws -> [MessagingInbox] {
        let data = try await send("GET", path: "/api/v1/tenants/\(try pathSegment(tenantId))/messaging/inboxes", token: jwt)
        return try decode([MessagingInbox].self, from: data)
    }

    /// GET .../messaging/inboxes/{did}/conversations
    func messagingConversations(jwt: String, tenantId: String, didId: String,
                                limit: Int = 200) async throws -> [MessagingConversation] {
        let data = try await send(
            "GET",
            path: "/api/v1/tenants/\(try pathSegment(tenantId))/messaging/inboxes/\(try pathSegment(didId))/conversations",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            token: jwt
        )
        return try decode([MessagingConversation].self, from: data)
    }

    /// GET .../messaging/inboxes/{did}/conversations/{number}
    func messagingThread(jwt: String, tenantId: String, didId: String, number: String,
                         limit: Int = 200) async throws -> MessagingThread {
        // `+` is legal in a path but a number may also hold spaces or
        // parentheses; encode it as one segment.
        guard let segment = number.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed),
              !segment.isEmpty else { throw ApiError.invalidURL }
        let data = try await send(
            "GET",
            path: "/api/v1/tenants/\(try pathSegment(tenantId))/messaging/inboxes/\(try pathSegment(didId))/conversations/\(segment)",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            token: jwt
        )
        return try decode(MessagingThread.self, from: data)
    }

    /// POST .../messaging/inboxes/{did}/messages. A retry that reuses
    /// `idempotencyKey` returns the first message instead of sending again.
    func sendMessage(jwt: String, tenantId: String, didId: String, to: String, body: String,
                     attachmentIds: [String], idempotencyKey: String) async throws -> MessagingMessage {
        var payload: [String: Any] = ["to": to, "body": body]
        if !attachmentIds.isEmpty { payload["attachment_ids"] = attachmentIds }
        let data = try await send(
            "POST",
            path: "/api/v1/tenants/\(try pathSegment(tenantId))/messaging/inboxes/\(try pathSegment(didId))/messages",
            body: payload,
            headers: ["Idempotency-Key": idempotencyKey],
            token: jwt
        )
        return try decode(MessagingMessage.self, from: data)
    }

    /// POST .../messaging/attachments (multipart `file`).
    func uploadMessagingAttachment(jwt: String, tenantId: String, data fileData: Data, filename: String,
                                   contentType: String) async throws -> MessagingAttachment {
        let boundary = "aria-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        let response = try await send(
            "POST",
            path: "/api/v1/tenants/\(try pathSegment(tenantId))/messaging/attachments",
            rawBody: (body, "multipart/form-data; boundary=\(boundary)"),
            token: jwt
        )
        return try decode(MessagingAttachment.self, from: response)
    }

    /// GET .../messaging/attachments/{id}: the file's bytes.
    func messagingAttachmentData(jwt: String, tenantId: String, attachmentId: String) async throws -> Data {
        try await send(
            "GET",
            path: "/api/v1/tenants/\(try pathSegment(tenantId))/messaging/attachments/\(try pathSegment(attachmentId))",
            headers: ["Accept": "*/*"],
            token: jwt
        )
    }

    /// The event stream's URL: the API's, over wss. The session JWT goes in
    /// the `Authorization` header of the upgrade, never in the URL.
    func eventStreamURL() throws -> URL {
        guard var components = URLComponents(string: baseUrl + "/api/v1/ws") else { throw ApiError.invalidURL }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw ApiError.invalidURL
        }
        guard let url = components.url else { throw ApiError.invalidURL }
        return url
    }

    private static let pathSegmentAllowed: CharacterSet = {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
    }()

    // MARK: - Helpers

    /// Ids come from the server, but they still go into a path: refuse
    /// anything that is not a plain token rather than let it change the route.
    func pathSegment(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ApiError.invalidURL
        }
        return value
    }

    private func buildURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: baseUrl + path) else {
            throw ApiError.invalidURL
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ApiError.invalidURL }
        return url
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.jsonDecoder.decode(type, from: data)
        } catch {
            throw ApiError.decodingError(String(describing: error))
        }
    }

    /// chrono serialises timestamps as RFC 3339, with or without fractional
    /// seconds.
    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid date: \(string)"
            )
        }
        return decoder
    }()

    /// The JSON body of the last non-2xx response from `send`, for routes
    /// whose errors carry fields beyond the message.
    private var lastErrorBody: [String: Any]?

    /// Send a request and return the body of a 2xx response.
    func send(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        headers: [String: String] = [:],
        rawBody: (data: Data, contentType: String)? = nil,
        token: String?
    ) async throws -> Data {
        var request = URLRequest(url: try buildURL(path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let rawBody {
            request.setValue(rawBody.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody.data
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 15
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            lastErrorBody = json
            let message = json?["error"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw ApiError.httpError(statusCode: http.statusCode, message: message)
        }
        return data
    }

    private func buildURL(path: String) throws -> URL {
        guard let url = URL(string: baseUrl + path) else {
            throw ApiError.invalidURL
        }
        return url
    }

    @discardableResult
    private func post(url: URL, body: [String: Any], token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApiError.emptyResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                return [:]
            }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ApiError.httpError(statusCode: httpResponse.statusCode, message: bodyText)
        }

        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            let errorMsg = json["error"] as? String ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ApiError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        return json
    }
}

// MARK: - Calls on the user's devices (call move)

extension PbxApiClient {
    /// GET /api/v1/me/calls/active
    func activeCalls(jwt: String) async throws -> [UserCall] {
        let data = try await send("GET", path: "/api/v1/me/calls/active", token: jwt)
        return try decode([UserCall].self, from: data)
    }

    /// GET /api/v1/me/devices
    func userDevices(jwt: String) async throws -> [UserDevice] {
        let data = try await send("GET", path: "/api/v1/me/devices", token: jwt)
        return try decode([UserDevice].self, from: data)
    }

    /// GET /api/v1/me/devices/current?sip_instance=<urn>: this phone's own
    /// registration.
    func currentDevice(jwt: String, sipInstance: String) async throws -> UserDevice {
        let data = try await send(
            "GET",
            path: "/api/v1/me/devices/current",
            query: [URLQueryItem(name: "sip_instance", value: sipInstance)],
            token: jwt
        )
        return try decode(UserDevice.self, from: data)
    }

    /// POST /api/v1/me/calls/{id}/move → 202 `{move_id}`. 404: not the
    /// user's call; 409: not answered or in a transfer; 422: device unknown
    /// or offline.
    func moveCall(jwt: String, callId: String, toRegistrationId: String) async throws -> String {
        let data = try await send(
            "POST",
            path: "/api/v1/me/calls/\(try pathSegment(callId))/move",
            body: ["to_registration_id": toRegistrationId],
            token: jwt
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let moveId = json["move_id"] as? String, !moveId.isEmpty else {
            throw ApiError.decodingError("Missing move_id")
        }
        return moveId
    }
}
