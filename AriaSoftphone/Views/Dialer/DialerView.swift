import SwiftUI

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
            VStack(spacing: 16) {
                Spacer()

                // Number display
                HStack {
                    Text(dialedNumber.isEmpty ? "Enter number" : dialedNumber)
                        .font(.system(size: 32, weight: .light, design: .monospaced))
                        .foregroundColor(dialedNumber.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    if !dialedNumber.isEmpty {
                        Button(action: { dialedNumber = String(dialedNumber.dropLast()) }) {
                            Image(systemName: "delete.backward")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(height: 50)
                .padding(.horizontal, 32)

                // Dial pad grid
                VStack(spacing: 16) {
                    ForEach(dialPad, id: \.self) { row in
                        HStack(spacing: 24) {
                            ForEach(row) { key in
                                DialPadButton(key: key) {
                                    dialedNumber.append(key.digit)
                                    // Haptic feedback
                                    let impact = UIImpactFeedbackGenerator(style: .light)
                                    impact.impactOccurred()
                                }
                            }
                        }
                    }
                }

                Spacer()
                    .frame(height: 24)

                // Call button
                Button(action: makeCall) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 72, height: 72)
                        .overlay(
                            Image(systemName: "phone.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        )
                }
                .disabled(dialedNumber.isEmpty)
                .opacity(dialedNumber.isEmpty ? 0.5 : 1.0)

                Spacer()
                    .frame(height: 32)
            }
            .navigationTitle("Dialer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Circle()
                        .fill(sipEngine.isRegistered ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                }
            }
        }
    }

    private func makeCall() {
        guard !dialedNumber.isEmpty else { return }
        callManager.startOutgoingCall(uri: dialedNumber)
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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(key.digit)
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.primary)

                if !key.letters.isEmpty {
                    Text(key.letters)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(2)
                }
            }
            .frame(width: 80, height: 80)
            .background(Color(.systemGray6))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DialerView()
        .environmentObject(CallManager.shared)
        .environmentObject(SipEngineManager.shared)
}
