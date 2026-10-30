import Foundation

/// Client for the Aria Cloud PBX REST API.
///
/// Handles extension login + device registration, replacing the old
/// direct-to-gateway auth flow.
class PbxApiClient {
    let baseUrl: String

    init(baseUrl: String) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
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
        let (tempURL, response) = try await URLSession.shared.download(for: request)
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

    // MARK: - Helpers

    /// Ids come from the server, but they still go into a path: refuse
    /// anything that is not a plain token rather than let it change the route.
    private func pathSegment(_ value: String) throws -> String {
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

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
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
    private func send(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        token: String?
    ) async throws -> Data {
        var request = URLRequest(url: try buildURL(path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 15
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
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

        let (data, response) = try await URLSession.shared.data(for: request)

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
