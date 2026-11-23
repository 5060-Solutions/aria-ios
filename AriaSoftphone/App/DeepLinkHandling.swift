import SwiftUI

/// Routes URLs the app is opened with (`aria://`, `sip:`, `sips:`) and
/// CallKit Recents / Siri call-backs (`INStartCallIntent`) to the screens that
/// confirm them. Applied once, at the root of the scene.
struct DeepLinkHandling: ViewModifier {
    @ObservedObject private var coordinator = DeepLinkCoordinator.shared

    func body(content: Content) -> some View {
        content
            .onOpenURL { coordinator.handle($0) }
            .onContinueUserActivity("INStartCallIntent") { coordinator.handle($0) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { coordinator.handle(url) }
            }
            .sheet(item: sheetBinding) { pending in
                switch pending.link {
                case .setupLink(let link):
                    SetupLinkConfirmView(link: link) { coordinator.dismiss() }
                case .legacyProvisioning(let credentials):
                    ProvisioningConfirmView(
                        credentials: credentials,
                        onConfirm: {
                            AccountSession.shared.applyProvisioning(credentials)
                            AccountSession.shared.login()
                            coordinator.dismiss()
                        },
                        onRescan: { coordinator.dismiss() }
                    )
                case .dial:
                    EmptyView()
                }
            }
            .alert(
                dialTitle,
                isPresented: dialBinding,
                presenting: dialNumber
            ) { number in
                Button("Call") {
                    CallManager.shared.startOutgoingCall(uri: number)
                    coordinator.dismiss()
                }
                .accessibilityIdentifier("deepLink.call")
                Button("Cancel", role: .cancel) { coordinator.dismiss() }
            } message: { number in
                Text(number)
            }
    }

    private var dialNumber: String? {
        if case .dial(let number)? = coordinator.pending?.link { return number }
        return nil
    }

    private var dialTitle: String {
        String(localized: "Call this number?")
    }

    private var sheetBinding: Binding<DeepLinkCoordinator.Pending?> {
        Binding(
            get: { dialNumber == nil ? coordinator.pending : nil },
            set: { if $0 == nil { coordinator.dismiss() } }
        )
    }

    private var dialBinding: Binding<Bool> {
        Binding(
            get: { dialNumber != nil },
            set: { if !$0 { coordinator.dismiss() } }
        )
    }
}
