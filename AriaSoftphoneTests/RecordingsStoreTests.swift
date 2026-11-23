import XCTest
@testable import AriaSoftphone

final class RecordingsStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recordings-\(UUID().uuidString)", isDirectory: true)
        suiteName = "recordings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(now: @escaping () -> Date = Date.init) -> RecordingsStore {
        RecordingsStore(directory: directory, defaults: defaults, now: now)
    }

    func testDisclosureStartsUnacceptedAndPersists() {
        let store = makeStore()
        XCTAssertFalse(store.disclosureAccepted)
        store.acceptDisclosure()
        XCTAssertTrue(makeStore().disclosureAccepted)
    }

    func testBeginPutsTheFileInTheRecordingsDirectory() throws {
        let store = makeStore()
        let recording = try store.begin(callId: "c1", remoteUri: "1001", remoteName: "Ann")
        XCTAssertEqual(recording.url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(recording.url.pathExtension, "wav")
        XCTAssertTrue(recording.isInProgress)
        XCTAssertEqual(store.recordings.map(\.id), [recording.id])
    }

    func testFinishClosesTheEntryAndItSurvivesAReload() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = makeStore(now: { clock })
        let recording = try store.begin(callId: "c1", remoteUri: "1001", remoteName: nil)
        FileManager.default.createFile(atPath: recording.url.path, contents: Data([0]))
        clock = clock.addingTimeInterval(42)
        store.finish(callId: "c1", path: recording.url.path)
        XCTAssertEqual(store.recordings.first?.duration, 42)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.recordings.count, 1)
        XCTAssertEqual(reloaded.recordings.first?.duration, 42)
        XCTAssertEqual(reloaded.recordings.first?.url.lastPathComponent, recording.fileName)
        XCTAssertEqual(reloaded.shareURL(for: reloaded.recordings[0])?.lastPathComponent, recording.fileName)
    }

    func testAnEntryWhoseFileIsGoneIsNotListed() throws {
        let store = makeStore()
        _ = try store.begin(callId: "c1", remoteUri: "1001", remoteName: nil)
        XCTAssertTrue(makeStore().recordings.isEmpty)
    }

    func testDeleteAndClearRemoveTheFiles() throws {
        let store = makeStore()
        let first = try store.begin(callId: "c1", remoteUri: "1001", remoteName: nil)
        let second = try store.begin(callId: "c2", remoteUri: "1002", remoteName: nil)
        for recording in [first, second] {
            FileManager.default.createFile(atPath: recording.url.path, contents: Data([0]))
        }
        store.delete(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(store.recordings.map(\.id), [second.id])
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertTrue(store.recordings.isEmpty)
    }

    func testFinishingAnUnknownCallChangesNothing() throws {
        let store = makeStore()
        let recording = try store.begin(callId: "c1", remoteUri: "1001", remoteName: nil)
        store.finish(callId: "other", path: nil)
        XCTAssertEqual(store.recordings.first?.id, recording.id)
        XCTAssertTrue(store.recordings[0].isInProgress)
    }
}
