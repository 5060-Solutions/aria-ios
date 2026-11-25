import XCTest
@testable import AriaSoftphone

final class SystemDNSTests: XCTestCase {
    /// Whatever the system reports is a list of numeric addresses (a scope
    /// id allowed), never host names; an empty list is a valid answer.
    func testServersAreNumericAddresses() {
        for s in SystemDNS.servers() {
            let addr = s.split(separator: "%").first.map(String.init) ?? s
            var v4 = in_addr(), v6 = in6_addr()
            XCTAssertTrue(inet_pton(AF_INET, addr, &v4) == 1 || inet_pton(AF_INET6, addr, &v6) == 1, s)
        }
    }

    func testNormalizedDropsEmpty() {
        XCTAssertEqual(SystemDNS.normalized(["", "10.0.0.1", "fe80::1%en0"]), ["10.0.0.1", "fe80::1%en0"])
    }
}
