import Foundation
import UIKit

/// Emergency numbers never go over VoIP: a VoIP call carries no reliable
/// location and may not reach the local emergency service. They are handed
/// to the phone's own dialer with a `tel:` URL, which places them over the
/// cellular network.
///
/// The list is the core's (`is_emergency_number`: 911, 112, 999, 000 after
/// stripping spaces, dashes, a `sip:`/`tel:` prefix and any host), so every
/// Aria client agrees on it.
enum EmergencyDialer {
    /// Opens the `tel:` URL. Replaced in tests, which must never dial.
    static var open: (URL) -> Void = { url in
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }

    static func isEmergency(_ dial: String) -> Bool {
        isEmergencyNumber(dial: dial)
    }

    /// `tel:` for the digits of an emergency number, or nil if there are
    /// none. Only digits survive, so nothing else reaches the dialer.
    static func telURL(for dial: String) -> URL? {
        var value = dial.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = value.firstIndex(of: ":"),
           ["sip", "sips", "tel"].contains(value[..<colon].lowercased()) {
            value = String(value[value.index(after: colon)...])
        }
        if let cut = value.firstIndex(where: { $0 == "@" || $0 == ";" }) {
            value = String(value[..<cut])
        }
        let digits = value.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    /// Hand `dial` to the native dialer. Returns false (and opens nothing)
    /// if it is not an emergency number.
    @discardableResult
    static func handOff(_ dial: String) -> Bool {
        guard isEmergency(dial), let url = telURL(for: dial) else { return false }
        open(url)
        return true
    }
}
