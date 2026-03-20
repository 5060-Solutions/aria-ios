import SwiftUI

/// Call history view.
struct HistoryView: View {
    @EnvironmentObject var callManager: CallManager
    @State private var callHistory: [CallHistoryEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if callHistory.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Call History")
                            .font(.headline)
                        Text("Your recent calls will appear here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(callHistory) { entry in
                            CallHistoryRow(entry: entry) {
                                callManager.startOutgoingCall(uri: entry.remoteUri)
                            }
                        }
                        .onDelete(perform: deleteEntries)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !callHistory.isEmpty {
                    EditButton()
                }
            }
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        callHistory.remove(atOffsets: offsets)
    }
}

// MARK: - Call History Entry

struct CallHistoryEntry: Identifiable {
    let id = UUID()
    let remoteUri: String
    let remoteName: String?
    let direction: String  // "inbound" or "outbound"
    let timestamp: Date
    let duration: TimeInterval
    let missed: Bool

    var displayName: String {
        remoteName ?? remoteUri
    }

    var icon: String {
        if missed {
            return "phone.arrow.down.left"
        }
        return direction == "inbound" ? "phone.arrow.down.left" : "phone.arrow.up.right"
    }

    var iconColor: Color {
        missed ? .red : (direction == "inbound" ? .blue : .green)
    }
}

// MARK: - History Row

struct CallHistoryRow: View {
    let entry: CallHistoryEntry
    let onCall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.icon)
                .foregroundColor(entry.iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(.body)
                    .foregroundColor(entry.missed ? .red : .primary)

                HStack(spacing: 4) {
                    Text(entry.timestamp, style: .relative)
                    if entry.duration > 0 {
                        Text("(\(formatDuration(entry.duration)))")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onCall) {
                Image(systemName: "phone.fill")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
