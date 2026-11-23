import SwiftUI

/// One key of the dial pad: its digit and the letters under it.
struct DialPadKey: Identifiable, Hashable {
    var id: String { digit }
    let digit: String
    let letters: String

    init(_ digit: String, _ letters: String = "") {
        self.digit = digit
        self.letters = letters
    }

    /// The 4×3 telephone keypad. Long-press 0 for +.
    static let rows: [[DialPadKey]] = [
        [.init("1"), .init("2", "ABC"), .init("3", "DEF")],
        [.init("4", "GHI"), .init("5", "JKL"), .init("6", "MNO")],
        [.init("7", "PQRS"), .init("8", "TUV"), .init("9", "WXYZ")],
        [.init("*"), .init("0", "+"), .init("#")],
    ]

    /// What VoiceOver reads: "5, J K L"; "star" and "pound" for * and #.
    var accessibilityLabel: String {
        let name: String
        switch digit {
        case "*": name = String(localized: "star")
        case "#": name = String(localized: "pound")
        default: name = digit
        }
        guard !letters.isEmpty else { return name }
        return "\(name), " + letters.map(String.init).joined(separator: " ")
    }
}

/// A 76 pt glass dial key (DESIGN.md §3). At accessibility text sizes the
/// letters are dropped and the grid stays.
struct DialKey: View {
    let key: DialPadKey
    /// Draw for a dark backdrop (the in-call keypad).
    var onDark = false
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var longPressFired = false

    var body: some View {
        Button {
            // A long press already acted; do not add the digit as well.
            if longPressFired {
                longPressFired = false
                return
            }
            action()
        } label: {
            VStack(spacing: 0) {
                Text(key.digit)
                    .ariaFont(.dialDigit)
                    .monospacedDigit()
                if !key.letters.isEmpty, !dynamicTypeSize.isAccessibilitySize {
                    Text(key.letters)
                        .ariaFont(.dialLetters)
                        .foregroundStyle(onDark ? Color.white.opacity(0.75) : AriaColor.onSurfaceVariant)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .foregroundStyle(onDark ? Color.white : AriaColor.onSurface)
            .frame(width: ComponentSize.dialKey, height: ComponentSize.dialKey)
            .contentShape(.circle)
        }
        .buttonStyle(DialKeyButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard let onLongPress else { return }
                longPressFired = true
                onLongPress()
            },
            isEnabled: onLongPress != nil
        )
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityAddTraits(.isKeyboardKey)
        .accessibilityActions {
            if let onLongPress, key.digit == "0" {
                Button(String(localized: "Plus")) { onLongPress() }
            }
        }
    }
}

/// Interactive glass circle that dips slightly while pressed.
private struct DialKeyButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(.regular.interactive(), in: .circle)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(Motion.snappy(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
