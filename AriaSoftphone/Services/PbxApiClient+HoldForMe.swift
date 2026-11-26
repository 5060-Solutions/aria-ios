import Foundation

// The Hold for me routes (shared contract C2). `callId` is the PBX call id
// (`ActiveCall.id` of `GET /me/calls/active`). A non-2xx answer is thrown as
// `HoldRequestError`, carrying the 409's `reason`.

extension PbxApiClient {
    private func holdSend(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        token: String
    ) async throws -> Data {
        do {
            return try await send(method, path: path, query: query, body: body, token: token)
        } catch ApiError.httpError(let code, _) {
            throw HoldRequestError(status: code, reason: lastErrorBody?["reason"] as? String)
        }
    }

    private func holdPath(_ callId: String) throws -> String {
        "/api/v1/me/calls/\(try pathSegment(callId))/hold-for-me"
    }

    /// POST /api/v1/me/calls/{id}/hold-for-me → 202 `HoldWait`.
    func startHoldForMe(jwt: String, callId: String, greeting: HoldGreeting?, displayName: String?) async throws -> HoldWait {
        var body: [String: Any] = [:]
        if let greeting { body["greeting"] = greeting.rawValue }
        if let displayName { body["display_name"] = displayName }
        let data = try await holdSend("POST", path: try holdPath(callId), body: body, token: jwt)
        return try decode(HoldWait.self, from: data)
    }

    /// GET /api/v1/me/calls/{id}/hold-for-me → the latest wait on that call.
    func holdWait(jwt: String, callId: String) async throws -> HoldWait {
        let data = try await holdSend("GET", path: try holdPath(callId), token: jwt)
        return try decode(HoldWait.self, from: data)
    }

    /// DELETE /api/v1/me/calls/{id}/hold-for-me?action=rejoin|hang_up → 202.
    func cancelHoldForMe(jwt: String, callId: String, action: String) async throws -> HoldWait {
        let data = try await holdSend(
            "DELETE", path: try holdPath(callId),
            query: [URLQueryItem(name: "action", value: action)], token: jwt
        )
        return try decode(HoldWait.self, from: data)
    }

    /// POST /api/v1/me/calls/{id}/hold-for-me/still-on-hold → 202.
    func stillOnHold(jwt: String, callId: String) async throws -> HoldWait {
        let data = try await holdSend("POST", path: try holdPath(callId) + "/still-on-hold", token: jwt)
        return try decode(HoldWait.self, from: data)
    }

    /// GET /api/v1/me/hold-waits → the caller's waits that are not ended.
    func holdWaits(jwt: String) async throws -> [HoldWait] {
        let data = try await holdSend("GET", path: "/api/v1/me/hold-waits", token: jwt)
        return try decode([HoldWait].self, from: data)
    }

    /// GET /api/v1/me/hold-for-me/settings
    func holdForMeSettings(jwt: String) async throws -> HoldSettings {
        let data = try await holdSend("GET", path: "/api/v1/me/hold-for-me/settings", token: jwt)
        return try decode(HoldSettings.self, from: data)
    }

    /// PUT /api/v1/me/hold-for-me/settings `{"greeting"}` → the settings as saved.
    func setHoldForMeGreeting(jwt: String, _ greeting: HoldGreeting) async throws -> HoldSettings {
        let data = try await holdSend(
            "PUT", path: "/api/v1/me/hold-for-me/settings", body: ["greeting": greeting.rawValue], token: jwt
        )
        return try decode(HoldSettings.self, from: data)
    }
}
