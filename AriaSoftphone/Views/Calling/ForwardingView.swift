import SwiftUI

/// Call forwarding on the PBX: always, when busy, when unanswered. One
/// forward of each kind; each can be switched off without losing its number.
struct ForwardingView: View {
    @ObservedObject private var service = SelfService.shared

    var body: some View {
        Form {
            ForEach(SelfService.ForwardType.allCases) { type in
                ForwardSection(type: type, existing: service.forward(type))
            }
            if let error = service.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("forwarding.error")
                }
            }
        }
        .navigationTitle("Call Forwarding")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if service.isLoading && service.forwards.isEmpty && service.doNotDisturb == nil {
                ProgressView()
            }
        }
        .refreshable { await service.refresh() }
        .task { await service.refresh() }
    }
}

/// One kind of forward: on/off, where to, and (when unanswered) after how
/// long.
private struct ForwardSection: View {
    let type: SelfService.ForwardType
    let existing: SelfService.Forward?

    @ObservedObject private var service = SelfService.shared
    @State private var destination = ""
    @State private var ringTimeout = 20
    @State private var saving = false

    private var isEnabled: Bool { existing?.enabled ?? false }
    private var trimmed: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isEdited: Bool {
        trimmed != (existing?.destination ?? "") || (type == .noAnswer && ringTimeout != (existing?.ringTimeoutSecs ?? 20))
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { on in Task { await toggle(on) } }
            )) {
                Label(Self.title(type), systemImage: Self.icon(type))
            }
            .disabled(saving || (existing == nil && trimmed.isEmpty))
            .accessibilityIdentifier("forwarding.\(type.rawValue).toggle")

            TextField("Number or extension", text: $destination)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .accessibilityIdentifier("forwarding.\(type.rawValue).destination")

            if type == .noAnswer {
                Stepper(value: $ringTimeout, in: 5...300, step: 5) {
                    Text("After \(ringTimeout) seconds")
                }
                .accessibilityIdentifier("forwarding.noAnswer.timeout")
            }

            if isEdited && !trimmed.isEmpty {
                Button(existing == nil ? "Turn On" : "Save") {
                    Task { await save(enabled: existing == nil ? true : isEnabled) }
                }
                .disabled(saving)
                .accessibilityIdentifier("forwarding.\(type.rawValue).save")
            }
            if existing != nil {
                Button("Remove", role: .destructive) {
                    Task {
                        saving = true
                        await service.removeForward(type)
                        saving = false
                        destination = ""
                    }
                }
                .disabled(saving)
            }
        } footer: {
            Text(Self.footer(type))
        }
        .onAppear(perform: load)
        .onChange(of: existing) { _ in load() }
    }

    private func load() {
        destination = existing?.destination ?? destination
        ringTimeout = existing?.ringTimeoutSecs ?? ringTimeout
    }

    private func toggle(_ on: Bool) async {
        if existing == nil {
            await save(enabled: on)
        } else {
            saving = true
            await service.setForwardEnabled(type, on)
            saving = false
        }
    }

    private func save(enabled: Bool) async {
        saving = true
        await service.saveForward(type: type, destination: trimmed, ringTimeoutSecs: ringTimeout, enabled: enabled)
        saving = false
    }

    static func title(_ type: SelfService.ForwardType) -> LocalizedStringKey {
        switch type {
        case .unconditional: return "Always"
        case .busy: return "When busy"
        case .noAnswer: return "When unanswered"
        }
    }

    static func icon(_ type: SelfService.ForwardType) -> String {
        switch type {
        case .unconditional: return "arrowshape.turn.up.right"
        case .busy: return "phone.badge.waveform"
        case .noAnswer: return "phone.arrow.up.right"
        }
    }

    static func footer(_ type: SelfService.ForwardType) -> LocalizedStringKey {
        switch type {
        case .unconditional: return "Every call goes to this number. Your phone doesn't ring."
        case .busy: return "Calls go here while you're on another call."
        case .noAnswer: return "Calls go here if you don't answer in time."
        }
    }
}
