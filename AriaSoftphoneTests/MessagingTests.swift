import XCTest
@testable import AriaSoftphone

final class MessagingSupportTests: XCTestCase {
    func testGsmSegments() {
        XCTAssertEqual(SmsSegments("").segments, 0)
        let one = SmsSegments(String(repeating: "a", count: 160))
        XCTAssertEqual(one.encoding, .gsm7)
        XCTAssertEqual(one.segments, 1)
        XCTAssertEqual(one.remaining, 0)
        let two = SmsSegments(String(repeating: "a", count: 161))
        XCTAssertEqual(two.segments, 2)
        XCTAssertEqual(two.remaining, 306 - 161)
        XCTAssertEqual(SmsSegments(String(repeating: "a", count: 1530)).segments, 10)
        XCTAssertTrue(SmsSegments(String(repeating: "a", count: 1531)).isTooLong)
    }

    func testCrlfIsTwoGsmCharacters() {
        let s = SmsSegments("a\r\nb")
        XCTAssertEqual(s.encoding, .gsm7)
        XCTAssertEqual(s.units, 4)
        XCTAssertEqual(SmsSegments(String(repeating: "\r\n", count: 80)).segments, 1) // 160 septets
        XCTAssertEqual(SmsSegments(String(repeating: "\r\n", count: 81)).segments, 2)
    }

    func testGsmExtensionCharactersCountTwice() {
        let s = SmsSegments("€")
        XCTAssertEqual(s.encoding, .gsm7)
        XCTAssertEqual(s.units, 2)
    }

    func testUnicodeFallsBackToUcs2() {
        let s = SmsSegments("héllo 😀")
        XCTAssertEqual(s.encoding, .ucs2)
        XCTAssertEqual(s.segments, 1)
        XCTAssertEqual(SmsSegments(String(repeating: "😀", count: 36)).segments, 2) // 72 units
        XCTAssertEqual(SmsSegments(String(repeating: "あ", count: 71)).segments, 2)
    }

    func testE164() {
        XCTAssertEqual(MessageNumber.e164("(303) 555-0100"), "+13035550100")
        XCTAssertEqual(MessageNumber.e164("1 303 555 0100"), "+13035550100")
        XCTAssertEqual(MessageNumber.e164("+44 20 7946 0958"), "+442079460958")
        XCTAssertNil(MessageNumber.e164("555-0100"))
        XCTAssertNil(MessageNumber.e164(""))
    }

