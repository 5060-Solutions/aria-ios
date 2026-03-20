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

    // MARK: - Helpers

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
