import XCTest
@testable import AriaSoftphone

final class HistoryContactsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func record(_ at: Date, missed: Bool = false) -> CallRecord {
        CallRecord(direction: .inbound, remoteUri: "1000", remoteName: "Front Desk", startedAt: at,
                   duration: missed ? 0 : 60, outcome: missed ? .missed : .answered)
    }

    // MARK: History

    func testGroupsByDayNewestFirst() {
        let now = date(23, 15)
        let records = [record(date(23, 14)), record(date(23, 9)), record(date(22, 20)),
                       record(date(19, 10)), record(date(2, 10))]
        let sections = HistoryGrouping.sections(records, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.records.count), [2, 1, 1, 1])
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[1].title, "Yesterday")
        XCTAssertEqual(sections[2].title, date(19, 10).formatted(.dateTime.weekday(.wide)))
        XCTAssertTrue(sections[3].title.contains("2026"))
    }

    func testMissedFilter() {
        let records = [record(date(23, 14), missed: true), record(date(23, 9))]
        XCTAssertEqual(HistoryFilter.missed.apply(records).count, 1)
        XCTAssertEqual(HistoryFilter.all.apply(records).count, 2)
    }

    func testSummaries() {
        let outgoing = CallRecord(direction: .outbound, remoteUri: "1", remoteName: nil, startedAt: Date(),
                                  duration: 754, outcome: .answered)
        XCTAssertEqual(outgoing.summary, "Outgoing · 12:34")
        XCTAssertEqual(outgoing.directionSymbol, "phone.arrow.up.right")
        let missed = record(Date(), missed: true)
        XCTAssertEqual(missed.summary, "Missed")
        XCTAssertEqual(missed.directionSymbol, "phone.down")
    }

    func testRemoveById() {
        let store = CallHistoryStore(fileURL: nil, records: FixtureData.history())
        let first = store.records[0]
        store.remove(id: first.id)
        XCTAssertFalse(store.records.contains(first))
    }

    // MARK: Contacts

    func testIndexLettersFoldAccentsAndSortHashLast() {
        let names = ["Émile Zola", "amelia", "Ben", "+1 555", "Zoë", "Chloé"]
        let contacts = names.map { ContactEntry(name: $0, phoneNumbers: ["1"], hasImage: false, thumbnailData: nil) }
        let sections = ContactIndex.sections(contacts)
        XCTAssertEqual(sections.map(\.letter), ["A", "B", "C", "E", "Z", "#"])
        XCTAssertEqual(ContactIndex.letter(for: "  "), "#")
    }

    @MainActor
    func testFavoritesPersistByName() {
        let defaults = UserDefaults(suiteName: "fav-\(UUID())")!
        let favorites = FavoriteContacts(defaults: defaults)
        let ben = ContactEntry(name: "Ben Carter", phoneNumbers: ["1"], hasImage: false, thumbnailData: nil)
        XCTAssertFalse(favorites.contains(ben))
        favorites.toggle(ben)
        XCTAssertTrue(FavoriteContacts(defaults: defaults).contains(ben))
        favorites.toggle(ben)
        XCTAssertFalse(favorites.contains(ben))
    }

    @MainActor
    func testFixtureFavoritesAreSeeded() {
        let favorites = FavoriteContacts(defaults: UserDefaults(suiteName: "fav-\(UUID())")!)
        favorites.seed(from: FixtureData.contacts)
        XCTAssertEqual(FixtureData.contacts.filter { favorites.contains($0) }.count,
                       FixtureData.contacts.filter(\.isFavorite).count)
    }
}
