import SwiftUI
import UIKit

/// Over every screen: the "call on another device" banner, the "Moved to"
/// notice, and the "Continue this call here" prompt.
struct CallMoveOverlays: ViewModifier {
    @ObservedObject private var moves = CallMoveModel.shared
    @ObservedObject private var proximity = Proximity.shared
    @ObservedObject private var callManager = CallManager.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                VStack(spacing: Space.xs) {
                    if let notice = moves.notice {
                        Banner(message: .info(notice.message)) { moves.notice = nil }
                            .accessibilityIdentifier("notice.moved")
                            .task(id: notice.id) {
                                UIAccessibility.post(notification: .announcement, argument: notice.message)
                                try? await Task.sleep(for: .seconds(6))
                                if moves.notice?.id == notice.id { moves.notice = nil }
                            }
                    }
                    if let message = moves.errorMessage {
                        Banner(message: .error(message)) { moves.errorMessage = nil }
                    }
                    if let suggested = proximity.suggestion {
                        CallElsewhereBanner(
                            call: suggested,
                            title: String(localized: "Continue this call here"),
                            actionTitle: String(localized: "Continue"),
                            isBusy: moves.isBusy,
                            onAction: { Task { await proximity.acceptSuggestion() } },
                            onDismiss: { proximity.dismissSuggestion() }
                        )
                        .accessibilityIdentifier("banner.handoff")
                    } else if let call = moves.elsewhere {
                        CallElsewhereBanner(
                            call: call,
                            title: CallMoveText.bannerTitle(call),
                            actionTitle: String(localized: "Move here"),
                            isBusy: moves.isBusy,
                            onAction: { Task { await moves.moveHere(call) } },
                            onDismiss: { moves.dismissBanner() }
                        )
                        .accessibilityIdentifier("banner.callElsewhere")
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.xs)
            }
            .animation(.smooth, value: moves.elsewhere)
            .animation(.smooth, value: proximity.suggestion)
            // The banner follows the phone's own calls.
            .onChange(of: callManager.registry.count) { _, _ in moves.recompute() }
    }
}

enum CallMoveText {
    /// "Call with Ada on Desk phone".
    static func bannerTitle(_ call: UserCall) -> String {
        String(localized: "Call with \(call.remoteDisplay) on \(call.deviceLabel)")
    }
}

/// "Call with X on <device> · Move here".
struct CallElsewhereBanner: View {
    let call: UserCall
    let title: String
    let actionTitle: String
    let isBusy: Bool
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "phone.arrow.right.fill")
                .foregroundStyle(AriaColor.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurface)
                    .lineLimit(2)
                Text("Started \(call.startedAt.formatted(date: .omitted, time: .shortened))")
                    .ariaFont(.label)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: onAction)
                .buttonStyle(.borderedProminent)
                .tint(AriaColor.primary)
                .disabled(isBusy)
                .accessibilityIdentifier("banner.action")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

/// The in-call "Move to…" sheet: the user's other online devices.
struct MoveToView: View {
    @ObservedObject private var moves = CallMoveModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if moves.devices.isEmpty {
                    Text(loaded ? LocalizedStringKey("No other devices are online.") : LocalizedStringKey("Looking for your devices…"))
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                        .accessibilityIdentifier("moveTo.empty")
                }
                ForEach(moves.devices) { device in
                    Button {
                        Task {
                            if await moves.moveOwnCall(to: device) { dismiss() }
                        }
                    } label: {
                        Label(device.displayName, systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                    .disabled(moves.isBusy)
                }
                if let message = moves.errorMessage {
                    Text(message).foregroundStyle(AriaColor.error)
                }
            }
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .task {
                await moves.loadDevices()
                loaded = true
            }
        }
        .presentationDetents([.medium])
    }
}

/// Settings "Call handoff": the `/me/call-handoff` switches.
struct CallHandoffSection: View {
    @ObservedObject private var proximity = Proximity.shared

    var body: some View {
        SectionCard(title: Text("Call handoff"), footer: footer) {
            ToggleRow(title: "Suggest Nearby Calls", systemImage: "location.viewfinder", isOn: binding(\.suggestNearby))
                .accessibilityIdentifier("settings.handoff.suggest")
            RowDivider()
            ToggleRow(title: "Move Call When I Leave", systemImage: "figure.walk.departure", isOn: binding(\.autoMoveOnLeave))
                .accessibilityIdentifier("settings.handoff.auto")
            RowDivider()
            ToggleRow(title: "Use Bluetooth", systemImage: "dot.radiowaves.left.and.right", isOn: binding(\.ble))
                .accessibilityIdentifier("settings.handoff.ble")
        }
        .disabled(proximity.settings == nil)
        .task { await proximity.becameActive() }
    }

    private var footer: Text? {
        if let message = proximity.errorMessage { return Text(message) }
        return Text("Bluetooth lets your devices notice each other while Aria is open. Off unless you turn it on. Your Wi-Fi name is never shared.")
    }

    private func binding(_ key: WritableKeyPath<CallHandoffSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { (proximity.settings ?? .off)[keyPath: key] },
            set: { on in
                proximity.errorMessage = nil
                Task { await proximity.update { $0[keyPath: key] = on } }
            }
        )
    }
}
