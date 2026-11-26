import XCTest

final class OnboardingUITests: AriaUITestCase {
    func testOnboardingOffersSetupAndFixtureModeAsksForNothing() {
        launch("onboarding")
        let start = element("onboarding.getStarted")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        assertNoSystemAlert()
        start.tap()
        XCTAssertTrue(element("onboarding.scanQR").waitForExistence(timeout: 3))
        XCTAssertTrue(element("onboarding.link").exists)
        XCTAssertTrue(element("onboarding.manual").exists)
        assertNoSystemAlert()
    }

    func testManualSetupValidatesBeforeSigningIn() {
        launch("onboarding")
        let start = element("onboarding.getStarted")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let manual = element("onboarding.manual")
        XCTAssertTrue(manual.waitForExistence(timeout: 3))
        manual.tap()
        // Skip the permission primer: fixture mode asks for nothing.
        let notNow = element("onboarding.permissions.notNow")
        XCTAssertTrue(notNow.waitForExistence(timeout: 3))
        notNow.tap()
        let signIn = element("manualSetup.signIn")
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))

        // Nothing filled in: the required fields say so, and nothing is sent.
        signIn.tap()
        XCTAssertTrue(element("manualSetup.domain.problem").waitForExistence(timeout: 2))
        XCTAssertTrue(element("manualSetup.extension.problem").exists)
        XCTAssertTrue(element("manualSetup.password.problem").exists)

        let domain = element("manualSetup.domain")
        domain.tap()
        domain.typeText("acme.ariaroute.com")
        let ext = element("manualSetup.extension")
        ext.tap()
        ext.typeText("1001")
        let password = element("manualSetup.password")
        password.tap()
        password.typeText("secret")

        // A cleartext API address is refused.
        element("manualSetup.advanced").tap()
        let api = element("manualSetup.apiUrl")
        XCTAssertTrue(api.waitForExistence(timeout: 2))
        api.tap()
        api.typeText("http://api.acme.example")
        signIn.tap()
        XCTAssertTrue(element("manualSetup.apiUrl.problem").waitForExistence(timeout: 2))
        XCTAssertFalse(element("manualSetup.domain.problem").exists)
        XCTAssertTrue(signIn.exists, "the sheet stays up while the form is invalid")
    }
}

final class NavigationUITests: AriaUITestCase {
    func testEveryTabOpens() {
        launch("dialer")
        XCTAssertTrue(element("dialKey.5").waitForExistence(timeout: 5))
        XCTAssertEqual(sectionCount, 5)
        for index in [1, 2, 3, 4, 0] {
            tab(index).tap()
            XCTAssertTrue(tab(index).isSelected || isSidebarLayout, "tab \(index) is selected")
        }
        XCTAssertTrue(element("dialKey.5").waitForExistence(timeout: 2), "back on the dialer")
        assertNoSystemAlert()
    }
}

final class DialerUITests: AriaUITestCase {
    func testDialPadInputAndBackspace() {
        launch("dialer")
        for digit in ["1", "0", "0", "2"] {
            element("dialKey.\(digit)").tap()
        }
        let number = element("dialer.number")
        XCTAssertTrue(number.waitForExistence(timeout: 2))
        XCTAssertEqual(number.value as? String, "1 0 0 2")
    }

    func testAnEmergencyNumberGoesToTheNativeDialerNotVoIP() {
        launch("dialer")
        for digit in ["9", "1", "1"] {
            element("dialKey.\(digit)").tap()
        }
        element("dialer.call").tap()

        let handoff = element("fixture.emergencyHandoff")
        XCTAssertTrue(handoff.waitForExistence(timeout: 3), "911 was handed to tel:")
        XCTAssertEqual(handoff.value as? String, "tel:911")
        XCTAssertFalse(element("call.screen").waitForExistence(timeout: 2), "no VoIP call started")
    }

