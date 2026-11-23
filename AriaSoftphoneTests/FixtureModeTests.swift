import XCTest
@testable import AriaSoftphone

final class FixtureModeTests: XCTestCase {
    // MARK: Launch arguments

    func testInactiveWithoutAFixtureArgument() {
        let parsed = FixtureMode.parse(["AriaSoftphone", "-FixtureScene", "in-call"])
        XCTAssertFalse(parsed.isActive)
    }

    func testEitherArgumentActivates() {
        XCTAssertTrue(FixtureMode.parse(["app", "-UITestMode"]).isActive)
        XCTAssertTrue(FixtureMode.parse(["app", "-ScreenshotMode"]).isActive)
    }

    func testSceneDefaultsToDialer() {
        XCTAssertEqual(FixtureMode.parse(["app", "-UITestMode"]).scene, .dialer)
        XCTAssertEqual(FixtureMode.parse(["app", "-UITestMode", "-FixtureScene"]).scene, .dialer)
        XCTAssertEqual(FixtureMode.parse(["app", "-UITestMode", "-FixtureScene", "nope"]).scene, .dialer)
    }

    func testSceneIsReadByScreenshotName() {
        let parsed = FixtureMode.parse(["app", "-ScreenshotMode", "-FixtureScene", "in-call-two-calls"])
        XCTAssertEqual(parsed.scene, .inCallTwoCalls)
    }

    func testTheTestHostIsNotInFixtureMode() {
        XCTAssertFalse(FixtureMode.isActive)
        XCTAssertNil(FixtureMode.scene)
    }

    // MARK: Scenes

    func testScenesFollowTheDesignSpecNumbering() {
        let names = FixtureScene.allCases.map { "\($0.number)-\($0.rawValue)" }
        XCTAssertEqual(names, [
            "01-onboarding", "02-dialer", "03-dialer-number", "04-incoming-call", "05-in-call",
            "06-in-call-two-calls", "07-history", "08-contacts", "09-voicemail",
            "10-voicemail-playing", "11-settings", "12-forwarding", "13-connection-sheet",
        ])
    }

    func testOnlyOnboardingIsSignedOut() {
        XCTAssertEqual(FixtureScene.allCases.filter { !$0.isSignedIn }, [.onboarding])
    }

    // MARK: Calls

    func testIncomingSceneRingsOneCall() {
        let calls = FixtureData.calls(for: .incomingCall)
        XCTAssertEqual(calls.map(\.state), [.incoming])
        var registry = CallRegistry()
        calls.forEach { registry.add($0) }
        XCTAssertEqual(registry.foreground?.state, .incoming)
    }

    func testInCallSceneHasOneTalkingCall() {
        var registry = CallRegistry()
        FixtureData.calls(for: .inCall).forEach { registry.add($0) }
        XCTAssertNotNil(registry.talking?.callId)
        XCTAssertTrue(registry.background.isEmpty)
        XCTAssertGreaterThan(registry.talking?.duration ?? 0, 60)
    }

    func testTwoCallSceneHoldsTheOlderAndCanSwap() {
        var registry = CallRegistry()
        FixtureData.calls(for: .inCallTwoCalls).forEach { registry.add($0) }
        XCTAssertEqual(registry.count, 2)
        let held = registry.calls[0], talking = registry.calls[1]
        XCTAssertTrue(held.isOnHold)
        XCTAssertEqual(registry.foreground?.uuid, talking.uuid)
        XCTAssertTrue(registry.canSwap(active: talking.uuid, held: held.uuid))
        XCTAssertNotNil(registry.attendedTransferPair)
    }

    func testOtherScenesHaveNoCalls() {
        XCTAssertTrue(FixtureData.calls(for: .dialer).isEmpty)
        XCTAssertTrue(FixtureData.calls(for: .history).isEmpty)
    }

    // MARK: Data

    func testHistoryIsNewestFirstWithMissedCalls() {
        let history = FixtureData.history()
        XCTAssertEqual(history.map(\.startedAt), history.map(\.startedAt).sorted(by: >))
        XCTAssertTrue(history.contains { $0.isMissed })
    }

    func testHistoryStoreFromRecordsDoesNotLoadOrSave() {
        let store = CallHistoryStore(fileURL: nil, records: FixtureData.history())
        XCTAssertEqual(store.records.count, FixtureData.history().count)
        store.clear()
        XCTAssertTrue(store.records.isEmpty)
    }

    func testFixtureContactsAllHaveNumbers() async throws {
        let source = FixtureContactsSource()
        let granted = try await source.requestAccess()
        XCTAssertTrue(granted)
        let contacts = try source.fetchContacts()
        XCTAssertFalse(contacts.isEmpty)
        XCTAssertTrue(contacts.allSatisfy { !$0.phoneNumbers.isEmpty })
        XCTAssertTrue(contacts.contains { $0.isFavorite })
    }

    func testRefusedContactsAccess() async throws {
        let granted = try await FixtureContactsSource(accessGranted: false).requestAccess()
        XCTAssertFalse(granted)
    }

    // MARK: Voicemail

    @MainActor
    func testVoicemailServiceLoadsMarksAndDeletesThroughItsBackend() async {
        let service = VoicemailService(backend: FixtureVoicemailBackend())
        await service.refresh()
        XCTAssertEqual(service.messages.count, 4)
        XCTAssertEqual(service.unreadCount, 2)
        XCTAssertTrue(service.messages.contains { $0.transcription != nil })

        let first = service.messages[0]
        await service.markRead(first)
        XCTAssertEqual(service.unreadCount, 1)

        await service.delete(first)
        XCTAssertEqual(service.messages.count, 3)
        await service.refresh()
        XCTAssertEqual(service.messages.count, 3, "the backend remembers the delete")
    }

    @MainActor
    func testNoMailbox() async {
        let service = VoicemailService(backend: FixtureVoicemailBackend(messages: nil))
        await service.refresh()
        XCTAssertFalse(service.hasMailbox)
        XCTAssertTrue(service.messages.isEmpty)
    }

    func testFixtureAudioIsAPlayableWavOfTheMessageLength() async throws {
        let backend = FixtureVoicemailBackend()
        let url = try await backend.audioFile(messageId: "vm-1")
        defer { try? FileManager.default.removeItem(at: url) }
        let player = try AVAudioPlayerProbe(url: url)
        XCTAssertEqual(player.duration, 38, accuracy: 0.1)
    }
}

import AVFoundation

/// Opens a file with AVAudioPlayer, as the voicemail player does.
private struct AVAudioPlayerProbe {
    let duration: TimeInterval
    init(url: URL) throws {
        duration = try AVAudioPlayer(contentsOf: url).duration
    }
}
