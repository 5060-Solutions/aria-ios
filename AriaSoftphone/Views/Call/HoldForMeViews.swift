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

    static func title(_ greeting: HoldGreeting) -> LocalizedStringKey {
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


/// When a hold-return call may say "Still on hold".
enum HoldReturnRules {
    /// The PBX accepts Still on hold for this long after the user joined.
    static let stillOnHoldWindow: TimeInterval = 10

    static func showsStillOnHold(joinedAt: Date?, now: Date) -> Bool {
        guard let joinedAt else { return false }
        return now.timeIntervalSince(joinedAt) < stillOnHoldWindow
    }
}

/// Who is back, for the system's incoming screen and the app's own.
enum HoldReturnLabel {
    /// The push's name, else the caller's, else the number.
    static func name(holdReturnName: String?, callerName: String?, callerUri: String) -> String {
        for candidate in [holdReturnName, callerName] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return callerUri
    }

    static func callKitName(holdReturnName: String?, callerName: String?, callerUri: String) -> String {
        let name = name(holdReturnName: holdReturnName, callerName: callerName, callerUri: callerUri)
        return String(localized: "They're back — \(name)")
    }
}

/// What the far party said while the assistant held the line (C3): shown
/// above Decline and Answer when the transcript is not empty.
struct HoldReturnTranscript: View {
    let lines: [TranscriptLine]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("What they said")
                .ariaFont(.label)
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Solid with Reduce Transparency, so the text keeps its contrast.
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.85))
            }
        }
        .glassEffect(reduceTransparency ? .identity : .regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("holdReturn.transcript")
    }

    private func row(_ line: TranscriptLine) -> some View {
        let speaker = line.speaker == "assistant"
            ? String(localized: "Assistant") : String(localized: "holdForMe.speaker.caller", defaultValue: "Them")
        return VStack(alignment: .leading, spacing: 0) {
            Text(speaker)
                .ariaFont(.label)
                .foregroundStyle(.white.opacity(0.7))
            Text(line.text)
                .ariaFont(.bodySmall)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}


/// Settings "Hold for me": the greeting used when a wait starts without a
/// choice. Shown only when the PBX offers Hold for me.
struct HoldForMeSection: View {
    @ObservedObject private var model = HoldForMeModel.shared

    var body: some View {
        if model.available {
            SectionCard(title: Text("Hold for me"), footer: model.settingsError.map { Text($0) }) {
                Picker("Hold for me greeting", selection: selection) {
                    ForEach(HoldGreeting.allCases, id: \.self) { greeting in
                        Text(HoldForMeSheet.title(greeting))
                            .tag(greeting)
                            .disabled(greeting == .assistant && !assistantAvailable)
                    }
                }
                .pickerStyle(.menu)
                .tint(AriaColor.primary)
                .frame(minHeight: ComponentSize.iconButton)
                .accessibilityIdentifier("settings.holdForMeGreeting")
            }
            .disabled(model.settings == nil)
            .task { await model.loadSettings() }
        }
    }

    private var assistantAvailable: Bool { model.settings?.assistantAvailable ?? false }

    private var selection: Binding<HoldGreeting> {
        Binding(
            get: { model.settings?.greeting ?? .line },
            set: { greeting in Task { await model.setGreeting(greeting) } }
        )
    }
}

/// The banner a tapped `hold_wait` notification opens the app to: who picked
/// up, and Call again. Shown whether or not the flag has been read yet.
struct HoldWaitNoticeBanner: View {
    let notice: HoldWaitNotice
    @ObservedObject private var model = HoldForMeModel.shared

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            Image(systemName: "hourglass")
                .foregroundStyle(AriaColor.primary)
                .accessibilityHidden(true)
            Text(notice.title)
                .ariaFont(.body)
                .foregroundStyle(AriaColor.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            AriaButton("Call again", kind: .prominent) {
                model.callAgain(notice.remoteNumber)
            }
            .accessibilityIdentifier("holdNotice.callAgain")
            Button("Cancel", systemImage: "xmark") { model.dismissNotice() }
                .labelStyle(.iconOnly)
                .frame(minWidth: ComponentSize.iconButton, minHeight: ComponentSize.iconButton)
                .accessibilityIdentifier("holdNotice.dismiss")
        }
        .padding(Space.m)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .padding(.horizontal, Space.screenMargin)
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("holdNotice.banner")
    }
}
