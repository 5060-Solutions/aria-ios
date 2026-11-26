import SwiftUI

/// The in-app mirror of the Hold for me Live Activity: who we are waiting
/// on, for how long, what is happening, and Cancel. Cancel asks Rejoin now
/// or Hang up before it does anything.
struct HoldWaitCard: View {
    let wait: HoldWait

    @ObservedObject private var model = HoldForMeModel.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `12:34`, or `1:02:03` past the hour.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    var body: some View {
        // Once a second; the text changes on the second, not between.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            card(elapsed: Self.elapsed(context.date.timeIntervalSince(wait.startedAt)))
        }
        .confirmationDialog("Stop holding?", isPresented: cancelDialogShown, titleVisibility: .visible) {
            Button("Rejoin now") { Task { await model.cancel(wait.holdWaitId, rejoin: true) } }
                .accessibilityIdentifier("holdWait.rejoinNow")
            Button("Hang up", role: .destructive) { Task { await model.cancel(wait.holdWaitId, rejoin: false) } }
                .accessibilityIdentifier("holdWait.hangUp")
            Button("Cancel", role: .cancel) { model.cancelRequest = nil }
        }
    }

    private var cancelDialogShown: Binding<Bool> {
        Binding(
            get: { model.cancelRequest == wait.holdWaitId },
            set: { if !$0 && model.cancelRequest == wait.holdWaitId { model.cancelRequest = nil } }
        )
    }

    private func card(elapsed: String) -> some View {
        let state = HoldWaitAttributes.ContentState(
            state: wait.state == "requested" ? "waiting" : wait.state, stateSince: wait.stateSince)
        let waiting = String(localized: "Waiting on hold · \(elapsed)")
        let status = state.statusLine
        let label = ([wait.displayName, waiting] + [status.map { String(localized: $0) }].compactMap { $0 })
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Space.s) { details(waiting, status); cancelButton }
            } else {
                HStack(alignment: .center, spacing: Space.s) {
                    details(waiting, status)
                    Spacer(minLength: Space.xs)
                    cancelButton
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .padding(.horizontal, Space.screenMargin)
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("holdWait.card")
    }

    private func details(_ waiting: String, _ status: LocalizedStringResource?) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "hourglass")
                .foregroundStyle(AriaColor.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.hairline) {
                Text(wait.displayName)
                    .ariaFont(.body)
                    .foregroundStyle(AriaColor.onSurface)
                    .lineLimit(1)
                Text(waiting)
                    .ariaFont(.bodySmall)
                    .monospacedDigit()
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                if let status {
                    Text(status)
                        .ariaFont(.bodySmall)
                        .fontWeight(.semibold)
                        .foregroundStyle(AriaColor.onSurface)
                }
            }
        }
    }

    private var cancelButton: some View {
        AriaButton("Cancel", kind: .standard) { model.cancelRequest = wait.holdWaitId }
            .accessibilityIdentifier("holdWait.cancel")
    }
}

/// The cards for every open wait, above the tab content. Nothing while the
/// feature is off.
struct HoldWaitCards: View {
    @ObservedObject private var model = HoldForMeModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.openWaits, id: \.holdWaitId) { HoldWaitCard(wait: $0) }
        }
    }
}
