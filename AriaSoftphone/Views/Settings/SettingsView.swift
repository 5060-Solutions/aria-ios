import SwiftUI

// MARK: - Indigo Theme Color

extension Color {
    static let ariaIndigo = Color(red: 0.388, green: 0.400, blue: 0.945) // #6366F1
}

/// Settings screen with PBX-mediated auth flow and Aria branding.
struct SettingsView: View {
    @EnvironmentObject var sipEngine: SipEngineManager

    // SIP credentials (from QR scan)
    @AppStorage("sipUsername") private var sipUsername = ""
    @AppStorage("sipDomain") private var sipDomain = ""
    @AppStorage("sipPort") private var sipPort = 5060
    @AppStorage("sipDisplayName") private var sipDisplayName = ""
    @AppStorage("sipRegistrar") private var sipRegistrar = ""
    @AppStorage("sipTransport") private var sipTransport = "udp"
    @AppStorage("apiUrl") private var apiUrl = ""

    // PBX auth state
    // JWT is a bearer credential — stored in the Keychain, not UserDefaults.
    // Held in @State for UI binding and loaded/persisted via KeychainStore.
    @State private var jwt = ""
    @AppStorage("extensionId") private var extensionId = ""
    @AppStorage("tenantId") private var tenantId = ""
    @AppStorage("pbxDeviceId") private var pbxDeviceId = ""
    @AppStorage("gatewayUrl") private var gatewayUrl = ""

    @State private var sipPassword = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showQRScanner = false
    @State private var showSignOutAlert = false

