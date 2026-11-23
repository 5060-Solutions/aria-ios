import Foundation

/// The manual sign-in form: what the user typed, checked before anything is
/// stored or sent.
///
/// The extension password is POSTed to the API URL, so that URL must be
/// HTTPS with a real host — the same rule the QR and setup-link paths follow
/// (`isValidProvisioningDestination`).
struct ManualSetup: Equatable {
    /// The tenant's SIP domain, e.g. `acme.ariaroute.com`.
    var domain = ""
    /// The SIP server; empty means the domain.
    var server = ""
    var extensionNumber = ""
    var password = ""
    /// The PBX API; empty means `defaultApiUrl`.
    var apiUrl = ""

    static let defaultApiUrl = "https://api.ariaroute.com"

    enum Field: Hashable, CaseIterable {
        case domain, server, extensionNumber, password, apiUrl
    }

    enum Problem: Equatable {
        case required
        case invalidHost
        case invalidExtension
        case notHttps
        case invalidUrl

        var message: String {
            switch self {
            case .required: return String(localized: "Required")
            case .invalidHost: return String(localized: "Enter a host name, like pbx.example.com")
            case .invalidExtension: return String(localized: "Use digits, letters, or . - _ only")
            case .notHttps: return String(localized: "The API address must start with https://")
            case .invalidUrl: return String(localized: "Enter a full address, like https://api.example.com")
            }
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A plain host name or IPv4 address: no scheme, port, path or spaces.
    static func isHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."),
              !host.contains("..") else { return false }
        if isIPv4(host) { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        let hostCharacters = host.unicodeScalars.allSatisfy { allowed.contains($0) }
        return hostCharacters && host.rangeOfCharacter(from: .letters) != nil
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let n = Int(part), part.count <= 3 else { return false }
            return (0...255).contains(n)
        }
    }

    /// SIP user characters, as the core accepts them in an extension.
    static func isExtension(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+*#")
        return !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    var effectiveApiUrl: String {
        let typed = Self.trimmed(apiUrl)
        return typed.isEmpty ? Self.defaultApiUrl : typed
    }

    var effectiveServer: String {
        let typed = Self.trimmed(server).lowercased()
        return typed.isEmpty ? Self.trimmed(domain).lowercased() : typed
    }

    /// Every field that is wrong, and why. Empty when the form can be used.
    func problems() -> [Field: Problem] {
        var problems: [Field: Problem] = [:]
        let domain = Self.trimmed(domain)
        if domain.isEmpty {
            problems[.domain] = .required
        } else if !Self.isHost(domain) {
            problems[.domain] = .invalidHost
        }
        let server = Self.trimmed(server)
        if !server.isEmpty && !Self.isHost(server) {
            problems[.server] = .invalidHost
        }
        let ext = Self.trimmed(extensionNumber)
        if ext.isEmpty {
            problems[.extensionNumber] = .required
        } else if !Self.isExtension(ext) {
            problems[.extensionNumber] = .invalidExtension
        }
        if password.isEmpty {
            problems[.password] = .required
        }
        let api = effectiveApiUrl
        if let components = URLComponents(string: api), let scheme = components.scheme {
            if scheme.lowercased() != "https" {
                problems[.apiUrl] = .notHttps
            } else if components.user != nil || components.password != nil
                        || !Self.isHost(components.host ?? "") {
                problems[.apiUrl] = .invalidUrl
            }
        } else {
            problems[.apiUrl] = .invalidUrl
        }
        if problems[.apiUrl] == nil, problems[.server] == nil, problems[.domain] == nil,
           !isValidProvisioningDestination(apiUrl: api, server: effectiveServer) {
            problems[.apiUrl] = .invalidUrl
        }
        return problems
    }

    var isValid: Bool { problems().isEmpty }

    /// The account to store, in the shape a scanned QR code produces, so
    /// sign-in goes through the one path (`AccountSession.login`). Nil while
    /// the form is invalid.
    func credentials() -> ProvisioningCredentials? {
        guard isValid else { return nil }
        let ext = Self.trimmed(extensionNumber)
        return ProvisioningCredentials(
            server: effectiveServer,
            port: 5061,
            username: ext,
            password: password,
            displayName: ext,
            transport: AccountSettings.defaultTransport,
            voicemail: "",
            apiUrl: effectiveApiUrl,
            tenantDomain: Self.trimmed(domain).lowercased()
        )
    }
}
