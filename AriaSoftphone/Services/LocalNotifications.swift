import Foundation
import UserNotifications

/// Local notifications for what iOS does not announce for a VoIP app: a call
/// missed while the app was in the background. CallKit puts the call in the
/// Phone app's Recents but posts no "Missed call" alert of its own.
///
/// Permission is asked for once, after the first successful sign-in, when
/// there is something to notify about, rather than at first launch.
enum LocalNotifications {
    static let missedCallCategory = "MISSED_CALL"

    /// Ask for alert, sound and badge permission if it has never been asked.
    static func requestAuthorizationIfNeeded(center: UNUserNotificationCenter = .current()) {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                if let error = error {
                    print("Notification authorization failed: \(error)")
                }
            }
        }
    }

    /// The content of a missed-call alert.
    static func missedCallContent(remoteUri: String, remoteName: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Missed call")
        let name = remoteName.flatMap { $0.isEmpty ? nil : $0 }
        if let name = name, name != remoteUri {
            content.body = "\(name) (\(remoteUri))"
        } else {
            content.body = remoteUri
        }
        content.sound = .default
        content.categoryIdentifier = missedCallCategory
        content.threadIdentifier = missedCallCategory
        content.userInfo = ["remoteUri": remoteUri]
        return content
    }

    /// Post a missed-call alert. Dropped silently when the user has not
    /// allowed notifications.
    static func postMissedCall(remoteUri: String, remoteName: String?, center: UNUserNotificationCenter = .current()) {
        let request = UNNotificationRequest(
            identifier: "missed-\(UUID().uuidString)",
            content: missedCallContent(remoteUri: remoteUri, remoteName: remoteName),
            trigger: nil
        )
        center.add(request) { error in
            if let error = error {
                print("Could not post missed-call notification: \(error)")
            }
        }
    }

    /// Missed-call alerts are stale once the user has opened History.
    static func clearMissedCalls(center: UNUserNotificationCenter = .current()) {
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.categoryIdentifier == missedCallCategory }
                .map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
