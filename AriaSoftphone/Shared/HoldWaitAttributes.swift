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

/// The one mapping from a wait's PBX state to what the card and the Live
/// Activity show. A joined wait is not shown (the user is on the call; Cancel
/// would hang it up), nor an ended one; `requested` reads as waiting.
enum HoldWaitPresentation {
    /// The state to show, or nil when the wait is not shown at all.
    static func shownState(_ state: String) -> String? {
        switch state {
        case "joined", "ended": return nil
        case "human_detected", "ringing": return state
        // `requested`, `waiting`, and anything newer the PBX still lists as
        // open.
        default: return "waiting"
        }
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
    /// The deep link a tap anywhere on the activity opens: the app, nothing
    /// more.
    static func openURL(_ holdWaitId: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "aria"
        parts.host = "hold-for-me"
        parts.path = "/" + holdWaitId
        return parts.url ?? URL(string: "aria://hold-for-me")!
    }

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
