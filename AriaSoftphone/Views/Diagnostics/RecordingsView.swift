import SwiftUI
import AVFoundation

/// Call recordings on this iPhone: play, share, delete.
struct RecordingsView: View {
    @ObservedObject private var store: RecordingsStore
    @StateObject private var player = RecordingPlayer()

    init(store: RecordingsStore = .shared) {
        self.store = store
    }

    var body: some View {
        Group {
            if store.recordings.isEmpty {
                EmptyState(
                    systemImage: "record.circle",
                    title: Text("No recordings"),
                    message: Text("Recordings you make during calls appear here. They stay on this iPhone.")
                )
            } else {
                List {
                    ForEach(store.recordings) { recording in
                        row(recording)
                            .ariaListRow()
                            .swipeActions {
                                Button(role: .destructive) {
                                    player.stop()
                                    store.delete(recording)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .ariaListStyle()
            }
        }
        .background(AriaColor.background)
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }

    private func row(_ recording: CallRecording) -> some View {
        AriaListRow(
            title: Text(recording.displayName),
            subtitle: Text(subtitle(recording)),
            hasAvatar: true
        ) {
            Button {
                player.toggle(recording.url)
            } label: {
                Image(systemName: player.playing == recording.url ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AriaColor.primary)
            .disabled(recording.isInProgress)
            .accessibilityLabel(Text(player.playing == recording.url ? "Stop" : "Play"))
        } trailing: {
            if let url = store.shareURL(for: recording), !recording.isInProgress {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                }
                .foregroundStyle(AriaColor.primary)
                .accessibilityLabel(Text("Share recording"))
            }
        }
    }

    private func subtitle(_ recording: CallRecording) -> String {
        let date = recording.startedAt.formatted(date: .abbreviated, time: .shortened)
        if recording.isInProgress { return "\(date) · " + String(localized: "Recording…") }
        let duration = Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond))
        return "\(date) · \(duration)"
    }
}

/// Plays one recording at a time.
@MainActor
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url {
            stop()
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            playing = url
        } catch {
            AppLog.shared.log("recording", "Playback failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
