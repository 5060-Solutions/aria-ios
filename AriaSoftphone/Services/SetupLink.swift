import Foundation

/// One-click setup links (`aria://provision?v=1&url=...`), through the core's
/// `provision_preview` / `provision_redeem`, which enforce the link rules
/// (https only, no userinfo, `/provision/softphone/<token>`, no redirects,
/// 10 s timeout, 16 KB cap). Both block on the network, so they run off the
/// main thread here.
///
/// The preview uses nothing up; only the redeem, after the user confirmed
/// the preview, consumes the link.
struct SetupLinkService {
    var preview: (String) throws -> ProvisionPreview
    var redeem: (String) throws -> ProvisionedAccount

    static let live = SetupLinkService(
        preview: { try provisionPreview(link: $0) },
        redeem: { try provisionRedeem(link: $0) }
    )

    func fetchPreview(_ link: String) async throws -> ProvisionPreview {
        try await Self.offMain { try preview(link) }
    }

    func fetchAccount(_ link: String) async throws -> ProvisionedAccount {
        try await Self.offMain { try redeem(link) }
    }

    private static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// A version-1 setup link, as opposed to a legacy QR link (which has no
    /// `v` and is parsed by `parseProvisioningURI`).
    static func isVersionedLink(_ link: String) -> Bool {
        guard let components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "aria",
              components.host?.lowercased() == "provision" else { return false }
        return components.queryItems?.contains { $0.name == "v" } ?? false
    }

    /// A user-facing sentence for a failed preview or redeem. The core's
    /// messages are written for the user and never contain the link.
    static func describe(_ error: Error) -> String {
        switch error as? ProvisionError {
        case .InvalidLink?:
            return String(localized: "This isn't a valid Aria setup link.")
        case .Expired?:
            return String(localized: "This setup link has expired or was already used. Ask your administrator for a new one.")
        case .Network?:
            return String(localized: "Couldn't reach the setup server. Check your connection and try again.")
        case .Mismatch?:
            return String(localized: "The setup server returned a different line than it showed. Nothing was saved.")
        case .Server(let message)?:
            return message.isEmpty ? String(localized: "The setup server sent an unexpected reply.") : message
        case nil:
            return error.localizedDescription
        }
    }
}

extension ProvisioningCredentials {
    /// The account a redeemed setup link returned, in the shape the rest of
    /// sign-in uses. The PBX API is the setup server itself: setup links are
    /// served by the API at `https://<server_host>/provision/softphone/...`.
    init(redeemed account: ProvisionedAccount) {
        let transport = isValidTransport(account.transport) ? account.transport.lowercased() : AccountSettings.defaultTransport
        let defaultPort = transport == "tls" ? 5061 : 5060
        self.init(
            server: Self.host(of: account.outboundProxy) ?? account.domain,
            port: account.port > 0 ? Int(account.port) : defaultPort,
            username: account.username,
            password: account.password,
            displayName: account.displayName,
            transport: transport,
            voicemail: account.voicemail ?? "",
            apiUrl: "https://\(account.serverHost)",
            tenantDomain: account.domain
        )
    }

    /// `host` from `host` or `host:port`; nil for nothing.
    private static func host(of proxy: String?) -> String? {
        guard let proxy = proxy?.trimmingCharacters(in: .whitespaces), !proxy.isEmpty else { return nil }
        if proxy.hasPrefix("[") {
            return proxy.split(separator: "]").first.map { String($0.dropFirst()) }
        }
        return proxy.split(separator: ":").first.map(String.init)
    }
}
