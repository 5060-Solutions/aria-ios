import SwiftUI
import UIKit

/// Everything about the connection, for support: registration, gateway,
/// transport, network, the current call's codec, SRTP and media stats, and
/// a log the user can copy or share. The connection sheet pushes this.
struct DiagnosticsView: View {
    @ObservedObject private var details: ConnectionDetails
    @State private var banner: BannerMessage?

    init(details: ConnectionDetails = .shared) {
        self.details = details
    }

    private var s: ConnectionDetails.Snapshot { details.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                SectionCard(title: Text("Registration")) {
                    row("Status", value: s.state.label, color: Self.color(for: s.state))
                    if let error = s.lastError, !error.isEmpty {
                        row("Last error", value: error, color: AriaColor.error)
                    }
                    row("Account", value: s.account.isEmpty ? "—" : s.account)
                    row("Device", value: s.deviceId ?? "—")
                }

                SectionCard(
                    title: Text("Gateway"),
                    footer: Text("Aria connects to the phone system through the gateway. Calls arrive by push even when this shows offline.")
                ) {
                    row("Server", value: s.gatewayNode.isEmpty ? "—" : s.gatewayNode)
                    row("SIP transport", value: s.sipTransport.isEmpty ? "—" : s.sipTransport)
                    row("Network", value: s.network)
                }

                SectionCard(title: Text("Media")) {
                    row("Codec", value: s.codec ?? (s.preferredCodecs.first.map { String(localized: "\($0) (preferred)") } ?? "—"))
                    if s.callId != nil {
                        row("Encryption",
                            value: s.srtp == true ? String(localized: "SRTP on") : String(localized: "None (unencrypted)"),
                            color: s.srtp == true ? AriaColor.success : AriaColor.warning)
                        if let stats = s.stats {
                            row("Packets", value: "↑ \(stats.packetsSent)  ↓ \(stats.packetsReceived)")
                            row("Loss", value: "\(stats.packetLoss)")
                            row("Jitter", value: String(format: "%.1f ms", stats.jitterMs))
                            row("Round trip", value: String(format: "%.1f ms", stats.rttMs))
                        }
                    } else {
                        row("Current call", value: String(localized: "None"))
                    }
                }

                SectionCard(title: Text("Log")) {
                    Text(logPreview)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.s)
                        .accessibilityIdentifier("diagnostics.log")
                }

                HStack(spacing: Space.s) {
                    AriaButton("Copy Log", systemImage: "doc.on.doc", kind: .prominent, size: .primary, fullWidth: true) {
                        UIPasteboard.general.string = details.reportText()
                        banner = .success(String(localized: "Diagnostics copied"))
                    }
                    .accessibilityIdentifier("diagnostics.copy")
                    ShareLink(item: details.reportText()) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                    }
                    .ariaButtonStyle(.standard)
                    .accessibilityLabel(Text("Share diagnostics"))
                }

                AriaButton("Reconnect", systemImage: "arrow.clockwise", kind: .standard, fullWidth: true) {
                    details.reconnect()
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .padding(.vertical, Space.m)
        }
        .background(AriaColor.background)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            if let banner {
                Banner(message: banner) { self.banner = nil }
                    .padding(.horizontal, Space.screenMargin)
                    .task(id: banner.id) {
                        try? await Task.sleep(for: .seconds(banner.duration ?? 4))
                        self.banner = nil
                    }
            }
        }
        .onAppear { details.startLiveUpdates() }
        .onDisappear { details.stopLiveUpdates() }
    }

    /// The last lines of the log; the copy has all of it.
    private var logPreview: String {
        let lines = AppLog.shared.text().split(separator: "\n").suffix(40)
        return lines.isEmpty ? String(localized: "Nothing logged yet.") : lines.joined(separator: "\n")
    }

    private func row(_ label: LocalizedStringKey, value: String, color: Color = AriaColor.onSurface) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(label)
                .ariaFont(.body)
                .foregroundStyle(AriaColor.onSurfaceVariant)
            Spacer(minLength: Space.s)
            Text(value)
                .ariaFont(.body)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .frame(minHeight: ComponentSize.row)
        .accessibilityElement(children: .combine)
    }

    static func color(for state: ConnectionState) -> Color {
        switch state {
        case .registered: return AriaColor.success
        case .connecting, .reconnecting: return Color.orange
        case .error: return AriaColor.error
        case .offline: return AriaColor.onSurfaceVariant
        }
    }
}
