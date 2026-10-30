import SwiftUI
import AVFoundation

/// The signed-in extension's voicemail: list, playback, mark-read, delete.
struct VoicemailView: View {
    @EnvironmentObject var callManager: CallManager
    @ObservedObject private var service = VoicemailService.shared
    @StateObject private var player = VoicemailPlayer()
    @AppStorage(AccountSettings.Key.voicemailNumber) private var voicemailNumber = ""

    var body: some View {
        NavigationStack {
            Group {
                if service.messages.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(service.messages) { message in
                            VoicemailRow(
                                message: message,
                                player: player,
                                canPlay: callManager.activeCall == nil
                            ) {
                                play(message)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    if player.currentId == message.id { player.stop() }
                                    Task { await service.delete(message) }
                                } label: {
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
                                    .tint(.ariaIndigo)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .safeAreaInset(edge: .top) {
                if let error = service.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                }
            }
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
            .refreshable { await service.refresh() }
            .task { await service.refresh() }
            .onDisappear { player.stop() }
            .onChange(of: callManager.activeCall != nil) { inCall in
                // A call takes the audio session; do not fight it.
                if inCall { player.stop() }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if service.isLoading {
                ProgressView()
            } else {
                Image(systemName: "recordingtape")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text(service.hasMailbox ? "No Voicemail" : "No Mailbox")
                    .font(.headline)
                Text(service.hasMailbox
                     ? "Messages left for you will appear here."
                     : "Your extension does not have a voicemail box.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
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
}

// MARK: - Row

private struct VoicemailRow: View {
    let message: VoicemailService.Message
    @ObservedObject var player: VoicemailPlayer
    let canPlay: Bool
    let onPlay: () -> Void

    private var isCurrent: Bool { player.currentId == message.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Circle()
                    .fill(message.read ? Color.clear : Color.ariaIndigo)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(message.read)
                    .accessibilityLabel("Unread")

                VStack(alignment: .leading, spacing: 4) {
                    Text(message.callerId.isEmpty ? "Unknown" : message.callerId)
                        .font(.body)
                        .fontWeight(message.read ? .regular : .semibold)
                    HStack(spacing: 4) {
                        Text(message.createdAt, style: .date)
                        Text(message.createdAt, style: .time)
                        Text("·")
                        Text(formatDuration(message.durationSecs))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onPlay) {
                    if isCurrent && player.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundColor(.ariaIndigo)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!canPlay)
                .accessibilityLabel(isCurrent && player.isPlaying ? "Pause" : "Play")
            }

            if isCurrent, player.duration > 0 {
                ProgressView(value: player.progress, total: player.duration)
                    .tint(.ariaIndigo)
                    .padding(.leading, 20)
            }

            if let error = isCurrent ? player.errorMessage : nil {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 20)
            }

            if let transcription = message.transcription, !transcription.isEmpty {
                Text(transcription)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(isCurrent ? nil : 2)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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

    private var audioPlayer: AVAudioPlayer?
    private var fileURL: URL?
    private var timer: Timer?

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

            // Playback, not the ambient default, so the ring/silent switch
            // does not mute a message the user asked to hear.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
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
