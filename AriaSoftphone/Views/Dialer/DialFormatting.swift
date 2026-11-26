import Foundation

/// How numbers are shown. Display only: the dialed string itself is never
/// changed. The country is the company's calling country (`DefaultCountry`).
enum DialFormatter {
    /// A number in a list (History, Contacts, Messages): national format for
    /// the default country, international otherwise; anything that is not a
    /// number is returned as given.
    static func format(_ number: String) -> String {
        format(number, country: DefaultCountry.cached)
    }

    static func format(_ number: String, country: String) -> String {
        PhoneFormat(country: country).listed(number)
    }

    /// The dialer's number as it is typed.
    static func typing(_ dialed: String, country: String) -> String {
        PhoneFormat(country: country).typing(dialed)
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
