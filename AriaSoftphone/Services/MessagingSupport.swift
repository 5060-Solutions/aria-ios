import Foundation

// Pure helpers for texting: segment counting, number normalisation, the
// server's live event, and the push payload that opens a thread. No I/O, so
// each is covered by unit tests.

// MARK: - Segments

/// How many SMS segments a body takes, by the rules the server enforces:
/// GSM-7 is 160 characters, then 153 a part; anything else is UCS-2, 70, then
/// 67. At most `maxSegments`, and at most `maxBodyLength` characters.
struct SmsSegments: Equatable {
    enum Encoding: Equatable { case gsm7, ucs2 }

    static let maxSegments = 10
    static let maxBodyLength = 1600

    let encoding: Encoding
    /// Code units used: GSM-7 septets (extension characters count twice) or
    /// UTF-16 units.
    let units: Int
    let segments: Int
    /// Units left in the segment in progress.
    let remaining: Int

    var isTooLong: Bool { segments > Self.maxSegments }

    init(_ text: String) {
        let septets = Self.gsmLength(text)
        if let septets {
            encoding = .gsm7
            units = septets
            let (single, multi) = (160, 153)
            segments = septets == 0 ? 0 : (septets <= single ? 1 : (septets + multi - 1) / multi)
            let capacity = segments <= 1 ? single : segments * multi
            remaining = capacity - septets
        } else {
            encoding = .ucs2
            let count = text.utf16.count
            units = count
            let (single, multi) = (70, 67)
            segments = count == 0 ? 0 : (count <= single ? 1 : (count + multi - 1) / multi)
            let capacity = segments <= 1 ? single : segments * multi
            remaining = capacity - count
        }
    }

    private static let gsmBasic: Set<Unicode.Scalar> = Set(
        "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà".unicodeScalars
    )
    private static let gsmExtension: Set<Unicode.Scalar> = Set("^{}\\[~]|€\u{0C}".unicodeScalars)

    /// Septets for a GSM-7 body, nil when any character forces UCS-2.
    private static func gsmLength(_ text: String) -> Int? {
        var total = 0
        // Scalars, not graphemes: "\r\n" is one Character but two GSM-7
        // characters, as the server counts them.
        for scalar in text.unicodeScalars {
            if gsmBasic.contains(scalar) {
                total += 1
            } else if gsmExtension.contains(scalar) {
                total += 2
            } else {
                return nil
            }
        }
        return total
    }
}

// MARK: - Numbers

enum MessageNumber {
    /// A typed number in the strict E.164 the send route requires
    /// (`+13035550100`), or nil. A bare 10-digit or 1-prefixed 11-digit
    /// number is North American, as the app's dialer reads it.
    static func e164(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isASCIIDigit)
        if trimmed.hasPrefix("+") {
            return (8...15).contains(digits.count) ? "+" + digits : nil
        }
        switch digits.count {
        case 10: return "+1" + digits
        case 11 where digits.hasPrefix("1"): return "+" + digits
        default: return nil
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Live event

/// `{"type":"sms_received", ...}` from the API's event stream. It carries ids
/// only; the thread is fetched through the API.
struct SmsReceivedEvent: Equatable {
    let tenantId: String
    let didId: String
    let messageId: String
    let remoteNumber: String

    static func parse(_ text: String) -> SmsReceivedEvent? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "sms_received",
              let tenantId = json["tenant_id"] as? String,
              let didId = json["did_id"] as? String,
              let messageId = json["message_id"] as? String else { return nil }
        return SmsReceivedEvent(tenantId: tenantId, didId: didId, messageId: messageId,
                                remoteNumber: json["remote_number"] as? String ?? "")
    }
}

// MARK: - Push payload

/// What a text-message notification opens: `{type: "sms", tenant_id, did_id,
/// remote_number, message_id}`.
struct SmsNotificationTarget: Equatable {
    let didId: String
    let remoteNumber: String

    /// Nil unless the payload is an `sms` one for the signed-in tenant, so a
    /// notification left over from another account opens nothing.
    static func parse(_ userInfo: [AnyHashable: Any], tenantId: String) -> SmsNotificationTarget? {
        func string(_ key: String) -> String? {
            (userInfo[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard string("type") == "sms",
              let pushedTenant = string("tenant_id"),
              !tenantId.isEmpty,
              pushedTenant.lowercased() == tenantId.lowercased(),
              let didId = string("did_id"),
              let remote = string("remote_number") else { return nil }
        return SmsNotificationTarget(didId: didId, remoteNumber: remote)
    }
}

// MARK: - Unread

/// Which conversations have text the person has not seen. The server keeps no
/// read state, so the device does: the time each conversation was last
/// opened. Text that predates the first run is taken as read.
struct MessageReadMarks {
    private let defaults: UserDefaults
    private let key = "messagingReadMarks"
    private let baselineKey = "messagingReadBaseline"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: baselineKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: baselineKey)
        }
    }

    private func mark(_ didId: String, _ number: String) -> String { "\(didId)|\(number)" }

    func isUnread(didId: String, conversation: PbxApiClient.MessagingConversation) -> Bool {
        guard conversation.lastDirection == "inbound" else { return false }
        let marks = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let baseline = defaults.double(forKey: baselineKey)
        let seen = max(marks[mark(didId, conversation.remoteNumber)] ?? 0, baseline)
        return conversation.lastAt.timeIntervalSince1970 > seen
    }

    func markRead(didId: String, number: String, at date: Date = Date()) {
        var marks = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        marks[mark(didId, number)] = date.timeIntervalSince1970
        defaults.set(marks, forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: baselineKey)
    }
}
