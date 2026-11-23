import SwiftUI

/// What the status chip opens: registration, gateway node, transport and the
/// last error, with Reconnect (DESIGN.md §5 Shell).
struct ConnectionSheet: View {
    @ObservedObject private var details = ConnectionDetails.shared
    @EnvironmentObject var sipEngine: SipEngineManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                            value(snapshot.gatewayNode.isEmpty ? String(localized: "Not set") : snapshot.gatewayNode)
                        }
                        SectionRow(title: Text("Transport"), systemImage: "lock.fill") {
                            value(snapshot.transport.isEmpty ? "–" : snapshot.transport)
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
            .safeAreaInset(edge: .bottom) {
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
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .onAppear { details.startLiveUpdates() }
        .onDisappear { details.stopLiveUpdates() }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
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

    static func detail(for state: ConnectionState) -> String {
        switch state {
        case .registered: return String(localized: "Calls can reach this iPhone.")
        case .connecting: return String(localized: "Signing in to your phone system.")
        case .offline: return String(localized: "No network, or no account set up.")
        case .error: return String(localized: "Incoming calls may not reach this iPhone.")
        }
    }
}
