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
            QRScannerView { credentials in
                handleQRScanned(credentials)
                showQRScanner = false
            }
        }
        .sheet(isPresented: $showManualSetup) {
            NavigationStack {
                SettingsView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { showManualSetup = false }
                        }
                    }
            }
        }
    }

    private func handleQRScanned(_ credentials: ProvisioningCredentials) {
        AccountSession.shared.applyProvisioning(credentials)
        AccountSession.shared.login()
    }
}

// MARK: - Main Tab View (shown after setup)

struct MainTabView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @State private var selectedTab: Tab = .dialer

    enum Tab {
        case dialer, contacts, history, settings
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                DialerView()
                    .tabItem {
                        Label("Dialer", systemImage: "phone.fill")
                    }
                    .tag(Tab.dialer)

                ContactsView()
                    .tabItem {
                        Label("Contacts", systemImage: "person.crop.circle.fill")
                    }
                    .tag(Tab.contacts)

                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock.fill")
                    }
                    .tag(Tab.history)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(Tab.settings)
            }
            .tint(.ariaIndigo)

            // Full-screen call overlay
            if callManager.activeCall != nil {
                CallView()
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut, value: callManager.activeCall != nil)
    }
}

#Preview {
    ContentView()
        .environmentObject(CallManager.shared)
        .environmentObject(SipEngineManager.shared)
}
