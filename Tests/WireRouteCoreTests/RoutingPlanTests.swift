// SPDX-License-Identifier: MIT

import XCTest
@testable import WireRouteCore

final class RoutingPlanTests: XCTestCase {
    func testSplitPlanPreservesConfiguredRoutesAndLeavesOtherFamiliesLocal() throws {
        let routes = [
            try RoutePrefix("10.20.0.0/16"),
            try RoutePrefix("2001:db8:20::/48")
        ]
        let policy = TunnelRoutingPolicy(mode: .split, splitAllowedIPs: routes)
        let capabilities = ProfileNetworkCapabilities(supportedFamilies: [.ipv4, .ipv6])

        let plan = try RoutingPlanBuilder.makePlan(policy: policy, capabilities: capabilities)

        XCTAssertEqual(plan.allowedIPs, routes)
        XCTAssertEqual(plan.blockedFamilies, [])
    }

    func testSplitPlanRequiresModalWhenNoSpecificRoutesCanBeDetected() throws {
        let importedRoutes = [try RoutePrefix("0.0.0.0/0"), try RoutePrefix("::/0")]
        let suggestedRoutes = TunnelRoutingPolicy.suggestedSplitAllowedIPs(from: importedRoutes)
        let policy = TunnelRoutingPolicy(mode: .split, splitAllowedIPs: suggestedRoutes)

        XCTAssertThrowsError(
            try RoutingPlanBuilder.makePlan(
                policy: policy,
                capabilities: ProfileNetworkCapabilities(supportedFamilies: [.ipv4, .ipv6])
            )
        ) { error in
            XCTAssertEqual(error as? RoutingPlanError, .missingSplitRoutes)
        }
    }

    func testFullPlanRoutesBothFamiliesWhenProfileSupportsBoth() throws {
        let policy = TunnelRoutingPolicy(mode: .full, splitAllowedIPs: [])
        let capabilities = ProfileNetworkCapabilities(supportedFamilies: [.ipv4, .ipv6])

        let plan = try RoutingPlanBuilder.makePlan(policy: policy, capabilities: capabilities)

        XCTAssertEqual(plan.allowedIPs.map(\.notation), ["0.0.0.0/0", "::/0"])
        XCTAssertEqual(plan.blockedFamilies, [])
    }

    func testFullPlanBlocksIPv6ForIPv4OnlyProfile() throws {
        let policy = TunnelRoutingPolicy(mode: .full, splitAllowedIPs: [])
        let capabilities = ProfileNetworkCapabilities(supportedFamilies: [.ipv4])

        let plan = try RoutingPlanBuilder.makePlan(policy: policy, capabilities: capabilities)

        XCTAssertEqual(plan.allowedIPs.map(\.notation), ["0.0.0.0/0"])
        XCTAssertEqual(plan.blockedFamilies, [.ipv6])
        XCTAssertTrue(plan.blocksIPv6)
    }

    func testFullPlanBlocksIPv4ForIPv6OnlyProfile() throws {
        let policy = TunnelRoutingPolicy(mode: .full, splitAllowedIPs: [])
        let capabilities = ProfileNetworkCapabilities(supportedFamilies: [.ipv6])

        let plan = try RoutingPlanBuilder.makePlan(policy: policy, capabilities: capabilities)

        XCTAssertEqual(plan.allowedIPs.map(\.notation), ["::/0"])
        XCTAssertEqual(plan.blockedFamilies, [.ipv4])
    }

    func testFullPlanRejectsProfileWithoutTunnelAddresses() {
        let policy = TunnelRoutingPolicy(mode: .full, splitAllowedIPs: [])

        XCTAssertThrowsError(
            try RoutingPlanBuilder.makePlan(
                policy: policy,
                capabilities: ProfileNetworkCapabilities(supportedFamilies: [])
            )
        ) { error in
            XCTAssertEqual(error as? RoutingPlanError, .profileHasNoTunnelAddress)
        }
    }

    func testPolicyDeduplicatesRoutesWithoutReorderingThem() throws {
        let first = try RoutePrefix("10.0.0.0/8")
        let second = try RoutePrefix("192.168.50.0/24")

        let policy = TunnelRoutingPolicy(splitAllowedIPs: [first, second, first])

        XCTAssertEqual(policy.splitAllowedIPs, [first, second])
    }

    func testSplitPlanRejectsDefaultRoutes() throws {
        let policy = TunnelRoutingPolicy(
            mode: .split,
            splitAllowedIPs: [try RoutePrefix("0.0.0.0/0")]
        )

        XCTAssertThrowsError(
            try RoutingPlanBuilder.makePlan(
                policy: policy,
                capabilities: ProfileNetworkCapabilities(supportedFamilies: [.ipv4])
            )
        ) { error in
            XCTAssertEqual(error as? RoutingPlanError, .splitRoutesContainDefaultRoute)
        }
    }
}
