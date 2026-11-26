import Foundation

/// Launches the app on canned data, with no network, no engine and no system
/// prompts, for UI tests and screenshots.
///
///     -UITestMode                  fixture data, app opens on the Dialer
///     -ScreenshotMode              the same; the name screenshot scripts use
///     -FixtureScene <scene>        open on one screen of DESIGN.md §8,
///                                  e.g. `-FixtureScene in-call`
///     -FixtureScanner              onboarding opens straight into the QR
///                                  scanner (review shots of its overlay)
///     -FixtureReconnecting         the core is recovering after a network
///                                  change (the amber "Reconnecting…" chip)
///
/// DEBUG builds only: in Release `isActive` is always false and the fixture
/// data is not compiled in. The data lives in `FixtureData`, the stand-in
/// services in `FixtureBackends.swift`, and `FixtureBootstrap.apply()` installs
/// them at launch. To add a scene, add a case here, set it up in
/// `FixtureBootstrap`, and open it from the view that owns it.
enum FixtureMode {
    static let activatingArguments: Set<String> = ["-UITestMode", "-ScreenshotMode"]
    static let sceneArgument = "-FixtureScene"
    static let reconnectingArgument = "-FixtureReconnecting"
    /// Turns the Hold for me flag off; fixtures offer it otherwise.
    static let noHoldForMeArgument = "-FixtureNoHoldForMe"

    /// Whether the fixture's `/me` offers Hold for me (DEBUG only).
    static var offersHoldForMe: Bool {
        #if DEBUG
        return isActive && !ProcessInfo.processInfo.arguments.contains(noHoldForMeArgument)
        #else
        return false
        #endif
    }

    /// Whether onboarding opens the QR scanner at once (DEBUG only).
    static var opensScanner: Bool {
        #if DEBUG
        return isActive && ProcessInfo.processInfo.arguments.contains("-FixtureScanner")
        #else
        return false
        #endif
    }

    /// Whether the fixture shows the core recovering (DEBUG only).
    static var isReconnecting: Bool {
        #if DEBUG
        return isActive && ProcessInfo.processInfo.arguments.contains(reconnectingArgument)
        #else
        return false
        #endif
    }

    /// True when the app was launched with a fixture argument (DEBUG only).
    static var isActive: Bool {
        #if DEBUG
        return launch.isActive
        #else
        return false
        #endif
    }

    /// The screen to open on; nil outside fixture mode.
    static var scene: FixtureScene? {
        #if DEBUG
        return launch.isActive ? launch.scene : nil
        #else
        return nil
        #endif
    }

    /// Whether the app is in fixture mode and showing `scene`.
    static func shows(_ scene: FixtureScene) -> Bool {
        self.scene == scene
    }

    /// Parse launch arguments. Separate from `ProcessInfo` so it can be tested.
    static func parse(_ arguments: [String]) -> (isActive: Bool, scene: FixtureScene) {
        let isActive = arguments.contains { activatingArguments.contains($0) }
        var scene = FixtureScene.dialer
        if let index = arguments.firstIndex(of: sceneArgument),
           arguments.indices.contains(index + 1),
           let parsed = FixtureScene(rawValue: arguments[index + 1]) {
            scene = parsed
        }
        return (isActive, scene)
    }

    #if DEBUG
    private static let launch = parse(ProcessInfo.processInfo.arguments)
    #endif
}

/// The review screens of DESIGN.md §8. Raw values are the screenshot names.
enum FixtureScene: String, CaseIterable {
    case onboarding
    case dialer
    case dialerNumber = "dialer-number"
    case incomingCall = "incoming-call"
    case inCall = "in-call"
    case inCallTwoCalls = "in-call-two-calls"
    case history
    case contacts
    case voicemail
    case voicemailPlaying = "voicemail-playing"
    case settings
    case forwarding
    case connectionSheet = "connection-sheet"
    /// Extra: the in-call screen for a call whose media is not encrypted
    /// (the amber capsule and the one-time notice).
    case inCallUnencrypted = "in-call-unencrypted"
    /// Extra: the in-call screen with Hold for me in the overflow.
    case inCallHoldForMe = "in-call-hold-for-me"
    /// Extra: the Hold for me waiting card above the Dialer.
    case holdWaiting = "hold-waiting"

    /// The DESIGN.md §8 file number, e.g. "05". An extra takes the number of
    /// the screen it is a variant of.
    var number: String {
        if self == .inCallUnencrypted || self == .inCallHoldForMe { return Self.inCall.number }
        if self == .holdWaiting { return Self.dialer.number }
        let index = Self.allCases.firstIndex(of: self)! + 1
        return String(format: "%02d", index)
    }

    /// Whether the scene needs a signed-in account (all but onboarding).
    var isSignedIn: Bool { self != .onboarding }
}
