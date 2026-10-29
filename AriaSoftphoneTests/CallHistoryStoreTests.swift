import XCTest
@testable import AriaSoftphone

final class CallHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallHistoryStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ number: String, outcome: CallOutcome = .answered, direction: CallRecord.Direction = .inbound) -> CallRecord {
        CallRecord(direction: direction, remoteUri: number, remoteName: nil,
                   startedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 42, outcome: outcome)
    }

    func testStartsEmptyWithoutAFile() {
        XCTAssertTrue(CallHistoryStore(fileURL: fileURL).records.isEmpty)
    }

    func testPersistsNewestFirstAcrossInstances() {
        let store = CallHistoryStore(fileURL: fileURL)
        store.add(record("100"))
        store.add(record("200", outcome: .missed))

        let reloaded = CallHistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.records.map(\.remoteUri), ["200", "100"])
        XCTAssertEqual(reloaded.records, store.records)
        XCTAssertEqual(reloaded.records.first?.outcome, .missed)
    }

    func testCapsTheNumberOfRecords() {
        let store = CallHistoryStore(fileURL: fileURL)
        for i in 0..<(CallHistoryStore.maxRecords + 5) {
            store.add(record("\(i)"))
        }
        XCTAssertEqual(store.records.count, CallHistoryStore.maxRecords)
        XCTAssertEqual(store.records.first?.remoteUri, "\(CallHistoryStore.maxRecords + 4)")
    }

    func testRemoveAndClearPersist() {
        let store = CallHistoryStore(fileURL: fileURL)
        ["1", "2", "3"].forEach { store.add(record($0)) }

        store.remove(atOffsets: IndexSet([0, 2]))
        XCTAssertEqual(CallHistoryStore(fileURL: fileURL).records.map(\.remoteUri), ["2"])

        store.clear()
        XCTAssertTrue(CallHistoryStore(fileURL: fileURL).records.isEmpty)
    }

    func testUnreadableFileIsDiscarded() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let store = CallHistoryStore(fileURL: fileURL)
        XCTAssertTrue(store.records.isEmpty)
        store.add(record("1"))
        XCTAssertEqual(CallHistoryStore(fileURL: fileURL).records.count, 1)
    }

    func testMissedIsOnlyForUnansweredIncoming() {
        XCTAssertTrue(record("1", outcome: .missed).isMissed)
        XCTAssertFalse(record("1", outcome: .rejected).isMissed)
        XCTAssertFalse(record("1", outcome: .answered).isMissed)
        XCTAssertFalse(record("1", outcome: .missed, direction: .outbound).isMissed)
    }
}
