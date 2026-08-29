// SPDX-License-Identifier: MIT

import Foundation
import Network

public struct RoutePrefix: Hashable, Sendable {
    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case invalidFormat(String)
        case invalidAddress(String)
        case invalidPrefixLength(String)

        public var errorDescription: String? {
            switch self {
            case .invalidFormat(let value):
                return "\(value) is not an address and prefix."
            case .invalidAddress(let value):
                return "\(value) does not contain a valid IP address."
            case .invalidPrefixLength(let value):
                return "\(value) has an invalid prefix length."
            }
        }
    }

    public let address: String
    public let prefixLength: UInt8
    public let family: IPFamily

    private init(address: String, prefixLength: UInt8, family: IPFamily) {
        self.address = address
        self.prefixLength = prefixLength
        self.family = family
    }

    public init(_ notation: String) throws {
        let trimmedNotation = notation.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmedNotation.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else {
            throw ValidationError.invalidFormat(notation)
        }

        let address = String(components[0])
        guard let prefixLength = UInt8(components[1]) else {
            throw ValidationError.invalidPrefixLength(notation)
        }

        if let ipv4Address = IPv4Address(address) {
            guard prefixLength <= 32 else {
                throw ValidationError.invalidPrefixLength(notation)
            }
            self.address = ipv4Address.debugDescription
            self.prefixLength = prefixLength
            self.family = .ipv4
        } else if let ipv6Address = IPv6Address(address) {
            guard prefixLength <= 128 else {
                throw ValidationError.invalidPrefixLength(notation)
            }
            self.address = ipv6Address.debugDescription
            self.prefixLength = prefixLength
            self.family = .ipv6
        } else {
            throw ValidationError.invalidAddress(notation)
        }
    }

    public var notation: String {
        "\(address)/\(prefixLength)"
    }

    public var isDefaultRoute: Bool {
        prefixLength == 0
    }

    public func contains(address candidate: String) -> Bool {
        let routeBytes: Data
        let candidateBytes: Data
        switch family {
        case .ipv4:
            guard let routeAddress = IPv4Address(address),
                  let candidateAddress = IPv4Address(candidate) else {
                return false
            }
            routeBytes = routeAddress.rawValue
            candidateBytes = candidateAddress.rawValue
        case .ipv6:
            guard let routeAddress = IPv6Address(address),
                  let candidateAddress = IPv6Address(candidate) else {
                return false
            }
            routeBytes = routeAddress.rawValue
            candidateBytes = candidateAddress.rawValue
        }

        let wholeBytes = Int(prefixLength / 8)
        let remainingBits = Int(prefixLength % 8)
        guard routeBytes.prefix(wholeBytes).elementsEqual(candidateBytes.prefix(wholeBytes)) else {
            return false
        }
        guard remainingBits > 0 else { return true }
        let mask = UInt8.max << UInt8(8 - remainingBits)
        return routeBytes[wholeBytes] & mask == candidateBytes[wholeBytes] & mask
    }

    public static func parseList(_ value: String) throws -> [RoutePrefix] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        let notations = value.components(separatedBy: separators).filter { !$0.isEmpty }
        var seen = Set<RoutePrefix>()
        return try notations
            .map(RoutePrefix.init)
            .filter { seen.insert($0).inserted }
    }

    static func defaultRoute(for family: IPFamily) -> RoutePrefix {
        switch family {
        case .ipv4:
            // These values are protocol-defined route semantics, not profile defaults.
            return RoutePrefix(address: "0.0.0.0", prefixLength: 0, family: .ipv4)
        case .ipv6:
            return RoutePrefix(address: "::", prefixLength: 0, family: .ipv6)
        }
    }
}

public struct ProfileDNSRouteSummary: Equatable, Sendable {
    public struct Server: Equatable, Sendable {
        public enum Route: Equatable, Sendable {
            case throughTunnel
            case outsideTunnel
        }

        public let address: String
        public let route: Route
    }

    public let isConfigurationAvailable: Bool
    public let servers: [Server]
    public let searchDomains: [String]

    public init(
        dnsServers: [String],
        searchDomains: [String],
        allowedRoutes: [RoutePrefix],
        isConfigurationAvailable: Bool = true
    ) {
        self.isConfigurationAvailable = isConfigurationAvailable
        servers = dnsServers.map { address in
            Server(
                address: address,
                route: allowedRoutes.contains { $0.contains(address: address) }
                    ? .throughTunnel
                    : .outsideTunnel
            )
        }
        self.searchDomains = searchDomains
    }
}

extension RoutePrefix: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let notation = try container.decode(String.self)
        try self.init(notation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(notation)
    }
}
