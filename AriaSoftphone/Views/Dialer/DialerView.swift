import SwiftUI
import AudioToolbox
import AVFoundation

/// Dial pad view for making outgoing calls.
struct DialerView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @State private var dialedNumber = FixtureMode.shows(.dialerNumber) ? "4155550142" : ""

    private let dialPad = DialPadKey.rows

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

                // Paste / Clear. PasteButton reads the pasteboard only when
                // tapped, so the dialer no longer triggers the "pasted from"
                // banner every time it is drawn.
                if dialedNumber.isEmpty {
                    PasteButton(payloadType: String.self) { strings in
                        guard let digits = DialString.pasteable(strings.first ?? "") else { return }
                        dialedNumber = digits
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .padding(.top, 4)
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
                                DialKey(key: key) {
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
