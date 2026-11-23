#if DEBUG
import Foundation

/// In-memory DND, forwards and server call records for fixture mode.
final class FixtureSelfServiceBackend: SelfServiceBackend {
    private var dnd = false
    private var stored: [PbxApiClient.CallForward] = [
        PbxApiClient.CallForward(id: "fwd-busy", forwardType: .busy, destination: "1000",
                                 ringTimeoutSecs: 20, enabled: true),
        PbxApiClient.CallForward(id: "fwd-noanswer", forwardType: .noAnswer, destination: "+15552019000",
                                 ringTimeoutSecs: 25, enabled: false),
    ]

    func doNotDisturb() async throws -> Bool { dnd }
    func setDoNotDisturb(_ enabled: Bool) async throws { dnd = enabled }
    func forwards() async throws -> [PbxApiClient.CallForward] { stored }

    func createForward(type: PbxApiClient.ForwardType, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward {
        let forward = PbxApiClient.CallForward(id: "fwd-\(type.rawValue)", forwardType: type,
                                               destination: destination, ringTimeoutSecs: ringTimeoutSecs,
                                               enabled: enabled)
        stored.removeAll { $0.forwardType == type }
        stored.append(forward)
        return forward
    }

    func updateForward(id: String, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward {
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            throw PbxApiClient.ApiError.httpError(statusCode: 404, message: "No such forward.")
        }
        let updated = PbxApiClient.CallForward(id: id, forwardType: stored[index].forwardType,
                                               destination: destination, ringTimeoutSecs: ringTimeoutSecs,
                                               enabled: enabled)
        stored[index] = updated
        return updated
    }

    func deleteForward(id: String) async throws { stored.removeAll { $0.id == id } }
    func callRecords(limit: Int) async throws -> [PbxApiClient.ServerCall] { [] }
    func reset() {}
}
#endif
