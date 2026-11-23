import SwiftUI

/// The Settings "Calling" group: Do Not Disturb, call forwarding, codecs.
struct CallingSection: View {
    @ObservedObject private var service = SelfService.shared
    @State private var showForwarding = FixtureMode.shows(.forwarding)

    var body: some View {
        SectionCard(title: Text("Calling"), footer: service.errorMessage.map(Text.init)) {
            ToggleRow(title: "Do Not Disturb", systemImage: "moon.fill", isOn: Binding(
                get: { service.doNotDisturb ?? false },
                set: { on in Task { await service.setDoNotDisturb(on) } }
            ))
            .disabled(service.doNotDisturb == nil)
            .accessibilityIdentifier("settings.dnd")

            RowDivider()
            NavigationLink {
                ForwardingView()
            } label: {
                NavigationRow(title: "Call Forwarding", systemImage: "arrowshape.turn.up.right",
                              detail: service.isForwardingAll ? String(localized: "On") : nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.forwarding")

            RowDivider()
            NavigationLink {
                CodecSettingsView()
            } label: {
                NavigationRow(title: "Codecs", systemImage: "waveform")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.codecs")
        }
        .navigationDestination(isPresented: $showForwarding) {
            ForwardingView()
        }
        .task { await service.refresh() }
    }
}

/// The Settings "Audio & recording" group: recordings and the voicemail badge.
struct AudioRecordingSection: View {
    @State private var badgeEnabled = ActivityRefresher.shared.badgeEnabled

    var body: some View {
        SectionCard(title: Text("Audio & recording")) {
            NavigationLink {
                RecordingsView()
            } label: {
                NavigationRow(title: "Recordings", systemImage: "record.circle")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.recordings")

            RowDivider()
            ToggleRow(title: "Voicemail Badge on App Icon", systemImage: "app.badge", isOn: Binding(
                get: { badgeEnabled },
                set: { on in
                    badgeEnabled = on
                    ActivityRefresher.shared.badgeEnabled = on
                }
            ))
            .accessibilityIdentifier("settings.voicemailBadge")
        }
    }
}

/// The Settings "Diagnostics" group.
struct DiagnosticsSection: View {
    var body: some View {
        SectionCard(title: Text("Diagnostics")) {
            NavigationLink {
                DiagnosticsView()
            } label: {
                NavigationRow(title: "Connection & Diagnostics", systemImage: "stethoscope")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.diagnostics")
        }
    }
}
