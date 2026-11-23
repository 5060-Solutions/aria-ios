import SwiftUI
import UIKit

/// A contact's photo, or their initials on a tonal circle; a person glyph
/// for a bare number. 40 pt in lists, 96 pt on the call screen. Decorative:
/// the row or screen names the person.
struct Avatar: View {
    let name: String
    var imageData: Data? = nil
    var size: CGFloat = ComponentSize.avatarList
    /// Glass on the call screen's gradient instead of a tonal fill.
    var onGlass = false

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let initials = Self.initials(for: name) {
                Text(initials)
                    .font(AriaFont.font(size: size * 0.38, weight: .semibold, relativeTo: .body))
                    .dynamicTypeSize(.large)
                    .foregroundStyle(onGlass ? Color.white : palette.foreground)
            } else {
                Image(systemName: "person.fill")
                    .font(AriaFont.font(size: size * 0.42, weight: .regular, relativeTo: .body))
                    .dynamicTypeSize(.large)
                    .foregroundStyle(onGlass ? Color.white : palette.foreground)
            }
        }
        .frame(width: size, height: size)
        .background {
            if !onGlass { Circle().fill(palette.background) }
        }
        .clipShape(.circle)
        .modifier(AvatarGlass(isOn: onGlass))
        .accessibilityHidden(true)
    }

    private var palette: (background: Color, foreground: Color) {
        Self.palettes[Self.paletteIndex(for: name, count: Self.palettes.count)]
    }

    private static let palettes: [(background: Color, foreground: Color)] = [
        (AriaColor.primaryContainer, AriaColor.onPrimaryContainer),
        (AriaColor.secondaryContainer, AriaColor.onSurface),
        (AriaColor.surfaceContainerHigh, AriaColor.primary),
    ]

    /// Up to two initials from a name; nil for a number or an empty name.
    static func initials(for name: String) -> String? {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "<" })
            .filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return nil }
        if words.count > 1, let last = words.last?.first {
            return String([first, last]).uppercased()
        }
        return String(first).uppercased()
    }

    /// A stable palette choice per name (not `hashValue`, which is seeded).
    static func paletteIndex(for name: String, count: Int) -> Int {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return sum % max(count, 1)
    }
}

private struct AvatarGlass: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.glassEffect(.regular, in: .circle)
        } else {
            content
        }
    }
}
