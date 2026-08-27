// SPDX-License-Identifier: MIT

import XCTest
@testable import WireRouteCore

final class RoutePrefixTests: XCTestCase {
    func testParsesIPv4AndIPv6Prefixes() throws {
        let ipv4 = try RoutePrefix(" 192.0.2.4/24 ")
        let ipv6 = try RoutePrefix("2001:db8::4/64")

        XCTAssertEqual(ipv4.family, .ipv4)
        XCTAssertEqual(ipv4.notation, "192.0.2.4/24")
        XCTAssertEqual(ipv6.family, .ipv6)
        XCTAssertEqual(ipv6.notation, "2001:db8::4/64")
    }

    func testRejectsInvalidAddressesAndPrefixLengths() {
        XCTAssertThrowsError(try RoutePrefix("not-an-address/24"))
        XCTAssertThrowsError(try RoutePrefix("192.0.2.1/33"))
        XCTAssertThrowsError(try RoutePrefix("2001:db8::1/129"))
        XCTAssertThrowsError(try RoutePrefix("192.0.2.1"))
    }

    func testCodableRoundTripUsesStandardNotation() throws {
        let route = try RoutePrefix("2001:db8::10/64")
        let encoded = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(RoutePrefix.self, from: encoded)

        XCTAssertEqual(decoded, route)
    }
}
