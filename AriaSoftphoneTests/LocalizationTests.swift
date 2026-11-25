import XCTest
@testable import AriaSoftphone

final class LocalizationTests: XCTestCase {
    func testDeclaredLocalizationsMatchShippedOnes() {
        let declared = AppLanguage.declared()
        let shipped = AppLanguage.shipped()
        XCTAssertFalse(declared.isEmpty)
        XCTAssertEqual(declared, shipped, "CFBundleLocalizations in project.yml must list exactly the shipped languages")
        XCTAssertEqual(declared, ["en", "es", "fr", "de"])
    }

    func testDevelopmentRegionIsEnglish() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleDevelopmentRegion"] as? String, "en")
    }

    func testLanguageIsNamedInItself() {
        XCTAssertEqual(AppLanguage.name(forCode: "es"), "Español")
        XCTAssertEqual(AppLanguage.name(forCode: "de"), "Deutsch")
        XCTAssertEqual(AppLanguage.name(forCode: "fr"), "Français")
        XCTAssertEqual(AppLanguage.name(forCode: "en"), "English")
    }

    func testCurrentLanguageIsOneOfTheShippedOnes() {
        XCTAssertTrue(AppLanguage.shipped().contains(AppLanguage.currentCode() ?? ""))
    }
}
