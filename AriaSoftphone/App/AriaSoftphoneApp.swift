import SwiftUI
import PushKit
import UserNotifications

@main
struct AriaSoftphoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var callManager = CallManager.shared
    @StateObject private var sipEngine = SipEngineManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(callManager)
                .environmentObject(sipEngine)
                .modifier(DeepLinkHandling())
                .modifier(CallNotices())
                .modifier(CallMoveOverlays())
        }
    }
}

/// UIKit App Delegate for push notification registration and lifecycle.
class AppDelegate: NSObject, UIApplicationDelegate {
    let pushRegistry = PKPushRegistry(queue: DispatchQueue.main)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        // UI tests and screenshots: canned data, no engine, no network, no
        // push registration, no permission prompts.
        if let scene = FixtureMode.scene {
            MainActor.assumeIsolated { FixtureBootstrap.apply(scene: scene) }
            return true
        }
        #endif

        // Migrate any secrets left in UserDefaults by older builds into the
        // Keychain, then scrub them. Runs once; a no-op thereafter.
        KeychainStore.migrateLegacyDefaultsIfNeeded()

        // Initialize the Rust runtime
        initRuntime()

        // Rebuild the SIP engine from the stored account. Without this the
        // engine existed only after an interactive login, so a relaunched app
        // could neither place calls nor fetch an incoming call's offer.
        SipEngineManager.shared.restoreSessionInBackground()

        // Tell the core about every network change (Wi-Fi <-> cellular, a
        // new address, the network coming back) so it re-checks its gateway
        // connection at once instead of on its next heartbeat.
        SipEngineManager.shared.startNetworkMonitoring()

        // Register for VoIP pushes. PushKit is the incoming-call path
        // whatever the state of the gateway connection or the network
        // monitor: the delegate is set here, synchronously, so a push that
        // cold-launched the app is delivered and reported to CallKit before
        // any engine restore finishes.
        pushRegistry.delegate = PushHandler.shared
        pushRegistry.desiredPushTypes = [.voIP]

        // Local notifications (missed calls) are shown in the foreground
        // too. Permission is asked for after sign-in, not here.
        UNUserNotificationCenter.current().delegate = self

        // The regular APNs token, for text-message alerts (PushKit above stays
        // the call path). Needs no permission: whether an alert shows is the
        // notification authorization, asked for after sign-in.
        application.registerForRemoteNotifications()

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        SipEngineManager.shared.updateAlertToken(ApnsToken.hex(deviceToken))
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs alert registration failed: \(error)")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !FixtureMode.isActive else { return }
        // A launch-time restore can fail while the device is locked or
        // offline, and a backgrounded app's gateway connection may have gone
        // stale; coming to the foreground is the natural retry. The restore
        // is a no-op once the engine is registered.
        SipEngineManager.shared.reconnect()
        // Voicemail (and the badge), server history, DND and forwarding:
        // now, then every minute while active.
        MainActor.assumeIsolated {
            ActivityRefresher.shared.becameActive()
            MessagingService.shared.becameActive()
            CallMoveModel.shared.becameActive()
            // The flag from /me, and the waits the PBX still has open: one
            // may have ended while the app was away.
            Task { await HoldForMeModel.shared.becameActive() }
            Task { await Proximity.shared.becameActive() }
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
        guard !FixtureMode.isActive else { return }
        MainActor.assumeIsolated {
            ActivityRefresher.shared.resignedActive()
            MessagingService.shared.resignedActive()
            CallMoveModel.shared.resignedActive()
            Proximity.shared.resignedActive()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        guard !FixtureMode.isActive else { return }
        shutdownRuntime()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// A tap on a text-message notification opens its thread.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let tenantId = UserDefaults.standard.string(forKey: AccountSettings.Key.tenantId) ?? ""
        if let target = SmsNotificationTarget.parse(userInfo, tenantId: tenantId) {
            Task { @MainActor in await MessagingService.shared.openFromNotification(target) }
        }
        completionHandler()
    }
}
