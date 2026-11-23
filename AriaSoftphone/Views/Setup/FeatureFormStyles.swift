import SwiftUI

// Small building blocks shared by the feature screens (setup, forwarding,
// codecs, calling settings), on top of the design system tokens.

extension View {
    /// A text field on a filled, rounded surface (DESIGN.md: radius 14).
    func ariaField(invalid: Bool = false) -> some View {
        self
            .ariaFont(.body)
            .foregroundStyle(AriaColor.onSurface)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .frame(minHeight: ComponentSize.row)
            .background(AriaColor.surfaceContainerHigh,
                        in: .rect(cornerRadius: Radius.textField, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.textField, style: .continuous)
                    .strokeBorder(invalid ? AriaColor.error : .clear, lineWidth: 1.5)
            }
    }
}

/// A labelled field with its problem underneath.
struct FieldBlock<Field: View>: View {
    let label: LocalizedStringKey
    var problem: String? = nil
    var problemIdentifier: String? = nil
    @ViewBuilder var field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(label)
                .ariaFont(.label)
                .foregroundStyle(AriaColor.onSurfaceVariant)
            field()
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.error)
                    .accessibilityIdentifier(problemIdentifier ?? "")
            }
        }
        .padding(.vertical, Space.xs)
    }
}

/// Label on the left, value on the right; for read-only details.
struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String
    var valueColor: Color = AriaColor.onSurface

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the value goes under the label so neither
        // breaks mid-word.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.s))
        layout {
            Text(label)
                .ariaFont(.body)
                .foregroundStyle(AriaColor.onSurfaceVariant)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Space.s) }
            Text(value)
                .ariaFont(.body)
                .fontWeight(.medium)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? Space.xs : 0)
        .frame(minHeight: ComponentSize.row)
        .accessibilityElement(children: .combine)
    }
}

/// A settings row that opens another screen.
struct NavigationRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: systemImage)
                .foregroundStyle(AriaColor.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .ariaFont(.body)
                .foregroundStyle(AriaColor.onSurface)
            Spacer()
            if let detail {
                Text(detail)
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AriaColor.onSurfaceVariant)
                .accessibilityHidden(true)
        }
        .frame(minHeight: ComponentSize.row)
        .contentShape(.rect)
    }
}

/// A settings toggle with an icon.
struct ToggleRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Space.s) {
                Image(systemName: systemImage)
                    .foregroundStyle(AriaColor.primary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .ariaFont(.body)
                    .foregroundStyle(AriaColor.onSurface)
            }
        }
        .tint(AriaColor.primary)
        .frame(minHeight: ComponentSize.row)
    }
}

/// A divider inset past a row's icon.
struct RowDivider: View {
    var body: some View {
        Divider().overlay(AriaColor.outlineVariant).padding(.leading, 40)
    }
}
