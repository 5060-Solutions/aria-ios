import SwiftUI

/// A one-click setup link: fetch its preview, show who is setting the line
/// up (`server_host`), and only on the user's confirmation redeem it — which
/// uses the link up — then sign in.
struct SetupLinkConfirmView: View {
    let link: String
    var service: SetupLinkService = .live
    var onFinished: () -> Void = {}

    private enum Phase {
        case loading
        case preview(ProvisionPreview)
        case redeeming(ProvisionPreview)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Set Up Aria")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { finish() }
                    }
                }
        }
        .task { await loadPreview() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Checking the setup link…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "link.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("setupLink.error")
                Button("Close") { finish() }
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preview(let preview), .redeeming(let preview):
            List {
                Section {
                    row("Organization", preview.tenantName)
                    row("Extension", preview.extension)
                    if !preview.displayName.isEmpty && preview.displayName != preview.extension {
                        row("Name", preview.displayName)
                    }
                    row("Domain", preview.domain)
                } header: {
                    Text("This link will add")
                }
                Section {
                    row("Setup server", preview.serverHost)
                        .accessibilityIdentifier("setupLink.serverHost")
                } footer: {
                    Text("Only continue if you expected a setup link from \(preview.serverHost). The link can be used once.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await redeem(preview) }
                } label: {
                    Group {
                        if case .redeeming = phase {
                            ProgressView()
                        } else {
                            Text("Set Up This Line")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRedeeming)
                .accessibilityIdentifier("setupLink.confirm")
                .padding()
                .background(.bar)
            }
        }
    }

    private var isRedeeming: Bool {
        if case .redeeming = phase { return true }
        return false
    }

    private func loadPreview() async {
        do {
            phase = .preview(try await service.fetchPreview(link))
        } catch {
            phase = .failed(SetupLinkService.describe(error))
        }
    }

    private func redeem(_ preview: ProvisionPreview) async {
        phase = .redeeming(preview)
        do {
            let account = try await service.fetchAccount(link)
            let credentials = ProvisioningCredentials(redeemed: account)
            AccountSession.shared.applyProvisioning(credentials)
            AccountSession.shared.login()
            finish()
        } catch {
            phase = .failed(SetupLinkService.describe(error))
        }
    }

    private func finish() {
        onFinished()
        dismiss()
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// Paste a setup link someone sent (for the onboarding "Open setup link"
/// choice). A valid link moves on to `SetupLinkConfirmView`.
struct SetupLinkEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var confirming: String?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("aria://provision?v=1&url=…", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("setupLink.field")
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first }
                    }
                } footer: {
                    if let problem = problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("Paste the setup link your administrator sent you.")
                    }
                }
            }
            .navigationTitle("Open Setup Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: open)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .sheet(item: Binding(
            get: { confirming.map(IdentifiedLink.init) },
            set: { confirming = $0?.link }
        )) { item in
            SetupLinkConfirmView(link: item.link) { dismiss() }
        }
    }

    private struct IdentifiedLink: Identifiable {
        let link: String
        var id: String { link }
    }

    private func open() {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link) else {
            problem = String(localized: "This isn't a valid Aria setup link.")
            return
        }
        switch DeepLink.parse(url) {
        case .setupLink(let link)?:
            problem = nil
            confirming = link
        case .legacyProvisioning(let credentials)?:
            problem = nil
            DeepLinkCoordinator.shared.pending = .init(link: .legacyProvisioning(credentials))
            dismiss()
        default:
            problem = String(localized: "This isn't a valid Aria setup link.")
        }
    }
}
