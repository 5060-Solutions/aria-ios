import SwiftUI
import AVFoundation

/// The signed-in extension's voicemail (DESIGN.md §5 Voicemail): unread
/// dots, caller, duration and date; a row expands into an inline player
/// with a scrubber, speed, speaker, the transcription, Call back and Delete.
struct VoicemailView: View {
    @EnvironmentObject var callManager: CallManager
    @ObservedObject private var service = VoicemailService.shared
    @ObservedObject private var directory = ContactDirectory.shared
    @StateObject private var player = VoicemailPlayer()
    @AppStorage(AccountSettings.Key.voicemailNumber) private var voicemailNumber = ""
    @State private var expanded: String?
    @State private var banner: BannerMessage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if service.messages.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(service.messages) { message in
                            row(message)
                        }
                    }
                    .ariaListStyle()
                    .animation(Motion.standard(reduceMotion: reduceMotion), value: expanded)
                }
            }
            .background(AriaColor.background)
            .navigationTitle("Voicemail")
            .toolbar {
                if !voicemailNumber.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            callManager.startOutgoingCall(uri: voicemailNumber)
                        } label: {
                            Label("Call Voicemail", systemImage: "phone.fill")
                        }
                    }
                }
            }
            .banner($banner)
            .refreshable { await service.refresh() }
            .task {
                await directory.loadIfAuthorized()
                await service.refresh()
                if FixtureMode.shows(.voicemailPlaying), let first = service.messages.first {
                    expanded = first.id
                    play(first)
                }
            }
            .onChange(of: service.errorMessage) { _, error in
                if let error { banner = .error(error) }
            }
            .onDisappear { player.stop() }
            .onChange(of: callManager.activeCall != nil) { _, inCall in
                // A call takes the audio session; do not fight it.
                if inCall { player.stop() }
            }
        }
    }

    private func row(_ message: VoicemailService.Message) -> some View {
        let caller = VoicemailCaller(message.callerId, matcher: ContactMatcher(contacts: directory.contacts, history: []))
        return VoicemailRow(
            message: message,
            caller: caller,
            isExpanded: expanded == message.id,
            player: player,
            canPlay: callManager.activeCall == nil,
            onToggle: {
                expanded = expanded == message.id ? nil : message.id
                if expanded != message.id, player.currentId == message.id { player.stop() }
            },
            onPlay: { play(message) },
            onCallBack: { callBack(caller) },
            onDelete: { delete(message) }
        )
        .ariaListRow()
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(message) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if !message.read {
                Button {
                    Task { await service.markRead(message) }
                } label: {
                    Label("Mark Read", systemImage: "envelope.open")
                }
                .tint(AriaColor.primary)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if service.hasMailbox {
            EmptyState(systemImage: "recordingtape", title: Text("No Voicemail"),
                       message: Text("Messages left for you appear here."))
        } else {
            EmptyState(systemImage: "recordingtape", title: Text("No Mailbox"),
                       message: Text("Your extension does not have a voicemail box."))
        }
    }

    private func play(_ message: VoicemailService.Message) {
        if player.currentId == message.id {
            player.togglePause()
            return
        }
        Task {
            await player.play(id: message.id) {
                try await service.audioFile(for: message)
            }
            if player.currentId == message.id, player.errorMessage == nil {
                await service.markRead(message)
            }
        }
    }

    private func delete(_ message: VoicemailService.Message) {
        if player.currentId == message.id { player.stop() }
        if expanded == message.id { expanded = nil }
        Task { await service.delete(message) }
    }

    private func callBack(_ caller: VoicemailCaller) {
        guard let number = caller.number else { return }
        player.stop()
        if callManager.startOutgoingCall(uri: number) == .refused {
            banner = .error(String(localized: "Can't place another call right now."))
        }
    }
}

// MARK: - Caller

/// The PBX's caller id, "Name <number>" or a bare number, split for display.
struct VoicemailCaller: Equatable {
    let name: String?
    let number: String?

