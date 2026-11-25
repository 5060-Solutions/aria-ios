import SwiftUI

/// Business texting: the conversations of each inbox the seat may use, newest
/// first, with unread state, and a new conversation by number.
struct MessagesView: View {
    @ObservedObject private var service = MessagingService.shared
    @State private var path: [MessagingService.ThreadKey] = []
    @State private var selectedInbox: String?
    @State private var showNew = false

    private var inbox: MessagingService.Inbox? {
        service.inbox(selectedInbox ?? "") ?? service.inboxes.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let inbox {
                    list(for: inbox)
                } else if service.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(systemImage: "message", title: Text("No Messages"),
                               message: Text("Texts on your business numbers appear here."))
                }
            }
            .background(AriaColor.background)
            .navigationTitle("Messages")
            .navigationDestination(for: MessagingService.ThreadKey.self) { key in
                ThreadView(key: key)
            }
            .toolbar {
                if !service.sendableInboxes.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNew = true } label: {
                            Label("New Message", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("messages.new")
                    }
                }
            }
            .sheet(isPresented: $showNew) {
                NewConversationView(initialInbox: inbox?.didId) { key in
                    showNew = false
                    path.append(key)
                }
            }
            .refreshable { await service.refresh() }
            .task {
                await service.refresh()
                LocalNotifications.requestAuthorizationIfNeeded()
            }
            .onChange(of: service.pendingThread, initial: true) { _, pending in
                guard let pending else { return }
                selectedInbox = pending.didId
                path = [pending]
                service.pendingThread = nil
            }
        }
    }

    @ViewBuilder
    private func list(for inbox: MessagingService.Inbox) -> some View {
        let conversations = service.conversations[inbox.didId] ?? []
        VStack(spacing: 0) {
            if service.inboxes.count > 1 {
                Picker("Number", selection: Binding(get: { inbox.didId }, set: { selectedInbox = $0 })) {
                    ForEach(service.inboxes) { Text(DialFormatter.format($0.number)).tag($0.didId) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, Space.screenMargin)
            }
            if let error = service.errorMessage {
                Banner(message: .error(error))
                    .padding(.horizontal, Space.screenMargin)
            }
            if conversations.isEmpty {
                EmptyState(systemImage: "message", title: Text("No Messages"),
                           message: Text(inbox.enabled
                                         ? "Texts to and from \(DialFormatter.format(inbox.number)) appear here."
                                         : "Texting is turned off for this number."))
            } else {
                List {
                    ForEach(conversations) { conversation in
                        let key = MessagingService.ThreadKey(didId: inbox.didId, remoteNumber: conversation.remoteNumber)
                        NavigationLink(value: key) {
                            ConversationRow(conversation: conversation,
                                            isUnread: service.isUnread(didId: inbox.didId, conversation))
                        }
                        .ariaListRow()
                    }
                }
                .ariaListStyle()
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: PbxApiClient.MessagingConversation
    let isUnread: Bool

    private var preview: String {
        if conversation.lastBody.isEmpty, conversation.lastHasMedia { return String(localized: "Photo") }
        let prefix = conversation.lastDirection == "outbound" ? String(localized: "You: ") : ""
        return prefix + conversation.lastBody
    }

    var body: some View {
        AriaListRow(
            title: Text(DialFormatter.format(conversation.remoteNumber)).fontWeight(isUnread ? .semibold : .regular),
            subtitle: Text(preview)
        ) {
            ZStack(alignment: .topLeading) {
                Avatar(name: "")
                if isUnread {
                    Circle()
                        .fill(AriaColor.primary)
                        .frame(width: Space.s, height: Space.s)
                        .overlay(Circle().stroke(AriaColor.surface, lineWidth: 2))
                        .offset(x: -2, y: -2)
                        .accessibilityHidden(true)
                }
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: Space.hairline) {
                Text(conversation.lastAt.formatted(.relative(presentation: .named)))
                    .ariaFont(.label)
                    .foregroundStyle(AriaColor.onSurfaceVariant)
                if conversation.lastStatus == "failed" {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(AriaColor.error)
                        .accessibilityLabel(Text("Failed to send"))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(isUnread ? "Unread" : ""))
    }
}

// MARK: - New conversation

/// Start a conversation by typing a number.
struct NewConversationView: View {
    @ObservedObject private var service = MessagingService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var inboxId: String
    let onStart: (MessagingService.ThreadKey) -> Void

    init(initialInbox: String?, onStart: @escaping (MessagingService.ThreadKey) -> Void) {
        _inboxId = State(initialValue: initialInbox ?? "")
        self.onStart = onStart
    }

    private var e164: String? { MessageNumber.e164(number) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Phone number", text: $number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .accessibilityIdentifier("messages.newNumber")
                } footer: {
                    if !number.isEmpty, e164 == nil {
                        Text("Enter a full number, for example +1 303 555 0100.")
                    }
                }
                if service.sendableInboxes.count > 1 {
                    Section("Send from") {
                        Picker("Send from", selection: $inboxId) {
                            ForEach(service.sendableInboxes) { Text(DialFormatter.format($0.number)).tag($0.didId) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
                        if let e164, let did = chosenInbox {
                            onStart(.init(didId: did, remoteNumber: e164))
                        }
                    }
                    .disabled(e164 == nil || chosenInbox == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var chosenInbox: String? {
        let sendable = service.sendableInboxes
        return sendable.first { $0.didId == inboxId }?.didId ?? sendable.first?.didId
    }
}
