import SwiftUI

// MARK: - App version

enum AppVersion {
    /// "1.0.0 (1)": the marketing version and build number from Info.plist,
    /// which take them from MARKETING_VERSION and CURRENT_PROJECT_VERSION.
    static func describe(_ info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    static var current: String { describe(Bundle.main.infoDictionary) }
}

// MARK: - Appearance

/// The Appearance setting: follow the system, or force light or dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appAppearance"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// For `preferredColorScheme`; nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - About links

enum AboutLinks {
    static let website = URL(string: "https://aria-softphone.com")!
    /// Third-party components and their licences, as the desktop links.
    static let acknowledgements = URL(string: "https://github.com/5060-Solutions/aria/network/dependencies")!
}

/// Settings (DESIGN.md §5): Account, Calling, Audio & recording,
/// Appearance, Transcription, Diagnostics, About, then Sign out.
struct SettingsView: View {
    @EnvironmentObject var sipEngine: SipEngineManager
    @ObservedObject private var session = AccountSession.shared

    @AppStorage("sipUsername") private var sipUsername = ""
    @AppStorage("sipDomain") private var sipDomain = ""
    @AppStorage("sipPort") private var sipPort = 0
    @AppStorage("sipDisplayName") private var sipDisplayName = ""
    @AppStorage("sipRegistrar") private var sipRegistrar = ""
    @AppStorage("sipTransport") private var sipTransport = AccountSettings.defaultTransport
    // PBX auth state. The JWT itself lives in the Keychain; `session`
    // reports whether one is held.
    @AppStorage("pbxDeviceId") private var pbxDeviceId = ""
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system

    @State private var showQRScanner = false
    @State private var showSignOutAlert = false
    @State private var showConnection = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isSignedIn: Bool { session.hasSession && !pbxDeviceId.isEmpty }
    private var hasAccount: Bool { !sipUsername.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.sectionGap) {
                    accountSection

                    if hasAccount {
                        CallingSection()
                        AudioRecordingSection()
                    }

                    appearanceSection

                    if sipEngine.aiAvailable() {
                        transcriptionSection
                    }

                    if hasAccount {
                        DiagnosticsSection()
                    }

                    aboutSection

                    if hasAccount {
                        AriaButton("Sign Out", systemImage: "rectangle.portrait.and.arrow.right",
                                   kind: .destructive, size: .primary, fullWidth: true) {
                            showSignOutAlert = true
                        }
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xxl)
            }
            .background(AriaColor.background)
            .navigationTitle("Settings")
            .sheet(isPresented: $showQRScanner) {
                ProvisioningFlowView { credentials in
                    session.applyProvisioning(credentials)
                    showQRScanner = false
                    // Log in now the user has confirmed where the code points.
                    session.login()
                }
            }
            .sheet(isPresented: $showConnection) {
                ConnectionSheet()
            }
            .alert("Sign Out?", isPresented: $showSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) { session.signOut() }
            } message: {
                Text("You will need your setup QR code or link to sign in again.")
            }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        SectionCard(title: Text("Account")) {
            if hasAccount {
                HStack(spacing: Space.s) {
                    Avatar(name: sipDisplayName.isEmpty ? sipUsername : sipDisplayName)
                    VStack(alignment: .leading, spacing: Space.hairline) {
                        Text(sipDisplayName.isEmpty ? String(localized: "Extension \(sipUsername)") : sipDisplayName)
                            .ariaFont(.title)
                            .foregroundStyle(AriaColor.onSurface)
                        Text("Ext \(sipUsername) · \(sipDomain.breakingAtDots)")
                            .ariaFont(.bodySmall)
                            .foregroundStyle(AriaColor.onSurfaceVariant)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                .padding(.vertical, Space.s)

                StatusChip(accountName: "", state: sipEngine.connectionState) {
                    showConnection = true
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Space.s)

                RowDivider()
                DetailRow(label: "Server", value: dynamicTypeSize.isAccessibilitySize
                          ? (sipRegistrar.isEmpty ? sipDomain : sipRegistrar).breakingAtDots
                          : (sipRegistrar.isEmpty ? sipDomain : sipRegistrar))
                RowDivider()
                DetailRow(label: "SIP transport", value: transportLabel)

                if let error = session.errorMessage {
                    Banner(message: .error(error))
                        .padding(.vertical, Space.s)
                }

                VStack(spacing: Space.s) {
                    if !isSignedIn || session.errorMessage != nil {
                        AriaButton(isSignedIn ? "Reconnect" : "Sign In", kind: .prominent, size: .primary,
                                   fullWidth: true, isLoading: session.isConnecting) {
                            session.login()
                        }
                        .disabled(sipDomain.isEmpty)
                    }
                    AriaButton("Scan New Setup Code", systemImage: "qrcode.viewfinder", kind: .standard,
                               fullWidth: true) {
                        showQRScanner = true
                    }
                }
                .padding(.vertical, Space.s)
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Not signed in")
                        .ariaFont(.title)
                        .foregroundStyle(AriaColor.onSurface)
                    Text("Scan the setup code from your phone system to sign in.")
                        .ariaFont(.bodySmall)
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                    AriaButton("Scan Setup Code", systemImage: "qrcode.viewfinder", kind: .prominent,
                               size: .primary, fullWidth: true) {
                        showQRScanner = true
                    }
                    .padding(.top, Space.xs)
                }
                .padding(.vertical, Space.m)
            }
        }
    }

    /// "TLS · 5061", with the defaults the call path applies.
    private var transportLabel: String {
        var account = AccountSettings.load()
        account.transport = sipTransport
        account.port = sipPort
        return "\(account.effectiveTransport.uppercased()) · \(account.effectivePort)"
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SectionCard(title: Text("Appearance")) {
            Picker("Theme", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, Space.s)
        }
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        SectionCard(title: Text("Transcription"),
                    footer: Text("Calls are transcribed on this iPhone. Nothing is uploaded.")) {
            NavigationLink {
                TranscriptionView()
            } label: {
                NavigationRow(title: "On-Device Transcription", systemImage: "text.bubble")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SectionCard(title: Text("About")) {
            HStack(spacing: Space.s) {
                Image("AriaLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: ComponentSize.avatarList, height: ComponentSize.avatarList)
                    .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.hairline) {
                    Text("Aria")
                        .ariaFont(.title)
                        .foregroundStyle(AriaColor.onSurface)
                    Text("Version \(AppVersion.current)")
                        .ariaFont(.bodySmall)
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                }
                Spacer()
            }
            .padding(.vertical, Space.s)
            .accessibilityElement(children: .combine)
            RowDivider()
            Link(destination: AboutLinks.website) {
                NavigationRow(title: "Website", systemImage: "safari")
            }
            .buttonStyle(.plain)
            RowDivider()
            Link(destination: AboutLinks.acknowledgements) {
                NavigationRow(title: "Acknowledgements", systemImage: "doc.text")
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SipEngineManager.shared)
}
