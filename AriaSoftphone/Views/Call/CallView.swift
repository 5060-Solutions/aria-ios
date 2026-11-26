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
    @State private var showMoveTo = false
    /// The call the Hold for me sheet is for, fixed when it is tapped.
    @State private var holdForMeCall: ActiveCall?
    @ObservedObject private var holdForMe = HoldForMeModel.shared
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
            // The controls scroll in their own glass container; glass from
            // a container outside a scroll view is drawn unclipped, so
            // scrolled content would show over Hang-up. Hang-up and the
            // answer buttons sit below in theirs: Decline morphs into
            // Hang-up, and at the largest text sizes the rest scrolls while
            // Hang-up never does.
            VStack(spacing: 0) {
                // At least the available height, so the spacers lay it out
                // when it fits; it scrolls (with a flashed indicator) when
                // it does not.
                GeometryReader { proxy in
                    ScrollView {
                        GlassEffectContainer(spacing: Space.l) {
                            content(shown, size: proxy.size)
                                .frame(minHeight: proxy.size.height)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicatorsFlash(onAppear: true)
                    .clipped()
                }
                GlassEffectContainer(spacing: Space.l) {
                    bottomActions(shown)
                        .padding(.top, Space.m)
                        .padding(.bottom, Space.l)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .banner($banner)
        // A refused Hold for me leaves the call as it was; say why.
        .onChange(of: holdForMe.banner) { _, refusal in
            guard let refusal else { return }
            banner = .error(String(localized: refusal.message))
            holdForMe.banner = nil
        }
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
            .sheet(isPresented: $showMoveTo) {
                MoveToView()
            }
            .sheet(item: $holdForMeCall) { call in
                HoldForMeSheet(call: call)
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
                    refreshLink(shown)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .task(id: shown?.uuid) { announceBack(shown) }
            .onAppear { nameFocused = true }
            .onChange(of: shown?.state) { _, state in
                announce(state)
                refreshLink(shown)
            }
            // Every call-state event carries the call's encryption; a change
            // mid-call arrives with the state unchanged.
            .onChange(of: shown?.isEncrypted) { refreshLink(shown) }
            .onChange(of: shown?.isRecording) { old, recording in
                guard old != nil, let recording else { return }
                AccessibilityNotification.Announcement(
                    recording ? String(localized: "Recording started") : String(localized: "Recording stopped")
                ).post()
            }
    }

    /// Re-read the call's encryption and quality, and give the one-time
    /// notice if the call is (or has just become) unencrypted.
    private func refreshLink(_ shown: ActiveCall?) {
        link = CallLinkStatus.current(call: shown, engine: sipEngine)
        let notices = CallEncryptionNotices.shared
        notices.retain(only: Set(callManager.registry.calls.map(\.uuid)))
        if let shown, notices.shouldNotify(call: shown.uuid, encryption: link.encryption) {
            showUnencryptedExplanation()
        }
    }

    /// The banner (announced as it appears) explaining an unencrypted call:
    /// the one-time notice, and again when the capsule is tapped.
    private func showUnencryptedExplanation() {
        banner = .warning(CallEncryption.unencryptedExplanation)
    }

    // MARK: - Layout

    /// A wide, short window (an iPad on its side, or a wide Split View)
    /// puts the caller beside the controls instead of above them.
    static func isSideBySide(_ size: CGSize) -> Bool {
        size.width >= 640 && size.width > size.height * 1.1
    }

    /// The widest the call's column grows on a big screen: the controls
    /// keep their size and are not spread across an iPad.
    private static let columnMaxWidth: CGFloat = 520

    private func content(_ shown: ActiveCall?, size: CGSize) -> some View {
        let sideBySide = Self.isSideBySide(size)
        let showsControls = shown.map { phase(of: $0) != .incoming } ?? false
        return VStack(spacing: 0) {
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

                if sideBySide {
                    HStack(alignment: .center, spacing: Space.xxxl) {
                        callerHeader(shown)
                            .frame(maxWidth: .infinity)
                        if let shown, showsControls {
                            VStack(spacing: 0) {
                                controlsAndTransfer(shown, width: Self.columnMaxWidth + 2 * Space.screenMargin)
                            }
                            .frame(maxWidth: Self.columnMaxWidth)
                        }
                    }
                    Spacer(minLength: Space.m)
                } else {
                    callerHeader(shown)

                    Spacer(minLength: Space.xl)

                    if let shown, showsControls {
                        controlsAndTransfer(shown, width: min(size.width, Self.columnMaxWidth + 2 * Space.screenMargin))
                        Spacer(minLength: Space.m)
                    }
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .frame(maxWidth: sideBySide ? 1100 : Self.columnMaxWidth + 2 * Space.screenMargin)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func controlsAndTransfer(_ shown: ActiveCall, width: CGFloat) -> some View {
        controls(shown, width: width)
        if let pair = callManager.attendedTransferPair, !callManager.isInConference {
            completeTransferButton(pair)
                .padding(.top, Space.m)
        }
    }

    // MARK: Top bar

    private func topBar(_ shown: ActiveCall?) -> some View {
        HStack(spacing: Space.xs) {
            if shown?.isConnected == true, link.encryption != .unknown || link.quality != nil {
                if link.encryption == .unencrypted {
                    Button(action: showUnencryptedExplanation) {
                        // A 44 pt target around the slimmer capsule.
                        linkChip
                            .frame(minHeight: ComponentSize.iconButton)
                            .contentShape(.rect)
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(linkAccessibilityText))
                        .accessibilityHint(Text("Explains why this call isn't encrypted"))
                        .accessibilityIdentifier("call.notEncrypted")
                } else {
                    linkChip
                        .accessibilityIdentifier(link.encryption == .encrypted ? "call.encrypted" : "call.link")
                }
            }
            Spacer(minLength: 0)
            if let shown, shown.isConnected {
                moreMenu(shown)
            }
        }
        .frame(minHeight: ComponentSize.iconButton)
    }

    /// The top row's glass, tinted with the mesh's primary so the chip and
    /// the overflow match wherever the gradient has drifted.
    static let topBarGlass = Glass.regular.tint(AriaColor.callMesh[1].opacity(0.55))

    /// One glass capsule: the SRTP lock and the call quality. A call that is
    /// not encrypted gets a solid amber capsule with an open lock instead,
    /// never the look of an encrypted one, for as long as it lasts.
    private var linkChip: some View {
        let unencrypted = link.encryption == .unencrypted
        return HStack(spacing: Space.s) {
            switch link.encryption {
            case .encrypted:
                Label("Encrypted", systemImage: "lock.fill")
            case .unencrypted:
                Label {
                    Text("Not encrypted")
                } icon: {
                    Image(systemName: "lock.open.fill")
                        .foregroundStyle(AriaColor.warning)
                }
            case .unknown:
                EmptyView()
            }
            if link.encryption != .unknown, link.quality != nil {
                Rectangle()
                    .fill(unencrypted ? AriaColor.onWarningContainer.opacity(0.4) : .white.opacity(0.3))
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
        .foregroundStyle(unencrypted ? AriaColor.onWarningContainer : .white)
        .padding(.horizontal, Space.s)
        .frame(minHeight: ComponentSize.iconButton - Space.xs)
        .background {
            // Solid, not glass: the label keeps its contrast wherever the
            // gradient behind it has drifted.
            if unencrypted {
                Capsule().fill(AriaColor.warningContainer)
            }
        }
        .glassEffect(unencrypted ? .identity : Self.topBarGlass, in: .capsule)
        .contentShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(linkAccessibilityText))
    }

    private var linkAccessibilityText: String {
        var parts: [String] = []
        switch link.encryption {
        case .encrypted: parts.append(String(localized: "Encrypted call"))
        case .unencrypted: parts.append(String(localized: "Call not encrypted"))
        case .unknown: break
        }
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
            Button("Move to…", systemImage: "arrow.left.arrow.right") { showMoveTo = true }
                .accessibilityIdentifier("call.moveTo")
            if holdForMe.canHoldForMe(shown) {
                Button(String(localized: "Hold for me"), systemImage: "hourglass") { holdForMeCall = shown }
                    .accessibilityIdentifier("call.holdForMe")
            }
            if callManager.isInConference {
                Button("Split Calls", systemImage: "arrow.triangle.branch") { callManager.splitConference() }
                    .accessibilityIdentifier("call.split")
            } else if callManager.canMergeCalls {
                Button("Merge Calls", systemImage: "arrow.triangle.merge") { callManager.mergeCalls() }
                    .accessibilityIdentifier("call.merge")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white)
                .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                .glassEffect(Self.topBarGlass.interactive(), in: .circle)
        }
        .accessibilityLabel(Text("More call actions"))
        .accessibilityIdentifier("call.more")
    }

    // MARK: Caller

    private func callerHeader(_ shown: ActiveCall?) -> some View {
        VStack(spacing: Space.s) {
            // Left out at accessibility sizes, leaving room for the controls.
            if !isLargeText {
                Avatar(name: headerName(shown), size: ComponentSize.avatarCall, onGlass: true)
                    .glassEffectID("avatar", in: glass)
                    .padding(.bottom, Space.xxs)
            }

            Text(headerName(shown))
                .ariaFont(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityLabel(Text("Call time"))
                        .accessibilityValue(Text(Duration.seconds(Int(shown.duration))
                            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))))
                }
                if let began = shown.originalStartedAt {
                    Text("Started \(began.formatted(date: .omitted, time: .shortened))")
                        .ariaFont(.label)
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityIdentifier("call.movedStart")
                }
            case .held:
                statusText(String(localized: "On hold"), systemImage: "pause.fill")
            case .incoming where shown.holdReturnId != nil:
                holdReturnStatus(shown)
            case .incoming:
                statusText(String(localized: "Incoming call"), systemImage: "antenna.radiowaves.left.and.right",
                           ringing: true)
            case .connecting:
                statusText(shown.direction == .outbound ? String(localized: "Calling…") : String(localized: "Connecting…"),
                           systemImage: "antenna.radiowaves.left.and.right", ringing: true)
            }
        }
    }

    /// The far party of a Hold for me wait is back. After the maximum wait
    /// the ring says so instead, and asks what to do.
    @ViewBuilder
    private func holdReturnStatus(_ shown: ActiveCall) -> some View {
        let wait = shown.holdReturnId.flatMap { holdForMe.waits[$0] }
        if wait?.ringReason == "max_wait", let wait {
            statusText(String(localized: "Still waiting after \(wait.maxWaitSecs / 3600) hours. Rejoin or hang up?"),
                       systemImage: "hourglass", ringing: true)
        } else {
            statusText(String(localized: "They're back — \(shown.holdReturnLabelName)"),
                       systemImage: "antenna.radiowaves.left.and.right", ringing: true)
            Text("Tap to rejoin")
                .ariaFont(.label)
                .foregroundStyle(.white.opacity(0.7))
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
        .multilineTextAlignment(.center)
        // Capped so a long word ("Eingehender") never breaks mid-word.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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

    private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

    /// Three 96 pt cells; at accessibility sizes two columns that share the
    /// width, so the larger labels fit without shrinking.
    private var controlColumns: [GridItem] {
        isLargeText
            ? Array(repeating: GridItem(.flexible(), spacing: Space.m), count: 2)
            : Array(repeating: GridItem(.fixed(ComponentSize.callControlCell), spacing: Space.l), count: 3)
    }

    private var controlCellWidth: CGFloat? { isLargeText ? nil : ComponentSize.callControlCell }

    /// The control labels, for fitting the pills.
    private func controlLabels(_ shown: ActiveCall) -> [String] {
        [String(localized: "Mute"), String(localized: "Keypad"), String(localized: "Speaker"),
         String(localized: "Hold"), String(localized: "Add call"), String(localized: "Transfer")]
    }

    private func controls(_ shown: ActiveCall, width: CGFloat) -> some View {
        let connected = shown.isConnected
        let columnWidth = (width - 2 * Space.screenMargin - Space.m) / 2
        let cap = PillLabelFit.cap(labels: controlLabels(shown), columnWidth: columnWidth,
                                   current: dynamicTypeSize)
        return LazyVGrid(columns: controlColumns, spacing: isLargeText ? Space.m : Space.l) {
            CallControlButton(icon: shown.isMuted ? "mic.slash.fill" : "mic.fill",
                              label: String(localized: "Mute"), isActive: shown.isMuted,
                              glassID: "answer", namespace: glass, cellWidth: controlCellWidth, isPill: isLargeText, labelSizeCap: cap) {
                callManager.setMuted(uuid: shown.uuid, !shown.isMuted)
            }
            CallControlButton(icon: "circle.grid.3x3.fill", label: String(localized: "Keypad"),
                              isActive: showKeypad, isToggle: false, glassID: "keypad", namespace: glass, cellWidth: controlCellWidth, isPill: isLargeText, labelSizeCap: cap) {
                showKeypad = true
            }
            CallControlButton(icon: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                              label: String(localized: "Speaker"), isActive: callManager.isSpeakerOn,
                              glassID: "speaker", namespace: glass, cellWidth: controlCellWidth, isPill: isLargeText, labelSizeCap: cap) {
                callManager.setSpeaker(!callManager.isSpeakerOn)
            }
            CallControlButton(icon: "pause.fill", label: String(localized: "Hold"), isActive: shown.isOnHold,
                              glassID: "hold", namespace: glass, cellWidth: controlCellWidth, isPill: isLargeText, labelSizeCap: cap) {
                callManager.setHeld(uuid: shown.uuid, !shown.isOnHold)
            }
            .disabled(!connected)
            CallControlButton(icon: "plus", label: String(localized: "Add call"), isToggle: false,
                              glassID: "add", namespace: glass, cellWidth: controlCellWidth, isPill: isLargeText, labelSizeCap: cap) {
                showAddCall = true
            }
            .disabled(!connected || !callManager.canAddCall)
            CallControlButton(icon: "phone.arrow.right", label: String(localized: "Transfer"), isToggle: false,
                              glassID: "transfer", namespace: glass, cellWidth: controlCellWidth, isPill: isLargeText, labelSizeCap: cap) {
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
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityHint(Text("Connects \(pair.transferred.displayName) to \(pair.consult.displayName) and ends both of your calls."))
    }

    // MARK: Bottom

    private func bottomActions(_ shown: ActiveCall?) -> some View {
        VStack(spacing: Space.m) {
            if let shown { holdReturnExtras(shown) }
            answerOrHangUp(shown)
        }
    }

    /// A hold-return ring shows what the far party said and Still on hold;
    /// once answered, Still on hold stays for the PBX's ten seconds.
    @ViewBuilder
    private func holdReturnExtras(_ shown: ActiveCall) -> some View {
        if let id = shown.holdReturnId {
            if phase(of: shown) == .incoming {
                let lines = holdForMe.transcripts[id] ?? []
                if !lines.isEmpty { HoldReturnTranscript(lines: lines) }
                stillOnHoldButton(shown, waitId: id, endsCall: true)
            } else if let joinedAt = shown.joinedAt {
                // Re-drawn at the boundary, so the button goes on time.
                TimelineView(.explicit([joinedAt, joinedAt.addingTimeInterval(HoldReturnRules.stillOnHoldWindow)])) { _ in
                    if HoldReturnRules.showsStillOnHold(joinedAt: joinedAt, now: Date()) {
                        stillOnHoldButton(shown, waitId: id, endsCall: false)
                    }
                }
            }
        }
    }

    /// "Still on hold": the person is not there. Ringing, the local ring
    /// then ends too (the PBX goes back to waiting). A refusal or a second
    /// tap while one is in flight changes nothing.
    private func stillOnHoldButton(_ shown: ActiveCall, waitId: String, endsCall: Bool) -> some View {
        AriaButton("Still on hold", systemImage: "hourglass", kind: .standard) {
            Task {
                guard await holdForMe.stillOnHold(waitId) else { return }
                if endsCall { callManager.endCall(uuid: shown.uuid) }
            }
        }
        .foregroundStyle(.white)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityIdentifier("call.stillOnHold")
    }

    @ViewBuilder
    private func answerOrHangUp(_ shown: ActiveCall?) -> some View {
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

    /// A hold-return ring is announced to VoiceOver by name.
    private func announceBack(_ shown: ActiveCall?) {
        guard let shown, shown.holdReturnId != nil, phase(of: shown) == .incoming else { return }
        AccessibilityNotification.Announcement(String(localized: "They're back, \(shown.holdReturnLabelName)")).post()
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
