import SwiftUI

struct ContentView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @AppStorage("sipUsername") private var sipUsername = ""
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system

    var body: some View {
        Group {
            if sipUsername.isEmpty {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .preferredColorScheme(appearance.colorScheme)
    }
}

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
                    // A container element, so the controls keep their own
                    // identifiers.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("call.screen")
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
