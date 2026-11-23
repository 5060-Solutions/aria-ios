import SwiftUI

// MARK: - Models

/// How a call sounds, from the core's RTP statistics.
enum CallQuality: Equatable {
    case good, fair, poor

    /// `packetLoss` is a count of lost packets; the ratio is taken against
    /// those received.
    init(packetsReceived: UInt64, packetLoss: UInt32, jitterMs: Double, rttMs: Double) {
        let total = Double(packetsReceived) + Double(packetLoss)
        let loss = total > 0 ? Double(packetLoss) / total : 0
        if loss < 0.01, jitterMs < 30, rttMs < 300 {
            self = .good
        } else if loss < 0.05, jitterMs < 60, rttMs < 500 {
            self = .fair
        } else {
            self = .poor
        }
    }

    init(_ stats: MediaStats) {
        self.init(packetsReceived: stats.packetsReceived, packetLoss: stats.packetLoss,
                  jitterMs: stats.jitterMs, rttMs: stats.rttMs)
    }

    /// Fill for the `cellularbars` symbol.
    var barValue: Double {
        switch self {
        case .good: return 1
        case .fair: return 0.6
        case .poor: return 0.25
        }
    }

    var label: String {
        switch self {
        case .good: return String(localized: "Good")
        case .fair: return String(localized: "Fair")
        case .poor: return String(localized: "Poor")
        }
    }
}

/// What the call screen's top bar shows about the media link.
struct CallLinkStatus: Equatable {
    var isEncrypted = false
    var quality: CallQuality?

    @MainActor
    static func current(callId: String?, engine: SipEngineManager) -> CallLinkStatus {
        #if DEBUG
        if FixtureMode.isActive { return CallLinkStatus(isEncrypted: true, quality: .good) }
        #endif
        guard let callId else { return CallLinkStatus() }
        return CallLinkStatus(
            isEncrypted: engine.callIsEncrypted(callId: callId),
            quality: engine.getMediaStats(callId: callId).map(CallQuality.init)
        )
    }
}

/// Call durations: "03:29", "1:02:03".
enum CallClock {
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Background

/// The call screen's slowly drifting mesh, primary-dark to background. Still
/// under Reduce Motion.
struct CallBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                mesh(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    mesh(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func mesh(at time: TimeInterval) -> some View {
        let a = Float(sin(time * 0.21)) * 0.08
        let b = Float(cos(time * 0.17)) * 0.07
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5 + a, 0], [1, 0],
                [0, 0.45 + b], [0.5 - a, 0.5 + b], [1, 0.4 - a],
                [0, 1], [0.5 + b, 1], [1, 1],
            ],
            colors: AriaColor.callMesh
        )
    }
}

// MARK: - Top bar

/// Icon and title with a tight gap, for chips.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xxs + 2) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Recording badge

struct RecordingBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "record.circle")
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text("Recording")
                .ariaFont(.label)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(AriaColor.tertiary)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xxs + 2)
        .glassEffect(.regular.tint(AriaColor.tertiary.opacity(0.18)), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Other call

/// The call that is not on screen: held, or in progress while another rings.
/// Swap, Merge and End act on it.
struct OtherCallCard: View {
    let call: ActiveCall
    let canSwap: Bool
    let canMerge: Bool
    let onSwap: () -> Void
    let onMerge: () -> Void
    let onEnd: () -> Void

    private var status: String {
        switch call.state {
        case .incoming: return String(localized: "Incoming call")
        case .connecting: return call.direction == .outbound ? String(localized: "Calling…") : String(localized: "Connecting…")
        case .onHold: return String(localized: "On hold")
        case .connected: return call.isOnHold ? String(localized: "On hold") : String(localized: "Active")
        case .ended: return String(localized: "Call ended")
        }
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Avatar(name: call.displayName, onGlass: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.displayName)
                    .ariaFont(.body)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: Space.xxs) {
                    if call.isOnHold {
                        Image(systemName: "pause.fill").imageScale(.small)
                    }
                    Text(status)
                }
                .ariaFont(.bodySmall)
                .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityElement(children: .combine)

            if canSwap {
                iconButton("arrow.left.arrow.right", label: String(localized: "Swap"), action: onSwap)
            }
            if canMerge {
                iconButton("arrow.triangle.merge", label: String(localized: "Merge calls"), action: onMerge)
            }
            iconButton("phone.down.fill", label: String(localized: "End \(call.displayName)"),
                       tint: AriaColor.hangUp, action: onEnd)
        }
        .padding(.leading, Space.s)
        .padding(.trailing, Space.xs)
        .padding(.vertical, Space.xs)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.card, style: .continuous))
    }

    private func iconButton(_ systemImage: String, label: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white)
                .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                .glassEffect(.regular.tint(tint).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Keypad sheet

/// DTMF keys over the controls, with the digits sent so far.
struct CallKeypadSheet: View {
    let onDigit: (String) -> Void
    @State private var sent = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Space.m) {
            Text(sent.isEmpty ? " " : sent)
                .ariaFont(.display)
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(Text("Sent"))
                .accessibilityValue(Text(sent))
                .padding(.horizontal, Space.screenMargin)

            Grid(horizontalSpacing: ComponentSize.dialKeyGapH, verticalSpacing: ComponentSize.dialKeyGapV) {
                ForEach(DialPadKey.rows, id: \.self) { row in
                    GridRow {
                        ForEach(row) { key in
                            DialKey(key: key, onDark: true) {
                                sent.append(key.digit)
                                onDigit(key.digit)
                            }
                        }
                    }
                }
            }

            AriaButton("Hide keypad", kind: .plain) { dismiss() }
                .foregroundStyle(.white)
        }
        .padding(.top, Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .presentationDetents([.height(560), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AriaColor.callBackdrop.opacity(0.55))
        .environment(\.colorScheme, .dark)
    }
}
