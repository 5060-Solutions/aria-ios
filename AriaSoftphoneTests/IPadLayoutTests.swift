import XCTest
import SwiftUI
@testable import AriaSoftphone

final class IPadLayoutTests: XCTestCase {
    // MARK: Dial pad

    func testPadGrowsOnALargePhone() {
        // iPhone Pro Max: 440 pt wide, about 600 pt left for the pad.
        let m = DialPadMetrics.fitting(width: 400, height: 600)
        XCTAssertGreaterThan(m.key, DialPadMetrics.baseKey)
        XCTAssertLessThanOrEqual(m.key, DialPadMetrics.maxKeyCompact)
        XCTAssertGreaterThan(m.digitSize, 34)
    }

    func testPadKeepsTheDesignSizeOnABasePhone() {
        // 393 x 852 with the tab bar and header taken out.
        let m = DialPadMetrics.fitting(width: 353, height: 430)
        XCTAssertEqual(m.key, 75, accuracy: 2)
    }

    func testPadStopsAtItsMaximum() {
        XCTAssertEqual(DialPadMetrics.fitting(width: 2000, height: 2000).key, DialPadMetrics.maxKeyCompact)
        XCTAssertEqual(DialPadMetrics.fitting(width: 2000, height: 2000,
                                              maxKey: DialPadMetrics.maxKeyRegular).key,
                       DialPadMetrics.maxKeyRegular)
    }

    func testPadShrinksToFitAndNeverBelowItsFloor() {
        let small = DialPadMetrics.fitting(width: 300, height: 400)
        XCTAssertLessThan(small.key, DialPadMetrics.baseKey)
        XCTAssertGreaterThanOrEqual(small.key, DialPadMetrics.minKey)
        // Room too small for the floor: the pad takes what there is.
        XCTAssertLessThan(DialPadMetrics.fitting(width: 150, height: 150).key, DialPadMetrics.minKey)
    }

    func testPadAlwaysFitsItsRoom() {
        for (w, h) in [(300.0, 330.0), (353.0, 430.0), (400.0, 600.0), (700.0, 500.0), (800.0, 900.0)] {
            let m = DialPadMetrics.fitting(width: w, height: h, maxKey: DialPadMetrics.maxKeyRegular)
            XCTAssertLessThanOrEqual(m.width, w + 1)
            XCTAssertLessThanOrEqual(m.height(), h + 5)
        }
    }

    func testTextSizeScalesThePadWithinItsRoom() {
        let normal = DialPadMetrics.fitting(width: 600, height: 800, typeScale: DialPadMetrics.typeScale(for: .large))
        let big = DialPadMetrics.fitting(width: 600, height: 800, typeScale: DialPadMetrics.typeScale(for: .accessibility3))
        XCTAssertGreaterThan(big.key, normal.key)
        XCTAssertLessThan(DialPadMetrics.typeScale(for: .xSmall), 1)
    }

    func testBaseMetricsAreTheDesignSizes() {
        let m = DialPadMetrics.base
        XCTAssertEqual(m.key, 76)
        XCTAssertEqual(m.gapH, 12, accuracy: 0.01)
        XCTAssertEqual(m.gapV, 14, accuracy: 0.01)
        XCTAssertEqual(m.digitSize, 34, accuracy: 0.01)
        XCTAssertEqual(m.callButton, 72, accuracy: 0.01)
    }

    // MARK: Call screen

    func testCallScreenGoesSideBySideOnlyWhenWideAndShort() {
        XCTAssertTrue(CallView.isSideBySide(CGSize(width: 1180, height: 700)))
        XCTAssertFalse(CallView.isSideBySide(CGSize(width: 820, height: 1180)))   // iPad portrait
        XCTAssertFalse(CallView.isSideBySide(CGSize(width: 440, height: 900)))    // iPhone
        XCTAssertFalse(CallView.isSideBySide(CGSize(width: 320, height: 800)))    // Slide Over
    }

    // MARK: Build settings

    func testBundleIsUniversalAndAllowsMultitasking() {
        // The raw plist: `infoDictionary` merges the ~ipad keys away on an iPhone.
        let url = Bundle.main.bundleURL.appendingPathComponent("Info.plist")
        let info = (NSDictionary(contentsOf: url) as? [String: Any]) ?? [:]
        XCTAssertFalse(info.isEmpty)
        XCTAssertNil(info["UIRequiresFullScreen"], "Split View and Slide Over need the app not to require full screen")
        let ipad = info["UISupportedInterfaceOrientations~ipad"] as? [String] ?? []
        XCTAssertEqual(Set(ipad), ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                   "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
        XCTAssertEqual(Set(info["UIDeviceFamily"] as? [Int] ?? []), [1, 2])
    }

    func testSidebarHasEverySection() {
        let all: [AppTab] = [.dialer, .history, .contacts, .voicemail, .messages, .settings]
        XCTAssertEqual(Set(all.map(\.systemImage)).count, all.count)
        // With an inbox the sidebar lists Messages, as the tab bar does.
        XCTAssertEqual(SidebarShell.sections(hasInbox: true), all)
        XCTAssertEqual(SidebarShell.sections(hasInbox: false), all.filter { $0 != .messages })
    }
}