    func testSmsReceivedEvent() {
        let json = #"{"type":"sms_received","tenant_id":"t","did_id":"d","message_id":"m","remote_number":"+13035550100","extension_ids":[]}"#
        XCTAssertEqual(SmsReceivedEvent.parse(json),
                       SmsReceivedEvent(tenantId: "t", didId: "d", messageId: "m", remoteNumber: "+13035550100"))
        XCTAssertNil(SmsReceivedEvent.parse(#"{"type":"pong"}"#))
        XCTAssertNil(SmsReceivedEvent.parse("nope"))
    }

    func testNotificationTarget() {
        let info: [AnyHashable: Any] = ["type": "sms", "tenant_id": "ABC", "did_id": "d1",
                                        "remote_number": "+13035550100", "message_id": "m"]
        XCTAssertEqual(SmsNotificationTarget.parse(info, tenantId: "abc"),
                       SmsNotificationTarget(didId: "d1", remoteNumber: "+13035550100"))
        XCTAssertNil(SmsNotificationTarget.parse(info, tenantId: "other"))
        XCTAssertNil(SmsNotificationTarget.parse(info, tenantId: ""))
        var wrong = info
        wrong["type"] = "call"
        XCTAssertNil(SmsNotificationTarget.parse(wrong, tenantId: "abc"))
    }

    func testReadMarks() {
        let defaults = UserDefaults(suiteName: "MessagingTests-\(UUID().uuidString)")!
        let marks = MessageReadMarks(defaults: defaults)
        func conversation(_ at: Date, _ direction: String = "inbound") -> PbxApiClient.MessagingConversation {
            let json = """
            {"remote_number":"+1","message_count":1,"last_body":"hi","last_direction":"\(direction)",
             "last_status":"received","last_at":"\(ISO8601DateFormatter().string(from: at))",
             "last_has_media":false,"opted_out":false}
            """
            return try! PbxApiClient.jsonDecoder.decode(PbxApiClient.MessagingConversation.self, from: Data(json.utf8))
        }
        let old = conversation(Date().addingTimeInterval(-3600))
        XCTAssertFalse(marks.isUnread(didId: "d", conversation: old), "before the first run is read")
        let fresh = conversation(Date().addingTimeInterval(60))
        XCTAssertTrue(marks.isUnread(didId: "d", conversation: fresh))
        XCTAssertFalse(marks.isUnread(didId: "d", conversation: conversation(Date().addingTimeInterval(60), "outbound")))
        marks.markRead(didId: "d", number: "+1", at: Date().addingTimeInterval(120))
        XCTAssertFalse(marks.isUnread(didId: "d", conversation: fresh))
    }

    func testDecodesThreadAndStatuses() throws {
        let json = """
        {"remote_number":"+13035550100","opted_out":false,"messages":[
          {"id":"1","direction":"outbound","from_number":"+1","to_number":"+2","remote_number":"+13035550100",
           "body":"hi","status":"failed","error_message":"carrier refused","created_at":"2026-11-25T10:00:00.123Z",
           "attachments":[{"id":"a","content_type":"image/jpeg","size_bytes":10}]},
          {"id":"2","direction":"inbound","remote_number":"+13035550100","body":"yo","status":"received",
           "error_message":null,"created_at":"2026-11-25T09:00:00Z"}]}
        """
        let thread = try PbxApiClient.jsonDecoder.decode(PbxApiClient.MessagingThread.self, from: Data(json.utf8))
        XCTAssertEqual(thread.messages.count, 2)
        XCTAssertEqual(thread.messages[0].errorMessage, "carrier refused")
        XCTAssertTrue(thread.messages[0].attachments[0].isImage)
        XCTAssertTrue(thread.messages[0].isOutbound)
        XCTAssertTrue(thread.messages[1].attachments.isEmpty)
    }

    func testEventStreamURLIsWssWithoutToken() throws {
        let url = try PbxApiClient(baseUrl: "https://api.example.com/").eventStreamURL()
        XCTAssertEqual(url.absoluteString, "wss://api.example.com/api/v1/ws")
        XCTAssertThrowsError(try PbxApiClient(baseUrl: "ftp://x").eventStreamURL())
    }
}

@MainActor
final class MessagingServiceTests: XCTestCase {
    final class FakeBackend: MessagingBackend {
        var sentKeys: [String] = []
        var sendError: Error?
        var extraInbox = false
        var failingConversations: Set<String> = []
        var inboxDelay: UInt64 = 0
        var inboxCalls = 0
        var threadCalls = 0
        let inbox = PbxApiClient.MessagingInbox(didId: "d1", number: "+13035550000", lastInboundAt: nil, enabled: true)

        func inboxes() async throws -> [PbxApiClient.MessagingInbox] {
            inboxCalls += 1
            if inboxDelay > 0 { try await Task.sleep(nanoseconds: inboxDelay) }
            return extraInbox
                ? [inbox, PbxApiClient.MessagingInbox(didId: "d2", number: "+13035551111", lastInboundAt: nil, enabled: true)]
                : [inbox]
        }
        func conversations(didId: String) async throws -> [PbxApiClient.MessagingConversation] {
            if failingConversations.contains(didId) { throw PbxApiClient.ApiError.httpError(statusCode: 404, message: "gone") }
            return []
        }
        func thread(didId: String, number: String) async throws -> PbxApiClient.MessagingThread {
            threadCalls += 1
            return try PbxApiClient.jsonDecoder.decode(
                PbxApiClient.MessagingThread.self,
                from: Data(#"{"remote_number":"+13035550100","opted_out":false,"messages":[]}"#.utf8))
        }
        func send(didId: String, to: String, body: String, attachmentIds: [String],
                  idempotencyKey: String) async throws -> PbxApiClient.MessagingMessage {
            sentKeys.append(idempotencyKey)
            if let sendError { throw sendError }
            return PbxApiClient.MessagingMessage(id: "m", direction: "outbound", body: body, status: "sent",
                                                 createdAt: Date(), remoteNumber: to)
        }
        func upload(data: Data, filename: String, contentType: String) async throws -> PbxApiClient.MessagingAttachment {
            throw PbxApiClient.ApiError.emptyResponse
        }
        func attachmentData(id: String) async throws -> Data { Data() }
        func eventStreamRequest() async throws -> URLRequest? { nil }
    }

    private func service(_ backend: FakeBackend) -> MessagingService {
        let defaults = UserDefaults(suiteName: "MessagingServiceTests-\(UUID().uuidString)")!
        return MessagingService(backend: backend, readMarks: MessageReadMarks(defaults: defaults))
    }

    func testRefreshLoadsInboxes() async {
        let s = service(FakeBackend())
        XCTAssertFalse(s.hasInbox)
        await s.refresh()
        XCTAssertTrue(s.hasInbox)
        XCTAssertEqual(s.sendableInboxes.count, 1)
    }

    func testSendPassesIdempotencyKeyAndReloadsThread() async throws {
        let backend = FakeBackend()
        let s = service(backend)
        try await s.send(didId: "d1", to: "+13035550100", body: "hi", attachment: nil)
        XCTAssertEqual(backend.sentKeys.count, 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(backend.threadCalls, 1)
    }

    func testSendErrorCarriesServerMessage() async {
        let backend = FakeBackend()
        backend.sendError = PbxApiClient.ApiError.httpError(statusCode: 422, message: "recipient opted out")
        let s = service(backend)
        do {
            try await s.send(didId: "d1", to: "+1", body: "x", attachment: nil)
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("recipient opted out"))
        }
    }

    func testOpenedThreadCountsRead() async {
        let s = service(FakeBackend())
        s.opened(.init(didId: "d1", remoteNumber: "+13035550100"))
        s.reset()
        XCTAssertFalse(s.hasInbox)
    }

    func testOneFailingInboxDoesNotFailRefresh() async {
        let backend = FakeBackend()
        backend.extraInbox = true
        backend.failingConversations = ["d1"]
        let s = service(backend)
        await s.refresh()
        XCTAssertEqual(s.inboxes.count, 2)
        XCTAssertNotNil(s.conversations["d2"])
        XCTAssertNotNil(s.errorMessage)
    }

    func testRefreshDuringRefreshIsQueued() async throws {
        let backend = FakeBackend()
        backend.inboxDelay = 100_000_000
        let s = service(backend)
        let first = Task { await s.refresh() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await s.refresh() // returns at once, queued
        await first.value
        XCTAssertEqual(backend.inboxCalls, 2)
    }

    func testUnansweredSendKeepsKeyAndAnsweredSendDropsIt() async throws {
        let backend = FakeBackend()
        let s = service(backend)
        let thread = MessagingService.ThreadKey(didId: "d1", remoteNumber: "+13035550100")
        backend.sendError = URLError(.notConnectedToInternet)
        _ = try? await s.send(didId: "d1", to: thread.remoteNumber, body: "hi", attachment: nil)
        XCTAssertNotNil(s.pendingSend(for: thread))
        backend.sendError = nil
        try await s.send(didId: "d1", to: thread.remoteNumber, body: "hi", attachment: nil)
        XCTAssertEqual(backend.sentKeys.count, 2)
        XCTAssertEqual(backend.sentKeys[0], backend.sentKeys[1], "a retry reuses the key")
        XCTAssertNil(s.pendingSend(for: thread))
        backend.sendError = PbxApiClient.ApiError.httpError(statusCode: 422, message: "no")
        _ = try? await s.send(didId: "d1", to: thread.remoteNumber, body: "hi", attachment: nil)
        XCTAssertNil(s.pendingSend(for: thread), "a refusal ends the attempt")
    }

    func testNotificationOpensOnlyKnownInbox() async {
        let s = service(FakeBackend())
        await s.openFromNotification(.init(didId: "nope", remoteNumber: "+13035550100"))
        XCTAssertNil(s.pendingThread)
        await s.openFromNotification(.init(didId: "d1", remoteNumber: "not a number"))
        XCTAssertNil(s.pendingThread)
        await s.openFromNotification(.init(didId: "d1", remoteNumber: "+13035550100"))
        XCTAssertEqual(s.pendingThread, .init(didId: "d1", remoteNumber: "+13035550100"))
    }
}
