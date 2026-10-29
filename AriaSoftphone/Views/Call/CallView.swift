import SwiftUI
import AudioToolbox

/// Full-screen call view shown during active calls.
struct CallView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showDTMFKeypad = false
    @State private var rxLevel: Float = 0
    @State private var txLevel: Float = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var isEncrypted = false
    @State private var showTransfer = false
    @State private var showAddCall = false
    @State private var isCompletingTransfer = false
    @State private var transferError: String?

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(.systemBlue), Color(.systemIndigo)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // The other call: held, or the one in progress while a
                // second call rings.
                ForEach(callManager.otherCalls) { other in
                    OtherCallRow(
                        call: other,
                        canSwap: canSwap(with: other),
                        onSwap: { callManager.swapCalls() }
                    )
                }

                Spacer()

                // Caller info
                VStack(spacing: 12) {
                    // Avatar circle with pulse for ringing
                    ZStack {
                        if isRinging {
                            Circle()
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 120, height: 120)
                                .scaleEffect(pulseScale)
                        }
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 100, height: 100)
                            .overlay(
                                Text(initials)
                                    .font(.system(size: 36, weight: .semibold))
                                    .foregroundColor(.white)
                            )
                    }

                    Text(callManager.activeCall?.displayName ?? "Unknown")
                        .font(.title)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    HStack(spacing: 6) {
                        if isActive && isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .accessibilityLabel("Encrypted call")
                        }
                        Text(statusText)
                            .font(.subheadline)
                    }
                    .foregroundColor(.white.opacity(0.8))
                }

                // Audio level meters
                if isActive {
                    HStack(spacing: 20) {
                        AudioLevelMeter(label: "RX", level: rxLevel, color: .green)
                        AudioLevelMeter(label: "TX", level: txLevel, color: .indigo)
                    }
                    .padding(.horizontal, 40)
                }

                Spacer()

                // DTMF overlay
                if showDTMFKeypad {
                    DTMFKeypad { digit in
                        callManager.sendDTMF(digit)
                        playDTMFTone(digit: digit)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Mid-call controls
                if isActive {
                    HStack(spacing: 40) {
                        CallControlButton(
                            icon: callManager.activeCall?.isMuted == true ? "mic.slash.fill" : "mic.fill",
                            label: "Mute",
                            isActive: callManager.activeCall?.isMuted == true
                        ) {
                            callManager.setMuted(!(callManager.activeCall?.isMuted ?? false))
                        }

                        CallControlButton(
                            icon: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                            label: "Speaker",
                            isActive: callManager.isSpeakerOn
                        ) {
                            callManager.setSpeaker(!callManager.isSpeakerOn)
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
                            isActive: showDTMFKeypad
                        ) {
                            withAnimation(.spring(response: 0.3)) {
                                showDTMFKeypad.toggle()
                            }
                        }

                        if callManager.canAddCall {
                            CallControlButton(
                                icon: "plus",
                                label: "Add Call",
                                isActive: false
                            ) {
                                showAddCall = true
                            }
                        }

                        // The PBX only acts on a REFER from the side that
                        // answered, so a call this phone placed cannot be
                        // transferred.
                        if callManager.activeCall?.direction == .inbound {
                            CallControlButton(
                                icon: "arrow.turn.up.right",
                                label: "Transfer",
                                isActive: false
                            ) {
                                showTransfer = true
                            }
                            .disabled(callManager.activeCall?.callId == nil)
                        }
                    }

                    if let pair = callManager.attendedTransferPair {
                        completeTransferButton(pair)
                    }
                }

                Spacer()

                // End call / Accept-Reject buttons
                if callManager.activeCall?.state == .incoming, !callManager.otherCalls.isEmpty {
                    // Call waiting: say what happens to the call in progress.
                    HStack(spacing: 28) {
                        AnswerChoiceButton(icon: "phone.down.fill", label: "Decline", color: .red) {
                            callManager.endCall()
                        }
                        AnswerChoiceButton(icon: "phone.fill", label: "Hold & Accept", color: .green) {
                            callManager.answerCall(.holdOthers)
                        }
                        AnswerChoiceButton(icon: "phone.arrow.down.left.fill", label: "End & Accept", color: .orange) {
                            callManager.answerCall(.endOthers)
                        }
                    }
                } else if callManager.activeCall?.state == .incoming {
                    HStack(spacing: 60) {
                        Button(action: { callManager.endCall() }) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 72, height: 72)
                                .overlay(
                                    Image(systemName: "phone.down.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                )
                        }

                        Button(action: { callManager.answerCall() }) {
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
                    Button(action: { callManager.endCall() }) {
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

                Spacer().frame(height: 40)
            }
            .padding()
        }
        .sheet(isPresented: $showTransfer) {
            if let call = callManager.activeCall {
                TransferView(callUUID: call.uuid, callerName: call.displayName)
                    .environmentObject(callManager)
            }
        }
        .sheet(isPresented: $showAddCall) {
            AddCallView()
                .environmentObject(callManager)
        }
        .alert(
            "Transfer Failed",
            isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            ),
            presenting: transferError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onAppear { startTimers() }
        .onDisappear { stopTimers() }
    }

    // MARK: - Call waiting

    /// Swap is offered between two connected calls, from the call on screen.
    private func canSwap(with other: ActiveCall) -> Bool {
        guard let current = callManager.activeCall else { return false }
        return current.isConnected && other.isConnected && other.isOnHold
    }

    /// Join the caller to the consulted party and drop out of both calls.
    private func completeTransferButton(_ pair: (transferred: ActiveCall, consult: ActiveCall)) -> some View {
        Button {
            isCompletingTransfer = true
            callManager.completeAttendedTransfer { error in
                isCompletingTransfer = false
                transferError = error?.localizedDescription
            }
        } label: {
            HStack(spacing: 8) {
                if isCompletingTransfer {
                    ProgressView().tint(.indigo)
                } else {
                    Image(systemName: "arrow.triangle.merge")
                }
                Text(isCompletingTransfer ? "Transferring..." : "Complete Transfer")
                    .fontWeight(.semibold)
            }
            .foregroundColor(.indigo)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.white))
        }
        .disabled(isCompletingTransfer)
        .accessibilityHint("Connects \(pair.transferred.displayName) to \(pair.consult.displayName) and ends both of your calls.")
    }

    // MARK: - State

    private var isRinging: Bool {
        callManager.activeCall?.state == .incoming ||
        callManager.activeCall?.state == .connecting
    }

    private var isActive: Bool {
        callManager.activeCall?.state == .connected ||
        callManager.activeCall?.state == .onHold
    }

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
        case .incoming: return "Incoming call..."
        case .connecting: return "Connecting..."
        case .connected: return formatDuration(elapsedTime)
        case .onHold: return "On Hold"
        case .ended: return "Call Ended"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Timers

    private func startTimers() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            elapsedTime = callManager.activeCall?.duration ?? 0

            // Poll audio levels
            if let callId = callManager.activeCall?.callId {
                rxLevel = sipEngine.getRxAudioLevel(callId: callId)
                txLevel = sipEngine.getTxAudioLevel(callId: callId)
                // What SRTP negotiation produced, not what was configured.
                isEncrypted = sipEngine.callIsEncrypted(callId: callId)
            } else {
                isEncrypted = false
            }
        }

        // Pulse animation for ringing
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulseScale = 1.15
        }
    }

    private func stopTimers() {
        timer?.invalidate()
        timer = nil
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

// MARK: - Other Call Row

/// The call that is not on screen, with Swap when both are connected.
struct OtherCallRow: View {
    let call: ActiveCall
    let canSwap: Bool
    let onSwap: () -> Void

    private var status: String {
        switch call.state {
        case .incoming: return "Incoming call"
        case .connecting: return call.direction == .outbound ? "Calling..." : "Connecting..."
        case .onHold: return "On hold"
        case .connected: return call.isOnHold ? "On hold" : "Active"
        case .ended: return "Call ended"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: call.isOnHold ? "pause.circle.fill" : "phone.circle.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(status)
                    .font(.caption)
                    .opacity(0.8)
            }
            Spacer()
            if canSwap {
                Button(action: onSwap) {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.25)))
                }
            }
        }
        .foregroundColor(.white)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Answer Choice Button

/// One of the answer buttons shown when a second call rings.
struct AnswerChoiceButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(.white)
                    )
                Text(label)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }
        }
    }
}

// MARK: - Audio Level Meter

struct AudioLevelMeter: View {
    let label: String
    let level: Float
    let color: Color

    private var normalizedLevel: CGFloat {
        // Level ranges 0..~8000+, normalize to 0..1
        min(CGFloat(level) / 5000.0, 1.0)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * normalizedLevel, height: 6)
                        .animation(.linear(duration: 0.15), value: normalizedLevel)
                }
            }
            .frame(height: 6)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
    }
}

// MARK: - DTMF Keypad

struct DTMFKeypad: View {
    let onDigit: (String) -> Void

    private let keys = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"],
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.self) { digit in
                        Button {
                            onDigit(digit)
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                        } label: {
                            Text(digit)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(Circle().fill(Color.white.opacity(0.2)))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
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
