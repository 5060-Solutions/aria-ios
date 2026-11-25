import SwiftUI

/// The app's shell at regular width (iPad, full screen or a wide Split
/// View): a sidebar of the same sections as the tab bar, and the chosen
/// section in the detail column. `MainTabView` picks it from
/// `horizontalSizeClass`, so Slide Over and a narrow Split View get the tab
/// bar and the width the user gives the app decides, not the device.
struct SidebarShell: View {
    @Binding var selection: AppTab
    @ObservedObject private var voicemail = VoicemailService.shared
    @ObservedObject private var messaging = MessagingService.shared
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// The sections in the sidebar; Messages only for a seat that can text.
    private var sections: [AppTab] {
        [.dialer, .history, .contacts, .voicemail] + (messaging.hasInbox ? [.messages] : []) + [.settings]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(sections, id: \.self, selection: Binding<AppTab?>(
                get: { selection },
                set: { if let tab = $0 { selection = tab } }
            )) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .badge(badge(for: tab))
                    .accessibilityIdentifier("sidebar.\(tab)")
            }
            .navigationTitle("Aria")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            selection.screen
                // A new section starts fresh, as a tab does.
                .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func badge(for tab: AppTab) -> Int {
        switch tab {
        case .voicemail: return voicemail.unreadCount
        case .messages: return messaging.unreadCount
        default: return 0
        }
    }
}
