import SwiftUI

/// The full-screen call (DESIGN.md §5 Call screen): a drifting mesh, the
/// SRTP lock and call quality at the top, the caller in the middle, the
/// other call as a glass card, a 3×2 grid of glass controls, and Hang-up.
/// Incoming calls show Decline and Answer, which morph into the in-call
/// controls when answered.
struct CallView: View {
    @EnvironmentObject var callManager: CallManager
    @EnvironmentObject var sipEngine: SipEngineManager

    @Namespace private var glass
    @AccessibilityFocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showKeypad = false
    /// The call the transfer sheet is for, fixed when Transfer is tapped so
    /// the sheet never moves to a call that takes the screen meanwhile.
    @State private var transferCall: ActiveCall?
    @State private var showAddCall = false
    @State private var isCompletingTransfer = false
    @State private var transferError: String?
    @State private var link = CallLinkStatus()
    /// The call Record was tapped for while the disclosure was unaccepted.
    @State private var disclosureFor: UUID?
    @State private var banner: BannerMessage?

    var body: some View {
        // The call these controls were drawn for. Buttons act on it, not on
        // whatever call is on screen when the tap lands.
        let shown = callManager.activeCall
        let screen = ZStack {
            CallBackground()
            // One container, so Answer can morph into the controls. The
            // bottom actions sit outside the scroll view: at the largest
            // text sizes the rest scrolls, but Hang-up never does.
            GlassEffectContainer(spacing: Space.l) {
                VStack(spacing: 0) {
                    ViewThatFits(in: .vertical) {
                        content(shown)
                        ScrollView { content(shown) }
                            .scrollBounceBehavior(.basedOnSize)
                            .scrollIndicators(.hidden)
                    }
                    bottomActions(shown)
                        .padding(.top, Space.m)
                        .padding(.bottom, Space.l)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .banner($banner)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: shown?.state)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: callManager.otherCalls.map(\.uuid))
        return withAnnouncements(withAlerts(withSheets(screen, shown: shown)), shown: shown)
    }

    private func withSheets(_ view: some View, shown: ActiveCall?) -> some View {
        view
            .sheet(isPresented: $showKeypad) {
                CallKeypadSheet { digit in
                    if let shown { callManager.sendDTMF(uuid: shown.uuid, digit) }
                    DTMFTone.play(digit)
                }
            }
            .sheet(item: $transferCall) { call in
                TransferView(callUUID: call.uuid, callerName: call.displayName)
                    .environmentObject(callManager)
            }
            .sheet(isPresented: $showAddCall) {
                AddCallView()
                    .environmentObject(callManager)
            }
    }

    private func withAlerts(_ view: some View) -> some View {
        view
            .alert(
                "Transfer Failed",
                isPresented: Binding(get: { transferError != nil }, set: { if !$0 { transferError = nil } }),
                presenting: transferError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .alert(
                "Record this call?",
                isPresented: Binding(get: { disclosureFor != nil }, set: { if !$0 { disclosureFor = nil } })
            ) {
                Button("Cancel", role: .cancel) {}
                Button("I'll tell them — Record") {
                    RecordingsStore.shared.acceptDisclosure()
                    if let uuid = disclosureFor { startRecording(uuid) }
                }
            } message: {
                Text("In many places everyone on a call must know it is being recorded. Tell the other party before you record.")
            }
    }

    private func withAnnouncements(_ view: some View, shown: ActiveCall?) -> some View {
        view
            .task(id: shown?.callId) {
                while !Task.isCancelled {
                    link = CallLinkStatus.current(callId: shown?.callId, engine: sipEngine)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .onAppear { nameFocused = true }
            .onChange(of: shown?.state) { _, state in announce(state) }
            .onChange(of: shown?.isRecording) { old, recording in
                guard old != nil, let recording else { return }
                AccessibilityNotification.Announcement(
                    recording ? String(localized: "Recording started") : String(localized: "Recording stopped")
                ).post()
            }
    }

    // MARK: - Layout

    private func content(_ shown: ActiveCall?) -> some View {
            VStack(spacing: 0) {
                topBar(shown)
                    .padding(.top, Space.xs)

                VStack(spacing: Space.xs) {
                    ForEach(otherCallsShown) { other in
                        OtherCallCard(
                            call: other,
                            canSwap: canSwap(with: other),
                            canMerge: callManager.canMergeCalls,
                            onSwap: { if let shown { callManager.swapCalls(active: shown.uuid, held: other.uuid) } },
                            onMerge: { callManager.mergeCalls() },
                            onEnd: { callManager.endCall(uuid: other.uuid) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, Space.s)

                Spacer(minLength: Space.xl)

                callerHeader(shown)

                Spacer(minLength: Space.xl)

                if let shown, phase(of: shown) != .incoming {
                    controls(shown)
                    if let pair = callManager.attendedTransferPair, !callManager.isInConference {
                        completeTransferButton(pair)
                            .padding(.top, Space.m)
                    }
                    Spacer(minLength: Space.m)
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .frame(maxWidth: .infinity)
    }

    // MARK: Top bar

    private func topBar(_ shown: ActiveCall?) -> some View {
        HStack(spacing: Space.xs) {
            if shown?.isConnected == true, link.isEncrypted || link.quality != nil {
                linkChip
            }
            Spacer(minLength: 0)
            if let shown, shown.isConnected {
                moreMenu(shown)
            }
        }
        .frame(minHeight: ComponentSize.iconButton)
    }

    /// One glass capsule: the SRTP lock and the call quality.
    private var linkChip: some View {
        HStack(spacing: Space.s) {
            if link.isEncrypted {
                Label("Encrypted", systemImage: "lock.fill")
            }
            if link.isEncrypted, link.quality != nil {
                Rectangle()
                    .fill(.white.opacity(0.3))
                    .frame(width: 1, height: Space.m)
            }
            if let quality = link.quality {
                Label {
                    Text(quality.label)
                } icon: {
                    Image(systemName: "cellularbars", variableValue: quality.barValue)
                }
            }
        }
        .labelStyle(CompactLabelStyle())
        .ariaFont(.label)
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(.white)
        .padding(.horizontal, Space.s)
        .frame(minHeight: ComponentSize.iconButton - Space.xs)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(linkAccessibilityText))
    }

    private var linkAccessibilityText: String {
        var parts: [String] = []
        if link.isEncrypted { parts.append(String(localized: "Encrypted call")) }
        if let quality = link.quality { parts.append(String(localized: "Call quality, \(quality.label)")) }
        return parts.joined(separator: ", ")
    }

    /// The overflow: Record and Merge/Split.
    private func moreMenu(_ shown: ActiveCall) -> some View {
        Menu {
            if shown.isRecording {
                Button("Stop Recording", systemImage: "stop.circle") {
                    callManager.stopRecording(uuid: shown.uuid)
                }
            } else {
                Button("Record", systemImage: "record.circle") { startRecording(shown.uuid) }
            }
            if callManager.isInConference {
                Button("Split Calls", systemImage: "arrow.triangle.branch") { callManager.splitConference() }
            } else if callManager.canMergeCalls {
                Button("Merge Calls", systemImage: "arrow.triangle.merge") { callManager.mergeCalls() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white)
                .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel(Text("More call actions"))
    }

    // MARK: Caller

    private func callerHeader(_ shown: ActiveCall?) -> some View {
        VStack(spacing: Space.s) {
            Avatar(name: headerName(shown), size: ComponentSize.avatarCall, onGlass: true)
                .glassEffectID("avatar", in: glass)
                .padding(.bottom, Space.xxs)

            Text(headerName(shown))
                .ariaFont(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($nameFocused)

            if let subtitle = headerSubtitle(shown) {
                Text(subtitle)
                    .ariaFont(.bodySmall)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            statusLine(shown)
                .padding(.top, Space.xxs)

            if shown?.isRecording == true {
                RecordingBadge()
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ shown: ActiveCall?) -> some View {
        if let shown {
            switch phase(of: shown) {
            case .active:
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(CallClock.format(shown.duration))
                        .ariaFont(.display)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityLabel(Text("Call time"))
                        .accessibilityValue(Text(Duration.seconds(Int(shown.duration))
                            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))))
                }
            case .held:
                statusText(String(localized: "On hold"), systemImage: "pause.fill")
            case .incoming:
                statusText(String(localized: "Incoming call"), systemImage: "antenna.radiowaves.left.and.right",
                           ringing: true)
            case .connecting:
                statusText(shown.direction == .outbound ? String(localized: "Calling…") : String(localized: "Connecting…"),
                           systemImage: "antenna.radiowaves.left.and.right", ringing: true)
            }
        }
    }

    private func statusText(_ text: String, systemImage: String, ringing: Bool = false) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: systemImage)
                .symbolEffect(.variableColor.iterative, isActive: ringing && !reduceMotion)
                .accessibilityHidden(true)
            Text(text)
        }
        .font(AriaTextStyle.title.font)
        .foregroundStyle(.white.opacity(0.85))
        .frame(minHeight: AriaTextStyle.display.lineHeight)
    }

    private func headerName(_ shown: ActiveCall?) -> String {
        if callManager.isInConference { return String(localized: "Conference") }
        return shown?.displayName ?? ""
    }

    private func headerSubtitle(_ shown: ActiveCall?) -> String? {
        if callManager.isInConference {
            return callManager.registry.conference.map(\.displayName).formatted(.list(type: .and))
        }
        guard let shown, let name = shown.remoteName, !name.isEmpty, name != shown.remoteUri else { return nil }
        return DialFormatter.format(shown.remoteUri)
    }

    // MARK: Controls

    private var controlColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 2 : 3
        return Array(repeating: GridItem(.fixed(ComponentSize.callControlCell), spacing: Space.l), count: count)
    }

    private func controls(_ shown: ActiveCall) -> some View {
        let connected = shown.isConnected
        return LazyVGrid(columns: controlColumns, spacing: Space.l) {
            CallControlButton(icon: shown.isMuted ? "mic.slash.fill" : "mic.fill",
                              label: String(localized: "Mute"), isActive: shown.isMuted,
                              glassID: "answer", namespace: glass) {
                callManager.setMuted(uuid: shown.uuid, !shown.isMuted)
            }
            CallControlButton(icon: "circle.grid.3x3.fill", label: String(localized: "Keypad"),
                              isActive: showKeypad, isToggle: false, glassID: "keypad", namespace: glass) {
                showKeypad = true
            }
            CallControlButton(icon: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                              label: String(localized: "Speaker"), isActive: callManager.isSpeakerOn,
                              glassID: "speaker", namespace: glass) {
                callManager.setSpeaker(!callManager.isSpeakerOn)
            }
            CallControlButton(icon: "pause.fill", label: String(localized: "Hold"), isActive: shown.isOnHold,
                              glassID: "hold", namespace: glass) {
                callManager.setHeld(uuid: shown.uuid, !shown.isOnHold)
            }
            .disabled(!connected)
            CallControlButton(icon: "plus", label: String(localized: "Add call"), isToggle: false,
                              glassID: "add", namespace: glass) {
                showAddCall = true
            }
            .disabled(!connected || !callManager.canAddCall)
            CallControlButton(icon: "phone.arrow.right", label: String(localized: "Transfer"), isToggle: false,
                              glassID: "transfer", namespace: glass) {
                transferCall = shown
            }
            .disabled(shown.callId == nil)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    /// Join the transferred call's party to the consulted party and drop out
    /// of both calls.
    private func completeTransferButton(_ pair: (transferred: ActiveCall, consult: ActiveCall)) -> some View {
        AriaButton(isCompletingTransfer ? "Transferring…" : "Complete Transfer",
                   systemImage: "phone.arrow.right", kind: .standard, isLoading: isCompletingTransfer) {
            isCompletingTransfer = true
            callManager.completeAttendedTransfer(
                transferred: pair.transferred.uuid,
                consult: pair.consult.uuid
            ) { error in
                isCompletingTransfer = false
                transferError = error?.localizedDescription
            }
        }
        .foregroundStyle(.white)
        .accessibilityHint(Text("Connects \(pair.transferred.displayName) to \(pair.consult.displayName) and ends both of your calls."))
    }

    // MARK: Bottom

    @ViewBuilder
    private func bottomActions(_ shown: ActiveCall?) -> some View {
        if let shown, phase(of: shown) == .incoming {
            if callManager.otherCalls.isEmpty {
                HStack(spacing: Space.xxxl + Space.xl) {
                    CallActionButton(role: .hangUp, accessibilityLabel: String(localized: "Decline"),
                                     caption: String(localized: "Decline"), glassID: "hangup", namespace: glass) {
                        callManager.endCall(uuid: shown.uuid)
                    }
                    CallActionButton(role: .answer, accessibilityLabel: String(localized: "Answer"),
                                     caption: String(localized: "Answer"), glassID: "answer", namespace: glass) {
                        callManager.answerCall(uuid: shown.uuid)
                    }
                }
            } else {
                // Call waiting: say what happens to the call in progress.
                HStack(alignment: .top, spacing: Space.s) {
                    CallActionButton(role: .hangUp, accessibilityLabel: String(localized: "Decline"),
                                     caption: String(localized: "Decline"), glassID: "hangup", namespace: glass) {
                        callManager.endCall(uuid: shown.uuid)
                    }
                    CallActionButton(role: .hangUp, accessibilityLabel: String(localized: "End and answer"),
                                     caption: String(localized: "End & Answer"), icon: "phone.arrow.down.left.fill") {
                        callManager.answerCall(uuid: shown.uuid, .endOthers)
                    }
                    CallActionButton(role: .answer, accessibilityLabel: String(localized: "Hold and answer"),
                                     caption: String(localized: "Hold & Answer"), glassID: "answer", namespace: glass) {
                        callManager.answerCall(uuid: shown.uuid, .holdOthers)
                    }
                }
            }
        } else {
            CallActionButton(role: .hangUp, accessibilityLabel: String(localized: "End call"),
                             glassID: "hangup", namespace: glass) {
                if let shown { callManager.endCall(uuid: shown.uuid) }
            }
        }
    }

    // MARK: - State

    enum Phase: Equatable { case incoming, connecting, active, held }

    private func phase(of call: ActiveCall) -> Phase {
        switch call.state {
        case .incoming: return .incoming
        case .connecting, .ended: return .connecting
        case .connected: return call.isOnHold ? .held : .active
        case .onHold: return .held
        }
    }

    /// The other calls, unless they are in the conference the header shows.
    private var otherCallsShown: [ActiveCall] {
        callManager.isInConference ? callManager.otherCalls.filter { !$0.inConference } : callManager.otherCalls
    }

    /// Swap is offered from the talking call on screen to a held one.
    private func canSwap(with other: ActiveCall) -> Bool {
        guard let current = callManager.activeCall else { return false }
        return callManager.registry.canSwap(active: current.uuid, held: other.uuid)
    }

    private func startRecording(_ uuid: UUID) {
        do {
            try callManager.startRecording(uuid: uuid)
        } catch RecordingError.disclosureRequired {
            disclosureFor = uuid
        } catch {
            banner = .error(error.localizedDescription)
        }
    }

    private func announce(_ state: ActiveCall.ActiveCallState?) {
        let text: String
        switch state {
        case .connected: text = String(localized: "Call connected")
        case .onHold: text = String(localized: "Call on hold")
        case .ended: text = String(localized: "Call ended")
        default: return
        }
        AccessibilityNotification.Announcement(text).post()
    }
}
