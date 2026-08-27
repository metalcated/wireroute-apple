// SPDX-License-Identifier: MIT

import Foundation

enum TunnelRoutingError: WireGuardAppError, Sendable {
    case missingSplitRoutes
    case profileHasNoTunnelAddress
    case ambiguousFullTunnelPeer
    case invalidStoredRoutes

    var alertText: AlertText {
        switch self {
        case .missingSplitRoutes:
            return (tr("alertRoutingMissingSplitRoutesTitle"), tr("alertRoutingMissingSplitRoutesMessage"))
        case .profileHasNoTunnelAddress:
            return (tr("alertRoutingNoAddressTitle"), tr("alertRoutingNoAddressMessage"))
        case .ambiguousFullTunnelPeer:
            return (tr("alertRoutingMultiplePeersTitle"), tr("alertRoutingMultiplePeersMessage"))
        case .invalidStoredRoutes:
            return (tr("alertRoutingInvalidRoutesTitle"), tr("alertRoutingInvalidRoutesMessage"))
        }
    }
}

struct TunnelRoutingUpdate: Sendable {
    let configuration: TunnelConfiguration
    let splitAllowedIPs: [String: [String]]
    let blockedAddressFamilies: BlockedAddressFamilies
}

enum TunnelRoutingController {
    static func detectedMode(
        configuration: TunnelConfiguration,
        storedMode: String?
    ) -> TunnelRouteMode {
        if let storedMode, let mode = TunnelRouteMode(rawValue: storedMode) {
            return mode
        }
        let hasDefaultRoute = configuration.peers
            .flatMap(\.allowedIPs)
            .contains { routePrefix(from: $0)?.isDefaultRoute == true }
        return hasDefaultRoute ? .full : .split
    }

    static func makeUpdate(
        configuration: TunnelConfiguration,
        mode: TunnelRouteMode,
        storedSplitAllowedIPs: [String: [String]]?
    ) throws -> TunnelRoutingUpdate {
        let splitAllowedIPs = try splitRoutes(
            configuration: configuration,
            storedSplitAllowedIPs: storedSplitAllowedIPs
        )
        let interfaceAddresses = try configuration.interface.addresses.map(validatedRoutePrefix)
        let capabilities = ProfileNetworkCapabilities(interfaceAddresses: interfaceAddresses)
        let allSplitRoutes = try splitAllowedIPs.values.flatMap { try $0.map(RoutePrefix.init) }
        let policy = TunnelRoutingPolicy(mode: mode, splitAllowedIPs: allSplitRoutes)

        let plan: RoutingPlan
        do {
            plan = try RoutingPlanBuilder.makePlan(policy: policy, capabilities: capabilities)
        } catch RoutingPlanError.missingSplitRoutes {
            throw TunnelRoutingError.missingSplitRoutes
        } catch RoutingPlanError.profileHasNoTunnelAddress {
            throw TunnelRoutingError.profileHasNoTunnelAddress
        } catch {
            throw TunnelRoutingError.invalidStoredRoutes
        }

        var peers = configuration.peers
        switch mode {
        case .split:
            for index in peers.indices {
                let publicKey = peers[index].publicKey.base64Key
                peers[index].allowedIPs = try (splitAllowedIPs[publicKey] ?? []).map(validatedIPAddressRange)
            }

        case .full:
            let gatewayPeerIndex = try fullTunnelGatewayPeerIndex(in: peers)
            for index in peers.indices {
                if index == gatewayPeerIndex {
                    peers[index].allowedIPs = try plan.allowedIPs.map { try validatedIPAddressRange($0.notation) }
                } else {
                    let publicKey = peers[index].publicKey.base64Key
                    peers[index].allowedIPs = try (splitAllowedIPs[publicKey] ?? []).map(validatedIPAddressRange)
                }
            }
        }

        var blockedAddressFamilies: BlockedAddressFamilies = []
        if plan.blockedFamilies.contains(.ipv4) {
            blockedAddressFamilies.insert(.ipv4)
        }
        if plan.blockedFamilies.contains(.ipv6) {
            blockedAddressFamilies.insert(.ipv6)
        }

        return TunnelRoutingUpdate(
            configuration: TunnelConfiguration(
                name: configuration.name,
                interface: configuration.interface,
                peers: peers
            ),
            splitAllowedIPs: splitAllowedIPs,
            blockedAddressFamilies: blockedAddressFamilies
        )
    }

    private static func splitRoutes(
        configuration: TunnelConfiguration,
        storedSplitAllowedIPs: [String: [String]]?
    ) throws -> [String: [String]] {
        if let storedSplitAllowedIPs {
            for routes in storedSplitAllowedIPs.values {
                let parsedRoutes = try routes.map(RoutePrefix.init)
                guard !parsedRoutes.contains(where: \.isDefaultRoute) else {
                    throw TunnelRoutingError.invalidStoredRoutes
                }
            }
            return storedSplitAllowedIPs
        }

        return Dictionary(uniqueKeysWithValues: configuration.peers.map { peer in
            let splitRoutes = peer.allowedIPs.compactMap(routePrefix(from:))
                .filter { !$0.isDefaultRoute }
                .map(\.notation)
            return (peer.publicKey.base64Key, stableUnique(splitRoutes))
        })
    }

    private static func fullTunnelGatewayPeerIndex(in peers: [PeerConfiguration]) throws -> Int {
        guard !peers.isEmpty else {
            throw TunnelRoutingError.ambiguousFullTunnelPeer
        }
        if peers.count == 1 {
            return peers.startIndex
        }

        let peersWithDefaultRoute = peers.indices.filter { index in
            peers[index].allowedIPs.contains { routePrefix(from: $0)?.isDefaultRoute == true }
        }
        guard peersWithDefaultRoute.count == 1, let index = peersWithDefaultRoute.first else {
            throw TunnelRoutingError.ambiguousFullTunnelPeer
        }
        return index
    }

    private static func routePrefix(from range: IPAddressRange) -> RoutePrefix? {
        try? RoutePrefix(range.stringRepresentation)
    }

    private static func validatedRoutePrefix(_ range: IPAddressRange) throws -> RoutePrefix {
        guard let route = routePrefix(from: range) else {
            throw TunnelRoutingError.invalidStoredRoutes
        }
        return route
    }

    private static func validatedIPAddressRange(_ notation: String) throws -> IPAddressRange {
        _ = try RoutePrefix(notation)
        guard let range = IPAddressRange(from: notation) else {
            throw TunnelRoutingError.invalidStoredRoutes
        }
        return range
    }

    private static func stableUnique(_ routes: [String]) -> [String] {
        var seen = Set<String>()
        return routes.filter { seen.insert($0).inserted }
    }
}
