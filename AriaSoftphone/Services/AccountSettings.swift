import Foundation

/// The provisioned account as persisted: non-secret fields in `UserDefaults`,
/// secrets in the Keychain.
///
/// Every path that needs the account — login, the outgoing-call action, and
/// the engine restore that runs at launch and inside a VoIP push — reads it
/// through here, so they cannot disagree about defaults.
struct AccountSettings: Equatable {
    var username: String
    var domain: String
    var registrar: String
    var port: Int
    var transport: String
    var displayName: String
    var apiUrl: String
    var gatewayUrl: String
    var voicemailNumber: String

    /// Signalling defaults to TLS. An explicit, supported transport from
    /// provisioning is honoured; anything else is not a reason to fall back to
    /// cleartext.
    static let defaultTransport = "tls"

    /// UserDefaults keys. Several are also bound with `@AppStorage` in views.
    enum Key {
        static let username = "sipUsername"
        static let domain = "sipDomain"
        static let registrar = "sipRegistrar"
        static let port = "sipPort"
        static let transport = "sipTransport"
        static let displayName = "sipDisplayName"
        static let apiUrl = "apiUrl"
        static let gatewayUrl = "gatewayUrl"
        static let voicemailNumber = "voicemailNumber"
        static let extensionId = "extensionId"
        static let tenantId = "tenantId"
        static let pbxDeviceId = "pbxDeviceId"
    }

    static func load(from defaults: UserDefaults = .standard) -> AccountSettings {
        AccountSettings(
            username: defaults.string(forKey: Key.username) ?? "",
            domain: defaults.string(forKey: Key.domain) ?? "",
            registrar: defaults.string(forKey: Key.registrar) ?? "",
            port: defaults.integer(forKey: Key.port),
            transport: defaults.string(forKey: Key.transport) ?? "",
            displayName: defaults.string(forKey: Key.displayName) ?? "",
            apiUrl: defaults.string(forKey: Key.apiUrl) ?? "",
            gatewayUrl: defaults.string(forKey: Key.gatewayUrl) ?? "",
            voicemailNumber: defaults.string(forKey: Key.voicemailNumber) ?? ""
        )
    }

    /// Build the persisted form of a scanned provisioning code.
    init(provisioning credentials: ProvisioningCredentials) {
        // SIP domain = tenant domain (used in From/To headers for auth).
        // SIP registrar = server address (where to send REGISTER).
        self.init(
            username: credentials.username,
            domain: credentials.tenantDomain.isEmpty ? credentials.server : credentials.tenantDomain,
            registrar: credentials.server,
            port: credentials.port,
            transport: credentials.transport.lowercased(),
            displayName: credentials.displayName,
            apiUrl: credentials.apiUrl,
            gatewayUrl: "",
            voicemailNumber: credentials.voicemail
        )
    }

    init(
        username: String,
        domain: String,
        registrar: String,
        port: Int,
        transport: String,
        displayName: String,
        apiUrl: String,
        gatewayUrl: String,
        voicemailNumber: String
    ) {
        self.username = username
        self.domain = domain
        self.registrar = registrar
        self.port = port
        self.transport = transport
        self.displayName = displayName
        self.apiUrl = apiUrl
        self.gatewayUrl = gatewayUrl
        self.voicemailNumber = voicemailNumber
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(username, forKey: Key.username)
        defaults.set(domain, forKey: Key.domain)
        defaults.set(registrar, forKey: Key.registrar)
        defaults.set(port, forKey: Key.port)
        defaults.set(transport, forKey: Key.transport)
        defaults.set(displayName, forKey: Key.displayName)
        defaults.set(apiUrl, forKey: Key.apiUrl)
        defaults.set(gatewayUrl, forKey: Key.gatewayUrl)
        defaults.set(voicemailNumber, forKey: Key.voicemailNumber)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        for key in [
            Key.username, Key.domain, Key.registrar, Key.port, Key.transport,
            Key.displayName, Key.apiUrl, Key.gatewayUrl, Key.voicemailNumber,
            Key.extensionId, Key.tenantId, Key.pbxDeviceId,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    var isProvisioned: Bool {
        !username.isEmpty && !domain.isEmpty
    }

    /// The transport to signal over: the stored one when it is a supported
    /// value, TLS otherwise.
    var effectiveTransport: String {
        let stored = transport.lowercased()
        return isValidTransport(stored) ? stored : Self.defaultTransport
    }

    /// The stored port, or the well-known port for the transport when none
    /// was provisioned.
    var effectivePort: Int {
        if port > 0 && port <= Int(UInt16.max) { return port }
        return effectiveTransport == "tls" ? 5061 : 5060
    }

    func sipCredentials(password: String) -> SipCredentials {
        SipCredentials(
            username: username,
            password: password,
            domain: domain,
            registrar: registrar.isEmpty ? nil : registrar,
            transport: effectiveTransport,
            port: UInt16(effectivePort),
            authUsername: nil,
            displayName: displayName
        )
    }
}
