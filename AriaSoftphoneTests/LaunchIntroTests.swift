import XCTest
@testable import AriaSoftphone

final class LaunchIntroTests: XCTestCase {
    func testPlaysOnAColdStart() {
        XCTAssertTrue(LaunchIntro.shouldPlay(hasPlayed: false, isFixture: false, fixtureAsked: false, hasCall: false))
    }

    func testNeverPlaysTwiceInOneProcess() {
        XCTAssertFalse(LaunchIntro.shouldPlay(hasPlayed: true, isFixture: false, fixtureAsked: false, hasCall: false))
    }

    func testAnIncomingCallSkipsIt() {
        XCTAssertFalse(LaunchIntro.shouldPlay(hasPlayed: false, isFixture: false, fixtureAsked: false, hasCall: true))
    }

    func testFixturesSkipItUnlessAsked() {
        XCTAssertFalse(LaunchIntro.shouldPlay(hasPlayed: false, isFixture: true, fixtureAsked: false, hasCall: false))
        XCTAssertTrue(LaunchIntro.shouldPlay(hasPlayed: false, isFixture: true, fixtureAsked: true, hasCall: false))
    }

    func testStaysWithinTheBudget() {
        XCTAssertLessThanOrEqual(LaunchIntro.total, 0.6)
    }
}
