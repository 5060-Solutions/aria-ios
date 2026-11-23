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

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !FixtureMode.isActive else { return }
        // A launch-time restore can fail while the device is locked or
        // offline, and a backgrounded app's gateway connection may have gone
        // stale; coming to the foreground is the natural retry. The restore
        // is a no-op once the engine is registered.
        SipEngineManager.shared.reconnect()
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
}
