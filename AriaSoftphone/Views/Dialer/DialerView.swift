import SwiftUI
import AudioToolbox
import AVFoundation

/// Dial pad view for making outgoing calls.
struct DialerView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @State private var dialedNumber = ""

    private let dialPad: [[DialKey]] = [
        [.init("1", ""), .init("2", "ABC"), .init("3", "DEF")],
        [.init("4", "GHI"), .init("5", "JKL"), .init("6", "MNO")],
        [.init("7", "PQRS"), .init("8", "TUV"), .init("9", "WXYZ")],
        [.init("*", ""), .init("0", "+"), .init("#", "")],
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header: identity + status
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let displayName = UserDefaults.standard.string(forKey: "sipDisplayName"),
                           !displayName.isEmpty {
                            Text(displayName)
                                .font(.subheadline.weight(.semibold))
                        }
                        if let ext = UserDefaults.standard.string(forKey: "sipUsername"),
                           !ext.isEmpty {
                            let domain = UserDefaults.standard.string(forKey: "sipDomain") ?? ""
                            Text("Ext \(ext)" + (domain.isEmpty ? "" : " · \(domain)"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    // Status chip
                    HStack(spacing: 5) {
                        Circle()
                            .fill(sipEngine.isRegistered ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(sipEngine.isRegistered ? "Online" : "Offline")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(sipEngine.isRegistered ? .green : .red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (sipEngine.isRegistered ? Color.green : Color.red)
                            .opacity(0.14)
                    )
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer(minLength: 0)

                // Number display
                HStack {
                    Text(dialedNumber.isEmpty ? "Enter number" : dialedNumber)
                        .font(.system(size: dialedNumber.count > 12 ? 24 : 32, weight: dialedNumber.isEmpty ? .regular : .medium))
                        .foregroundColor(dialedNumber.isEmpty ? .secondary.opacity(0.5) : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                        .tracking(2)

                    if !dialedNumber.isEmpty {
                        Button(action: {
                            dialedNumber = String(dialedNumber.dropLast())
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                        }) {
                            Image(systemName: "delete.backward")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(.systemGray6).opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                // Paste / Clear
                if dialedNumber.isEmpty {
                    if let clipDigits = pasteableClipboardDigits, clipDigits.count >= 3 {
                        Button {
                            dialedNumber = clipDigits
                        } label: {
                            Text("Paste \(String(clipDigits.prefix(12)))\(clipDigits.count > 12 ? "..." : "")")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.accentColor)
                        }
                        .padding(.top, 4)
                    } else {
                        Spacer().frame(height: 12)
                    }
                } else {
                    Button {
                        dialedNumber = ""
                    } label: {
                        Text("Clear")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }

                Spacer().frame(height: 12)

                // Dial pad grid
                VStack(spacing: 10) {
                    ForEach(dialPad, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(row) { key in
                                DialPadButton(key: key) {
                                    dialedNumber.append(key.digit)
                                    playDTMFTone(digit: key.digit)
                                    let impact = UIImpactFeedbackGenerator(style: .light)
                                    impact.impactOccurred()
                                } onLongPress: {
                                    if key.digit == "0" {
                                        dialedNumber.append("+")
                                        let impact = UIImpactFeedbackGenerator(style: .medium)
                                        impact.impactOccurred()
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)

                Spacer().frame(height: 16)

                // Call button with glow
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 74, height: 74)
                    Button(action: makeCall) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 66, height: 66)
                            .shadow(color: .green.opacity(0.3), radius: 6, y: 3)
                            .overlay(
                                Image(systemName: "phone.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            )
                    }
                    .disabled(dialedNumber.isEmpty)
                    .opacity(dialedNumber.isEmpty ? 0.5 : 1.0)
                }

                Spacer(minLength: 8)
            }
        }
    }

    private var pasteableClipboardDigits: String? {
        guard let text = UIPasteboard.general.string else { return nil }
        let digits = text.filter { $0.isNumber || $0 == "+" }
        return digits.count >= 3 ? digits : nil
    }

    private func makeCall() {
        guard !dialedNumber.isEmpty else { return }
        callManager.startOutgoingCall(uri: dialedNumber)
    }

    private func playDTMFTone(digit: String) {
        let toneMap: [String: SystemSoundID] = [
            "1": 1200, "2": 1201, "3": 1202,
            "4": 1203, "5": 1204, "6": 1205,
            "7": 1206, "8": 1207, "9": 1208,
            "*": 1210, "0": 1209, "#": 1211,
        ]
        if let soundID = toneMap[digit] {
            AudioServicesPlaySystemSound(soundID)
        }
    }
}

// MARK: - Dial Pad Button

struct DialKey: Identifiable, Hashable {
    let id = UUID()
    let digit: String
    let letters: String

    init(_ digit: String, _ letters: String) {
        self.digit = digit
        self.letters = letters
    }
}

struct DialPadButton: View {
    let key: DialKey
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 2) {
            Text(key.digit)
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(.primary)

            if !key.letters.isEmpty {
                Text(key.letters)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentColor.opacity(0.8))
                    .tracking(2)
            }
        }
        .frame(width: 76, height: 76)
        .background(
            Circle()
                .fill(Color(.systemGray5).opacity(isPressed ? 0.9 : 0.65))
        )
        .overlay(
            Circle()
                .stroke(isPressed ? Color.accentColor.opacity(0.5) : Color(.systemGray4).opacity(0.35), lineWidth: isPressed ? 1.5 : 1)
        )
        .clipShape(Circle())
        .scaleEffect(isPressed ? 0.92 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.4), value: isPressed)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    onLongPress?()
                    isPressed = false
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        action()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                }
        )
    }
}

#Preview {
    DialerView()
        .environmentObject(CallManager.shared)
        .environmentObject(SipEngineManager.shared)
}
