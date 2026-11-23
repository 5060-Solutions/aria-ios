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
                .background(AriaColor.background)
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
            VStack(spacing: Space.m) {
                ProgressView()
                Text("Checking the setup link…")
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyState(
                systemImage: "link.badge.plus",
                title: Text("Can't use this link"),
                message: Text(message),
                actionTitle: "Close",
                action: finish
            )
            .accessibilityIdentifier("setupLink.error")
        case .preview(let preview), .redeeming(let preview):
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    SectionCard(title: Text("This link will add")) {
                        DetailRow(label: "Organization", value: preview.tenantName)
                        DetailRow(label: "Extension", value: preview.extension)
                        if !preview.displayName.isEmpty && preview.displayName != preview.extension {
                            DetailRow(label: "Name", value: preview.displayName)
                        }
                        DetailRow(label: "Domain", value: preview.domain)
                    }
                    SectionCard(
                        footer: Text("Only continue if you expected a setup link from \(preview.serverHost). The link can be used once.")
                    ) {
                        DetailRow(label: "Setup server", value: preview.serverHost)
                            .accessibilityIdentifier("setupLink.serverHost")
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.vertical, Space.m)
            }
            .safeAreaInset(edge: .bottom) {
                AriaButton("Set Up This Line", kind: .prominent, size: .primary, fullWidth: true,
                           isLoading: isRedeeming) {
                    Task { await redeem(preview) }
                }
                .accessibilityIdentifier("setupLink.confirm")
                .padding(.horizontal, Space.screenMargin)
                .padding(.bottom, Space.xs)
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
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    SectionCard(footer: Text("Paste the setup link your administrator sent you.")) {
                        FieldBlock(label: "Setup link", problem: problem) {
                            TextField("aria://provision?v=1&url=…", text: $text, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .lineLimit(1...4)
                                .ariaField(invalid: problem != nil)
                                .accessibilityIdentifier("setupLink.field")
                        }
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first { text = first }
                        }
                        .buttonBorderShape(.capsule)
                        .tint(AriaColor.primary)
                        .padding(.vertical, Space.xs)
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.vertical, Space.m)
            }
            .background(AriaColor.background)
            .safeAreaInset(edge: .bottom) {
                AriaButton("Continue", kind: .prominent, size: .primary, fullWidth: true, action: open)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.bottom, Space.xs)
            }
            .navigationTitle("Open Setup Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
