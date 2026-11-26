import ActivityKit
import SwiftUI
import WidgetKit

/// The Hold for me waiting card on the lock screen and in the Dynamic Island.
/// Strings come from the app's string catalog, which this target includes.
struct HoldWaitLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HoldWaitAttributes.self) { context in
            HoldWaitActivityContent(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.6))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("holdWait.activity")
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HoldWaitActivityContent(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Image(systemName: "hourglass")
                    .accessibilityLabel(Text("Hold for me"))
            } compactTrailing: {
                HoldWaitTimer(startedAt: context.attributes.startedAt)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "hourglass")
                    .accessibilityLabel(Text("Hold for me"))
            }
            // A tap opens the app; only the explicit Cancel asks to stop.
            .widgetURL(HoldWaitAttributes.openURL(context.attributes.holdWaitId))
        }
    }
}

/// The elapsed time, counting up on its own without any update.
private struct HoldWaitTimer: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// Who is being waited on, for how long, what is happening, and Cancel.
private struct HoldWaitActivityContent: View {
    let attributes: HoldWaitAttributes
    let state: HoldWaitAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(attributes.remoteName)
                .font(.headline)
                .lineLimit(1)
            Text("Waiting on hold · \(Text(timerInterval: attributes.startedAt...Date.distantFuture, countsDown: false))")
                .font(.subheadline)
                .monospacedDigit()
            if let line = state.statusLine {
                Text(line)
                    .font(.subheadline.weight(.semibold))
            }
            Link(destination: HoldWaitAttributes.cancelURL(attributes.holdWaitId)) {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
                    .background(.tint.opacity(0.2), in: .capsule)
            }
            .accessibilityIdentifier("holdWait.activity.cancel")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
