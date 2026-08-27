// SPDX-License-Identifier: MIT

public struct ProfileNetworkCapabilities: Codable, Equatable, Sendable {
    public let supportedFamilies: Set<IPFamily>

    public init(interfaceAddresses: [RoutePrefix]) {
        supportedFamilies = Set(interfaceAddresses.map(\.family))
    }

    public init(supportedFamilies: Set<IPFamily>) {
        self.supportedFamilies = supportedFamilies
    }
}

public struct RoutingPlan: Equatable, Sendable {
    public let mode: TunnelRouteMode
    public let allowedIPs: [RoutePrefix]
    public let blockedFamilies: Set<IPFamily>

    public var blocksIPv6: Bool {
        blockedFamilies.contains(.ipv6)
    }
}

public enum RoutingPlanError: Error, Equatable, Sendable {
    case missingSplitRoutes
    case splitRoutesContainDefaultRoute
    case profileHasNoTunnelAddress
}

public enum RoutingPlanBuilder {
    public static func makePlan(
        policy: TunnelRoutingPolicy,
        capabilities: ProfileNetworkCapabilities
    ) throws -> RoutingPlan {
        switch policy.mode {
        case .split:
            guard !policy.splitAllowedIPs.isEmpty else {
                throw RoutingPlanError.missingSplitRoutes
            }
            guard !policy.splitAllowedIPs.contains(where: \.isDefaultRoute) else {
                throw RoutingPlanError.splitRoutesContainDefaultRoute
            }
            return RoutingPlan(
                mode: .split,
                allowedIPs: policy.splitAllowedIPs,
                blockedFamilies: []
            )

        case .full:
            guard !capabilities.supportedFamilies.isEmpty else {
                throw RoutingPlanError.profileHasNoTunnelAddress
            }
            let routedFamilies = IPFamily.allCases.filter(capabilities.supportedFamilies.contains)
            let blockedFamilies = Set(IPFamily.allCases).subtracting(capabilities.supportedFamilies)
            return RoutingPlan(
                mode: .full,
                allowedIPs: routedFamilies.map(RoutePrefix.defaultRoute),
                blockedFamilies: blockedFamilies
            )
        }
    }
}
