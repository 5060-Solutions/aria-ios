import SwiftUI

/// The in-call "Hold for me" sheet: what the far party hears when they pick
/// up, and Start holding.
struct HoldForMeSheet: View {
    let call: ActiveCall

    @ObservedObject private var model = HoldForMeModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: HoldGreeting?

    private var assistantAvailable: Bool { model.settings?.assistantAvailable ?? true }

    /// The row picked, else the user's saved greeting; an assistant the
    /// account does not have reads as the short message.
    private var selection: HoldGreeting {
        let wanted = chosen ?? model.settings?.greeting ?? .line
        return wanted == .assistant && !assistantAvailable ? .line : wanted
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    Text("We'll wait on hold and ring you when a person answers. Your phone is free meanwhile.")
                        .ariaFont(.body)
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("holdForMe.body")

                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("When they pick up")
                            .ariaFont(.label)
                            .foregroundStyle(AriaColor.onSurfaceVariant)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            ForEach(Array(HoldGreeting.allCases.enumerated()), id: \.element) { index, greeting in
                                if index > 0 { Divider() }
                                row(greeting)
                            }
                        }
                        .glassEffect(.regular, in: .rect(cornerRadius: Radius.card, style: .continuous))
                    }

                    AriaButton("Start holding", kind: .prominent, size: .primary, fullWidth: true) {
                        let greeting = selection
                        Task { await model.start(call: call, greeting: greeting) }
                        dismiss()
                    }
                    .accessibilityIdentifier("holdForMe.start")
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.vertical, Space.m)
            }
            .navigationTitle("Hold for me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .task { await model.loadSettings() }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ greeting: HoldGreeting) -> some View {
        let disabled = greeting == .assistant && !assistantAvailable
        let selected = selection == greeting
        return Button {
            chosen = greeting
        } label: {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.hairline) {
                    Text(Self.title(greeting))
                        .ariaFont(.body)
                        .foregroundStyle(AriaColor.onSurface)
                    Text(disabled ? LocalizedStringKey("Not available on this account") : Self.detail(greeting))
                        .ariaFont(.bodySmall)
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AriaColor.primary : AriaColor.onSurfaceVariant)
                    .accessibilityHidden(true)
            }
            .padding(Space.m)
            .frame(minHeight: ComponentSize.iconButton)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("holdForMe.greeting.\(greeting.rawValue)")
    }

    private static func title(_ greeting: HoldGreeting) -> LocalizedStringKey {
        switch greeting {
        case .silence: return "Silence"
        case .line: return "Short message"
        case .assistant: return "AI assistant"
        }
    }

    private static func detail(_ greeting: HoldGreeting) -> LocalizedStringKey {
        switch greeting {
        case .silence: return "They hear nothing until you join."
        case .line: return "They hear: “One moment please, I'm connecting you now.”"
        case .assistant:
            return "An automated assistant says it's automated, asks what the call is about, and shows you what they say."
        }
    }
}
