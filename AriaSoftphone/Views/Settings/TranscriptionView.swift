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
            VStack(alignment: .leading, spacing: Space.sectionGap) {
                Text("Calls are transcribed on this phone. Audio and transcripts never leave the device.")
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)

                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if !supported {
                    // Say plainly that this build cannot do it, rather than
                    // showing an empty list that looks like a loading failure.
                    EmptyState(systemImage: "text.bubble", title: Text("Not in This Build"),
                               message: Text("This version of Aria was built without transcription support."))
                } else {
                    if let errorMessage {
                        Banner(message: BannerMessage(kind: .error, text: errorMessage, duration: nil))
                    }
                    optInCard
                    modelsSection
                    transcriptsSection
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .padding(.vertical, Space.m)
        }
        .background(AriaColor.background)
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $openInsight) { TranscriptDetailView(insight: $0) }
    }

    // MARK: - Sections

    /// Capturing call audio is a recording, so it stays off until the user asks
    /// for it — having a model installed is not consent on its own.
    private var optInCard: some View {
        SectionCard(footer: Text(sttInstalled
                                 ? "Both sides of the call are transcribed on this phone."
                                 : "Download a speech model below to turn this on.")) {
            ToggleRow(title: "Transcribe My Calls", systemImage: "text.bubble", isOn: Binding(
                get: { transcribeCalls && sttInstalled },
                set: { on in
                    transcribeCalls = on
                    CallTranscription.shared.isEnabled = on
                }
            ))
            .disabled(!sttInstalled)
        }
    }

    private var modelsSection: some View {
        SectionCard(title: Text("Models")) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                modelRow(model)
                if index < models.count - 1 { RowDivider() }
            }
        }
    }

    private func modelRow(_ model: AiModel) -> some View {
        let p = progress[model.id]
        let downloading = p.map { ["queued", "downloading", "verifying"].contains($0.state) } ?? false

        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.hairline) {
                    Text(model.displayName)
                        .ariaFont(.body)
                        .foregroundStyle(AriaColor.onSurface)
                    Text("\(model.kind == "llm" ? "Summaries" : "Transcription") · \(humanBytes(model.sizeBytes))"
                         + (model.unavailableReason.map { " · \($0)" } ?? ""))
                        .ariaFont(.bodySmall)
                        .foregroundStyle(AriaColor.onSurfaceVariant)
                }
                Spacer(minLength: Space.xs)
                if model.installed {
                    Button(role: .destructive) {
                        Task { await deleteModel(model.id) }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(AriaColor.error)
                            .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Delete \(model.displayName)"))
                } else if downloading {
                    AriaButton("Cancel", kind: .plain) {
                        SipEngineManager.shared.aiCancelDownload(modelId: model.id)
                    }
                } else {
                    AriaButton("Download", systemImage: "arrow.down.circle", kind: .standard) {
                        try? SipEngineManager.shared.aiStartDownload(modelId: model.id)
                    }
                    .disabled(!model.available)
                }
            }
            if downloading, let p, p.totalBytes > 0 {
                ProgressView(value: Double(p.downloadedBytes), total: Double(p.totalBytes))
                    .tint(AriaColor.primary)
            }
            if let err = p?.error {
                Text(err)
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.error)
            }
        }
        .padding(.vertical, Space.s)
    }

    private var transcriptsSection: some View {
        SectionCard(title: Text("Transcripts")) {
            if insights.isEmpty {
                Text("No transcripts yet.")
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity, minHeight: ComponentSize.row, alignment: .leading)
            } else {
                ForEach(insights, id: \.callId) { row in
                    HStack(spacing: Space.s) {
                        // The list carries no transcript text, so tapping is
                        // what decrypts one.
                        Button {
                            openInsight = SipEngineManager.shared.aiInsight(callId: row.callId)
                        } label: {
                            VStack(alignment: .leading, spacing: Space.hairline) {
                                Text(formatTimestamp(row.createdAt))
                                    .ariaFont(.body)
                                    .foregroundStyle(AriaColor.onSurface)
                                Text(CallClock.format(TimeInterval(row.durationSecs))
                                     + (row.status == "complete" ? "" : " · \(row.status)"))
                                    .ariaFont(.bodySmall)
                                    .foregroundStyle(AriaColor.onSurfaceVariant)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            _ = SipEngineManager.shared.aiDeleteInsight(callId: row.callId)
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(AriaColor.error)
                                .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Delete transcript"))
                    }
                    .frame(minHeight: ComponentSize.row)
                    RowDivider()
                }
                AriaButton("Clear All Transcripts", kind: .plain) {
                    _ = SipEngineManager.shared.aiClearInsights()
                    Task { await refresh() }
                }
                .foregroundStyle(AriaColor.error)
                .padding(.vertical, Space.xs)
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
                VStack(alignment: .leading, spacing: Space.sectionGap) {
                    if let headline = insight.summaryHeadline {
                        SectionCard(title: Text("Summary")) {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(headline)
                                    .ariaFont(.body)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(AriaColor.onSurface)
                                ForEach(insight.summaryPoints, id: \.self) {
                                    Text("• \($0)")
                                        .ariaFont(.bodySmall)
                                        .foregroundStyle(AriaColor.onSurface)
                                }
                            }
                            .padding(.vertical, Space.s)
                        }
                    }

                    if insight.segments.isEmpty {
                        EmptyState(systemImage: "waveform.slash", title: Text("No Speech"),
                                   message: Text("No speech was recognised in this call."))
                    }

                    ForEach(Array(insight.segments.enumerated()), id: \.offset) { _, seg in
                        VStack(alignment: .leading, spacing: Space.hairline) {
                            Text(seg.speaker == "local" ? "You" : "Them")
                                .ariaFont(.label)
                                .foregroundStyle(seg.speaker == "local" ? AriaColor.primary : AriaColor.tertiary)
                            Text(seg.text)
                                .ariaFont(.body)
                                .foregroundStyle(AriaColor.onSurface)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.vertical, Space.m)
            }
            .background(AriaColor.background)
            .navigationTitle(formatTimestamp(insight.createdAt))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
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
