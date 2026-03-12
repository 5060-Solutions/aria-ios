import SwiftUI

struct ContentView: View {
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
            .tint(.blue)

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