    init(_ callerId: String, matcher: ContactMatcher? = nil) {
        let trimmed = callerId.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">") {
            let name = trimmed[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let number = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            self.name = name.isEmpty ? matcher?.name(for: number) : name
            self.number = number.isEmpty ? nil : number
        } else {
            self.number = trimmed.isEmpty ? nil : trimmed
            self.name = trimmed.isEmpty ? nil : matcher?.name(for: trimmed)
        }
    }

    var title: String {
        name ?? number.map(DialFormatter.format) ?? String(localized: "Unknown caller")
    }

    /// The number under a name; nil when the title already is the number.
    var subtitle: String? {
        guard name != nil, let number else { return nil }
        return DialFormatter.format(number)
    }
}

// MARK: - Row

private struct VoicemailRow: View {
    let message: VoicemailService.Message
    let caller: VoicemailCaller
    let isExpanded: Bool
    @ObservedObject var player: VoicemailPlayer
    let canPlay: Bool
    let onToggle: () -> Void
    let onPlay: () -> Void
    let onCallBack: () -> Void
    let onDelete: () -> Void

    private var isCurrent: Bool { player.currentId == message.id }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? Space.s : 0) {
            header
            if isExpanded {
                VoicemailPlayerControls(message: message, player: player, canPlay: canPlay, onPlay: onPlay)
                if let transcription = message.transcription, !transcription.isEmpty {
                    Text(transcription)
                        .ariaFont(.body)
                        .foregroundStyle(AriaColor.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text("Transcription: \(transcription)"))
                }
                HStack(spacing: Space.s) {
                    AriaButton("Call Back", systemImage: "phone.fill", kind: .standard, fullWidth: true,
                               action: onCallBack)
                        .disabled(caller.number == nil)
                    AriaButton("Delete", systemImage: "trash", kind: .destructive, fullWidth: true,
                               action: onDelete)
                }
                .padding(.bottom, Space.xs)
            } else if let transcription = message.transcription, !transcription.isEmpty {
                Text(transcription)
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .lineLimit(2)
                    .padding(.leading, ComponentSize.avatarList + Space.s)
                    .padding(.bottom, Space.xs)
            }
        }
    }

    private var header: some View {
        AriaListRow(
            title: Text(caller.title).fontWeight(message.read ? .regular : .semibold),
            subtitle: Text("\(message.createdAt.formatted(.relative(presentation: .named))) · \(CallClock.format(TimeInterval(message.durationSecs)))")
        ) {
            ZStack(alignment: .topLeading) {
                Avatar(name: caller.name ?? "")
                if !message.read {
                    Circle()
                        .fill(AriaColor.primary)
                        .frame(width: Space.s, height: Space.s)
                        .overlay(Circle().stroke(AriaColor.surface, lineWidth: 2))
                        .offset(x: -2, y: -2)
                        .accessibilityHidden(true)
                }
            }
        } trailing: {
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AriaColor.onSurfaceVariant)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(message.read ? "" : String(localized: "Unread")))
        .accessibilityHint(Text(isExpanded ? "Collapses the message" : "Shows the player and transcription"))
    }
}

// MARK: - Player controls

/// Play/pause, a scrubber with times, speed and speaker.
private struct VoicemailPlayerControls: View {
    let message: VoicemailService.Message
    @ObservedObject var player: VoicemailPlayer
    let canPlay: Bool
    let onPlay: () -> Void

    private var isCurrent: Bool { player.currentId == message.id }
    private var duration: TimeInterval {
        isCurrent && player.duration > 0 ? player.duration : TimeInterval(message.durationSecs)
    }
    private var position: TimeInterval { isCurrent ? player.progress : 0 }

