import SwiftUI

/// Manage on-device transcription: pick a model, download it, opt in, and read
/// past transcripts.
///
/// Transcription runs entirely on the handset. Call audio is tapped inside the
/// Rust core, where it is already decoded, and never reaches this layer — this
/// view only ever deals with model management and finished text.
struct TranscriptionView: View {
    @State private var supported = false
    @State private var models: [AiModel] = []
    @State private var progress: [String: AiDownloadProgress] = [:]
    @State private var transcribeCalls = CallTranscription.shared.isEnabled
    @State private var insights: [AiInsightSummary] = []
    @State private var openInsight: AiCallInsight?
    @State private var errorMessage: String?
    @State private var loading = true

    private var sttInstalled: Bool {
        models.contains { $0.kind == "stt" && $0.installed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Calls are transcribed on this phone. Audio and transcripts never leave the device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if loading {
                    ProgressView().padding()
                } else if !supported {
                    // Say plainly that this build cannot do it, rather than
                    // showing an empty list that looks like a loading failure.
                    Text("This version of Aria was built without transcription support.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                    optInCard
                    modelsSection
                    transcriptsSection
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $openInsight) { TranscriptDetailView(insight: $0) }
    }

    // MARK: - Sections

    /// Capturing call audio is a recording, so it stays off until the user asks
    /// for it — having a model installed is not consent on its own.
    private var optInCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { transcribeCalls && sttInstalled },
                set: { on in
                    transcribeCalls = on
                    CallTranscription.shared.isEnabled = on
                }
            )) {
                Text("Transcribe my calls").font(.body)
            }
            .disabled(!sttInstalled)

            Text(sttInstalled
                 ? "Both sides of the call are transcribed on this phone."
                 : "Download a speech model below to turn this on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models").font(.headline)
            ForEach(models, id: \.id) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: AiModel) -> some View {
        let p = progress[model.id]
        let downloading = p.map { ["queued", "downloading", "verifying"].contains($0.state) } ?? false

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.body)
                    Text("\(model.kind == "llm" ? "Summaries" : "Transcription") · \(humanBytes(model.sizeBytes))"
                         + (model.unavailableReason.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.installed {
                    Button(role: .destructive) {
                        Task { await deleteModel(model.id) }
                    } label: { Image(systemName: "trash") }
                } else if downloading {
                    Button("Cancel") {
                        SipEngineManager.shared.aiCancelDownload(modelId: model.id)
                    }
                } else {
                    Button("Download") {
                        try? SipEngineManager.shared.aiStartDownload(modelId: model.id)
                    }
                    .disabled(!model.available)
                }
            }
            if downloading, let p, p.totalBytes > 0 {
                ProgressView(value: Double(p.downloadedBytes), total: Double(p.totalBytes))
            }
            if let err = p?.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcripts").font(.headline)
                Spacer()
                if !insights.isEmpty {
                    Button("Clear all", role: .destructive) {
                        _ = SipEngineManager.shared.aiClearInsights()
                        Task { await refresh() }
                    }
                    .font(.footnote)
                }
            }
            if insights.isEmpty {
                Text("No transcripts yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(insights, id: \.callId) { row in
                    HStack {
                        // The list carries no transcript text, so tapping is
                        // what decrypts one.
                        Button {
                            openInsight = SipEngineManager.shared.aiInsight(callId: row.callId)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatTimestamp(row.createdAt)).font(.body)
                                Text("\(row.durationSecs)s"
                                     + (row.status == "complete" ? "" : " · \(row.status)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(role: .destructive) {
                            _ = SipEngineManager.shared.aiDeleteInsight(callId: row.callId)
                            Task { await refresh() }
                        } label: { Image(systemName: "trash") }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Data

    private func load() async {
        supported = CallTranscription.shared.isAvailable
        guard supported else {
            loading = false
            return
        }
        do {
            try CallTranscription.shared.initialise()
        } catch {
            errorMessage = "Could not start on-device AI: \(error)"
        }
        await refresh()
        loading = false
        await pollDownloads()
    }

    private func refresh() async {
        models = SipEngineManager.shared.aiModels()
        insights = SipEngineManager.shared.aiInsights(limit: 100, offset: 0)
    }

    /// Downloads report progress by polling rather than pushing, so this is the
    /// view's own timer rather than a callback across the FFI boundary. It ends
    /// as soon as nothing is left to install.
    private func pollDownloads() async {
        while !Task.isCancelled {
            let pending = models.filter { !$0.installed }
            if pending.isEmpty { return }

            var next: [String: AiDownloadProgress] = [:]
            var completed = false
            for m in pending {
                if let p = SipEngineManager.shared.aiDownloadProgress(modelId: m.id) {
                    next[m.id] = p
                    if p.state == "completed" { completed = true }
                }
            }
            progress = next
            if completed { await refresh() }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func deleteModel(_ id: String) async {
        try? SipEngineManager.shared.aiDeleteModel(modelId: id)
        await refresh()
        // Without a speech model there is nothing to capture for, so leaving
        // the switch on would be a promise the app cannot keep.
        if !sttInstalled {
            transcribeCalls = false
            CallTranscription.shared.isEnabled = false
        }
    }
}

/// One transcript, decrypted on open.
struct TranscriptDetailView: View {
    let insight: AiCallInsight
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let headline = insight.summaryHeadline {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(headline).font(.body).bold()
                            ForEach(insight.summaryPoints, id: \.self) { Text("• \($0)").font(.callout) }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if insight.segments.isEmpty {
                        Text("No speech was recognised in this call.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(insight.segments.enumerated()), id: \.offset) { _, seg in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(seg.speaker == "local" ? "You" : "Them")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            Text(seg.text).font(.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(formatTimestamp(insight.createdAt))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// `sheet(item:)` needs identity, and a call id is already unique per insight.
extension AiCallInsight: Identifiable {
    public var id: String { callId }
}

private func humanBytes(_ n: UInt64) -> String {
    if n >= 1_000_000_000 { return String(format: "%.1f GB", Double(n) / 1_000_000_000) }
    if n >= 1_000_000 { return "\(n / 1_000_000) MB" }
    return "\(n / 1000) KB"
}

private func formatTimestamp(_ epochSeconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: date)
}
