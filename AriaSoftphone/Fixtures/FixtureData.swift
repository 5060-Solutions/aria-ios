#if DEBUG
import Foundation

/// Canned data for fixture mode. Plain values, so UI tests can assert on them
/// (`FixtureData.contacts[0].name`) and new tests can add their own.
///
/// Names and numbers are fictional; numbers use the 555-01xx range.
enum FixtureData {
    // MARK: Account

    struct Account {
        var username = "1001"
        var displayName = "Alex Morgan"
        var domain = "northwind.ariaroute.com"
        var registrar = "sip.ariaroute.com"
        var port = 5061
        var transport = "tls"
        var apiUrl = "https://api.fixture.invalid"
        var gatewayUrl = "https://push.ariaroute.com"
        var voicemailNumber = "*97"
        var extensionId = "ext-fixture-1001"
        var tenantId = "tenant-fixture"
        var pbxDeviceId = "device-fixture"
    }

    static var account = Account()

    // MARK: Contacts

    static var contacts: [ContactEntry] = [
        ("Amelia Brooks", ["+1 (415) 555-0118"], true),
        ("Ben Carter", ["+1 (212) 555-0173"], false),
        ("Chloé Dubois", ["+33 1 55 50 01 27"], false),
        ("Daniel Okafor", ["+1 (312) 555-0190", "1042"], true),
        ("Emma Lindqvist", ["+46 8 555 011 45"], false),
        ("Front Desk", ["1000"], true),
        ("Grace Kim", ["+1 (206) 555-0136"], false),
        ("Hiroshi Tanaka", ["+81 3 5550 0182"], false),
        ("Isabel Ortega", ["+1 (305) 555-0164"], false),
        ("Marcus Chen", ["+1 (628) 555-0147", "1017"], true),
        ("Nora Walsh", ["+353 1 555 0129"], false),
        ("Priya Raman", ["+1 (415) 555-0142"], false),
        ("Sam Patel", ["1023"], false),
    ].map { ContactEntry(name: $0.0, phoneNumbers: $0.1, hasImage: false, thumbnailData: nil, isFavorite: $0.2) }

    // MARK: History

    /// Newest first, spread over today, yesterday and earlier in the week.
    static func history(now: Date = Date()) -> [CallRecord] {
        func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            CallRecord(direction: .inbound, remoteUri: "+14155550142", remoteName: "Priya Raman",
                       startedAt: ago(minutes: 12), duration: 0, outcome: .missed),
            CallRecord(direction: .outbound, remoteUri: "+16285550147", remoteName: "Marcus Chen",
                       startedAt: ago(minutes: 48), duration: 754, outcome: .answered),
            CallRecord(direction: .inbound, remoteUri: "1000", remoteName: "Front Desk",
                       startedAt: ago(minutes: 95), duration: 121, outcome: .answered),
            CallRecord(direction: .outbound, remoteUri: "+12125550173", remoteName: "Ben Carter",
                       startedAt: ago(minutes: 180), duration: 0, outcome: .cancelled),
            CallRecord(direction: .inbound, remoteUri: "+13125550190", remoteName: "Daniel Okafor",
                       startedAt: ago(minutes: 60 * 26), duration: 1830, outcome: .answered),
            CallRecord(direction: .inbound, remoteUri: "+15035550111", remoteName: nil,
                       startedAt: ago(minutes: 60 * 27), duration: 0, outcome: .missed),
            CallRecord(direction: .outbound, remoteUri: "1023", remoteName: "Sam Patel",
                       startedAt: ago(minutes: 60 * 30), duration: 64, outcome: .answered),
            CallRecord(direction: .inbound, remoteUri: "+14155550118", remoteName: "Amelia Brooks",
                       startedAt: ago(minutes: 60 * 52), duration: 402, outcome: .transferred),
            CallRecord(direction: .outbound, remoteUri: "+12065550136", remoteName: "Grace Kim",
                       startedAt: ago(minutes: 60 * 75), duration: 285, outcome: .answered),
            CallRecord(direction: .inbound, remoteUri: "+33155500127", remoteName: "Chloé Dubois",
                       startedAt: ago(minutes: 60 * 98), duration: 0, outcome: .rejected),
        ]
    }

    // MARK: Voicemail

    static func voicemail(now: Date = Date()) -> [VoicemailService.Message] {
        [
            .init(id: "vm-1", boxId: "box-1", callerId: "Priya Raman <+14155550142>", durationSecs: 38,
                  read: false, createdAt: now.addingTimeInterval(-11 * 60),
                  transcription: "Hi Alex, it's Priya. The contract came back signed, so we're good to "
                      + "start on Monday. Give me a call when you get a moment and I'll walk you through "
                      + "the timeline."),
            .init(id: "vm-2", boxId: "box-1", callerId: "+15035550111", durationSecs: 17,
                  read: false, createdAt: now.addingTimeInterval(-27 * 3600),
                  transcription: "Hello, this is a reminder about your dental appointment on Thursday "
                      + "at 10:30. Please call us back to confirm."),
            .init(id: "vm-3", boxId: "box-1", callerId: "Daniel Okafor <1042>", durationSecs: 64,
                  read: true, createdAt: now.addingTimeInterval(-50 * 3600),
                  transcription: "Quick update on the warehouse install: the second rack is in and "
                      + "the phones are all registered. I'll send the photos over tonight."),
            .init(id: "vm-4", boxId: "box-1", callerId: "Front Desk <1000>", durationSecs: 9,
                  read: true, createdAt: now.addingTimeInterval(-6 * 86400),
                  transcription: nil),
        ]
    }

    // MARK: Calls

    static let incomingCaller = (name: "Priya Raman", uri: "+14155550142")
    static let activeCaller = (name: "Marcus Chen", uri: "+16285550147")

    /// The calls a scene starts with, oldest first.
    static func calls(for scene: FixtureScene, now: Date = Date()) -> [ActiveCall] {
        switch scene {
        case .incomingCall:
            return [incoming()]
        case .inCall, .inCallHoldForMe:
            return [connected(activeCaller, id: "fx-call-1", since: now.addingTimeInterval(-207))]
        case .inCallUnencrypted:
            // The phone system declined SRTP.
            return [connected(activeCaller, id: "fx-call-1", since: now.addingTimeInterval(-207), encrypted: false)]
        case .inCallTwoCalls:
            var held = connected(activeCaller, id: "fx-call-1", since: now.addingTimeInterval(-412))
            held.setHeld(true)
            let talking = connected(incomingCaller, id: "fx-call-2", since: now.addingTimeInterval(-63),
                                    direction: .inbound)
            return [held, talking]
        default:
            return []
        }
    }

    static func incoming() -> ActiveCall {
        ActiveCall(uuid: UUID(), callToken: "fx-token-1", remoteUri: incomingCaller.uri,
                   remoteName: incomingCaller.name, direction: .inbound, state: .incoming)
    }

    static func connected(
        _ party: (name: String, uri: String),
        id: String,
        since: Date,
        direction: ActiveCall.CallDirection = .outbound,
        encrypted: Bool = true
    ) -> ActiveCall {
        var call = ActiveCall(uuid: UUID(), callToken: direction == .inbound ? "tok-\(id)" : nil,
                              remoteUri: party.uri, remoteName: party.name,
                              direction: direction, state: .connected)
        call.callId = id
        call.connectedAt = since
        call.isEncrypted = encrypted
        return call
    }
}
#endif
