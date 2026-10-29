import SwiftUI
import PushKit

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
        // Migrate any secrets left in UserDefaults by older builds into the
        // Keychain, then scrub them. Runs once; a no-op thereafter.
        KeychainStore.migrateLegacyDefaultsIfNeeded()

        // Initialize the Rust runtime
        initRuntime()

        // Rebuild the SIP engine from the stored account. Without this the
        // engine existed only after an interactive login, so a relaunched app
        // could neither place calls nor fetch an incoming call's offer.
        SipEngineManager.shared.restoreSessionInBackground()

        // Register for VoIP pushes
        pushRegistry.delegate = PushHandler.shared
        pushRegistry.desiredPushTypes = [.voIP]

        // Register for regular remote notifications (for non-VoIP alerts)
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                print("Notification auth error: \(error)")
            }
            print("Notification permission granted: \(granted)")
        }

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // A launch-time restore can fail while the device is locked or
        // offline; coming to the foreground is the natural retry. A no-op
        // once the engine is registered.
        SipEngineManager.shared.restoreSessionInBackground()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        shutdownRuntime()
    }
}
