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
            List {
                Section {
                    row("Server", apiHost)
                    row("SIP Server", credentials.server)
                    row("Domain", account.domain)
                } header: {
                    Text("Connect to")
                } footer: {
                    Text("Your extension password will be sent to \(apiHost). Only continue if you recognise this server.")
                }

                Section("Account") {
                    row("Extension", credentials.username)
                    if !credentials.displayName.isEmpty && credentials.displayName != credentials.username {
                        row("Name", credentials.displayName)
                    }
                    row("Transport", "\(account.effectiveTransport.uppercased()) : \(account.effectivePort)")
                }

                if account.effectiveTransport != "tls" {
                    Section {
                        Label(
                            "This code uses \(account.effectiveTransport.uppercased()), so call signalling will not be encrypted.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Confirm Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        onConfirm()
                    } label: {
                        Text("Connect")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.ariaIndigo)

                    Button("Scan a Different Code", action: onRescan)
                        .font(.subheadline)
                        .foregroundColor(.ariaIndigo)
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
