import ActivityKit
import Foundation
import SwiftUI

/// The Live Activity of a Hold for me wait. A member of both the app and the
/// AriaHoldActivity extension; it carries no secrets and shares no storage.
struct HoldWaitAttributes: ActivityAttributes {
    let holdWaitId: String
    let callId: String
    let startedAt: Date
    let remoteName: String

    struct ContentState: Codable, Hashable {
        /// `waiting`, `human_detected`, `ringing` or `joined` (the PBX's
        /// `requested` is shown as `waiting`).
        var state: String
        var stateSince: Date
    }
}

extension HoldWaitAttributes.ContentState {
    /// The line under the timer: someone answered, or the phone is ringing.
    /// nil while the wait is simply waiting.
    var statusLine: LocalizedStringResource? {
        switch state {
        case "human_detected": return "Someone answered"
        case "ringing": return "Ringing you…"
        default: return nil
        }
    }
}

extension HoldWaitAttributes {
    /// The deep link the activity's Cancel opens in the app.
    static func cancelURL(_ holdWaitId: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "aria"
        parts.host = "hold-for-me"
        parts.path = "/" + holdWaitId
        parts.queryItems = [URLQueryItem(name: "action", value: "cancel")]
        return parts.url ?? URL(string: "aria://hold-for-me")!
    }
}
