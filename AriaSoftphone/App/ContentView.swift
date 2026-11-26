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
        // The cold-start intro; an incoming call (CallKit/PushKit) skips it.
        .launchIntro(hasCall: callManager.activeCall != nil)
    }
}

/// The tabs, in DESIGN.md order.
enum AppTab: Hashable {
    case dialer, history, contacts, voicemail, messages, settings

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

    var title: LocalizedStringKey {
        switch self {
        case .dialer: return "Dialer"
        case .history: return "History"
        case .contacts: return "Contacts"
        case .voicemail: return "Voicemail"
        case .messages: return "Messages"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dialer: return "circle.grid.3x3.fill"
        case .history: return "clock"
        case .contacts: return "person.2"
        case .voicemail: return "recordingtape"
        case .messages: return "message"
        case .settings: return "gearshape"
        }
    }

    /// The screen a tab or sidebar row opens.
    @ViewBuilder var screen: some View {
        switch self {
        case .dialer: DialerView()
        case .history: HistoryView()
        case .contacts: ContactsView()
        case .voicemail: VoicemailView()
        case .messages: MessagesView()
        case .settings: SettingsView()
        }
    }
}

/// The Liquid Glass tab bar shell, with the call screen over it.
struct MainTabView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @ObservedObject private var voicemail = VoicemailService.shared
    @ObservedObject private var messaging = MessagingService.shared
    @State private var selectedTab = AppTab(fixtureScene: FixtureMode.scene)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Regular width (an iPad, full screen or in a wide Split View) shows the
    /// sidebar; compact width (an iPhone, Slide Over, a narrow Split View)
    /// shows the tab bar.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            // The wait cards take their own row above the tabs, so they push
            // the screen down rather than lie over its header.
            VStack(spacing: 0) {
                HoldWaitCards()
                Group {
                    if horizontalSizeClass == .regular {
                        SidebarShell(selection: $selectedTab)
                    } else {
                        tabs
                    }
                }
            }
            .background(AriaColor.background)
            .tint(AriaColor.primary)
            // A text notification was tapped: open its thread.
            .onChange(of: messaging.pendingThread, initial: true) { _, pending in
                guard pending != nil else { return }
                // No inbox, no Messages tab: nothing to open.
                if messaging.hasInbox { selectedTab = .messages } else { messaging.pendingThread = nil }
            }

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

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab(AppTab.dialer.title, systemImage: AppTab.dialer.systemImage, value: AppTab.dialer) {
                AppTab.dialer.screen
            }
            Tab(AppTab.history.title, systemImage: AppTab.history.systemImage, value: AppTab.history) {
                AppTab.history.screen
            }
            Tab(AppTab.contacts.title, systemImage: AppTab.contacts.systemImage, value: AppTab.contacts) {
                AppTab.contacts.screen
            }
            Tab(AppTab.voicemail.title, systemImage: AppTab.voicemail.systemImage, value: AppTab.voicemail) {
                AppTab.voicemail.screen
            }
            .badge(voicemail.unreadCount)
            // Only a seat with a number to text from has the tab.
            if messaging.hasInbox {
                Tab(AppTab.messages.title, systemImage: AppTab.messages.systemImage, value: AppTab.messages) {
                    AppTab.messages.screen
                }
                .badge(messaging.unreadCount)
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                AppTab.settings.screen
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#Preview {
    ContentView()
        .environmentObject(CallManager.shared)
        .environmentObject(SipEngineManager.shared)
}
