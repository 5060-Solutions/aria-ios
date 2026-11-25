import SwiftUI

/// The size of the dial pad for the room it has (DESIGN.md §3 gives 76 pt
/// keys as the base). The key grows to fill the width and height it is
/// given, so the digits stay in proportion to the screen on a Pro Max or an
/// iPad, and with Dynamic Type; it stops at `maxKey` so the pad never turns
/// into a wall of buttons, and never goes below `minKey`.
struct DialPadMetrics: Equatable {
    /// The key's diameter.
    let key: CGFloat

    static let baseKey: CGFloat = ComponentSize.dialKey
    static let minKey: CGFloat = 60
    /// Largest key on a compact-width device (iPhone).
    static let maxKeyCompact: CGFloat = 104
    /// Largest key on a regular-width device (iPad).
    static let maxKeyRegular: CGFloat = 124

    /// Gaps keep the 76 pt design's proportions (12 and 14 pt).
    var gapH: CGFloat { key * ComponentSize.dialKeyGapH / Self.baseKey }
    var gapV: CGFloat { key * ComponentSize.dialKeyGapV / Self.baseKey }
    /// The digit is 34 pt on a 76 pt key.
    var digitSize: CGFloat { key * 34 / Self.baseKey }
    /// The letters under it are 10 pt on a 76 pt key.
    var letterSize: CGFloat { key * 10 / Self.baseKey }
    /// Call and Hang-up are 72 pt beside a 76 pt key.
    var callButton: CGFloat { key * ComponentSize.primaryCall / Self.baseKey }

    /// Four rows of keys and the Call row, with the gaps between.
    static let dialerRows = 5

    /// The pad's width and height at this key size.
    var width: CGFloat { 3 * key + 2 * gapH }
    func height(rows: Int = dialerRows) -> CGFloat { CGFloat(rows) * key + CGFloat(rows - 1) * gapV }

    static let base = DialPadMetrics(key: baseKey)

    /// The key that fits `width` x `height` in `rows` rows of keys, scaled
    /// by the text size. Pure, so tests can hold it.
    static func fitting(width: CGFloat, height: CGFloat, rows: Int = dialerRows, typeScale: CGFloat = 1,
                        maxKey: CGFloat = maxKeyCompact) -> DialPadMetrics {
        // Width = 3 keys + 2 horizontal gaps; height = rows keys + rows-1 vertical
        // gaps; both gaps are proportional to the key.
        let unitW = 3 + 2 * ComponentSize.dialKeyGapH / baseKey
        let unitH = CGFloat(rows) + CGFloat(rows - 1) * ComponentSize.dialKeyGapV / baseKey
        let fit = min(width / unitW, height / unitH)
        let wanted = min(fit, maxKey * typeScale)
        guard wanted.isFinite else { return base }
        return DialPadMetrics(key: max(min(minKey, fit), wanted).rounded(.down))
    }

    /// How much larger the pad may grow at a text size: 1 at the default,
    /// a little under 1 at the smallest, 1.3 from the second accessibility
    /// size up.
    static func typeScale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.9
        case .small: return 0.95
        case .medium, .large: return 1
        case .xLarge: return 1.05
        case .xxLarge: return 1.1
        case .xxxLarge: return 1.15
        case .accessibility1: return 1.22
        default: return 1.3
        }
    }
}

private struct DialPadMetricsKey: EnvironmentKey {
    static let defaultValue = DialPadMetrics.base
}

extension EnvironmentValues {
    /// The dial pad's size, set by the view that knows how much room it has.
    var dialPadMetrics: DialPadMetrics {
        get { self[DialPadMetricsKey.self] }
        set { self[DialPadMetricsKey.self] = newValue }
    }
}

extension AriaFont {
    /// Figtree at an exact size: for text that sits in a shape that is
    /// itself scaled for Dynamic Type (the dial keys), so it is not scaled twice.
    static func fixed(size: CGFloat, weight: Weight) -> Font {
        guard isAvailable else { return .system(size: size, weight: weight.system) }
        return .custom(postScriptName(weight), fixedSize: size)
    }
}
