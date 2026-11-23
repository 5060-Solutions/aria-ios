import XCTest
@testable import AriaSoftphone

final class CodecPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "codec-tests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheDefaultIsTheCoresOrder() {
        XCTAssertEqual(CodecPreferences.load(from: defaults).ordered, [.opus, .pcmu, .pcma])
    }

    func testOrderAndSwitchesRoundTrip() {
        var prefs = CodecPreferences.standard
        prefs.entries.move(fromOffsets: [2], toOffset: 0)   // PCMA first
        prefs.entries[1].enabled = false                     // Opus off
        prefs.save(to: defaults)
        XCTAssertEqual(CodecPreferences.load(from: defaults).ordered, [.pcma, .pcmu])
    }

    func testNothingEnabledStillOffersG711() {
        var prefs = CodecPreferences.standard
        for index in prefs.entries.indices { prefs.entries[index].enabled = false }
        XCTAssertEqual(prefs.ordered, [.pcmu])
    }

    func testUnknownAndMissingStoredEntries() {
        defaults.set(["pcma:1", "bogus:1", "pcma:0"], forKey: CodecPreferences.storageKey)
        let prefs = CodecPreferences.load(from: defaults)
        XCTAssertEqual(prefs.entries.map(\.codec), [.pcma, .opus, .pcmu, .g729])
        XCTAssertEqual(prefs.ordered, [.pcma], "codecs missing from storage come back off")
    }
}

private struct FakeContacts: ContactsSource {
    var contacts: [ContactEntry]
    func requestAccess() async throws -> Bool { true }
    func fetchContacts() throws -> [ContactEntry] { contacts }
}

final class CallerNamesTests: XCTestCase {
    private func names(authorized: Bool = true) -> CallerNames {
        let names = CallerNames(source: FakeContacts(contacts: [
            ContactEntry(name: "Ann Lee", phoneNumbers: ["+1 (555) 201-4410"], hasImage: false, thumbnailData: nil),
            ContactEntry(name: "Front Desk", phoneNumbers: ["1000"], hasImage: false, thumbnailData: nil),
        ]), isAuthorized: { authorized })
        names.reloadNow()
        return names
    }

    func testNumbersMatchOnTheirLastTenDigitsOrWhole() {
        let names = names()
        XCTAssertEqual(names.name(for: "sip:+15552014410@carrier.example"), "Ann Lee")
        XCTAssertEqual(names.name(for: "5552014410"), "Ann Lee")
        XCTAssertEqual(names.name(for: "sip:1000@acme"), "Front Desk")
        XCTAssertNil(names.name(for: "10000"))
        XCTAssertNil(names.name(for: "sip:bob@acme"))
    }

    func testARealNameFromThePbxIsKept() {
        let names = names()
        XCTAssertEqual(names.resolve(uri: "1000", current: "Reception"), "Reception")
        XCTAssertEqual(names.resolve(uri: "1000", current: nil), "Front Desk")
        XCTAssertEqual(names.resolve(uri: "sip:1000@acme", current: "1000"), "Front Desk",
                       "a name that is only the number is replaced")
    }

    func testNothingWithoutContactsAccess() {
        XCTAssertNil(names(authorized: false).name(for: "1000"))
    }
}

private final class FakeVoicemailBackend: VoicemailBackend {
    var stored: [VoicemailService.Message]
    var fetches = 0
    init(_ messages: [VoicemailService.Message]) { stored = messages }
    func messages() async throws -> [VoicemailService.Message]? { fetches += 1; return stored }
    func markRead(messageId: String) async throws {
        if let i = stored.firstIndex(where: { $0.id == messageId }) { stored[i].read = true }
    }
    func delete(messageId: String) async throws { stored.removeAll { $0.id == messageId } }
    func audioFile(messageId: String) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func reset() {}
}

private final class NoSelfService: SelfServiceBackend {
    func doNotDisturb() async throws -> Bool { false }
    func setDoNotDisturb(_ enabled: Bool) async throws {}
    func forwards() async throws -> [PbxApiClient.CallForward] { [] }
    func createForward(type: PbxApiClient.ForwardType, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward { throw URLError(.badURL) }
    func updateForward(id: String, destination: String, ringTimeoutSecs: Int,
                       enabled: Bool) async throws -> PbxApiClient.CallForward { throw URLError(.badURL) }
    func deleteForward(id: String) async throws {}
    func callRecords(limit: Int) async throws -> [PbxApiClient.ServerCall] { [] }
    func reset() {}
}

@MainActor
final class ActivityRefresherTests: XCTestCase {
    private func message(_ id: String, read: Bool) -> VoicemailService.Message {
        VoicemailService.Message(id: id, boxId: "b", callerId: "1001", durationSecs: 10, read: read,
                                 createdAt: Date(), transcription: nil)
    }

    private var defaults: UserDefaults!
    private var badges: [Int] = []

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "refresher-tests")
        defaults.removePersistentDomain(forName: "refresher-tests")
        badges = []
    }

    private func make(_ messages: [VoicemailService.Message]) -> (ActivityRefresher, VoicemailService, FakeVoicemailBackend) {
        let backend = FakeVoicemailBackend(messages)
        let voicemail = VoicemailService(backend: backend)
        let refresher = ActivityRefresher(voicemail: voicemail, selfService: SelfService(backend: NoSelfService()),
                                          defaults: defaults)
        refresher.isSignedIn = { true }
        refresher.setBadge = { [unowned self] in self.badges.append($0) }
        return (refresher, voicemail, backend)
    }

    func testTheBadgeFollowsUnreadVoicemail() async {
        let (refresher, voicemail, _) = make([message("a", read: false), message("b", read: false), message("c", read: true)])
        await voicemail.refresh()
        XCTAssertEqual(badges.last, 2)
        await voicemail.markRead(voicemail.messages.first { !$0.read }!)
        XCTAssertEqual(badges.last, 1)
        _ = refresher
    }

    func testTheBadgeSettingTurnsItOff() async {
        let (refresher, voicemail, _) = make([message("a", read: false)])
        await voicemail.refresh()
        XCTAssertEqual(badges.last, 1)
        refresher.badgeEnabled = false
        XCTAssertEqual(badges.last, 0)
        XCTAssertFalse(ActivityRefresher(voicemail: voicemail, selfService: SelfService(backend: NoSelfService()),
                                         defaults: defaults).badgeEnabled)
    }

    func testPollingRunsOnlyWhileActive() {
        let (refresher, _, _) = make([])
        XCTAssertFalse(refresher.isPolling)
        refresher.becameActive()
        XCTAssertTrue(refresher.isPolling)
        XCTAssertEqual(ActivityRefresher.interval, 60)
        refresher.resignedActive()
        XCTAssertFalse(refresher.isPolling)
    }

    func testEachEndedCallRefreshesVoicemail() {
        let (refresher, _, _) = make([])
        NotificationCenter.default.post(name: CallManager.callEndedNotification, object: nil)
        XCTAssertEqual(refresher.refreshCount, 1)
        refresher.isSignedIn = { false }
        NotificationCenter.default.post(name: CallManager.callEndedNotification, object: nil)
        XCTAssertEqual(refresher.refreshCount, 1, "nothing to refresh when signed out")
    }
}
