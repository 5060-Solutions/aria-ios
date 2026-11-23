import SwiftUI

// MARK: - List row

/// A list row: leading avatar or icon, primary and secondary text, and a
/// trailing accessory. 64 pt tall with an avatar, 52 without. At
/// accessibility text sizes the trailing accessory moves under the text so
/// nothing is truncated.
struct AriaListRow<Leading: View, Trailing: View>: View {
    let title: Text
    var subtitle: Text? = nil
    var titleColor: Color = AriaColor.onSurface
    var hasAvatar = true
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: isLarge ? .top : .center, spacing: Space.s) {
            leading()
            let layout = isLarge
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
                : AnyLayout(HStackLayout(alignment: .center, spacing: Space.s))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .ariaFont(.body)
                        .foregroundStyle(titleColor)
                        .lineLimit(isLarge ? nil : 1)
                    if let subtitle {
                        subtitle
                            .ariaFont(.bodySmall)
                            .foregroundStyle(AriaColor.onSurfaceVariant)
                            .lineLimit(isLarge ? nil : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: hasAvatar ? ComponentSize.rowWithAvatar : ComponentSize.row)
    }
}

extension AriaListRow where Trailing == EmptyView {
    init(
        title: Text,
        subtitle: Text? = nil,
        titleColor: Color = AriaColor.onSurface,
        hasAvatar: Bool = true,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.init(title: title, subtitle: subtitle, titleColor: titleColor, hasAvatar: hasAvatar,
                  leading: leading, trailing: { EmptyView() })
    }
}

extension View {
    /// List-row chrome for Aria lists: a 16 pt content-row card, 4 pt apart,
    /// inside the 20 pt screen margin; no separators.
    func ariaListRow(background: Color = AriaColor.surface) -> some View {
        self
            // The card is inset by the screen margin; the content by the
            // margin plus the card's padding.
            .listRowInsets(EdgeInsets(top: 0, leading: Space.screenMargin + Space.s, bottom: 0,
                                      trailing: Space.screenMargin + Space.xs))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: Radius.contentRow, style: .continuous)
                    .fill(background)
                    .padding(.vertical, Space.rowGap / 2)
                    .padding(.horizontal, Space.screenMargin)
            )
            .listRowSpacing(0)
    }

    /// The list chrome the row style expects: plain, on the app background.
    func ariaListStyle() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AriaColor.background)
    }
}

// MARK: - Empty state

/// The one empty state used everywhere: an icon, a title and one sentence,
/// with an optional action.
struct EmptyState: View {
    let systemImage: String
    let title: Text
    let message: Text
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(AriaColor.primary)
                .frame(width: ComponentSize.emptyStateIcon, height: ComponentSize.emptyStateIcon)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: Space.xs) {
                title
                    .ariaFont(.title)
                    .foregroundStyle(AriaColor.onSurface)
                    .accessibilityAddTraits(.isHeader)
                message
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
            }
            .multilineTextAlignment(.center)
            if let actionTitle, let action {
                AriaButton(actionTitle, kind: .prominent, action: action)
                    .padding(.top, Space.xs)
            }
        }
        .padding(.horizontal, Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Section card

/// A titled group on a 20 pt card: Settings sections, sheet groups.
struct SectionCard<Content: View>: View {
    var title: Text? = nil
    var footer: Text? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let title {
                title
                    .ariaFont(.label)
                    .textCase(.uppercase)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .padding(.horizontal, Space.m)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.xxs)
            .background(AriaColor.surface, in: .rect(cornerRadius: Radius.card, style: .continuous))
            if let footer {
                footer
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .padding(.horizontal, Space.m)
            }
        }
    }
}

/// A row inside a `SectionCard`: label, optional value or control, 52 pt.
/// At accessibility text sizes the value moves under the label, so neither
/// breaks mid-word.
struct SectionRow<Accessory: View>: View {
    let title: Text
    var systemImage: String? = nil
    var showsDivider = true
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        VStack(spacing: 0) {
            HStack(alignment: stacked ? .top : .center, spacing: Space.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(AriaColor.primary)
                        .frame(width: ComponentSize.rowIcon)
                        .padding(.top, stacked ? Space.xs : 0)
                        .accessibilityHidden(true)
                }
                let layout = stacked
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xxs))
                    : AnyLayout(HStackLayout(spacing: Space.xs))
                layout {
                    title
                        .ariaFont(.body)
                        .foregroundStyle(AriaColor.onSurface)
                    if !stacked { Spacer(minLength: Space.xs) }
                    accessory()
                        .ariaFont(.body)
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, stacked ? Space.s : 0)
            .frame(minHeight: ComponentSize.row)
            if showsDivider {
                Divider().overlay(AriaColor.outlineVariant.opacity(0.6))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
