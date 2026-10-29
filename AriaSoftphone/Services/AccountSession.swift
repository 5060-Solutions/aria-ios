import Foundation

/// Signs the provisioned extension in to the PBX and the push gateway, and
/// out again.
///
/// This used to live inside `SettingsView`, which meant the only way to bring
/// the SIP engine up was to have that screen run a login. It is shared now so
/// setup, settings and the launch-time restore all go through one path.
@MainActor
final class AccountSession: ObservableObject {
    static let shared = AccountSession()

    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?
    /// True while a PBX session token is held.
    @Published private(set) var hasSession: Bool

    private init() {
        hasSession = KeychainStore.get(KeychainStore.jwtKey) != nil
    }

    // MARK: - Provisioning

    /// Persist a scanned (and confirmed) provisioning code.
    func applyProvisioning(_ credentials: ProvisioningCredentials) {
        var account = AccountSettings(provisioning: credentials)
        // Keep the gateway learnt from the last login until the next one
        // replaces it: an account switch resets the engine regardless.
        account.gatewayUrl = AccountSettings.load().gatewayUrl
        account.save()
        // SIP password is a secret — store it in the Keychain, never UserDefaults.
        KeychainStore.set(credentials.password, forKey: KeychainStore.sipPasswordKey)
    }

    // MARK: - PBX Login + Device Registration

    func login() {
        let account = AccountSettings.load()
        let password = KeychainStore.get(KeychainStore.sipPasswordKey) ?? ""

        guard !account.apiUrl.isEmpty, account.isProvisioned, !password.isEmpty else {
            errorMessage = "Missing required fields. Scan a QR code to configure."
            return
        }

        // Defense in depth: never POST the extension password to a cleartext or
        // malformed host, even if configuration was set outside the QR flow.
        guard isValidProvisioningDestination(
            apiUrl: account.apiUrl,
            server: account.registrar.isEmpty ? account.domain : account.registrar
        ) else {
            errorMessage = "Refusing to connect: the configured server is insecure or invalid. The API endpoint must use HTTPS."
            return
        }

        isConnecting = true
        errorMessage = nil

        Task {
            do {
                let client = PbxApiClient(baseUrl: account.apiUrl)

                // Step 1: Extension login
                let loginResult = try await client.extensionLogin(
                    extensionNumber: account.username,
                    password: password,
                    tenantDomain: account.domain
                )
                KeychainStore.set(loginResult.jwt, forKey: KeychainStore.jwtKey)
                hasSession = true
                UserDefaults.standard.set(loginResult.extensionId, forKey: AccountSettings.Key.extensionId)
                UserDefaults.standard.set(loginResult.tenantId, forKey: AccountSettings.Key.tenantId)

                // Step 2: Device registration with the PBX
                let pushToken = KeychainStore.get(KeychainStore.pushTokenKey) ?? ""
                let defaults = UserDefaults.standard
                var gatewayToken = ""
                do {
                    let deviceResult = try await client.registerDevice(
                        jwt: loginResult.jwt,
                        pushToken: pushToken,
                        platform: "ios"
                    )
                    defaults.set(deviceResult.deviceId, forKey: AccountSettings.Key.pbxDeviceId)
                    if !deviceResult.gatewayUrl.isEmpty {
                        defaults.set(deviceResult.gatewayUrl, forKey: AccountSettings.Key.gatewayUrl)
                    }
                    // The PBX says which transport (and port) its mobile SIP
                    // endpoint uses; it outranks what the QR code carried.
                    if isValidTransport(deviceResult.sipTransport) {
                        defaults.set(deviceResult.sipTransport, forKey: AccountSettings.Key.transport)
                        if deviceResult.sipPort > 0 {
                            defaults.set(deviceResult.sipPort, forKey: AccountSettings.Key.port)
                        }
                    }
                    gatewayToken = deviceResult.gatewayToken
                } catch PbxApiClient.ApiError.gatewayTokenUnavailable(let deviceId, _, _) {
                    // The device was stored; only its token is missing.
                    defaults.set(deviceId, forKey: AccountSettings.Key.pbxDeviceId)
                }
                if (defaults.string(forKey: AccountSettings.Key.gatewayUrl) ?? "").isEmpty {
                    defaults.set("https://push.ariaroute.com", forKey: AccountSettings.Key.gatewayUrl)
                }

                // Only a PBX-issued gateway token authenticates to the gateway;
                // the login JWT is not one. Without a token, renew it.
                if gatewayToken.isEmpty {
                    let deviceId = defaults.string(forKey: AccountSettings.Key.pbxDeviceId) ?? ""
                    gatewayToken = try await client.renewGatewayToken(jwt: loginResult.jwt, deviceId: deviceId)
                }
                // Persisted so the engine can be rebuilt at launch and inside a
                // VoIP push without another interactive login.
                KeychainStore.set(gatewayToken, forKey: KeychainStore.gatewayTokenKey)

                // Step 3: Build the SIP engine from what was just stored and
                // register with the gateway (gateway token, not the API JWT).
                SipEngineManager.shared.reset()
                try await SipEngineManager.shared.ensureReadyAsync()

                isConnecting = false
            } catch {
                isConnecting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Sign Out

    func signOut() {
        let jwt = KeychainStore.get(KeychainStore.jwtKey) ?? ""
        let defaults = UserDefaults.standard
        let deviceId = defaults.string(forKey: AccountSettings.Key.pbxDeviceId) ?? ""
        let apiUrl = defaults.string(forKey: AccountSettings.Key.apiUrl) ?? ""

        // Unregister device from PBX in background
        if !jwt.isEmpty && !deviceId.isEmpty && !apiUrl.isEmpty {
            Task {
                try? await PbxApiClient(baseUrl: apiUrl)
                    .unregisterDevice(jwt: jwt, deviceId: deviceId)
            }
        }

        // Unregister from gateway
        SipEngineManager.shared.signOut()

        // Clear all stored state, secrets included.
        AccountSettings.clear()
        KeychainStore.remove(KeychainStore.jwtKey)
        KeychainStore.remove(KeychainStore.sipPasswordKey)
        KeychainStore.remove(KeychainStore.gatewayTokenKey)
        // History belongs to the account; the next one should not see it.
        CallHistoryStore.shared.clear()
        VoicemailService.shared.reset()
        hasSession = false
        errorMessage = nil
    }
}
