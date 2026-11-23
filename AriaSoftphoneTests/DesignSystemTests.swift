import XCTest
import SwiftUI
import UIKit
@testable import AriaSoftphone

final class DesignSystemTests: XCTestCase {
    // MARK: Colour assets

    private static let colorNames = [
        "Primary", "OnPrimary", "PrimaryContainer", "OnPrimaryContainer", "Secondary",
        "SecondaryContainer", "Tertiary", "Error", "OnError", "ErrorContainer", "Success",
        "Background", "Surface", "SurfaceContainerHigh", "OnSurface", "OnSurfaceVariant",
        "OutlineVariant", "CallHangup", "CallAnswer", "CallBackdrop",
    ]

    private func color(_ name: String, _ style: UIUserInterfaceStyle) throws -> UIColor {
        let base = try XCTUnwrap(UIColor(named: "Theme/\(name)", in: Bundle(for: CallManager.self), compatibleWith: nil),
                                 "missing colour asset Theme/\(name)")
        return base.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    func testEveryColourTokenExists() throws {
        for name in Self.colorNames {
            _ = try color(name, .light)
        }
    }

    func testColoursMatchTheDesignSpec() throws {
        let expected: [String: (String, String)] = [
            "Primary": ("1a6b52", "7ddcb0"), "OnPrimary": ("ffffff", "003826"),
            "PrimaryContainer": ("a8f0cf", "005138"), "Tertiary": ("6366f1", "a5b4fc"),
            "Error": ("ba1a1a", "ffb4ab"), "Success": ("2e7d32", "66bb6a"),
            "Background": ("f5fbf5", "0f1511"), "Surface": ("edf3ed", "1b211d"),
            "OnSurface": ("171d19", "e8ede8"), "OnSurfaceVariant": ("404943", "c8d2c9"),
            "OutlineVariant": ("bfc9c1", "404943"),
        ]
        for (name, (light, dark)) in expected {
            XCTAssertEqual(hex(try color(name, .light)), light, name)
            XCTAssertEqual(hex(try color(name, .dark)), dark, name)
        }
    }

    func testHangUpAndAnswerAreFixed() throws {
        for name in ["CallHangup", "CallAnswer"] {
            XCTAssertEqual(hex(try color(name, .light)), hex(try color(name, .dark)), name)
        }
    }

    // MARK: Contrast (DESIGN.md §1: 4.5:1 text, 3:1 large text and icons)

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testTextContrastInBothModes() throws {
        let textPairs = [
            ("OnSurface", "Background"), ("OnSurface", "Surface"), ("OnSurface", "SurfaceContainerHigh"),
            ("OnSurfaceVariant", "Background"), ("OnSurfaceVariant", "Surface"),
            ("OnPrimary", "Primary"), ("OnPrimaryContainer", "PrimaryContainer"),
            ("OnError", "Error"), ("Primary", "Background"), ("Primary", "Surface"),
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (fg, bg) in textPairs {
                let ratio = contrast(try color(fg, style), try color(bg, style))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fg) on \(bg), \(style == .dark ? "dark" : "light"): \(ratio)")
            }
        }
    }

