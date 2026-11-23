import Foundation

/// Launches the app on canned data, with no network, no engine and no system
/// prompts, for UI tests and screenshots.
///
///     -UITestMode                  fixture data, app opens on the Dialer
///     -ScreenshotMode              the same; the name screenshot scripts use
///     -FixtureScene <scene>        open on one screen of DESIGN.md §8,
///                                  e.g. `-FixtureScene in-call`
///
/// DEBUG builds only: in Release `isActive` is always false and the fixture
/// data is not compiled in. The data lives in `FixtureData`, the stand-in
/// services in `FixtureBackends.swift`, and `FixtureBootstrap.apply()` installs
/// them at launch. To add a scene, add a case here, set it up in
/// `FixtureBootstrap`, and open it from the view that owns it.
enum FixtureMode {
    static let activatingArguments: Set<String> = ["-UITestMode", "-ScreenshotMode"]
    static let sceneArgument = "-FixtureScene"

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

    /// The DESIGN.md §8 file number, e.g. "05".
    var number: String {
        let index = Self.allCases.firstIndex(of: self)! + 1
        return String(format: "%02d", index)
    }

    /// Whether the scene needs a signed-in account (all but onboarding).
    var isSignedIn: Bool { self != .onboarding }
}
