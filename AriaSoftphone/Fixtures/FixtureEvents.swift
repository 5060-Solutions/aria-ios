#if DEBUG
import SwiftUI

/// What the app did that leaves no trace on screen in fixture mode, for UI
/// tests to read: the `tel:` URL of the last emergency hand-off.
@MainActor
final class FixtureEvents: ObservableObject {
    static let shared = FixtureEvents()
    @Published var emergencyHandoff: String?
    /// What the Hold for me fixture backend was asked to do, in order
    /// (`holdForMe.started:assistant`).
    @Published var holdForMe: [String] = []
}

/// An invisible element carrying `FixtureEvents`, in fixture mode only.
struct FixtureEventsMarker: View {
    @ObservedObject private var events = FixtureEvents.shared

    var body: some View {
        if FixtureMode.isActive {
            if let handoff = events.emergencyHandoff {
                Text(handoff)
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("fixture.emergencyHandoff")
                    .accessibilityValue(handoff)
                    .allowsHitTesting(false)
            }
            if !events.holdForMe.isEmpty {
                let value = events.holdForMe.joined(separator: ",")
                Text(value)
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("fixture.holdForMe")
                    .accessibilityValue(value)
                    .allowsHitTesting(false)
            }
        }
    }
}
#endif
