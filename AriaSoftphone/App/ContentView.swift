import SwiftUI

struct ContentView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @AppStorage("sipUsername") private var sipUsername = ""

    var body: some View {
        if sipUsername.isEmpty {
            SetupView()
        } else {
            MainTabView()
        }
    }
}

// MARK: - Setup View (shown when no credentials)

struct SetupView: View {
    @EnvironmentObject var sipEngine: SipEngineManager
    @State private var showQRScanner = false
    @State private var showManualSetup = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Aria branding
            VStack(spacing: 12) {
                Image("AriaLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22))

                Text("Aria")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.ariaIndigo)
                    .tracking(4)

                Text("Softphone")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Setup options
            VStack(spacing: 16) {
                Text("Get started by scanning your provisioning QR code")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    showQRScanner = true
                } label: {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Scan QR Code")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.ariaIndigo)
                .padding(.horizontal, 32)

                Button {
                    showManualSetup = true
                } label: {
                    Text("Manual Setup")
                        .font(.subheadline)
                        .foregroundColor(.ariaIndigo)
                }
            }

            Spacer()
                .frame(height: 60)
        }
        .sheet(isPresented: $showQRScanner) {
            ProvisioningFlowView { credentials in
                handleQRScanned(credentials)
                showQRScanner = false
            }
        }
        .sheet(isPresented: $showManualSetup) {
            ManualSetupView()
        }
    }

    private func handleQRScanned(_ credentials: ProvisioningCredentials) {
        AccountSession.shared.applyProvisioning(credentials)
        AccountSession.shared.login()
    }
}

// MARK: - Main Tab View (shown after setup)

/// The five tabs, in DESIGN.md order.
enum AppTab: Hashable {
    case dialer, history, contacts, voicemail, settings

    /// The tab a fixture scene opens on; the Dialer otherwise.
    init(fixtureScene: FixtureScene?) {
        switch fixtureScene {
        case .history: self = .history
        case .contacts: self = .contacts
        case .voicemail, .voicemailPlaying: self = .voicemail
        case .settings, .forwarding: self = .settings
        default: self = .dialer
        }
    }
}

/// The Liquid Glass tab bar shell, with the call screen over it.
struct MainTabView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @ObservedObject private var voicemail = VoicemailService.shared
    @State private var selectedTab = AppTab(fixtureScene: FixtureMode.scene)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab("Dialer", systemImage: "circle.grid.3x3.fill", value: AppTab.dialer) {
                    DialerView()
                }
                Tab("History", systemImage: "clock", value: AppTab.history) {
                    HistoryView()
                }
                Tab("Contacts", systemImage: "person.2", value: AppTab.contacts) {
                    ContactsView()
                }
                Tab("Voicemail", systemImage: "recordingtape", value: AppTab.voicemail) {
                    VoicemailView()
                }
                .badge(voicemail.unreadCount)
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                    SettingsView()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tint(AriaColor.primary)

            // Full-screen call overlay
            if callManager.activeCall != nil {
                CallView()
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            }
        }
        .animation(Motion.standard(reduceMotion: reduceMotion), value: callManager.activeCall != nil)
    }
}

#Preview {
    ContentView()
        .environmentObject(CallManager.shared)
        .environmentObject(SipEngineManager.shared)
}
