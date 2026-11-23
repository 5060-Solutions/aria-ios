import Foundation
import Combine
import UserNotifications

/// Keeps what the PBX knows fresh while the app is in use: unread voicemail
/// (message waiting) on coming to the foreground, every 60 s while active,
/// and after each call; server call history and DND/forwarding alongside.
/// Mirrors the unread count onto the app icon badge unless turned off.
@MainActor
final class ActivityRefresher {
    static let shared = ActivityRefresher()

    static let badgeSettingKey = "showVoicemailBadge"
    static let interval: TimeInterval = 60

    /// Sets the icon badge. Replaced in tests.
    var setBadge: (Int) -> Void = { count in
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error = error { print("Badge update failed: \(error)") }
        }
    }
    /// Whether an account is signed in to refresh for.
    var isSignedIn: () -> Bool = { AccountSettings.load().isProvisioned }

    private let voicemail: VoicemailService
    private let selfService: SelfService
    private let defaults: UserDefaults
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var callEndObserver: NSObjectProtocol?
    private(set) var refreshCount = 0

    init(voicemail: VoicemailService = .shared, selfService: SelfService = .shared,
         defaults: UserDefaults = .standard) {
        self.voicemail = voicemail
        self.selfService = selfService
        self.defaults = defaults
        // The badge follows the unread count however it changes: a refresh,
        // a message played or deleted.
        voicemail.$messages
            .map { $0.filter { !$0.read }.count }
            .removeDuplicates()
            .sink { [weak self] unread in self?.updateBadge(unread: unread) }
            .store(in: &subscriptions)
        callEndObserver = NotificationCenter.default.addObserver(
            forName: CallManager.callEndedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.callEnded() }
        }
    }

    var badgeEnabled: Bool {
        get { defaults.object(forKey: Self.badgeSettingKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.badgeSettingKey)
            updateBadge(unread: voicemail.unreadCount)
        }
    }

    /// The app came to the foreground: refresh now and every minute.
    func becameActive() {
        refreshAll()
        CallerNames.shared.reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVoicemail() }
        }
    }

    /// Backgrounded: stop polling. Incoming calls still arrive by push.
    func resignedActive() {
        timer?.invalidate()
        timer = nil
    }

    var isPolling: Bool { timer != nil }

    /// After a call the caller may have left a message, and the PBX has a
    /// new call record.
    func callEnded() {
        guard isSignedIn() else { return }
        refreshVoicemail()
        Task { await selfService.syncCallHistory() }
    }

    func refreshAll() {
        guard isSignedIn() else {
            updateBadge(unread: 0)
            return
        }
        refreshVoicemail()
        Task {
            await selfService.refresh()
            await selfService.syncCallHistory()
        }
    }

    func refreshVoicemail() {
        guard isSignedIn() else { return }
        refreshCount += 1
        Task { await voicemail.refresh() }
    }

    func updateBadge(unread: Int) {
        setBadge(badgeEnabled && isSignedIn() ? unread : 0)
    }
}
