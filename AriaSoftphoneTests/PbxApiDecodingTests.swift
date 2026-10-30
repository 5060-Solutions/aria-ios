import XCTest
@testable import AriaSoftphone

/// Shapes from aria-api's voicemail handlers (`VoicemailMessage` in aria-db).
final class PbxApiDecodingTests: XCTestCase {

    func testDecodesVoicemailMessages() throws {
        let json = """
        [
          {"id": "6f1c0e8e-0000-4000-8000-000000000001", "box_id": "b0x", "tenant_id": "t",
           "caller_id": "+15551234567", "duration_secs": 37, "recording_url": "/spool/a.wav",
           "storage_key": null, "read": false, "created_at": "2026-10-29T14:03:07.123456Z",
           "transcription": "Call me back", "transcription_language": "en"},
          {"id": "6f1c0e8e-0000-4000-8000-000000000002", "box_id": "b0x", "tenant_id": "t",
           "caller_id": "", "duration_secs": 3, "recording_url": "/spool/b.wav",
           "read": true, "created_at": "2026-10-29T14:03:07Z", "transcription": null}
        ]
        """
        let messages = try PbxApiClient.jsonDecoder.decode(
            [PbxApiClient.VoicemailMessage].self, from: Data(json.utf8)
        )
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].callerId, "+15551234567")
        XCTAssertEqual(messages[0].durationSecs, 37)
        XCTAssertFalse(messages[0].read)
        XCTAssertEqual(messages[0].transcription, "Call me back")
        XCTAssertTrue(messages[1].read)
        XCTAssertNil(messages[1].transcription)
        XCTAssertEqual(messages[1].createdAt.timeIntervalSince1970, 1_793_282_587, accuracy: 1)
    }

    func testDecodesIdentity() throws {
        let withExtension = try PbxApiClient.jsonDecoder.decode(
            PbxApiClient.Identity.self,
            from: Data(#"{"subject":"s","tenant_id":"t","role":"user","is_superadmin":false,"tenants":["t"],"acting_extension":"e1","acting_extension_number":"1001"}"#.utf8)
        )
        XCTAssertEqual(withExtension.actingExtension, "e1")

        let withoutExtension = try PbxApiClient.jsonDecoder.decode(
            PbxApiClient.Identity.self,
            from: Data(#"{"subject":"s","tenant_id":"t","role":"admin","is_superadmin":false,"tenants":[]}"#.utf8)
        )
        XCTAssertNil(withoutExtension.actingExtension)
    }
}
