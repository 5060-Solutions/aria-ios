import XCTest

final class HoldForMeUITests: AriaUITestCase {
    func testHoldForMeIsInTheOverflowAndStartsWithTheChosenGreeting() {
        launch("in-call-hold-for-me")
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 5))
        element("call.more").tap()
        element("call.holdForMe").tap()
        XCTAssertTrue(element("holdForMe.greeting.silence").waitForExistence(timeout: 5))
        element("holdForMe.greeting.assistant").tap()
        element("holdForMe.start").tap()
        XCTAssertTrue(fixtureEvent("holdForMe.started:assistant"))
        XCTAssertTrue(element("holdForMe.start").waitForNonExistence(timeout: 5), "the sheet closes")
    }

    func testHoldForMeIsHiddenWithoutTheFlag() {
        launch("in-call", extra: ["-FixtureNoHoldForMe"])
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 5))
        element("call.more").tap()
        XCTAssertTrue(element("call.moveTo").waitForExistence(timeout: 5), "the menu is open")
        XCTAssertFalse(element("call.holdForMe").exists)
    }
}
