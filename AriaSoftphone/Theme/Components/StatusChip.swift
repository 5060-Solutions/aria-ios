import SwiftUI

/// Registration status colours (DESIGN.md §1). Always shown beside a label,
/// never alone.
enum StatusColor {
    static let registered = Color(red: 0x4c / 255, green: 0xaf / 255, blue: 0x50 / 255)
    static let connecting = Color(red: 0xff / 255, green: 0x98 / 255, blue: 0x00 / 255)
    static let error = Color(red: 0xf4 / 255, green: 0x43 / 255, blue: 0x36 / 255)
    static let offline = Color(red: 0x9e / 255, green: 0x9e / 255, blue: 0x9e / 255)
}

extension ConnectionState {
    /// Which DESIGN.md status a connection state shows as.
    enum Status: Equatable {
        case registered, connecting, error, offline
    }

    var status: Status {
        switch self {
        case .registered: return .registered
        case .connecting, .reconnecting: return .connecting
        case .error: return .error
        case .offline: return .offline
        }
    }

    var statusColor: Color {
        switch status {
        case .registered: return StatusColor.registered
        case .connecting: return StatusColor.connecting
        case .error: return StatusColor.error
        case .offline: return StatusColor.offline
        }
    }
}

/// The dialer's glass capsule: account name, a registration dot and label,
/// and moon / arrow glyphs when DND or forwarding is on. Tapping it opens the
/// connection sheet.
struct StatusChip: View {
    let accountName: String
    let state: ConnectionState
    var isDoNotDisturb = false
    var isForwarding = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if !accountName.isEmpty {
                    Text(accountName)
                        .ariaFont(.label)
                        .foregroundStyle(AriaColor.onSurface)
                        .lineLimit(1)
                    Divider()
                        .frame(height: 12)
                }
                Image(systemName: "circle.fill")
                    .font(.system(.caption2))
                    .imageScale(.small)
                    .foregroundStyle(state.statusColor)
                    .symbolEffect(.pulse, isActive: state.status == .connecting && !reduceMotion)
                Text(state.label)
                    .ariaFont(.label)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .lineLimit(1)
                if isDoNotDisturb {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(AriaColor.tertiary)
                }
                if isForwarding {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .foregroundStyle(AriaColor.primary)
                }
            }
            .font(.footnote)
            .padding(.horizontal, Space.m)
            .frame(minHeight: ComponentSize.iconButton - Space.xs)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(minHeight: ComponentSize.iconButton)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(Text("Shows connection details"))
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if !accountName.isEmpty { parts.append(accountName) }
        parts.append(state.label)
        if isDoNotDisturb { parts.append(String(localized: "Do Not Disturb on")) }
        if isForwarding { parts.append(String(localized: "Forwarding on")) }
        return parts.joined(separator: ", ")
    }
}
