import Foundation

// Every proximity and call-handoff route in one place, so they can be aligned
// with the server's final shapes (the contract's Proximity section is not
// written yet): paths, bodies and key names below are provisional.

extension PbxApiClient {
    /// GET /api/v1/me/call-handoff
    func callHandoffSettings(jwt: String) async throws -> CallHandoffSettings {
        let data = try await send("GET", path: "/api/v1/me/call-handoff", token: jwt)
        return try decode(CallHandoffSettings.self, from: data)
    }

    /// PUT /api/v1/me/call-handoff → the settings as saved.
    func setCallHandoffSettings(jwt: String, _ settings: CallHandoffSettings) async throws -> CallHandoffSettings {
        let data = try await send(
            "PUT",
            path: "/api/v1/me/call-handoff",
            body: [
                "suggest_nearby": settings.suggestNearby,
                "auto_move_on_leave": settings.autoMoveOnLeave,
                "ble_enabled": settings.ble,
            ],
            token: jwt
        )
        return try decode(CallHandoffSettings.self, from: data)
    }

    /// POST /api/v1/me/devices/{registration_id}/proximity: a `network`,
    /// `left_network` or `ble_seen` report.
    func postProximity(jwt: String, registrationId: String, body: [String: Any]) async throws {
        _ = try await send(
            "POST",
            path: "/api/v1/me/devices/\(try pathSegment(registrationId))/proximity",
            body: body,
            token: jwt
        )
    }

    /// GET /api/v1/me/devices/{registration_id}/ble-token
    func bleToken(jwt: String, registrationId: String) async throws -> BleToken {
        let data = try await send(
            "GET",
            path: "/api/v1/me/devices/\(try pathSegment(registrationId))/ble-token",
            token: jwt
        )
        return try decode(BleToken.self, from: data)
    }
}