    func testAnOrdinaryNumberStartsAVoIPCall() {
        launch("dialer")
        for digit in ["1", "0", "0", "2"] {
            element("dialKey.\(digit)").tap()
        }
        element("dialer.call").tap()
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 3))
        XCTAssertFalse(element("fixture.emergencyHandoff").exists)
    }
}

final class CallingSettingsUITests: AriaUITestCase {
    func testDoNotDisturbToggles() {
        launch("settings")
        let dnd = app.switches["settings.dnd"].firstMatch
        XCTAssertTrue(dnd.waitForExistence(timeout: 5))
        let before = dnd.value as? String
        // The switch sits at the trailing edge of the row, about 40 pt in.
        dnd.coordinate(withNormalizedOffset: CGVector(dx: 1 - 40 / dnd.frame.width, dy: 0.5)).tap()
        let changed = NSPredicate { _, _ in (dnd.value as? String) != before }
        wait(for: [expectation(for: changed, evaluatedWith: nil)], timeout: 3)
    }

    func testForwardingShowsAndSetsForwards() {
        launch("forwarding")
        let busy = element("forwarding.busy.destination")
        XCTAssertTrue(busy.waitForExistence(timeout: 5))
        XCTAssertEqual(busy.value as? String, "1000")

        let always = element("forwarding.unconditional.destination")
        always.tap()
        always.typeText("1017")
        let save = element("forwarding.unconditional.save")
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        save.tap()

        let toggle = app.switches["forwarding.unconditional.toggle"].firstMatch
        let on = NSPredicate(format: "value == '1'")
        wait(for: [expectation(for: on, evaluatedWith: toggle)], timeout: 3)
        XCTAssertTrue(element("forwarding.unconditional.remove").exists)
    }
}

final class ConferenceUITests: AriaUITestCase {
    /// The call screen's Merge and Split controls (identifiers `call.merge`
    /// and `call.split`) on the two-call fixture.
    func testMergeThenSplitOnTwoCalls() {
        launch("in-call-two-calls")
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 5))
        // Merge and Split live in the call screen's overflow menu.
        let more = element("call.more")
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let merge = element("call.merge")
        XCTAssertTrue(merge.waitForExistence(timeout: 3), "two connected calls: Merge is offered")
        XCTAssertFalse(element("call.split").exists)
        merge.tap()

        more.tap()
        let split = element("call.split")
        XCTAssertTrue(split.waitForExistence(timeout: 3), "merged: Split is offered")
        XCTAssertFalse(element("call.merge").exists)
        split.tap()

        more.tap()
        XCTAssertTrue(element("call.merge").waitForExistence(timeout: 3), "split: Merge is offered again")
    }
}

final class CallEncryptionUITests: AriaUITestCase {
    /// A call whose media is not encrypted is called out: the amber capsule
    /// (read as "Call not encrypted"), the one-time notice, and the notice
    /// again when the capsule is tapped.
    func testAnUnencryptedCallIsCalledOut() {
        launch("in-call-unencrypted")
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 5))
        let notice = element("banner.warning")
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "the call connected unencrypted: the notice shows")

        let capsule = element("call.notEncrypted")
        XCTAssertTrue(capsule.waitForExistence(timeout: 3))
        XCTAssertTrue(capsule.label.hasPrefix("Call not encrypted"), capsule.label)
        XCTAssertFalse(element("call.encrypted").exists, "never the encrypted look")

        // Once per call: dismissed, it does not come back by itself.
        notice.buttons.firstMatch.tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 3))
        XCTAssertFalse(notice.waitForExistence(timeout: 3))

        // The capsule explains it again.
        capsule.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 3), "tapping the capsule explains")
    }

    func testAnEncryptedCallShowsNoWarning() {
        launch("in-call")
        XCTAssertTrue(element("call.screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element("call.encrypted").waitForExistence(timeout: 5))
        XCTAssertFalse(element("call.notEncrypted").exists)
        XCTAssertFalse(element("banner.warning").exists)
    }
}
