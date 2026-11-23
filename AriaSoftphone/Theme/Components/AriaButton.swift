import SwiftUI

/// The four button styles of DESIGN.md §3. Use exactly these everywhere.
enum AriaButtonKind {
    /// The one main action on a screen: tinted glass in primary.
    case prominent
    /// Secondary actions: clear glass.
    case standard
    /// Low-emphasis text actions.
    case plain
    /// Irreversible actions (Sign out, Delete): tinted glass in error.
    case destructive
}

/// Button heights: 52 for primary (form) buttons, 44 for the rest.
enum AriaButtonSize {
    case primary
    case secondary

    var height: CGFloat {
        switch self {
        case .primary: return ComponentSize.primaryButton
        case .secondary: return ComponentSize.secondaryButton
        }
    }
}

extension View {
    /// Style a `Button` as one of the four Aria kinds.
    @ViewBuilder
    func ariaButtonStyle(_ kind: AriaButtonKind) -> some View {
        switch kind {
        case .prominent:
            buttonStyle(.glassProminent)
                .tint(AriaColor.primary)
                .foregroundStyle(AriaColor.onPrimary)
        case .standard:
            buttonStyle(.glass)
                .foregroundStyle(AriaColor.primary)
        case .plain:
            buttonStyle(.borderless)
                .foregroundStyle(AriaColor.primary)
        case .destructive:
            buttonStyle(.glassProminent)
                .tint(AriaColor.error)
                .foregroundStyle(AriaColor.onError)
        }
    }
}

/// A text (and optional symbol) button in one of the Aria kinds.
///
///     AriaButton("Scan QR code", systemImage: "qrcode.viewfinder", kind: .prominent) { … }
struct AriaButton: View {
    private let title: Text
    private let systemImage: String?
    private let kind: AriaButtonKind
    private let size: AriaButtonSize
    private let fullWidth: Bool
    private let isLoading: Bool
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        kind: AriaButtonKind = .standard,
        size: AriaButtonSize = .secondary,
        fullWidth: Bool = false,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(verbatim: Text(title), systemImage: systemImage, kind: kind, size: size,
                  fullWidth: fullWidth, isLoading: isLoading, action: action)
    }

    init(
        verbatim title: Text,
        systemImage: String? = nil,
        kind: AriaButtonKind = .standard,
        size: AriaButtonSize = .secondary,
        fullWidth: Bool = false,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if isLoading {
                    ProgressView()
                        .tint(kind == .prominent ? AriaColor.onPrimary : AriaColor.primary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                title
            }
            .ariaFont(.label)
            .multilineTextAlignment(.center)
            .padding(.horizontal, kind == .plain ? 0 : Space.xs)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: size.height - Self.glassVerticalInset(kind))
            .contentShape(.capsule)
        }
        .buttonBorderShape(.capsule)
        .ariaButtonStyle(kind)
        .disabled(isLoading)
    }

    /// The glass styles add this much padding above and below the label;
    /// the label's frame is reduced by it so the button is exactly the token
    /// height.
    static func glassVerticalInset(_ kind: AriaButtonKind) -> CGFloat {
        kind == .plain ? 0 : 2 * 7
    }
}

// MARK: - Call-screen buttons

