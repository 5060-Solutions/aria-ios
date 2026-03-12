import SwiftUI

/// Full-screen call view shown during active calls.
struct CallView: View {
    @EnvironmentObject var callManager: CallManager
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(.systemBlue), Color(.systemIndigo)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Caller info
                VStack(spacing: 12) {
                    // Avatar circle
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 100, height: 100)
                        .overlay(
                            Text(initials)
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundColor(.white)
                        )

                    Text(callManager.activeCall?.displayName ?? "Unknown")
                        .font(.title)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }

                Spacer()

                // Mid-call controls
                if callManager.activeCall?.state == .connected ||
                   callManager.activeCall?.state == .onHold {
                    HStack(spacing: 40) {
                        CallControlButton(
                            icon: callManager.activeCall?.isMuted == true ? "mic.slash.fill" : "mic.fill",
                            label: "Mute",
                            isActive: callManager.activeCall?.isMuted == true
                        ) {
                            callManager.setMuted(!(callManager.activeCall?.isMuted ?? false))
                        }

                        CallControlButton(
                            icon: "speaker.wave.2.fill",
                            label: "Speaker",
                            isActive: false
                        ) {
                            // Toggle speaker
                        }

                        CallControlButton(
                            icon: callManager.activeCall?.isOnHold == true ? "play.fill" : "pause.fill",
                            label: callManager.activeCall?.isOnHold == true ? "Resume" : "Hold",
                            isActive: callManager.activeCall?.isOnHold == true
                        ) {
                            callManager.setHeld(!(callManager.activeCall?.isOnHold ?? false))
                        }
                    }

                    HStack(spacing: 40) {
                        CallControlButton(
                            icon: "circle.grid.3x3.fill",
                            label: "Keypad",
                            isActive: false
                        ) {
                            // Show DTMF keypad
                        }
                    }
                }

                Spacer()

                // End call / Accept-Reject buttons
                if callManager.activeCall?.state == .incoming {
                    HStack(spacing: 60) {
                        // Reject
                        Button(action: {
                            callManager.endCall()
                        }) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 72, height: 72)
                                .overlay(
                                    Image(systemName: "phone.down.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                )
                        }

                        // Accept
                        Button(action: {
                            // CallKit handles accept via CXAnswerCallAction
                        }) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 72, height: 72)
                                .overlay(
                                    Image(systemName: "phone.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                )
                        }
                    }
                } else {
                    // End call button
                    Button(action: {
                        callManager.endCall()
                    }) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Image(systemName: "phone.down.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            )
                    }
                }

                Spacer()
                    .frame(height: 40)
            }
            .padding()
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    // MARK: - Helpers

    private var initials: String {
        let name = callManager.activeCall?.displayName ?? "?"
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var statusText: String {
        guard let call = callManager.activeCall else { return "" }
        switch call.state {
        case .incoming:
            return "Incoming call..."
        case .connecting:
            return "Connecting..."
        case .connected:
            return formatDuration(elapsedTime)
        case .onHold:
            return "On Hold"
        case .ended:
            return "Call Ended"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsedTime = callManager.activeCall?.duration ?? 0
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Call Control Button

struct CallControlButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .fill(isActive ? Color.white : Color.white.opacity(0.2))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundColor(isActive ? .blue : .white)
                    )

                Text(label)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
}
