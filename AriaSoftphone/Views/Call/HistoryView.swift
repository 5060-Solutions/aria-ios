import SwiftUI

/// Call history view.
struct HistoryView: View {
    @EnvironmentObject var callManager: CallManager
    @ObservedObject private var history = CallHistoryStore.shared
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
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
                        ForEach(history.records) { record in
                            CallHistoryRow(record: record) {
                                callManager.startOutgoingCall(uri: record.remoteUri)
                            }
                        }
                        .onDelete(perform: history.remove(atOffsets:))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !history.records.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear", role: .destructive) {
                            showClearConfirmation = true
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
            .confirmationDialog(
                "Clear all call history?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    history.clear()
                }
            }
        }
    }
}

// MARK: - History Row

struct CallHistoryRow: View {
    let record: CallRecord
    let onCall: () -> Void

    var body: some View {
        // The whole row calls back, as in the system Phone app.
        Button(action: onCall) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayName)
                        .font(.body)
                        .foregroundColor(record.isMissed ? .red : .primary)

                    HStack(spacing: 4) {
                        Text(subtitle)
                        Text("·")
                        Text(record.startedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "phone.fill")
                    .foregroundColor(.blue)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Calls \(record.displayName)")
    }

    private var icon: String {
        switch record.direction {
        case .inbound:
            return record.outcome == .answered ? "phone.arrow.down.left" : "phone.down.fill"
        case .outbound:
            return "phone.arrow.up.right"
        }
    }

    private var iconColor: Color {
        switch record.outcome {
        case .answered: return record.direction == .inbound ? .blue : .green
        case .missed, .failed: return .red
        case .rejected, .cancelled: return .secondary
        }
    }

    private var subtitle: String {
        switch record.outcome {
        case .answered:
            let label = record.direction == .inbound ? "Incoming" : "Outgoing"
            return "\(label) \(formatDuration(record.duration))"
        case .missed: return "Missed"
        case .rejected: return "Declined"
        case .cancelled: return "Cancelled"
        case .failed: return record.direction == .inbound ? "Missed" : "Failed"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