/// A 64 pt in-call control on glass, with a 13 pt label beneath, in a 96 pt
/// wide cell (DESIGN.md §3). Toggles report "On"/"Off" to VoiceOver.
struct CallControlButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    /// Whether the control is an on/off toggle (Mute, Speaker, Hold, Record).
    var isToggle: Bool = true
    /// Shared glass id for morphing inside a `GlassEffectContainer`.
    var glassID: String? = nil
    var namespace: Namespace.ID? = nil
    var tint: Color? = nil
    /// The cell width; nil fills the grid column (the two-column layout at
    /// accessibility sizes).
    var cellWidth: CGFloat? = ComponentSize.callControlCell
    /// Circle with the label beneath, or a 52 pt pill with the label beside
    /// the icon: the compact form the call screen uses at accessibility
    /// sizes, so all six controls fit above Hang-up.
    var isPill = false
    /// The largest text size the pill labels may use; the call screen picks
    /// one for all six so every label is the same size (`PillLabelFit`).
    var labelSizeCap: DynamicTypeSize = .xxxLarge
    let action: () -> Void

    @State private var taps = 0
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        icon: String,
        label: String,
        isActive: Bool = false,
        isToggle: Bool = true,
        glassID: String? = nil,
        namespace: Namespace.ID? = nil,
        tint: Color? = nil,
        cellWidth: CGFloat? = ComponentSize.callControlCell,
        isPill: Bool = false,
        labelSizeCap: DynamicTypeSize = .xxxLarge,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.isActive = isActive
        self.isToggle = isToggle
        self.glassID = glassID
        self.namespace = namespace
        self.tint = tint
        self.cellWidth = cellWidth
        self.isPill = isPill
        self.labelSizeCap = labelSizeCap
        self.action = action
    }

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            if isPill { pill } else { circle }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isToggle ? Text(isActive ? "On" : "Off") : Text(""))
        .accessibilityAddTraits(isActive && isToggle ? .isSelected : [])
    }

    private var iconColor: Color {
        isActive ? AriaColor.callBackdrop : Color.white.opacity(isEnabled ? 1 : 0.4)
    }

    private var pill: some View {
        HStack(spacing: PillLabelFit.iconSpacing) {
            Image(systemName: icon)
                .font(.title3.weight(.medium))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(iconColor)
                .frame(width: ComponentSize.rowIcon)
            // One size for every pill (see PillLabelFit): no label shrinks
            // below the others, and words never break mid-word.
            Text(label)
                .ariaFont(.label)
                .foregroundStyle(isActive ? AriaColor.callBackdrop : .white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(...labelSizeCap)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PillLabelFit.horizontalPadding)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, minHeight: ComponentSize.primaryButton)
        .glassEffect(glass, in: .capsule)
        .modifier(GlassIDModifier(id: glassID, namespace: namespace))
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(.capsule)
    }

    private var circle: some View {
            VStack(spacing: Space.xs) {
                Image(systemName: icon)
                    .font(.title2.weight(.medium))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : taps)
                    .foregroundStyle(iconColor)
                    .frame(width: ComponentSize.callControl, height: ComponentSize.callControl)
                    .glassEffect(glass, in: .circle)
                    .modifier(GlassIDModifier(id: glassID, namespace: namespace))

                // Every label follows one rule, so none shrinks below the
                // others: full size, up to two lines broken at spaces, in the
                // cell plus the gap beside it (a single long word such as
                // "Lautsprecher" fits there up to the largest standard size).
                // Accessibility sizes use wide two-column cells instead.
                Text(label)
                    .ariaFont(.label)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: cellWidth.map { $0 + Space.l })
                    .frame(maxWidth: cellWidth == nil ? .infinity : nil)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .frame(width: cellWidth)
            .frame(maxWidth: cellWidth == nil ? .infinity : nil)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.rect)
    }

    private var glass: Glass {
        if isActive { return .regular.tint(tint ?? .white).interactive() }
        return .regular.tint(tint?.opacity(0.35)).interactive()
    }
}

/// The 72 pt Call / Answer / Decline / Hang-up button: a fixed semantic
/// colour with its glow, and an optional caption under it.
struct CallActionButton: View {
    enum Role {
        case call, answer, hangUp

        var color: Color {
            switch self {
            case .call, .answer: return AriaColor.answer
            case .hangUp: return AriaColor.hangUp
            }
        }

        var icon: String {
            switch self {
            case .call, .answer: return "phone.fill"
            case .hangUp: return "phone.down.fill"
            }
        }
    }

    let role: Role
    let accessibilityLabel: String
    var caption: String? = nil
    var icon: String? = nil
    var glassID: String? = nil
    var namespace: Namespace.ID? = nil
    /// Caption colour; white on the call screen, onSurfaceVariant elsewhere.
    var captionColor: Color = .white
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Image(systemName: icon ?? role.icon)
                    .font(.title.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.white)
                    .frame(width: ComponentSize.primaryCall, height: ComponentSize.primaryCall)
                    .background(role.color, in: .circle)
                    .glassEffect(.clear.interactive(), in: .circle)
                    .modifier(GlassIDModifier(id: glassID, namespace: namespace))
                    .ariaGlow(role.color, isEnabled: isEnabled)
                if let caption {
                    Text(caption)
                        .ariaFont(.label)
                        .foregroundStyle(captionColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(minWidth: caption == nil ? nil : ComponentSize.callControlCell)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Applies `glassEffectID` when both an id and a namespace are given.
struct GlassIDModifier: ViewModifier {
    let id: String?
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let id, let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

// MARK: - Pill label fit

/// Picks one text size for all the call screen's pill labels: the largest
/// (up to the largest standard size) at which every word of every label fits
/// on a line of its pill. Labels then wrap only at spaces and all match.
enum PillLabelFit {
    static let horizontalPadding = Space.s
    static let iconSpacing = Space.xs

    static let candidates: [DynamicTypeSize] = [.xxxLarge, .xxLarge, .xLarge, .large, .medium, .small, .xSmall]

    /// The width a pill leaves for its label in a column `columnWidth` wide.
    /// Less a safety margin: SwiftUI's line breaking runs a little short of
    /// the measured width, and breaks the word when it does not fit.
    static func textWidth(columnWidth: CGFloat) -> CGFloat {
        columnWidth - 2 * horizontalPadding - ComponentSize.rowIcon - iconSpacing - Space.s
    }

    static func cap(labels: [String], columnWidth: CGFloat, current: DynamicTypeSize) -> DynamicTypeSize {
        let available = textWidth(columnWidth: columnWidth)
        let words = labels.flatMap { $0.split(separator: " ").map(String.init) }
        let start = min(current, .xxxLarge)
        for candidate in candidates where candidate <= start {
            if words.allSatisfy({ width(of: $0, at: candidate) <= available }) { return candidate }
        }
        return .xSmall
    }

    /// The label token's width for `word` at a Dynamic Type size.
    static func width(of word: String, at size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let font = AriaFont.uiFont(.label, compatibleWith: traits)
        return ceil((word as NSString).size(withAttributes: [.font: font]).width)
    }
}