    private var isSignedIn: Bool {
        !jwt.isEmpty && !pbxDeviceId.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Aria branding header
                    ariaHeader

                    // Account section
                    if !sipUsername.isEmpty {
                        accountCard
                    }

                    // QR scan button
                    qrScanButton

                    // Status section
                    statusCard

                    // Error display
                    if let error = errorMessage ?? sipEngine.registrationError {
                        errorCard(error)
                    }

                    // Connect / Reconnect
                    if !isSignedIn || errorMessage != nil {
                        connectButton
                    }

                    // On-device transcription
                    transcriptionLink

                    // About section
                    aboutCard

                    // Sign Out
                    if !sipUsername.isEmpty {
                        signOutButton
                    }

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { credentials in
                    handleQRScanned(credentials)
                }
            }
            .alert("Sign Out", isPresented: $showSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    performSignOut()
                }
            } message: {
                Text("Are you sure you want to sign out? You will need to scan a QR code again to reconnect.")
            }
            .onAppear { loadSecrets() }
        }
    }

    // MARK: - Secret Loading / Persistence

    /// Load secrets (JWT, SIP password) from the Keychain into view state.
    private func loadSecrets() {
        jwt = KeychainStore.get(KeychainStore.jwtKey) ?? ""
        if sipPassword.isEmpty {
            sipPassword = KeychainStore.get(KeychainStore.sipPasswordKey) ?? ""
        }
    }

    /// Update the JWT in both view state and the Keychain (single source of truth).
    private func setJwt(_ value: String) {
        jwt = value
        KeychainStore.set(value, forKey: KeychainStore.jwtKey)
    }

    // MARK: - Aria Branding Header

    private var ariaHeader: some View {
        HStack(spacing: 10) {
            Image("AriaLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Aria")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.ariaIndigo)
                .tracking(2)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Account Card

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Account")

            VStack(spacing: 0) {
                settingsRow("Extension", sipUsername)
                Divider().padding(.leading, 16)
                settingsRow("Display Name", sipDisplayName.isEmpty ? "---" : sipDisplayName)
                Divider().padding(.leading, 16)
                settingsRow("Domain", sipDomain)
                Divider().padding(.leading, 16)
                settingsRow("Transport", sipTransport.uppercased())
                Divider().padding(.leading, 16)
                settingsRow("Port", "\(sipPort)")
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Transcription

    private var transcriptionLink: some View {
        NavigationLink {
            TranscriptionView()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-device transcription")
                        .foregroundStyle(.primary)
                    Text("Transcribe calls on this phone. Nothing is uploaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - QR Scan Button

    private var qrScanButton: some View {
        Button {
            showQRScanner = true
        } label: {
            HStack {
                Image(systemName: "qrcode.viewfinder")
                Text(sipUsername.isEmpty ? "Scan QR Code to Configure" : "Scan New QR Code")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.ariaIndigo)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Status")

            VStack(spacing: 0) {
                HStack {
                    Text("Registration")
                        .font(.body)
                    Spacer()
                    if isSignedIn && sipEngine.isRegistered {
                        connectedBadge
                    } else if isConnecting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Disconnected")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if !pbxDeviceId.isEmpty {
                    Divider().padding(.leading, 16)
                    settingsRow("Device ID", String(pbxDeviceId.prefix(12)) + "...")
                }

                if !extensionId.isEmpty {
                    Divider().padding(.leading, 16)
                    settingsRow("Extension ID", String(extensionId.prefix(12)) + "...")
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
            Text("Connected")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.green.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Error Card

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Connect Button

    private var connectButton: some View {
        Button {
            performLogin()
        } label: {
            HStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Connecting...")
                } else {
                    Text(isSignedIn ? "Reconnect" : "Connect")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.ariaIndigo)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .disabled(isConnecting || sipUsername.isEmpty || sipDomain.isEmpty)
    }

    // MARK: - About Card

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("About")

            VStack(spacing: 0) {
                settingsRow("App", "Aria Softphone")
                Divider().padding(.leading, 16)
                settingsRow("Version", "v1.0.0")
                Divider().padding(.leading, 16)
                settingsRow("Developer", "5060 Solutions")
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Sign Out Button

    private var signOutButton: some View {
        Button(role: .destructive) {
            showSignOutAlert = true
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("Sign Out")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.ariaIndigo)
            .padding(.leading, 4)
    }

    private func settingsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - QR Scan Handler

    private func handleQRScanned(_ credentials: ProvisioningCredentials) {
        sipUsername = credentials.username
        sipPassword = credentials.password
        // Persist the SIP password securely so outgoing/incoming call paths can
        // retrieve it after relaunch (Keychain, never UserDefaults).
        KeychainStore.set(credentials.password, forKey: KeychainStore.sipPasswordKey)
        // SIP domain = tenant domain (used in From/To headers for auth)
        // SIP registrar = server address (where to send REGISTER)
        sipDomain = credentials.tenantDomain.isEmpty ? credentials.server : credentials.tenantDomain
        sipRegistrar = credentials.server
        sipPort = credentials.port
        sipDisplayName = credentials.displayName
        sipTransport = credentials.transport.lowercased()
        apiUrl = credentials.apiUrl
        showQRScanner = false

        // Auto-trigger PBX login after QR scan
        performLogin()
    }

    // MARK: - PBX Login + Device Registration

    private func performLogin() {
        guard !apiUrl.isEmpty, !sipUsername.isEmpty, !sipPassword.isEmpty, !sipDomain.isEmpty else {
            errorMessage = "Missing required fields. Scan a QR code to configure."
            return
        }

        // Defense in depth: never POST the extension password to a cleartext or
        // malformed host, even if configuration was set outside the QR flow.
        guard isValidProvisioningDestination(apiUrl: apiUrl, server: sipRegistrar.isEmpty ? sipDomain : sipRegistrar) else {
            errorMessage = "Refusing to connect: the configured server is insecure or invalid. The API endpoint must use HTTPS."
            return
        }

        isConnecting = true
        errorMessage = nil

        Task {
            do {
                let client = PbxApiClient(baseUrl: apiUrl)

                // Step 1: Extension login
                let loginResult = try await client.extensionLogin(
                    extensionNumber: sipUsername,
                    password: sipPassword,
                    tenantDomain: sipDomain
                )

                await MainActor.run {
                    setJwt(loginResult.jwt)
                    extensionId = loginResult.extensionId
                    tenantId = loginResult.tenantId
                }

                // Step 2: Device registration
                let pushToken = PushHandler.shared.pushToken ?? ""
                let deviceResult = try await client.registerDevice(
                    jwt: loginResult.jwt,
                    pushToken: pushToken,
                    platform: "ios"
                )

                let gwUrl = deviceResult.gatewayUrl.isEmpty ? "https://push.ariaroute.com" : deviceResult.gatewayUrl
                let gwToken = deviceResult.gatewayToken.isEmpty ? loginResult.jwt : deviceResult.gatewayToken

                await MainActor.run {
                    pbxDeviceId = deviceResult.deviceId
                    gatewayUrl = gwUrl
                }

                // Step 3: Initialize SIP engine with gateway token (not API JWT)
                sipEngine.configure(gatewayUrl: gwUrl, apiKey: gwToken)

                let credentials = SipCredentials(
                    username: sipUsername,
                    password: sipPassword,
                    domain: sipDomain,
                    registrar: sipRegistrar.isEmpty ? nil : sipRegistrar,
                    transport: sipTransport,
                    port: UInt16(sipPort),
                    authUsername: nil,
                    displayName: sipDisplayName
                )

                let bundleId = Bundle.main.bundleIdentifier
                try sipEngine.registerDevice(
                    platform: "ios",
                    pushToken: pushToken,
                    bundleId: bundleId,
                    sip: credentials
                )

                await MainActor.run {
                    isConnecting = false
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Sign Out

    private func performSignOut() {
        let savedJwt = jwt
        let savedDeviceId = pbxDeviceId
        let savedApiUrl = apiUrl

        // Unregister device from PBX in background
        if !savedJwt.isEmpty && !savedDeviceId.isEmpty && !savedApiUrl.isEmpty {
            Task {
                try? await PbxApiClient(baseUrl: savedApiUrl)
                    .unregisterDevice(jwt: savedJwt, deviceId: savedDeviceId)
            }
        }

        // Unregister from gateway
        try? sipEngine.unregister()

        // Clear all stored state
        sipUsername = ""
        sipDomain = ""
        sipPort = 5060
        sipDisplayName = ""
        sipRegistrar = ""
        sipTransport = "udp"
        sipPassword = ""
        apiUrl = ""
        setJwt("")
        // Clear secrets from the Keychain on sign-out.
        KeychainStore.remove(KeychainStore.sipPasswordKey)
        extensionId = ""
        tenantId = ""
        pbxDeviceId = ""
        gatewayUrl = ""
        errorMessage = nil
    }
}

#Preview {
    SettingsView()
        .environmentObject(SipEngineManager.shared)
}
