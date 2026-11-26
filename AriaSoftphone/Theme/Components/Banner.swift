import SwiftUI

/// A short message shown over the top of a screen: errors, refused calls,
/// confirmations. Announced to VoiceOver and dismissed after a few seconds.
struct BannerMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case info, success, warning, error

        var systemImage: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "lock.open.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .info: return AriaColor.primary
            case .success: return AriaColor.success
            case .warning: return AriaColor.warning
            case .error: return AriaColor.error
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var text: String
    /// How long it stays up; nil keeps it until dismissed.
    var duration: TimeInterval? = 4

    static func error(_ text: String) -> BannerMessage { .init(kind: .error, text: text) }
    static func info(_ text: String) -> BannerMessage { .init(kind: .info, text: text) }
    static func success(_ text: String) -> BannerMessage { .init(kind: .success, text: text) }
    /// Stays up longer than the others: something the user should read.
    static func warning(_ text: String) -> BannerMessage { .init(kind: .warning, text: text, duration: 8) }
}

/// The glass banner itself.
struct Banner: View {
    let message: BannerMessage
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: message.kind.systemImage)
                .foregroundStyle(message.kind.color)
                .accessibilityHidden(true)
            Text(message.text)
                .ariaFont(.bodySmall)
                .foregroundStyle(AriaColor.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                        .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
                .padding(.vertical, -Space.s)
                .padding(.trailing, -Space.s)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background {
            // A warning is read over whatever it covers (the call screen's
            // amber capsule): solid, so nothing shows through its text.
            if message.kind == .warning {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(AriaColor.warningContainer)
            }
        }
        .glassEffect(.regular.tint(tint),
                     in: .rect(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner.\(message.kind)")
    }

    private var tint: Color? {
        switch message.kind {
        case .error: return AriaColor.errorContainer.opacity(0.6)
        case .warning: return AriaColor.warningContainer
        case .info, .success: return nil
        }
    }
}

extension View {
    /// Show `message` as a banner at the top, announce it, and clear it
    /// after its duration.
    func banner(_ message: Binding<BannerMessage?>) -> some View {
        modifier(BannerPresenter(message: message))
    }
}

private struct BannerPresenter: ViewModifier {
    @Binding var message: BannerMessage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let current = message {
                    Banner(message: current) { message = nil }
                        .padding(.horizontal, Space.screenMargin)
                        .padding(.top, Space.xs)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .task(id: current.id) {
                            AccessibilityNotification.Announcement(current.text).post()
                            guard let duration = current.duration else { return }
                            try? await Task.sleep(for: .seconds(duration))
                            if message?.id == current.id { message = nil }
                        }
                }
            }
            .animation(Motion.standard(reduceMotion: reduceMotion), value: message)
    }
}
