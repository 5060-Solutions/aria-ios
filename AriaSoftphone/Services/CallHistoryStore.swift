import Foundation

/// One finished call, as shown in History.
struct CallRecord: Codable, Identifiable, Equatable {
    enum Direction: String, Codable {
        case inbound, outbound
    }

    var id = UUID()
    let direction: Direction
    let remoteUri: String
    let remoteName: String?
    /// When the call was placed or started ringing.
    let startedAt: Date
    /// Talk time; zero for a call that never connected.
    let duration: TimeInterval
    let outcome: CallOutcome

    var displayName: String {
        if let name = remoteName, !name.isEmpty { return name }
        return remoteUri
    }

    /// An incoming call nobody here picked up.
    var isMissed: Bool {
        direction == .inbound && outcome == .missed
    }

    init(
        direction: Direction,
        remoteUri: String,
        remoteName: String?,
        startedAt: Date,
        duration: TimeInterval,
        outcome: CallOutcome
    ) {
        self.direction = direction
        self.remoteUri = remoteUri
        self.remoteName = remoteName
        self.startedAt = startedAt
        self.duration = max(0, duration)
        self.outcome = outcome
    }

    /// The record for a call that has just ended.
    init(call: ActiveCall, outcome: CallOutcome, endedAt: Date = Date()) {
        self.init(
            direction: call.direction == .inbound ? .inbound : .outbound,
            remoteUri: call.remoteUri,
            remoteName: call.remoteName,
            startedAt: call.startedAt,
            duration: call.connectedAt.map { endedAt.timeIntervalSince($0) } ?? 0,
            outcome: outcome
        )
    }
}

/// Call history, persisted as JSON in Application Support.
///
/// Newest first, capped at `maxRecords`. Writes are synchronous and small;
/// they happen once per call.
final class CallHistoryStore: ObservableObject {
    static let shared = CallHistoryStore(fileURL: CallHistoryStore.defaultFileURL())

    static let maxRecords = 500

    @Published private(set) var records: [CallRecord] = []

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        records = load()
    }

    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("call-history.json")
    }

    func add(_ record: CallRecord) {
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records.removeLast(records.count - Self.maxRecords)
        }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where records.indices.contains(index) {
            records.remove(at: index)
        }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() -> [CallRecord] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try Self.decoder.decode([CallRecord].self, from: data)
        } catch {
            print("Discarding unreadable call history: \(error)")
            return []
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(records)
            // Readable after first unlock: a call that ends while the phone is
            // locked still has to be recorded.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("Failed to save call history: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
