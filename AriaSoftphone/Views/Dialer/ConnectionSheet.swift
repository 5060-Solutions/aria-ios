import SwiftUI

/// What the status chip opens: registration, gateway node, transport and the
/// last error, with Reconnect (DESIGN.md §5 Shell).
struct ConnectionSheet: View {
    @ObservedObject private var details = ConnectionDetails.shared
    @EnvironmentObject var sipEngine: SipEngineManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var snapshot: ConnectionDetails.Snapshot { details.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.sectionGap) {
                    statusHeader

                    SectionCard(title: Text("Connection")) {
                        if !snapshot.account.isEmpty {
                            SectionRow(title: Text("Account"), systemImage: "person.crop.circle") {
                                value(snapshot.account)
                            }
                        }
                        SectionRow(title: Text("Gateway node"), systemImage: "server.rack") {
                            let node = Self.splitHostPort(snapshot.gatewayNode)
                            if node.host.isEmpty {
                                value(String(localized: "Not set"))
                            } else {
                                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
                                    value(node.host)
                                    if let port = node.port {
                                        Text("Port \(port)")
                                            .ariaFont(.bodySmall)
                                    }
                                }
                            }
                        }
                        SectionRow(title: Text("SIP transport"), systemImage: "lock.fill") {
                            value(snapshot.sipTransport.isEmpty ? "–" : Self.transportLabel(snapshot.sipTransport))
                        }
                        if let codec = snapshot.codec {
                            SectionRow(title: Text("Codec"), systemImage: "waveform") {
                                value(codec)
                            }
                        }
                        if let srtp = snapshot.srtp {
                            SectionRow(title: Text("Call encryption"), systemImage: "lock.shield") {
                                value(srtp ? String(localized: "SRTP") : String(localized: "Off"))
                            }
                        }
                        SectionRow(title: Text("Network"), systemImage: "wifi", showsDivider: false) {
                            value(snapshot.network)
                        }
                    }

                    if let error = snapshot.lastError, !error.isEmpty {
                        SectionCard(title: Text("Last error")) {
                            Text(error)
                                .ariaFont(.bodySmall)
                                .foregroundStyle(AriaColor.onSurface)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Space.s)
                                .textSelection(.enabled)
                        }
                    }

                    SectionCard {
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            SectionRow(title: Text("Diagnostics"), systemImage: "stethoscope", showsDivider: false) {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.bottom, Space.xl)
            }
            .background(AriaColor.background)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            // A bar, not a plain inset: the scroll edge effect sits behind
            // Reconnect, so rows scrolled beneath it never show through.
            .safeAreaBar(edge: .bottom) {
                AriaButton("Reconnect", systemImage: "arrow.clockwise", kind: .prominent,
                           size: .primary, fullWidth: true, isLoading: sipEngine.isConnecting) {
                    details.reconnect()
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.vertical, Space.s)
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { details.startLiveUpdates() }
        .onDisappear { details.stopLiveUpdates() }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.middle)
    }

    private var statusHeader: some View {
        let state = snapshot.state
        return HStack(spacing: Space.s) {
            Image(systemName: state.status == .registered ? "checkmark.circle.fill" : "circle.fill")
                .font(.title2)
                .foregroundStyle(state.statusColor)
                .symbolEffect(.pulse, isActive: state.status == .connecting && !reduceMotion)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.label)
                    .ariaFont(.title)
                    .foregroundStyle(AriaColor.onSurface)
                Text(Self.detail(for: state))
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .padding(.top, Space.xs)
    }

    /// "gw1.push.ariaroute.com:443" → host and port. IPv6 literals keep
    /// their brackets.
    static func splitHostPort(_ value: String) -> (host: String, port: String?) {
        guard let colon = value.lastIndex(of: ":"), !value.hasSuffix("]") else { return (value, nil) }
        let port = value[value.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return (value, nil) }
        let host = String(value[..<colon])
        if host.contains(":"), !host.hasPrefix("[") { return (value, nil) }
        return (host, String(port))
    }

    /// "TLS : 5061" → "TLS · 5061".
    static func transportLabel(_ value: String) -> String {
        value.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
    }

    static func detail(for state: ConnectionState) -> String {
        switch state {
        case .registered: return String(localized: "Calls can reach this iPhone.")
        case .connecting: return String(localized: "Signing in to your phone system.")
        case .reconnecting: return String(localized: "The network changed. Reconnecting; calls continue.")
        case .offline: return String(localized: "No network, or no account set up.")
        case .error: return String(localized: "Incoming calls may not reach this iPhone.")
        }
    }
}
