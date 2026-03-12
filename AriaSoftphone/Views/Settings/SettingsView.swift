import SwiftUI

/// Settings screen for SIP account configuration and gateway connection.
struct SettingsView: View {
    @EnvironmentObject var sipEngine: SipEngineManager
    @AppStorage("gatewayUrl") private var gatewayUrl = ""
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("sipUsername") private var sipUsername = ""
    @AppStorage("sipDomain") private var sipDomain = ""
    @AppStorage("sipTransport") private var sipTransport = "udp"
    @AppStorage("sipPort") private var sipPort = 5060
    @AppStorage("sipDisplayName") private var sipDisplayName = ""
    @AppStorage("sipRegistrar") private var sipRegistrar = ""
    @AppStorage("sipAuthUsername") private var sipAuthUsername = ""

    @State private var sipPassword = ""
    @State private var showPassword = false
    @State private var isRegistering = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                // Gateway section
                Section("Push Gateway") {
                    TextField("Gateway URL", text: $gatewayUrl)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    SecureField("API Key", text: $apiKey)
                }

                // SIP Account section
                Section("SIP Account") {
                    TextField("Display Name", text: $sipDisplayName)
                        .textContentType(.name)

                    TextField("Username", text: $sipUsername)
                        .autocapitalization(.none)
                        .textContentType(.username)

                    HStack {
                        if showPassword {
                            TextField("Password", text: $sipPassword)
                                .autocapitalization(.none)
                        } else {
                            SecureField("Password", text: $sipPassword)
                        }
                        Button(action: { showPassword.toggle() }) {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                    }

                    TextField("Domain", text: $sipDomain)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Registrar (optional)", text: $sipRegistrar)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Auth Username (optional)", text: $sipAuthUsername)
                        .autocapitalization(.none)

                    Picker("Transport", selection: $sipTransport) {
                        Text("UDP").tag("udp")
                        Text("TCP").tag("tcp")
                        Text("TLS").tag("tls")
                    }

                    Stepper("Port: \(sipPort)", value: $sipPort, in: 1...65535)
                }

                // Registration status
                Section("Status") {
                    HStack {
                        Text("Registration")
                        Spacer()
                        if sipEngine.isRegistered {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Label("Disconnected", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }

                    if let deviceId = sipEngine.deviceId {
                        HStack {
                            Text("Device ID")
                            Spacer()
                            Text(String(deviceId.prefix(8)) + "...")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    if let error = errorMessage ?? sipEngine.registrationError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                // Actions
                Section {
                    Button(action: register) {
                        if isRegistering {
                            HStack {
                                ProgressView()
                                Text("Registering...")
                            }
                        } else {
                            Text(sipEngine.isRegistered ? "Re-register" : "Register")
                        }
                    }
                    .disabled(isRegistering || !isFormValid)

                    if sipEngine.isRegistered {
                        Button("Unregister", role: .destructive) {
                            unregister()
                        }
                    }
                }

                // About
                Section("About") {
                    HStack {
                        Text("Aria Softphone")
                        Spacer()
                        Text("v1.0.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("5060 Solutions")
                        Spacer()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var isFormValid: Bool {
        !gatewayUrl.isEmpty && !apiKey.isEmpty &&
        !sipUsername.isEmpty && !sipPassword.isEmpty && !sipDomain.isEmpty
    }

    private func register() {
        isRegistering = true
        errorMessage = nil

        // Configure the engine
        sipEngine.configure(gatewayUrl: gatewayUrl, apiKey: apiKey)

        let credentials = SipCredentials(
            username: sipUsername,
            password: sipPassword,
            domain: sipDomain,
            registrar: sipRegistrar.isEmpty ? nil : sipRegistrar,
            transport: sipTransport,
            port: UInt16(sipPort),
            authUsername: sipAuthUsername.isEmpty ? nil : sipAuthUsername,
            displayName: sipDisplayName
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let pushToken = PushHandler.shared.pushToken ?? ""
                let bundleId = Bundle.main.bundleIdentifier

                try sipEngine.registerDevice(
                    platform: "ios",
                    pushToken: pushToken,
                    bundleId: bundleId,
                    sip: credentials
                )

                DispatchQueue.main.async {
                    isRegistering = false
                }
            } catch {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func unregister() {
        do {
            try sipEngine.unregister()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SipEngineManager.shared)
}