    func testCallButtonGlyphsClearThreeToOne() throws {
        for name in ["CallHangup", "CallAnswer"] {
            XCTAssertGreaterThanOrEqual(contrast(.white, try color(name, .light)), 3, name)
        }
        // The call screen's labels sit on its gradient's dark end.
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertGreaterThanOrEqual(contrast(.white, try color("CallBackdrop", style)), 4.5)
        }
    }

    // MARK: Typography

    func testFigtreeIsBundledInEveryWeight() {
        XCTAssertTrue(AriaFont.isAvailable)
        for weight in AriaFont.Weight.allCases {
            XCTAssertNotNil(UIFont(name: AriaFont.postScriptName(weight), size: 17), weight.rawValue)
        }
    }

    func testTypeScaleMatchesTheSpec() {
        let spec: [AriaTextStyle: (CGFloat, CGFloat?, AriaFont.Weight)] = [
            .display: (40, 48, .light), .headline: (28, 34, .medium), .title: (20, 26, .semibold),
            .body: (16, 22, .regular), .bodySmall: (14, 20, .regular), .label: (13, 16, .semibold),
            .dialDigit: (34, nil, .light), .dialLetters: (10, nil, .semibold),
        ]
        for style in AriaTextStyle.allCases {
            let (size, lineHeight, weight) = spec[style]!
            XCTAssertEqual(style.size, size)
            XCTAssertEqual(style.lineHeight, lineHeight)
            XCTAssertEqual(style.weight, weight)
        }
        XCTAssertEqual(AriaTextStyle.headline.tracking, -0.56, accuracy: 0.001)
        XCTAssertEqual(AriaTextStyle.dialLetters.tracking, 1, accuracy: 0.001)
        XCTAssertEqual(AriaTextStyle.body.lineSpacing, 22 - 16 * 1.2, accuracy: 0.001)
    }

    func testFontsScaleWithDynamicType() {
        let large = UITraitCollection(preferredContentSizeCategory: .large)
        let huge = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let base = UIFont(name: AriaFont.postScriptName(.regular), size: 16)!
        let metrics = UIFontMetrics(forTextStyle: .body)
        XCTAssertEqual(metrics.scaledFont(for: base, compatibleWith: large).pointSize, 16, accuracy: 0.5)
        XCTAssertGreaterThan(metrics.scaledFont(for: base, compatibleWith: huge).pointSize, 40)
    }

    // MARK: Sizes

    func testComponentSizesMatchTheSpec() {
        XCTAssertEqual(ComponentSize.dialKey, 76)
        XCTAssertEqual(ComponentSize.primaryCall, 72)
        XCTAssertEqual(ComponentSize.callControl, 64)
        XCTAssertEqual(ComponentSize.callControlCell, 96)
        XCTAssertEqual(ComponentSize.iconButton, 44)
        XCTAssertEqual(ComponentSize.primaryButton, 52)
        XCTAssertEqual(ComponentSize.rowWithAvatar, 64)
        XCTAssertEqual(ComponentSize.row, 52)
        XCTAssertEqual([Space.xxs, Space.xs, Space.s, Space.m, Space.l, Space.xl, Space.xxl, Space.xxxl],
                       [4, 8, 12, 16, 20, 24, 32, 40])
        XCTAssertEqual(Radius.card, 20)
        XCTAssertEqual(Radius.sheet, 28)
    }

    // MARK: Dial keys

    func testDialKeyAccessibilityLabels() {
        let keys = DialPadKey.rows.flatMap { $0 }
        XCTAssertEqual(keys.map(\.digit), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"])
        XCTAssertEqual(keys[4].accessibilityLabel, "5, J K L")
        XCTAssertEqual(keys[0].accessibilityLabel, "1")
        XCTAssertEqual(keys[9].accessibilityLabel, "star")
        XCTAssertEqual(keys[11].accessibilityLabel, "pound")
    }

    // MARK: Avatar

    func testInitials() {
        XCTAssertEqual(Avatar.initials(for: "Marcus Chen"), "MC")
        XCTAssertEqual(Avatar.initials(for: "Priya"), "P")
        XCTAssertEqual(Avatar.initials(for: "Mary Ann van Dyke"), "MD")
        XCTAssertEqual(Avatar.initials(for: "chloé dubois"), "CD")
        XCTAssertEqual(Avatar.initials(for: "Daniel Okafor <1042>"), "DO")
        XCTAssertNil(Avatar.initials(for: "+1 (415) 555-0142"))
        XCTAssertNil(Avatar.initials(for: ""))
    }

    func testAvatarPaletteIsStable() {
        XCTAssertEqual(Avatar.paletteIndex(for: "Marcus Chen", count: 3),
                       Avatar.paletteIndex(for: "Marcus Chen", count: 3))
        let indices = Set(["Amelia", "Ben", "Chloé", "Daniel", "Emma", "Grace"].map { Avatar.paletteIndex(for: $0, count: 3) })
        XCTAssertGreaterThan(indices.count, 1, "names spread over the palettes")
    }

    // MARK: Status chip

    func testConnectionStatesMapToTheirStatus() {
        XCTAssertEqual(ConnectionState.registered.status, .registered)
        XCTAssertEqual(ConnectionState.connecting.status, .connecting)
        XCTAssertEqual(ConnectionState.offline.status, .offline)
        XCTAssertEqual(ConnectionState.error("503").status, .error)
        // The label always accompanies the colour.
        for state in [ConnectionState.registered, .connecting, .offline, .error("x")] {
            XCTAssertFalse(state.label.isEmpty)
        }
    }

    // MARK: Banner

    func testBannerFactories() {
        XCTAssertEqual(BannerMessage.error("No route").kind, .error)
        XCTAssertEqual(BannerMessage.info("x").duration, 4)
        XCTAssertNotEqual(BannerMessage.info("x").id, BannerMessage.info("x").id)
    }
}

final class SettingsTests: XCTestCase {
    func testAppearanceMapsToColorScheme() {
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(AppAppearance(rawValue: "dark"), .dark)
        XCTAssertEqual(AppAppearance.allCases.count, 3)
    }

    func testAboutLinksAreHTTPS() {
        XCTAssertEqual(AboutLinks.website.scheme, "https")
        XCTAssertEqual(AboutLinks.acknowledgements.scheme, "https")
    }

    func testVersionDescription() {
        XCTAssertEqual(AppVersion.describe(["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "7"]), "1.0.0 (7)")
        XCTAssertEqual(AppVersion.describe(["CFBundleShortVersionString": "1.0.0"]), "1.0.0")
    }
}