    var body: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Button(action: onPlay) {
                    Group {
                        if isCurrent && player.isLoading {
                            ProgressView().tint(AriaColor.onPrimary)
                        } else {
                            Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.title3)
                    .foregroundStyle(AriaColor.onPrimary)
                    .frame(width: ComponentSize.iconButton + Space.xs, height: ComponentSize.iconButton + Space.xs)
                    .glassEffect(.regular.tint(AriaColor.primary).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .accessibilityLabel(Text(isCurrent && player.isPlaying ? "Pause" : "Play"))

                VStack(spacing: 2) {
                    Slider(
                        value: Binding(get: { position }, set: { player.seek(to: $0) }),
                        in: 0...max(duration, 1)
                    )
                    .tint(AriaColor.primary)
                    .disabled(!isCurrent)
                    .accessibilityLabel(Text("Position"))
                    .accessibilityValue(Text("\(CallClock.format(position)) of \(CallClock.format(duration))"))
                    HStack {
                        Text(CallClock.format(position))
                        Spacer()
                        Text("-" + CallClock.format(max(0, duration - position)))
                    }
                    .ariaFont(.label)
                    .monospacedDigit()
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .accessibilityHidden(true)
                }
            }

            HStack(spacing: Space.xs) {
                Button {
                    player.cycleRate()
                } label: {
                    Text(player.rateLabel)
                        .ariaFont(.label)
                        .monospacedDigit()
                        .frame(minWidth: Space.xxxl)
                }
                .ariaButtonStyle(.standard)
                .accessibilityLabel(Text("Playback speed"))
                .accessibilityValue(Text(player.rateLabel))

                Spacer()

                Button {
                    player.setSpeaker(!player.isSpeaker)
                } label: {
                    Label(player.isSpeaker ? "Speaker" : "iPhone",
                          systemImage: player.isSpeaker ? "speaker.wave.2.fill" : "iphone")
                        .ariaFont(.label)
                        .contentTransition(.symbolEffect(.replace))
                }
                .ariaButtonStyle(player.isSpeaker ? .prominent : .standard)
                .accessibilityLabel(Text("Speaker"))
                .accessibilityValue(Text(player.isSpeaker ? "On" : "Off"))
            }

            if let error = isCurrent ? player.errorMessage : nil {
                Text(error)
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.error)
            }
        }
        .padding(.top, Space.xxs)
    }
}

// MARK: - Player

/// Plays one voicemail at a time, outside of calls.
@MainActor
final class VoicemailPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentId: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    /// Playback speed: 1×, 1.5× or 2×.
    @Published private(set) var rate: Float = 1
    /// Loudspeaker, or the earpiece as in a call.
    @Published private(set) var isSpeaker = true

    static let rates: [Float] = [1, 1.5, 2]

    private var audioPlayer: AVAudioPlayer?
    private var fileURL: URL?
    private var timer: Timer?

    var rateLabel: String { Self.label(for: rate) }

    static func label(for rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(1))))×"
    }

    static func next(after rate: Float) -> Float {
        let index = rates.firstIndex(of: rate) ?? 0
        return rates[(index + 1) % rates.count]
    }

    func play(id: String, load: () async throws -> URL) async {
        stop()
        currentId = id
        isLoading = true
        defer { isLoading = false }

        do {
            let url = try await load()
            guard currentId == id else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            fileURL = url
            try applyRoute()

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            player.play()
            audioPlayer = player
            duration = player.duration
            isPlaying = true
            startTimer()
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
        }
    }

    func togglePause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = min(max(0, time), player.duration)
        progress = player.currentTime
    }

    func cycleRate() {
        rate = Self.next(after: rate)
        audioPlayer?.rate = rate
    }

    func setSpeaker(_ on: Bool) {
        isSpeaker = on
        if audioPlayer != nil { try? applyRoute() }
    }

    /// Playback goes to the loudspeaker; the earpiece needs play-and-record,
    /// as the Phone app's voicemail does.
    private func applyRoute() throws {
        let session = AVAudioSession.sharedInstance()
        if isSpeaker {
            // Playback, not the ambient default, so the ring/silent switch
            // does not mute a message the user asked to hear.
            try session.setCategory(.playback, mode: .spokenAudio)
        } else {
            try session.setCategory(.playAndRecord, mode: .spokenAudio)
            try session.overrideOutputAudioPort(.none)
        }
        try session.setActive(true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let hadPlayer = audioPlayer != nil
        audioPlayer?.stop()
        audioPlayer = nil
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
        currentId = nil
        isPlaying = false
        progress = 0
        duration = 0
        errorMessage = nil
        if hadPlayer {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let player = self.audioPlayer else { return }
                self.progress = player.currentTime
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
        }
    }
}
