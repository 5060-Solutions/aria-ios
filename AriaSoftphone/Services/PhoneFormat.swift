import Foundation
import PhoneNumberKit

/// Number formatting for display, a pure function of the default country.
///
/// Display only: what is dialed is always the raw typed string. Extensions,
/// star codes, short codes and anything that is not plainly a phone number
/// come back exactly as given.
struct PhoneFormat {
    /// ISO 3166-1 alpha-2, already checked by `normalized(_:)`.
    let country: String

    // Building the utility parses the libphonenumber metadata once.
    private static let utility = PhoneNumberUtility()

    /// Shortest digit string without a `+` that is treated as a phone number.
    /// Below this are extensions and short codes (911, 1001, 55501).
    static let minimumNationalDigits = 7

    init(country: String) {
        self.country = Self.normalized(country) ?? Self.deviceCountry
    }

    /// `code` uppercased when libphonenumber has a plan for it, else nil.
    static func normalized(_ code: String?) -> String? {
        guard let code = code?.uppercased(), !code.isEmpty,
              utility.metadata(for: code) != nil else { return nil }
        return code
    }

    /// The device's region, "US" when it has none libphonenumber knows.
    static var deviceCountry: String {
        normalized(Locale.current.region?.identifier) ?? "US"
    }

    // MARK: - As typed

    /// The dialer's number as it is typed: "8004444444" is "(800) 444-4444",
    /// "+442071838750" is "+44 20 7183 8750". Strings with `*` or `#`, and
    /// digit strings shorter than a number, are returned as typed.
    func typing(_ raw: String) -> String {
        guard let cleaned = Self.cleaned(raw) else { return raw }
        let digits = cleaned.filter(\.isASCIIDigit)
        let international = cleaned.hasPrefix("+")
        guard international ? digits.count >= 2 : digits.count >= Self.minimumNationalDigits else { return raw }

        let partial = PartialFormatter(utility: Self.utility, defaultRegion: country, withPrefix: true)
        let formatted = partial.formatPartial(cleaned)
        // The formatter only regroups; if it changed or dropped a digit, show
        // what was typed.
        guard formatted.filter(\.isASCIIDigit) == digits, !formatted.isEmpty else { return raw }
        // libphonenumber writes "1(800) ..."; a space after the 1 reads better.
        if formatted.hasPrefix("1(") {
            return "1 " + formatted.dropFirst()
        }
        return formatted
    }

    /// A subtle second line for the dialer, "+1 (800) 444-4444", when the
    /// typed digits are a valid national number for the default country.
    func hint(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.allSatisfy(\.isASCIIDigit),
              raw.count >= Self.minimumNationalDigits,
              let number = try? Self.utility.parse(raw, withRegion: country),
              number.regionID == country,
              Self.utility.isValidPhoneNumber(raw, withRegion: country) else { return nil }
        return "+\(number.countryCode) " + Self.utility.format(number, toType: .national)
    }

    // MARK: - In lists

    /// A number in History, Contacts and Messages: national format for the
    /// default country, international otherwise. Anything that is not a
    /// number (a name, an extension, a star code, a SIP address) is returned
    /// untouched.
    func listed(_ text: String) -> String {
        guard let cleaned = Self.cleaned(text) else { return text }
        let digits = cleaned.filter(\.isASCIIDigit)
        guard cleaned.hasPrefix("+") || digits.count >= Self.minimumNationalDigits else { return text }
        if let number = try? Self.utility.parse(cleaned, withRegion: country),
           Self.utility.isValidPhoneNumber(cleaned, withRegion: country) {
            let style: PhoneNumberFormat = number.regionID == country ? .national : .international
            return Self.utility.format(number, toType: style)
        }
        return typing(cleaned)
    }

    // MARK: - Dial strings

    /// The string to dial for text a person typed or pasted: digits, `*` and
    /// `#`, and a leading `+`, with spaces, dashes, dots and brackets dropped.
    /// nil when nothing dialable is left.
    static func dialString(_ text: String) -> String? {
        var result = ""
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isASCIIDigit || ch == "*" || ch == "#" {
                result.append(ch)
            } else if ch == "+" && result.isEmpty {
                result.append(ch)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// `text` as digits with an optional leading `+`, when it is made only of
    /// digits and the separators people write numbers with; otherwise nil.
    private static func cleaned(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let separators: Set<Character> = [" ", "\u{00A0}", "-", "(", ")", ".", "\u{2011}"]
        var result = ""
        for ch in text {
            if ch.isASCIIDigit {
                result.append(ch)
            } else if ch == "+" && result.isEmpty {
                result.append(ch)
            } else if !separators.contains(ch) {
                return nil
            }
        }
        return result.contains(where: \.isASCIIDigit) ? result : nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The company's calling country: where a number typed without a country
/// code is taken to be. Read from the PBX and kept on the device.
@MainActor
final class DefaultCountry: ObservableObject {
    static let shared = DefaultCountry()

    nonisolated static let defaultsKey = "callingCountry"

    @Published private(set) var country: String

    /// The stored country, for code outside the main actor.
    nonisolated static var cached: String {
        PhoneFormat.normalized(UserDefaults.standard.string(forKey: defaultsKey)) ?? PhoneFormat.deviceCountry
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        country = PhoneFormat.normalized(defaults.string(forKey: Self.defaultsKey)) ?? PhoneFormat.deviceCountry
    }

    var format: PhoneFormat { PhoneFormat(country: country) }

    func set(_ code: String?) {
        guard let code = PhoneFormat.normalized(code) else { return }
        defaults.set(code, forKey: Self.defaultsKey)
        if code != country { country = code }
    }

    /// Ask the PBX for the company's calling country. GET .../calling/settings
    /// is a tenant-admin route, so a seat gets 403 and keeps the cached value
    /// (the device region until something better is known); `/me` carries no
    /// country.
    func refresh() async {
        if FixtureMode.isActive { return }
        let settings = AccountSettings.load()
        let tenantId = defaults.string(forKey: AccountSettings.Key.tenantId) ?? ""
        guard !settings.apiUrl.isEmpty, !tenantId.isEmpty,
              KeychainStore.get(KeychainStore.jwtKey) != nil else { return }
        let client = PbxApiClient(baseUrl: settings.apiUrl)
        let code = try? await PbxSession.shared.authorized { jwt in
            try await client.callingCountry(jwt: jwt, tenantId: tenantId)
        }
        set(code)
    }
}
