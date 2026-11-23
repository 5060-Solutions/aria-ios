import Foundation

/// Merging the PBX's call records (`/extensions/{ext}/cdrs`) into local
/// history.
///
/// Local history has the calls this phone handled; the server also has the
/// ones answered on a desk phone or another device, and the ones missed while
/// this phone was off. A server call that history already has — the same
/// call recorded here, matched by direction, number and start time — is not
/// added twice; the local record is tagged with the server id instead, so it
/// is skipped on every later sync.
extension CallRecord {
    /// How far apart the phone's and the PBX's start times of one call may
    /// be: the PBX stamps the INVITE, the phone the push or the dial.
    static let serverMatchWindow: TimeInterval = 90

    /// The history entry for a PBX call record, from the point of view of
    /// `ownExtension`.
    init(server call: PbxApiClient.ServerCall, ownExtension: String) {
        let fromUser = Self.userPart(call.fromNumber ?? call.fromUri)
        let outbound: Bool
        switch call.direction.lowercased() {
        case "outbound": outbound = true
        case "inbound": outbound = false
        default:
            // Internal: outbound when this extension placed it.
            outbound = !ownExtension.isEmpty && fromUser == ownExtension
        }
        let remote = outbound
            ? (call.toNumber.flatMap { $0.isEmpty ? nil : $0 } ?? Self.userPart(call.toUri))
            : (call.fromNumber.flatMap { $0.isEmpty ? nil : $0 } ?? fromUser)
        let name = outbound ? call.toName : call.fromName
        let answered = call.disposition.lowercased() == "answered"
        let outcome: CallOutcome = answered ? .answered : (outbound ? .failed : .missed)
        self.init(
            direction: outbound ? .outbound : .inbound,
            remoteUri: remote,
            remoteName: name.flatMap { $0.isEmpty ? nil : $0 },
            startedAt: call.startedAt,
            duration: answered ? TimeInterval(call.durationSecs) : 0,
            outcome: outcome
        )
        serverId = call.id
    }

    /// `1001` from `sip:1001@pbx.example.com;user=phone`.
    static func userPart(_ uri: String) -> String {
        var value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = value.firstIndex(of: ":"),
           ["sip", "sips", "tel"].contains(value[..<colon].lowercased()) {
            value = String(value[value.index(after: colon)...])
        }
        if let cut = value.firstIndex(where: { $0 == "@" || $0 == ";" }) {
            value = String(value[..<cut])
        }
        return value
    }

    /// Whether two numbers are the same party: equal user parts, or the same
    /// last ten digits for phone numbers (`+15551234567` vs `5551234567`).
    static func sameParty(_ a: String, _ b: String) -> Bool {
        let ua = userPart(a).lowercased(), ub = userPart(b).lowercased()
        if ua == ub { return true }
        let da = ua.filter(\.isNumber), db = ub.filter(\.isNumber)
        guard da.count >= 7, db.count >= 7 else { return false }
        return da.suffix(10) == db.suffix(10)
    }

    /// Whether this local record is the phone's copy of the server's call.
    func matches(server record: CallRecord) -> Bool {
        direction == record.direction
            && abs(startedAt.timeIntervalSince(record.startedAt)) <= Self.serverMatchWindow
            && Self.sameParty(remoteUri, record.remoteUri)
    }
}

extension CallHistoryStore {
    /// `local` with `server` merged in: newest first, without duplicates,
    /// capped at `maxRecords`.
    static func merge(local: [CallRecord], server: [PbxApiClient.ServerCall], ownExtension: String) -> [CallRecord] {
        var records = local
        let known = Set(records.compactMap(\.serverId))
        for call in server where !known.contains(call.id) {
            let incoming = CallRecord(server: call, ownExtension: ownExtension)
            if let index = records.firstIndex(where: { $0.serverId == nil && $0.matches(server: incoming) }) {
                records[index].serverId = call.id
            } else {
                records.append(incoming)
            }
        }
        records.sort { $0.startedAt > $1.startedAt }
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
        return records
    }
}
