import XCTest

final class HoldForMeUITests: AriaUITestCase {
    func testHoldForMeIsInTheOverflowAndStartsWithTheChosenGreeting() {
        launch("in-call-hold-for-me")
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 5))
        element("call.more").tap()
        element("call.holdForMe").tap()
        XCTAssertTrue(element("holdForMe.greeting.silence").waitForExistence(timeout: 5))
        // The assistant row is enabled once the settings have loaded.
        let assistant = element("holdForMe.greeting.assistant")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: assistant)
        waitForExpectations(timeout: 5)
        assistant.tap()
        element("holdForMe.start").tap()
        XCTAssertTrue(fixtureEvent("holdForMe.started:assistant"))
        XCTAssertTrue(element("holdForMe.start").waitForNonExistence(timeout: 5), "the sheet closes")
    }

    func testStartingWithoutAPickLeavesTheGreetingToThePbx() {
        launch("in-call-hold-for-me")
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 5))
        element("call.more").tap()
        element("call.holdForMe").tap()
        XCTAssertTrue(element("holdForMe.start").waitForExistence(timeout: 5))
        element("holdForMe.start").tap()
        XCTAssertTrue(fixtureEvent("holdForMe.started:default"), "no greeting sent: the saved default applies")
    }

    func testHoldForMeIsHiddenWithoutTheFlag() {
        launch("in-call", extra: ["-FixtureNoHoldForMe"])
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 5))
        element("call.more").tap()
        XCTAssertTrue(element("call.moveTo").waitForExistence(timeout: 5), "the menu is open")
        XCTAssertFalse(element("call.holdForMe").exists)
    }

    func testTheWaitingCardShowsElapsedAndCancelOffersRejoinOrHangUp() {
        launch("hold-waiting")
        let card = element("holdWait.card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("12:3"), "elapsed time: \(card.label)")
        element("holdWait.cancel").tap()
        XCTAssertTrue(element("holdWait.hangUp").waitForExistence(timeout: 5))
        element("holdWait.rejoinNow").tap()
        XCTAssertTrue(fixtureEvent("holdForMe.cancelled:rejoin"))
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "the card goes when the wait ends")
    }

    func testTheWaitingCardIsHiddenWithoutTheFlag() {
        launch("hold-waiting", extra: ["-FixtureNoHoldForMe"])
        XCTAssertTrue(tab(0).waitForExistence(timeout: 5))
        XCTAssertFalse(element("holdWait.card").exists)
    }

    func testTheyreBackShowsTheTranscriptAndStillOnHold() {
        launch("incoming-hold-return")
        XCTAssertTrue(app.staticTexts["They're back — Acme Bank"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tap to rejoin"].exists)
        XCTAssertTrue(element("holdReturn.transcript").exists)
        element("call.stillOnHold").tap()
        XCTAssertTrue(fixtureEvent("holdForMe.stillOnHold"))
        XCTAssertTrue(element("call.stillOnHold").waitForNonExistence(timeout: 5), "the ringing call ends")
    }

    func testSettingsShowsTheGreetingOnlyWithTheFlag() {
        launch("settings")
        let picker = element("settings.holdForMeGreeting")
        for _ in 0..<6 where !picker.exists { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "offered with the flag")
        picker.tap()
        app.buttons["Silence"].firstMatch.tap()
        XCTAssertTrue(fixtureEvent("holdForMe.greeting:silence"))
        app.terminate()

        launch("settings", extra: ["-FixtureNoHoldForMe"])
        XCTAssertTrue(tab(4).waitForExistence(timeout: 5))
        for _ in 0..<6 { app.swipeUp() }
        XCTAssertFalse(element("settings.holdForMeGreeting").exists, "hidden without the flag")
    }
}
