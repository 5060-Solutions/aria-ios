import Foundation

/// One call recording: a 16-bit PCM WAV file the core wrote.
struct CallRecording: Codable, Identifiable, Equatable {
    let id: UUID
    /// The file's name inside the recordings directory. Only the name is
    /// stored: the app container's path changes between installs.
    let fileName: String
    /// The engine call id while the call is up; matches the recording to its
    /// call when it stops.
    let callId: String
    let remoteUri: String
    let remoteName: String?
    let startedAt: Date
    /// Nil while recording.
    var endedAt: Date?
    /// Where the file is; set by the store that lists it.
    var url: URL

    enum CodingKeys: String, CodingKey {
        case id, fileName, callId, remoteUri, remoteName, startedAt, endedAt
    }

    init(id: UUID, fileName: String, callId: String, remoteUri: String, remoteName: String?,
         startedAt: Date, endedAt: Date?, url: URL) {
        self.id = id
        self.fileName = fileName
        self.callId = callId
        self.remoteUri = remoteUri
        self.remoteName = remoteName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        callId = try c.decode(String.self, forKey: .callId)
        remoteUri = try c.decode(String.self, forKey: .remoteUri)
        remoteName = try c.decodeIfPresent(String.self, forKey: .remoteName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        url = URL(fileURLWithPath: fileName)
    }

    var displayName: String {
        if let name = remoteName, !name.isEmpty { return name }
        return remoteUri
    }

    var isInProgress: Bool { endedAt == nil }

    /// Length, from the timestamps; zero while recording.
    var duration: TimeInterval {
        guard let endedAt = endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// Call recordings in Application Support/Recordings, with a small JSON index
/// beside them for who and when.
///
/// Recording a call is the user's choice and theirs to disclose: the first
/// recording waits until they have accepted the disclosure
/// (`disclosureAccepted`), which the UI shows.
final class RecordingsStore: ObservableObject {
    static let shared = RecordingsStore(
        directory: RecordingsStore.defaultDirectory(),
        defaults: .standard
    )

    static let disclosureKey = "recordingDisclosureAccepted"

    /// Newest first.
    @Published private(set) var recordings: [CallRecording] = []

    let directory: URL?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(directory: URL?, defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.defaults = defaults
        self.now = now
        recordings = load()
    }

    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    // MARK: Disclosure

    /// Whether the user has confirmed they will tell the other party a call
    /// is recorded (required by law in many places).
    var disclosureAccepted: Bool {
        defaults.bool(forKey: Self.disclosureKey)
    }

    func acceptDisclosure() {
        defaults.set(true, forKey: Self.disclosureKey)
        objectWillChange.send()
    }

    // MARK: Recording lifecycle

    enum StoreError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "There is no room to store recordings on this iPhone."
        }
    }

    /// A new, in-progress entry and the file the core should write to.
    func begin(callId: String, remoteUri: String, remoteName: String?) throws -> CallRecording {
        guard let directory = directory else { throw StoreError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = now()
        let id = UUID()
        let fileName = "\(Self.fileStamp(started))-\(id.uuidString.prefix(8)).wav"
        let recording = CallRecording(
            id: id, fileName: fileName, callId: callId, remoteUri: remoteUri,
            remoteName: remoteName, startedAt: started, endedAt: nil,
            url: directory.appendingPathComponent(fileName)
        )
        update { $0.insert(recording, at: 0) }
        return recording
    }

    /// Close the in-progress recording of `callId`, if there is one. `path`
    /// is what the core returned from `stop_recording`, or nil when the call
    /// ended (the core stopped it then).
    func finish(callId: String, path: String?) {
        guard recordings.contains(where: { $0.callId == callId && $0.isInProgress }) else { return }
        let ended = now()
        update { list in
            for index in list.indices where list[index].callId == callId && list[index].isInProgress {
                list[index].endedAt = ended
            }
        }
    }

    /// Drop an entry whose recording never started.
    func discard(_ recording: CallRecording) {
        try? FileManager.default.removeItem(at: recording.url)
        update { $0.removeAll { $0.id == recording.id } }
    }

    func delete(_ recording: CallRecording) {
        discard(recording)
    }

    /// Remove every recording, e.g. on sign out.
    func clear() {
        for recording in recordings {
            try? FileManager.default.removeItem(at: recording.url)
        }
        update { $0.removeAll() }
    }

    /// The file to hand to a share sheet, if it is there.
    func shareURL(for recording: CallRecording) -> URL? {
        FileManager.default.fileExists(atPath: recording.url.path) ? recording.url : nil
    }

    // MARK: Persistence

    private var indexURL: URL? {
        directory?.appendingPathComponent("index.json")
    }

    private func update(_ change: (inout [CallRecording]) -> Void) {
        var list = recordings
        change(&list)
        recordings = list
        save()
    }

    private func load() -> [CallRecording] {
        guard let directory = directory, let indexURL = indexURL,
              let data = try? Data(contentsOf: indexURL),
              let decoded = try? Self.decoder.decode([CallRecording].self, from: data) else {
            return []
        }
        let fileManager = FileManager.default
        return decoded.compactMap { entry in
            var entry = entry
            entry.url = directory.appendingPathComponent(entry.fileName)
            // A file deleted outside the app has nothing left to list.
            guard fileManager.fileExists(atPath: entry.url.path) else { return nil }
            // An entry left open by a crash or kill mid-call: the core
            // finished the file when its call ended; mark it ended.
            if entry.endedAt == nil {
                let modified = (try? fileManager.attributesOfItem(atPath: entry.url.path))?[.modificationDate] as? Date
                entry.endedAt = modified ?? entry.startedAt
            }
            return entry
        }
    }

    private func save() {
        guard let directory = directory, let indexURL = indexURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(recordings)
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("Failed to save recordings index: \(error)")
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "call-" + formatter.string(from: date)
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
