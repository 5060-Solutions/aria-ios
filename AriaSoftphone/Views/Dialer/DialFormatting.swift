import Foundation

/// How the dialer shows a number as it is typed. Display only: the dialed
/// string itself is never changed.
enum DialFormatter {
    /// North American numbers are grouped as they are typed:
    /// "(415) 555-0142", "1 (415) 555-0142", "+1 415 555 0142".
    /// Short codes and extensions, other countries' numbers and anything with
    /// `*` or `#` are shown as typed.
    static func format(_ dialed: String) -> String {
        guard !dialed.isEmpty, !dialed.contains(where: { $0 == "*" || $0 == "#" }) else { return dialed }

        if dialed.hasPrefix("+") {
            let digits = String(dialed.dropFirst())
            guard digits.allSatisfy(\.isASCIIDigit), digits.hasPrefix("1") else { return dialed }
            let national = String(digits.dropFirst())
            guard national.count <= 10 else { return dialed }
            let groups = group(national, sizes: [3, 3, 4])
            return (["+1"] + groups).joined(separator: " ")
        }

        guard dialed.allSatisfy(\.isASCIIDigit) else { return dialed }
        if dialed.count == 11, dialed.hasPrefix("1") {
            return "1 " + national(String(dialed.dropFirst()))
        }
        switch dialed.count {
        case 0...4:
            return dialed
        case 5...7:
            let head = dialed.prefix(3), tail = dialed.dropFirst(3)
            return "\(head)-\(tail)"
        case 8...10:
            return national(dialed)
        default:
            return dialed
        }
    }

    /// "(415) 555-0142" for up to ten digits, partially filled.
    private static func national(_ digits: String) -> String {
        let groups = group(digits, sizes: [3, 3, 4])
        var result = "(\(groups[0]))"
        if groups.count > 1 { result += " \(groups[1])" }
        if groups.count > 2 { result += "-\(groups[2])" }
        return result
    }

    private static func group(_ digits: String, sizes: [Int]) -> [String] {
        var groups: [String] = []
        var rest = Substring(digits)
        for size in sizes where !rest.isEmpty {
            groups.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        if !rest.isEmpty { groups[groups.count - 1] += rest }
        return groups
    }
}

/// Finds the name for a number among contacts and call history.
struct ContactMatcher {
    struct Entry: Equatable {
        let name: String
        let number: String
    }

    private var byKey: [String: String] = [:]

    init(entries: [Entry]) {
        // Earlier entries win: contacts are passed before history.
        for entry in entries.reversed() where !entry.name.isEmpty {
            if let key = Self.key(entry.number) { byKey[key] = entry.name }
        }
    }

    init(contacts: [ContactEntry], history: [CallRecord]) {
        let fromContacts = contacts.flatMap { contact in
            contact.phoneNumbers.map { Entry(name: contact.name, number: $0) }
        }
        let fromHistory = history.compactMap { record -> Entry? in
            guard let name = record.remoteName, !name.isEmpty else { return nil }
            return Entry(name: name, number: record.remoteUri)
        }
        self.init(entries: fromContacts + fromHistory)
    }

    /// The name for `dialed`, once at least three digits have been typed.
    func name(for dialed: String) -> String? {
        guard let key = Self.key(dialed) else { return nil }
        return byKey[key]
    }

    /// Comparable form of a number: its digits, and only the last ten of a
    /// longer one, so "+1 (415) 555-0142" and "4155550142" match.
    static func key(_ number: String) -> String? {
        var raw = number
        if let colon = raw.firstIndex(of: ":"), raw.hasPrefix("sip") { raw = String(raw[raw.index(after: colon)...]) }
        if let at = raw.firstIndex(of: "@") { raw = String(raw[..<at]) }
        let digits = raw.filter(\.isASCIIDigit)
        guard digits.count >= 3 else { return nil }
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
