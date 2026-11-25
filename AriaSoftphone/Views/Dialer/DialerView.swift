import SwiftUI
import AudioToolbox

/// The dial pad (DESIGN.md §5 Dialer): status chip, number display with a
/// contact match line, the 4×3 keys, and Call with backspace.
struct DialerView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @ObservedObject private var selfService = SelfService.shared
    @ObservedObject private var history = CallHistoryStore.shared
    @ObservedObject private var directory = ContactDirectory.shared

    @AppStorage(AccountSettings.Key.displayName) private var displayName = ""
    @AppStorage(AccountSettings.Key.username) private var username = ""

    @State private var dialedNumber = FixtureMode.shows(.dialerNumber) ? "4155550142" : ""
    @State private var showConnection = FixtureMode.shows(.connectionSheet)
    @State private var banner: BannerMessage?
    @State private var keyTaps = 0
    @State private var pasteboardHasText = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The height of what sits above the keys (status chip, number, match
    /// line), measured, so the keys can take the rest.
    @State private var chipHeight: CGFloat = 0
    @State private var numberHeight: CGFloat = 0

    /// Space the pad's own layout uses besides the keys: above the keypad,
    /// above the Call row, below the pad.
    private static let padPadding = Space.m + Space.xl + Space.xs + Space.xl

    private func padMetrics(in size: CGSize) -> DialPadMetrics {
        .fitting(
            width: size.width - 2 * Space.screenMargin,
            height: size.height - chipHeight - numberHeight - Self.padPadding,
            typeScale: DialPadMetrics.typeScale(for: dynamicTypeSize),
            maxKey: horizontalSizeClass == .regular ? DialPadMetrics.maxKeyRegular : DialPadMetrics.maxKeyCompact
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                pad(padMetrics(in: proxy.size))
            }
            .background(AriaColor.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .banner($banner)
            .sheet(isPresented: $showConnection) {
                ConnectionSheet()
            }
            .sensoryFeedback(.impact(weight: .light), trigger: keyTaps)
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification).merge(
                with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            ) { _ in
                pasteboardHasText = UIPasteboard.general.hasStrings
            }
            .task {
                pasteboardHasText = UIPasteboard.general.hasStrings
                await directory.loadIfAuthorized()
                await selfService.refresh()
            }
        }
    }

    private func pad(_ metrics: DialPadMetrics) -> some View {
        VStack(spacing: 0) {
            StatusChip(
                accountName: displayName.isEmpty ? username : displayName,
                state: sipEngine.connectionState,
                isDoNotDisturb: selfService.doNotDisturb == true,
                isForwarding: selfService.isForwardingAll
            ) {
                showConnection = true
            }
            .padding(.top, Space.xs)
            .onGeometryChange(for: CGFloat.self) { $0.size.height + Space.xs } action: { chipHeight = $0 }

            // The pad sits low, as in Phone: free space goes above the
            // number, not between it and the keys.
            Spacer(minLength: Space.m)

            numberDisplay
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { numberHeight = $0 }

            keypad(metrics)
                .padding(.top, Space.xl)

            bottomRow(metrics)
                .padding(.top, metrics.gapV + Space.xs)
                .padding(.bottom, Space.xl)

            // On a wide screen the pad floats in the middle rather than
            // hanging off the bottom.
            if horizontalSizeClass == .regular { Spacer(minLength: 0) }
        }
        .environment(\.dialPadMetrics, metrics)
        .padding(.horizontal, Space.screenMargin)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Number

    private var matcher: ContactMatcher {
        ContactMatcher(contacts: directory.contacts, history: history.records)
    }

    private var numberDisplay: some View {
        VStack(spacing: Space.xxs) {
            ZStack {
                if dialedNumber.isEmpty, !pasteboardHasText {
                    Text("Enter a number")
                        .ariaFont(.display)
                        .foregroundStyle(AriaColor.onSurfaceVariant.opacity(0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                } else if dialedNumber.isEmpty {
                    // Only when there is text to paste: an empty pasteboard
                    // draws the system control dimmed. `hasStrings` does not
                    // read the pasteboard, so no paste banner.
                    if pasteboardHasText {
                        PasteButton(payloadType: String.self) { strings in
                        guard let digits = DialString.pasteable(strings.first ?? "") else { return }
                        dialedNumber = digits
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .tint(AriaColor.primary)
                    .transition(.opacity)
                    }
                } else {
                    Text(DialFormatter.format(dialedNumber))
                        .ariaFont(.display)
                        .monospacedDigit()
                        .foregroundStyle(AriaColor.onSurface)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = dialedNumber
                            }
                        }
                        .accessibilityLabel(Text("Number"))
                        .accessibilityValue(Text(dialedNumber.map(String.init).joined(separator: " ")))
                        .accessibilityIdentifier("dialer.number")
                }
            }
            .frame(minHeight: AriaTextStyle.display.lineHeight)

            // Reserve the line so the keypad does not jump when a match appears.
            Text(matchedName ?? " ")
                .ariaFont(.bodySmall)
                .foregroundStyle(AriaColor.primary)
                .lineLimit(1)
                .opacity(matchedName == nil ? 0 : 1)
                .accessibilityHidden(matchedName == nil)
        }
        .animation(Motion.snappy(reduceMotion: reduceMotion), value: dialedNumber)
    }

    private var matchedName: String? { matcher.name(for: dialedNumber) }

    // MARK: - Keys

    private func keypad(_ metrics: DialPadMetrics) -> some View {
        Grid(horizontalSpacing: metrics.gapH, verticalSpacing: metrics.gapV) {
            ForEach(DialPadKey.rows, id: \.self) { row in
                GridRow {
                    ForEach(row) { key in
                        DialKey(key: key, action: { press(key.digit) },
                                onLongPress: key.digit == "0" ? { press("+") } : nil)
                            .accessibilityIdentifier("dialKey.\(key.digit)")
                    }
                }
            }
        }
    }

    private func bottomRow(_ metrics: DialPadMetrics) -> some View {
        Grid(horizontalSpacing: metrics.gapH) {
            GridRow {
                Color.clear
                    .frame(width: metrics.key, height: metrics.key)
                    .accessibilityHidden(true)

                CallActionButton(role: .call, accessibilityLabel: String(localized: "Call"),
                                 diameter: metrics.callButton, action: call)
                    .accessibilityIdentifier("dialer.call")
                    .accessibilityHint(dialedNumber.isEmpty ? Text("Shows the last number you called") : Text(""))
                    .frame(width: metrics.key)

                ZStack {
                    if !dialedNumber.isEmpty {
                        backspace(metrics)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .frame(width: metrics.key, height: metrics.key)
            }
        }
    }

    private func backspace(_ metrics: DialPadMetrics) -> some View {
        Button {
            dialedNumber.removeLast()
            keyTaps += 1
        } label: {
            Image(systemName: "delete.backward.fill")
                .font(.title2)
                .foregroundStyle(AriaColor.onSurfaceVariant)
                .frame(width: metrics.key, height: metrics.key)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            dialedNumber = ""
        })
        .accessibilityLabel(Text("Delete"))
        .accessibilityHint(Text("Double-tap and hold to clear the number"))
        .accessibilityAction(named: Text("Clear")) { dialedNumber = "" }
    }

    // MARK: - Actions

    private func press(_ symbol: String) {
        if symbol == "+" {
            // Long-press 0: the 0 was not added (DialKey suppresses it).
            dialedNumber.append("+")
        } else {
            dialedNumber.append(symbol)
            DTMFTone.play(symbol)
        }
        keyTaps += 1
    }

    private func call() {
        guard !dialedNumber.isEmpty else {
            // As in Phone: an empty Call brings back the last number dialed.
            if let last = history.records.first(where: { $0.direction == .outbound }) {
                dialedNumber = last.remoteUri
            }
            return
        }
        switch callManager.startOutgoingCall(uri: dialedNumber) {
        case .placed:
            dialedNumber = ""
        case .emergencyHandoff:
            dialedNumber = ""
            banner = .info(String(localized: "Emergency calls are placed by your phone, not over Aria."))
        case .refused:
            banner = .error(String(localized: "Can't place another call right now."))
        }
    }
}

// MARK: - Tones

enum DTMFTone {
    private static let sounds: [String: SystemSoundID] = [
        "1": 1200, "2": 1201, "3": 1202,
        "4": 1203, "5": 1204, "6": 1205,
        "7": 1206, "8": 1207, "9": 1208,
        "*": 1210, "0": 1209, "#": 1211,
    ]

    static func play(_ digit: String) {
        if let sound = sounds[digit] { AudioServicesPlaySystemSound(sound) }
    }
}

// MARK: - Dial string

enum DialString {
    /// The dialable part of pasted text: digits, `*`, `#` and a leading `+`,
    /// with spaces, dashes, dots and brackets dropped. nil when fewer than
    /// three digits remain.
    static func pasteable(_ text: String) -> String? {
        var result = ""
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isASCII && (ch.isNumber || ch == "*" || ch == "#") {
                result.append(ch)
            } else if ch == "+" && result.isEmpty {
                result.append(ch)
            }
        }
        return result.filter(\.isNumber).count >= 3 ? result : nil
    }
}

#Preview {
    DialerView()
        .environmentObject(CallManager.shared)
        .environmentObject(SipEngineManager.shared)
}
