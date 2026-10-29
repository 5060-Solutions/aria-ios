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
        let gatewayUrl: String
        let gatewayToken: String
    }

    // MARK: - API Errors

    enum ApiError: LocalizedError {
        case invalidURL
        case emptyResponse
        case httpError(statusCode: Int, message: String)
        case decodingError(String)

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
        let url = try buildURL(path: "/api/v1/devices/register")

        let body: [String: Any] = [
            "push_token": pushToken,
            "platform": platform,
        ]

        let json = try await post(url: url, body: body, token: jwt)

        guard let deviceId = json["device_id"] as? String else {
            throw ApiError.decodingError("Missing device_id")
        }

        let sipDomain = json["sip_domain"] as? String ?? ""
        let gatewayUrl = json["gateway_url"] as? String ?? ""
        let gatewayToken = json["gateway_token"] as? String ?? ""

        return DeviceResponse(deviceId: deviceId, sipDomain: sipDomain, gatewayUrl: gatewayUrl, gatewayToken: gatewayToken)
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

    /// Send a request and return the body of a 2xx response.
    private func send(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        token: String?
    ) async throws -> Data {
        var request = URLRequest(url: try buildURL(path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
