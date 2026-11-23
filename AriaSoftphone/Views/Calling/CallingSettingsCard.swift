import SwiftUI

/// The Settings "Calling" group: Do Not Disturb and call forwarding on the
/// PBX. Plain SwiftUI, for the Settings restyle to take over.
struct CallingSettingsCard: View {
    @ObservedObject private var service = SelfService.shared
    @State private var showForwarding = FixtureMode.shows(.forwarding)
    @State private var badgeEnabled = ActivityRefresher.shared.badgeEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calling")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                Toggle(isOn: Binding(
                    get: { service.doNotDisturb ?? false },
                    set: { on in Task { await service.setDoNotDisturb(on) } }
                )) {
                    Label("Do Not Disturb", systemImage: "moon.fill")
                }
                .disabled(service.doNotDisturb == nil)
                .padding(16)
                .accessibilityIdentifier("settings.dnd")

                Divider().padding(.leading, 16)

                NavigationLink {
                    ForwardingView()
                } label: {
                    row("Call Forwarding", systemImage: "arrowshape.turn.up.right",
                        detail: service.isForwardingAll ? String(localized: "On") : nil)
                }
                .accessibilityIdentifier("settings.forwarding")

                Divider().padding(.leading, 16)

                NavigationLink {
                    CodecSettingsView()
                } label: {
                    row("Codecs", systemImage: "waveform", detail: nil)
                }
                .accessibilityIdentifier("settings.codecs")

                Divider().padding(.leading, 16)

                NavigationLink {
                    RecordingsView()
                } label: {
                    row("Recordings", systemImage: "record.circle", detail: nil)
                }
                .accessibilityIdentifier("settings.recordings")

                Divider().padding(.leading, 16)

                NavigationLink {
                    DiagnosticsView()
                } label: {
                    row("Diagnostics", systemImage: "stethoscope", detail: nil)
                }
                .accessibilityIdentifier("settings.diagnostics")

                Divider().padding(.leading, 16)

                Toggle(isOn: Binding(
                    get: { badgeEnabled },
                    set: { on in
                        badgeEnabled = on
                        ActivityRefresher.shared.badgeEnabled = on
                    }
                )) {
                    Label("Voicemail Badge on App Icon", systemImage: "app.badge")
                }
                .padding(16)
                .accessibilityIdentifier("settings.voicemailBadge")
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let error = service.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 4)
            }
        }
        .navigationDestination(isPresented: $showForwarding) {
            ForwardingView()
        }
        .task { await service.refresh() }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, detail: String?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
            Spacer()
            if let detail = detail {
                Text(detail).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }
}
