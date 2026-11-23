import SwiftUI

/// Scan a provisioning QR code, then ask before using it.
///
/// A scanned code decides where the extension password is sent, so nothing
/// is stored or sent until the user has seen where it points and agreed.
struct ProvisioningFlowView: View {
    /// Called with the confirmed credentials; the presenter stores them and
    /// logs in.
    let onConfirmed: (ProvisioningCredentials) -> Void

    @State private var pending: ProvisioningCredentials?

    var body: some View {
        if let credentials = pending {
            ProvisioningConfirmView(
                credentials: credentials,
                onConfirm: { onConfirmed(credentials) },
                onRescan: { pending = nil }
            )
        } else {
            QRScannerView { credentials in
                pending = credentials
            }
        }
    }
}

/// What a scanned code will do, for the user to accept or reject.
struct ProvisioningConfirmView: View {
    let credentials: ProvisioningCredentials
    let onConfirm: () -> Void
    let onRescan: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var account: AccountSettings {
        AccountSettings(provisioning: credentials)
    }

    private var apiHost: String {
        URLComponents(string: credentials.apiUrl)?.host ?? credentials.apiUrl
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.sectionGap) {
                    SectionCard(
                        title: Text("Connect to"),
                        footer: Text("Your extension password will be sent to \(apiHost). Only continue if you recognise this server.")
                    ) {
                        DetailRow(label: "Server", value: apiHost)
                        RowDivider()
                        DetailRow(label: "SIP server", value: credentials.server)
                        RowDivider()
                        DetailRow(label: "Domain", value: account.domain)
                    }

                    SectionCard(title: Text("Account")) {
                        DetailRow(label: "Extension", value: credentials.username)
                        if !credentials.displayName.isEmpty && credentials.displayName != credentials.username {
                            RowDivider()
                            DetailRow(label: "Name", value: credentials.displayName)
                        }
                        RowDivider()
                        DetailRow(label: "SIP transport",
                                  value: "\(account.effectiveTransport.uppercased()) · \(account.effectivePort)")
                    }

                    if account.effectiveTransport != "tls" {
                        Banner(message: BannerMessage(
                            kind: .error,
                            text: String(localized: "This code uses \(account.effectiveTransport.uppercased()), so call signalling will not be encrypted."),
                            duration: nil))
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xl)
            }
            .background(AriaColor.background)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .navigationTitle("Confirm Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: Space.xs) {
                    AriaButton("Connect", kind: .prominent, size: .primary, fullWidth: true, action: onConfirm)
                    AriaButton("Scan a Different Code", kind: .plain, action: onRescan)
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.vertical, Space.s)
            }
        }
    }
}
