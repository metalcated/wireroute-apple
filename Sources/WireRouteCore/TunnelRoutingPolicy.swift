// SPDX-License-Identifier: MIT

public enum TunnelRouteMode: String, Codable, CaseIterable, Sendable {
    case split
    case full
}

public struct TunnelRoutingPolicy: Codable, Equatable, Sendable {
    public var mode: TunnelRouteMode
    public var splitAllowedIPs: [RoutePrefix]

    public init(mode: TunnelRouteMode = .split, splitAllowedIPs: [RoutePrefix]) {
        self.mode = mode
        self.splitAllowedIPs = Self.unique(splitAllowedIPs)
    }

    public static func suggestedSplitAllowedIPs(from importedAllowedIPs: [RoutePrefix]) -> [RoutePrefix] {
        unique(importedAllowedIPs.filter { !$0.isDefaultRoute })
    }

    private static func unique(_ routes: [RoutePrefix]) -> [RoutePrefix] {
        var seen = Set<RoutePrefix>()
        return routes.filter { seen.insert($0).inserted }
    }
}
