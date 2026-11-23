import Foundation

/// A small in-memory log of connection and call events, for the
/// Diagnostics screen's "Copy log". Bounded; never written to disk.
///
/// Never log secrets here: no passwords, tokens, push tokens, setup links
/// or call tokens. Numbers the user called are fine — the log is theirs and
/// only leaves the phone when they copy it.
final class AppLog {
    static let shared = AppLog(capacity: 500)

    struct Entry: Equatable {
        let date: Date
        let category: String
        let message: String
    }

    let capacity: Int
    private var entries: [Entry] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func log(_ category: String, _ message: String, date: Date = Date()) {
        lock.lock()
        entries.append(Entry(date: date, category: category, message: Self.redact(message)))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
        #if DEBUG
        print("[\(category)] \(message)")
        #endif
    }

    var all: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// The log as text, oldest first, one line per entry.
    func text() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return all.map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
    }

    /// Belt and braces for messages built from errors: strip anything that
    /// looks like a bearer token or a setup-link token.
    static func redact(_ message: String) -> String {
        var result = message
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9\-_\.]+"#,
            #"eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+"#,
            #"/provision/softphone/[A-Za-z0-9\-_]+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }
}
