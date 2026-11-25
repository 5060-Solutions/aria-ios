import XCTest

/// Launches the app in fixture mode (canned data, no network, no engine) on
/// a given scene. Assertions use accessibility identifiers and tab indexes,
/// never visible text, so restyling and localization do not break them.
class AriaUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    func launch(_ scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-FixtureScene", scene]
        app.launch()
        self.app = app
        return app
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The tab bar's buttons in order: Dialer, History, Contacts, Voicemail,
    /// Settings.
    /// On an iPad at regular width the sections are the sidebar's rows
    /// instead (`sidebar.<section>`).
    func tab(_ index: Int) -> XCUIElement {
        if isSidebarLayout { return element("sidebar.\(Self.sections[index])") }
        return app.tabBars.buttons.element(boundBy: index)
    }

    static let sections = ["dialer", "history", "contacts", "voicemail", "settings"]

    var isSidebarLayout: Bool { app.tabBars.count == 0 }

    var sectionCount: Int {
        isSidebarLayout ? Self.sections.count : app.tabBars.buttons.count
    }

    /// Fails if SpringBoard is showing a permission alert: fixture mode must
    /// never ask for anything.
    func assertNoSystemAlert(file: StaticString = #filePath, line: UInt = #line) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2),
                       "a system alert is showing: \(springboard.alerts.firstMatch.label)",
                       file: file, line: line)
    }
}
