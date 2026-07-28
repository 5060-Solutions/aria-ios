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

    func applicationWillTerminate(_ application: UIApplication) {
        shutdownRuntime()
    }
}
