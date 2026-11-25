import SwiftUI
import PhotosUI

/// One conversation: bubbles oldest first, delivery status with the server's
/// error, a composer with a segment counter and a photo, and a call button.
struct ThreadView: View {
    let key: MessagingService.ThreadKey

    @EnvironmentObject var callManager: CallManager
    @ObservedObject private var service = MessagingService.shared
    @State private var text = ""
    @State private var attachment: PbxApiClient.MessagingAttachment?
    @State private var attachmentPreview: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var isSending = false
    @State private var banner: BannerMessage?

    private var thread: MessagingService.Thread? { service.threads[key] }
    private var messages: [MessagingService.Message] { (thread?.messages ?? []).reversed() }
    private var segments: SmsSegments { SmsSegments(text) }
    private var inbox: MessagingService.Inbox? { service.inbox(key.didId) }
    private var canSend: Bool {
        inbox?.enabled == true && thread?.optedOut != true && !isSending && !isUploading
            && !segments.isTooLong && text.unicodeScalars.count <= SmsSegments.maxBodyLength
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.xs) {
                        ForEach(messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }
                    .padding(.horizontal, Space.screenMargin)
                    .padding(.vertical, Space.s)
                }
                .onChange(of: messages.last?.id, initial: true) { _, last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            if thread?.optedOut == true {
                Text("This person replied STOP. They can't be texted until they reply START.")
                    .ariaFont(.bodySmall)
                    .foregroundStyle(AriaColor.error)
                    .padding(Space.s)
            }
            composer
        }
        .background(AriaColor.background)
        .navigationTitle(DialFormatter.format(key.remoteNumber))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let number = MessageNumber.e164(key.remoteNumber) else { return }
                    if callManager.startOutgoingCall(uri: number) == .refused {
                        banner = .error(String(localized: "Can't place another call right now."))
                    }
                } label: {
                    Label("Call", systemImage: "phone.fill")
                }
                .disabled(MessageNumber.e164(key.remoteNumber) == nil)
                .accessibilityIdentifier("thread.call")
            }
        }
        .banner($banner)
        .task {
            service.opened(key)
            // Back mid-retry: the unsent text and photo are still there.
            if let pending = service.pendingSend(for: key), text.isEmpty, attachment == nil {
                text = pending.body
                attachment = pending.attachment
            }
            await service.loadThread(key)
        }
        .onDisappear { service.closed(key) }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await attach(item) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let attachmentPreview {
                HStack {
                    Image(uiImage: attachmentPreview)
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: Radius.chip))
                        .accessibilityLabel(Text("Attached photo"))
                    Button {
                        attachment = nil
                        self.attachmentPreview = nil
                        pickerItem = nil
                    } label: {
                        Label("Remove photo", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    }
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: Space.xs) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Group {
                        if isUploading { ProgressView() } else { Image(systemName: "photo") }
                    }
                    .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                }
                .disabled(isUploading || attachment != nil || inbox?.enabled != true)
                .accessibilityLabel(Text("Attach photo"))
                .accessibilityIdentifier("thread.attach")

                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .ariaFont(.body)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .background(AriaColor.surface, in: .rect(cornerRadius: Radius.textField))
                    .accessibilityIdentifier("thread.field")

                Button(action: send) {
                    Group {
                        if isSending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    }
                    .frame(width: ComponentSize.iconButton, height: ComponentSize.iconButton)
                }
                .tint(AriaColor.primary)
                .disabled(!canSend)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("thread.send")
            }
            if !text.isEmpty {
                Text(counterText)
                    .ariaFont(.label)
                    .foregroundStyle(segments.isTooLong ? AriaColor.error : AriaColor.onSurfaceVariant)
                    .monospacedDigit()
                    .accessibilityIdentifier("thread.counter")
            }
        }
        .padding(.horizontal, Space.screenMargin)
        .padding(.vertical, Space.xs)
        .background(.bar)
    }

    private var counterText: String {
        if segments.isTooLong {
            return String(localized: "Too long: \(segments.segments) of \(SmsSegments.maxSegments) segments at most")
        }
        return String(localized: "\(segments.remaining) left · \(segments.segments) of \(SmsSegments.maxSegments) segments")
    }

    // MARK: Actions

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await service.send(didId: key.didId, to: key.remoteNumber, body: body,
                                       attachment: attachment)
                text = ""
                attachment = nil
                attachmentPreview = nil
                pickerItem = nil
            } catch {
                banner = .error(error.localizedDescription)
            }
        }
    }

    private func attach(_ item: PhotosPickerItem) async {
        isUploading = true
        defer { isUploading = false }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let jpeg = MessageImage.jpegForUpload(raw) else {
                banner = .error(String(localized: "That photo can't be sent."))
                pickerItem = nil
                return
            }
            attachment = try await service.upload(imageData: jpeg, filename: "photo.jpg", contentType: "image/jpeg")
            attachmentPreview = UIImage(data: jpeg)
        } catch {
            pickerItem = nil
            banner = .error(error.localizedDescription)
        }
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: PbxApiClient.MessagingMessage

    private var failed: Bool { message.status == "failed" }

    var body: some View {
        VStack(alignment: message.isOutbound ? .trailing : .leading, spacing: Space.hairline) {
            ForEach(message.attachments) { AttachmentView(attachment: $0) }
            if !message.body.isEmpty {
                Text(message.body)
                    .ariaFont(.body)
                    .foregroundStyle(message.isOutbound ? AriaColor.onPrimary : AriaColor.onSurface)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .background(
                        message.isOutbound ? (failed ? AriaColor.error : AriaColor.primary) : AriaColor.surfaceContainerHigh,
                        in: .rect(cornerRadius: Radius.contentRow)
                    )
                    .textSelection(.enabled)
            }
            if message.isOutbound {
                Text(statusText)
                    .ariaFont(.label)
                    .foregroundStyle(failed ? AriaColor.error : AriaColor.onSurfaceVariant)
                    .multilineTextAlignment(.trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isOutbound ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch message.status {
        case "pending": return String(localized: "Sending…")
        case "sent": return String(localized: "Sent")
        case "delivered": return String(localized: "Delivered")
        case "failed":
            if let reason = message.errorMessage, !reason.isEmpty {
                return String(localized: "Not delivered: \(reason)")
            }
            return String(localized: "Not delivered")
        default: return message.createdAt.formatted(date: .omitted, time: .shortened)
        }
    }
}

private struct AttachmentView: View {
    let attachment: PbxApiClient.MessagingAttachment
    @ObservedObject private var service = MessagingService.shared
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if attachment.isImage {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 280)
                        .clipShape(.rect(cornerRadius: Radius.contentRow))
                        .accessibilityLabel(Text("Photo"))
                } else {
                    RoundedRectangle(cornerRadius: Radius.contentRow)
                        .fill(AriaColor.surfaceContainerHigh)
                        .frame(width: 160, height: 120)
                        .overlay { failed ? Image(systemName: "photo.badge.exclamationmark") : nil }
                }
            } else {
                Label(attachment.contentType, systemImage: "paperclip")
                    .ariaFont(.bodySmall)
                    .padding(Space.xs)
                    .background(AriaColor.surfaceContainerHigh, in: .rect(cornerRadius: Radius.chip))
            }
        }
        .task {
            guard attachment.isImage, image == nil else { return }
            if let data = try? await service.attachmentData(attachment), let loaded = UIImage(data: data) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}
