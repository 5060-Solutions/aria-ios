import SwiftUI

// The Aria design tokens (DESIGN.md §1, §3, §6), shared with the desktop
// softphone and the Android app. Never improvise a size, spacing or colour in
// a view: add a token here first.

// MARK: - Colour

/// Colour roles. Asset-catalog colours under `Theme/`, each with a dark
/// variant, so they follow the system appearance without code.
enum AriaColor {
    static let primary = Color("Theme/Primary")
    static let onPrimary = Color("Theme/OnPrimary")
    static let primaryContainer = Color("Theme/PrimaryContainer")
    static let onPrimaryContainer = Color("Theme/OnPrimaryContainer")
    static let secondary = Color("Theme/Secondary")
    static let secondaryContainer = Color("Theme/SecondaryContainer")
    /// The brand accent: logo, AI, the recording badge.
    static let tertiary = Color("Theme/Tertiary")
    static let error = Color("Theme/Error")
    static let onError = Color("Theme/OnError")
    static let errorContainer = Color("Theme/ErrorContainer")
    static let success = Color("Theme/Success")
    static let background = Color("Theme/Background")
    static let surface = Color("Theme/Surface")
    static let surfaceContainerHigh = Color("Theme/SurfaceContainerHigh")
    static let onSurface = Color("Theme/OnSurface")
    static let onSurfaceVariant = Color("Theme/OnSurfaceVariant")
    static let outlineVariant = Color("Theme/OutlineVariant")

    /// Hang-up and answer: fixed, the same in both appearances, so a white
    /// glyph on them always clears 3:1 (6.5:1 and 5.1:1).
    static let hangUp = Color("Theme/CallHangup")
    static let answer = Color("Theme/CallAnswer")
    /// The dark end of the call screen's gradient.
    static let callBackdrop = Color("Theme/CallBackdrop")

    /// The call screen's 3×3 mesh, row by row: primary at the top drifting
    /// to the dark background, with a hint of the brand indigo. The call
    /// screen is dark in both appearances; white text clears 4.5:1 on every
    /// stop.
    static let callMesh: [Color] = [
        Color(hex: 0x1F7A5E), Color(hex: 0x155C47), Color(hex: 0x23406E),
        Color(hex: 0x0F4A39), Color(hex: 0x0B3D2E), Color(hex: 0x132E45),
        Color(hex: 0x07261C), Color(hex: 0x0A1C15), Color(hex: 0x0F1511),
    ]
}

extension Color {
    /// An sRGB colour from 0xRRGGBB.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

// MARK: - Spacing, shape and size

/// The 4 pt spacing scale.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40

    /// Leading and trailing screen margin.
    static let screenMargin: CGFloat = l
    /// Between list rows.
    static let rowGap: CGFloat = xxs
    /// Between sections.
    static let sectionGap: CGFloat = xl
}

enum Radius {
    static let card: CGFloat = 20
    /// Top corners of a sheet.
    static let sheet: CGFloat = 28
    /// Content rows (nav/action rows are capsules).
    static let contentRow: CGFloat = 16
    static let chip: CGFloat = 12
    static let textField: CGFloat = 14
}

/// Component sizes, identical on iOS and Android.
enum ComponentSize {
    static let dialKey: CGFloat = 76
    static let dialKeyGapH: CGFloat = 12
    static let dialKeyGapV: CGFloat = 14
    /// Call, Answer and Hang-up.
    static let primaryCall: CGFloat = 72
    static let callControl: CGFloat = 64
    static let callControlCell: CGFloat = 96
    /// The minimum hit target.
    static let iconButton: CGFloat = 44
    static let primaryButton: CGFloat = 52
    static let secondaryButton: CGFloat = 44
    static let rowWithAvatar: CGFloat = 64
    static let row: CGFloat = 52
    static let avatarList: CGFloat = 40
    static let avatarCall: CGFloat = 96
    /// The glass disc behind an empty state's symbol.
    static let emptyStateIcon: CGFloat = 88
    /// The leading symbol column of a settings row.
    static let rowIcon: CGFloat = 28
}

// MARK: - Motion

enum Motion {
    static let short: TimeInterval = 0.2
    static let medium: TimeInterval = 0.3
    static let long: TimeInterval = 0.45

    /// A spring, or a short fade when Reduce Motion is on.
    static func standard(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: short) : .smooth(duration: medium)
    }

    /// A quick spring for direct manipulation (toggles, keys).
    static func snappy(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: short) : .snappy(duration: short)
    }
}

// MARK: - Glow

extension View {
    /// The call-button glow: a `0 6 24` shadow at 40% of the button colour.
    func ariaGlow(_ color: Color, isEnabled: Bool = true) -> some View {
        shadow(color: isEnabled ? color.opacity(0.4) : .clear, radius: 12, x: 0, y: 6)
    }
}
