import Foundation

// The proximity and call-handoff routes of the call-move contract
// ("Proximity"). Every `devices/current` route names this phone by its
// `+sip.instance` (`urn:uuid:<pbx device id>`), which must be registered:
// 422 when it is not named, 404 when no registered device has it.

extension PbxApiClient {
    /// GET /api/v1/me/call-handoff
    func callHandoffSettings(jwt: String) async throws -> CallHandoffSettings {
        let data = try await send("GET", path: "/api/v1/me/call-handoff", token: jwt)
        return try decode(CallHandoffSettings.self, from: data)
    }

    /// PUT /api/v1/me/call-handoff → the settings as saved. The fields given
    /// are set and the rest kept (`auto_move_on_desktop_lock` is the desktop's).
    func setCallHandoffSettings(jwt: String, _ settings: CallHandoffSettings) async throws -> CallHandoffSettings {
        let data = try await send(
            "PUT",
            path: "/api/v1/me/call-handoff",
            body: [
                "suggest_nearby": settings.suggestNearby,
                "auto_move_on_leave": settings.autoMoveOnLeave,
                "ble_opt_in": settings.ble,
            ],
            token: jwt
        )
        return try decode(CallHandoffSettings.self, from: data)
    }

    /// POST /api/v1/me/devices/current/proximity?sip_instance=<urn>
    /// `{"network_hash"?, "ble_seen"?: [{"token", "rssi"}]}` (at most 32 tokens).
    func postProximity(jwt: String, sipInstance: String, networkHash: String?, bleSeen: [BleSighting]) async throws {
        var body: [String: Any] = [:]
        if let networkHash { body["network_hash"] = networkHash }
        if !bleSeen.isEmpty {
            body["ble_seen"] = bleSeen.prefix(BleSighting.maxPerReport).map { ["token": $0.token, "rssi": $0.rssi] as [String: Any] }
        }
        _ = try await send(
            "POST",
            path: "/api/v1/me/devices/current/proximity",
            query: [URLQueryItem(name: "sip_instance", value: sipInstance)],
            body: body,
            token: jwt
        )
    }

    /// POST /api/v1/me/devices/current/context?sip_instance=<urn> `{"event": "left_network"}`
    /// → `{"action": "moved" | "suggested" | "none", "call_id", "move_id"}`.
    func postContext(jwt: String, sipInstance: String, event: String) async throws -> ContextResult {
        let data = try await send(
            "POST",
            path: "/api/v1/me/devices/current/context",
            query: [URLQueryItem(name: "sip_instance", value: sipInstance)],
            body: ["event": event],
            token: jwt
        )
        return try decode(ContextResult.self, from: data)
    }

    /// GET /api/v1/me/devices/current/ble-token?sip_instance=<urn>
    /// → `{"token": <16 bytes hex>, "rotates_at"}`; 403 unless `ble_opt_in`.
    func bleToken(jwt: String, sipInstance: String) async throws -> BleToken {
        let data = try await send(
            "GET",
            path: "/api/v1/me/devices/current/ble-token",
            query: [URLQueryItem(name: "sip_instance", value: sipInstance)],
            token: jwt
        )
        return try decode(BleToken.self, from: data)
    }
}
