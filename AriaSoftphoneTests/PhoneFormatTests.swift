import XCTest
@testable import AriaSoftphone

final class PhoneFormatTests: XCTestCase {
    private let us = PhoneFormat(country: "US")
    private let gb = PhoneFormat(country: "GB")

    // MARK: As typed

    func testUSNationalNumbersGroupAsTyped() {
        XCTAssertEqual(us.typing("8004444444"), "(800) 444-4444")
        XCTAssertEqual(us.typing("4155550142"), "(415) 555-0142")
        XCTAssertEqual(us.typing("18004444444"), "1 (800) 444-4444")
    }

    func testPartialTypingSequenceNeverLosesDigits() {
        let full = "8004444444"
        for count in 1...full.count {
            let typed = String(full.prefix(count))
            let shown = us.typing(typed)
            XCTAssertEqual(shown.filter(\.isNumber), typed, "digits at \(count)")
        }
        XCTAssertEqual(us.typing("800444"), "800444", "below a number's length stays as typed")
        XCTAssertEqual(us.typing("8004444"), "800-4444")
        XCTAssertEqual(us.typing("800444444"), "(800) 444-444")
    }

    func testInternationalNumbers() {
        XCTAssertEqual(us.typing("+442071838750"), "+44 20 7183 8750")
        XCTAssertEqual(us.typing("+14155550142"), "+1 (415) 555-0142")
        XCTAssertEqual(us.typing("+1"), "+1")
        XCTAssertEqual(us.typing("+"), "+")
        XCTAssertEqual(gb.typing("+14155550142"), "+1 (415) 555-0142")
    }

    func testExtensionsStarCodesAndShortCodesAreNeverMangled() {
        for code in ["1", "911", "1001", "10042", "100421", "*97", "*80101", "#", "*", "##5", "4155550142#", "*8004444444", "#8004444444"] {
            XCTAssertEqual(us.typing(code), code, code)
            XCTAssertEqual(gb.typing(code), code, code)
        }
    }

    func testNonUSDefaultCountry() {
        XCTAssertEqual(gb.typing("02071838750"), "020 7183 8750")
        XCTAssertEqual(gb.typing("07911123456"), "07911 123456")
        XCTAssertEqual(gb.typing("1001"), "1001")
        XCTAssertEqual(gb.typing("+442071838750"), "+44 20 7183 8750")
    }

    func testUnknownCountryFallsBackToTheDevice() {
        XCTAssertEqual(PhoneFormat(country: "ZZ").country, PhoneFormat.deviceCountry)
        XCTAssertEqual(PhoneFormat(country: "gb").country, "GB")
    }

    // MARK: Hint

    func testHintShowsOnlyForAValidNationalNumber() {
        XCTAssertEqual(us.hint("8004444444"), "+1 (800) 444-4444")
        XCTAssertEqual(gb.hint("02071838750"), "+44 020 7183 8750")
        XCTAssertNil(us.hint("1001"))
        XCTAssertNil(us.hint("911"))
        XCTAssertNil(us.hint("*97"))
        XCTAssertNil(us.hint("+14155550142"))
        XCTAssertNil(us.hint("800444"))
        XCTAssertNil(us.hint(""))
    }

    // MARK: Lists

    func testListsShowNationalForTheDefaultCountryAndInternationalOtherwise() {
        XCTAssertEqual(us.listed("+14155550142"), "(415) 555-0142")
        XCTAssertEqual(us.listed("+1 (415) 555-0142"), "(415) 555-0142")
        XCTAssertEqual(us.listed("4155550142"), "(415) 555-0142")
        XCTAssertEqual(us.listed("+442071838750"), "+44 20 7183 8750")
        XCTAssertEqual(gb.listed("+14155550142"), "+1 415-555-0142")
        XCTAssertEqual(gb.listed("+442071838750"), "020 7183 8750")
    }

    func testListsLeaveNonNumbersUntouched() {
        for text in ["1001", "911", "*97", "*80101", "Front Desk", "sip:4155550142@acme.example", "alice@example.com",
                     "", "Unknown", "anonymous", "12345"] {
            XCTAssertEqual(us.listed(text), text, text)
        }
    }

    func testDialFormatterUsesTheGivenCountry() {
        XCTAssertEqual(DialFormatter.format("+14155550142", country: "US"), "(415) 555-0142")
        XCTAssertEqual(DialFormatter.typing("8004444444", country: "US"), "(800) 444-4444")
    }

    // MARK: Dial strings

    func testPastedTextStripsToWhatIsDialed() {
        XCTAssertEqual(PhoneFormat.dialString("(800) 444-4444"), "8004444444")
        XCTAssertEqual(PhoneFormat.dialString(" +1 800-444-4444 "), "+18004444444")
        XCTAssertEqual(PhoneFormat.dialString("800.444.4444"), "8004444444")
        XCTAssertEqual(PhoneFormat.dialString("*97"), "*97")
        XCTAssertEqual(PhoneFormat.dialString("12+34"), "1234")
        XCTAssertNil(PhoneFormat.dialString("hello"))
    }

    func testFormattingNeverChangesWhatIsDialed() {
        let typed = "8004444444"
        XCTAssertNotEqual(us.typing(typed), typed)
        XCTAssertEqual(PhoneFormat.dialString(us.typing(typed)), typed)
    }

    // MARK: Default country

    @MainActor
    func testDefaultCountryKeepsWhatItIsToldAndIgnoresJunk() {
        let defaults = UserDefaults(suiteName: "PhoneFormatTests")!
        defaults.removePersistentDomain(forName: "PhoneFormatTests")
        let store = DefaultCountry(defaults: defaults)
        XCTAssertEqual(store.country, PhoneFormat.deviceCountry)
        store.set("GB")
        XCTAssertEqual(store.country, "GB")
        store.set("not a country")
        store.set(nil)
        XCTAssertEqual(store.country, "GB")
        XCTAssertEqual(DefaultCountry(defaults: defaults).country, "GB", "cached across launches")
    }
}
