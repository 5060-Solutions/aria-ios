import SwiftUI
import UIKit

/// The type scale of DESIGN.md §2, in Figtree, scaled with Dynamic Type.
///
/// System chrome (navigation titles, tab labels, glass toolbars) stays in
/// SF Pro; these tokens are for content and display text.
enum AriaTextStyle: CaseIterable {
    /// Dialed number, call timer. 40/48, light.
    case display
    /// Caller name on the call screen, screen titles. 28/34, medium.
    case headline
    /// Section headers, sheet titles. 20/26, semibold.
    case title
    /// List primary text. 16/22, regular.
    case body
    /// Secondary text, timestamps. 14/20, regular.
    case bodySmall
    /// Buttons, chips, tab labels. 13/16, semibold.
    case label
    /// Dial-key digits. 34, light.
    case dialDigit
    /// Dial-key letters. 10, semibold, +0.1em.
    case dialLetters

    var size: CGFloat {
        switch self {
        case .display: return 40
        case .headline: return 28
        case .title: return 20
        case .body: return 16
        case .bodySmall: return 14
        case .label: return 13
        case .dialDigit: return 34
        case .dialLetters: return 10
        }
    }

    var lineHeight: CGFloat? {
        switch self {
        case .display: return 48
        case .headline: return 34
        case .title: return 26
        case .body: return 22
        case .bodySmall: return 20
        case .label: return 16
        case .dialDigit, .dialLetters: return nil
        }
    }

    var weight: AriaFont.Weight {
        switch self {
        case .display, .dialDigit: return .light
        case .headline: return .medium
        case .title, .label, .dialLetters: return .semibold
        case .body, .bodySmall: return .regular
        }
    }

    /// The Dynamic Type style the size scales with.
    var textStyle: Font.TextStyle {
        switch self {
        case .display, .dialDigit: return .largeTitle
        case .headline: return .title
        case .title: return .title3
        case .body: return .body
        case .bodySmall: return .subheadline
        case .label: return .footnote
        case .dialLetters: return .caption2
        }
    }

    /// Letter spacing in ems.
    var trackingEm: CGFloat {
        switch self {
        case .headline: return -0.02
        case .dialLetters: return 0.1
        default: return 0
        }
    }

    var tracking: CGFloat { trackingEm * size }

    /// Extra leading to reach the token's line height. Figtree's natural line
    /// is 1.2 × size.
    var lineSpacing: CGFloat {
        guard let lineHeight else { return 0 }
        return max(0, lineHeight - size * 1.2)
    }

    var font: Font { AriaFont.font(size: size, weight: weight, relativeTo: textStyle) }
}

/// Figtree, bundled as static weights (instanced from the desktop's variable
/// font). Falls back to the system font if the files are missing.
enum AriaFont {
    enum Weight: String, CaseIterable {
        case light = "Light"
        case regular = "Regular"
        case medium = "Medium"
        case semibold = "SemiBold"
        case bold = "Bold"

        var system: Font.Weight {
            switch self {
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    static func postScriptName(_ weight: Weight) -> String { "Figtree-\(weight.rawValue)" }

    static let isAvailable: Bool = UIFont(name: postScriptName(.regular), size: 17) != nil

    static func font(size: CGFloat, weight: Weight, relativeTo style: Font.TextStyle) -> Font {
        guard isAvailable else { return .system(size: size, weight: weight.system) }
        return .custom(postScriptName(weight), size: size, relativeTo: style)
    }

    /// A UIKit font for the token, scaled for the current Dynamic Type size.
    static func uiFont(_ style: AriaTextStyle, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        let base = UIFont(name: postScriptName(style.weight), size: style.size)
            ?? .systemFont(ofSize: style.size, weight: .regular)
        return UIFontMetrics(forTextStyle: style.textStyle.uiKit).scaledFont(for: base, compatibleWith: traits)
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension View {
    /// Figtree in an Aria type token: font, tracking and line height.
    func ariaFont(_ style: AriaTextStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

extension Font {
    static func aria(_ style: AriaTextStyle) -> Font { style.font }
}

extension String {
    /// A host or address that wraps only after its dots (and @), never
    /// mid-label: zero-width spaces mark the break points. For display only.
    var breakingAtDots: String {
        replacingOccurrences(of: ".", with: ".\u{200B}")
            .replacingOccurrences(of: "@", with: "@\u{200B}")
    }
}
