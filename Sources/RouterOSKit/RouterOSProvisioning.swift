// SPDX-License-Identifier: MIT

import Foundation
import Network

#if SWIFT_PACKAGE
import WireRouteCore
#endif

public enum RouterOSProvisioningError: Error, Equatable, LocalizedError, Sendable {
    case missingInterface
    case missingPeerName
    case invalidKey
    case invalidClientAddress
    case duplicatePublicKey
    case overlappingClientAddress(String)
    case invalidPersistentKeepalive
    case missingEndpoint
    case invalidEndpoint
    case invalidEndpointPort
    case missingClientRoutes
    case invalidClientRoute(String)
    case invalidDNSServer(String)

    public var errorDescription: String? {
        switch self {
        case .missingInterface:
            return "Select a WireGuard interface."
        case .missingPeerName:
            return "Enter a name for this peer."
        case .invalidKey:
            return "A WireGuard key is invalid."
        case .invalidClientAddress:
            return "The client address must be one IPv4 /32 or IPv6 /128 address."
        case .duplicatePublicKey:
            return "This WireGuard public key already exists on the selected interface."
        case .overlappingClientAddress(let address):
            return "The client address overlaps the existing RouterOS peer route \(address)."
        case .invalidPersistentKeepalive:
            return "Persistent keepalive must be between 0 and 65535 seconds."
        case .missingEndpoint:
            return "Enter the public hostname or address clients use to reach this router."
        case .invalidEndpoint:
            return "Enter only a public hostname or IP address, without a URL scheme, path, or port."
        case .invalidEndpointPort:
            return "The endpoint port must be between 1 and 65535."
        case .missingClientRoutes:
            return "Choose at least one route for the client profile."
        case .invalidClientRoute(let value):
            return "\(value) is not a valid client route."
        case .invalidDNSServer(let value):
            return "\(value) is not a valid DNS server address."
        }
    }
}

public struct RouterOSPublicEndpointSuggestion: Equatable, Sendable {
    public let address: String

    public static func discover(from addresses: [RouterOSIPAddress]) -> Self? {
        let candidates = Set(addresses.compactMap { address -> String? in
            guard !address.isDisabled, !address.isInvalid,
                  let prefix = try? RoutePrefix(address.address),
                  prefix.family == .ipv4,
                  let ipv4Address = IPv4Address(prefix.address),
                  Self.isPublic(ipv4Address) else {
                return nil
            }
            return ipv4Address.debugDescription
        })
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return Self(address: candidate)
    }

    private static func isPublic(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1], bytes[2]) {
        case (0, _, _), (10, _, _), (127, _, _):
            return false
        case (100, 64 ... 127, _):
            return false
        case (169, 254, _):
            return false
        case (172, 16 ... 31, _):
            return false
        case (192, 0, 0), (192, 0, 2), (192, 168, _):
            return false
        case (198, 18 ... 19, _), (198, 51, 100), (203, 0, 113):
            return false
        case (224 ... 255, _, _):
            return false
        default:
            return true
        }
    }
}

public struct RouterOSPeerDefaults: Equatable, Sendable {
    public let endpointAddress: String?
    public let dnsServers: [String]
    public let splitRoutes: [RoutePrefix]
    public let persistentKeepalive: UInt16

    public static var standard: Self {
        Self(
            endpointAddress: nil,
            dnsServers: [],
            splitRoutes: [RoutePrefix](),
            persistentKeepalive: UInt16(25)
        )
    }

    private init(
        endpointAddress: String?,
        dnsServers: [String],
        splitRoutes: [RoutePrefix],
        persistentKeepalive: UInt16
    ) {
        self.endpointAddress = endpointAddress
        self.dnsServers = dnsServers
        self.splitRoutes = splitRoutes
        self.persistentKeepalive = persistentKeepalive
    }

    public init(
        endpointAddress: String?,
        dnsServers: [String],
        splitRoutes: [String],
        persistentKeepalive: Int = 25
    ) throws {
        let trimmedEndpoint = endpointAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEndpoint: String?
        if let trimmedEndpoint, !trimmedEndpoint.isEmpty {
            guard let endpoint = WireGuardClientConfiguration.normalizedEndpointAddress(trimmedEndpoint) else {
                throw RouterOSProvisioningError.invalidEndpoint
            }
            normalizedEndpoint = endpoint
        } else {
            normalizedEndpoint = nil
        }

        var normalizedDNSServers = [String]()
        for dnsServer in dnsServers {
            guard let address = WireGuardClientConfiguration.normalizedIPAddress(dnsServer) else {
                throw RouterOSProvisioningError.invalidDNSServer(dnsServer)
            }
            normalizedDNSServers.append(address)
        }

        var parsedRoutes = [RoutePrefix]()
        for route in splitRoutes {
            do {
                parsedRoutes.append(try RoutePrefix(route))
            } catch {
                throw RouterOSProvisioningError.invalidClientRoute(route)
            }
        }
        guard (0 ... Int(UInt16.max)).contains(persistentKeepalive) else {
            throw RouterOSProvisioningError.invalidPersistentKeepalive
        }

        self.init(
            endpointAddress: normalizedEndpoint,
            dnsServers: normalizedDNSServers,
            splitRoutes: parsedRoutes,
            persistentKeepalive: UInt16(persistentKeepalive)
        )
    }
}

public struct RouterOSClientAddressSuggestion: Equatable, Sendable {
    public let address: RoutePrefix
    public let sourceAddressCount: Int

    public static func discover(
        for interfaceName: String,
        existingPeers: [RouterOSWireGuardPeer]
    ) -> Self? {
        let peersOnInterface = existingPeers.filter { $0.interfaceName == interfaceName }
        let existingPrefixes = peersOnInterface
            .flatMap(\.allowedAddresses)
            .compactMap { try? RoutePrefix($0) }

        var uniqueHostAddresses = Set<Data>()
        for prefix in existingPrefixes where prefix.family == .ipv4 && prefix.prefixLength == 32 {
            guard let address = IPv4Address(prefix.address) else { continue }
            uniqueHostAddresses.insert(address.rawValue)
        }

        let pools = Dictionary(grouping: uniqueHostAddresses) { Data($0.prefix(3)) }
        guard let largestPoolSize = pools.values.map(\.count).max() else { return nil }
        let largestPools = pools.values.filter { $0.count == largestPoolSize }
        guard largestPools.count == 1, let pool = largestPools.first,
              let highestHost = pool.compactMap(\.last).max(), highestHost < 254,
              var candidateBytes = pool.first else {
            return nil
        }

        candidateBytes[3] = highestHost + 1
        guard let candidateAddress = IPv4Address(candidateBytes),
              let candidate = try? RoutePrefix("\(candidateAddress.debugDescription)/32"),
              !existingPrefixes.contains(where: { RouterOSPeerCreation.overlaps(candidate, $0) }) else {
            return nil
        }

        return Self(address: candidate, sourceAddressCount: pool.count)
    }
}

public struct RouterOSPeerCreation: Equatable, Sendable {
    public let interfaceName: String
    public let name: String
    public let comment: String?
    public let publicKey: String
    public let clientAddress: RoutePrefix
    public let persistentKeepalive: UInt16
    public let isResponder: Bool

    public init(
        interfaceName: String,
        name: String,
        comment: String? = nil,
        publicKey: String,
        clientAddress: String,
        persistentKeepalive: Int = 25,
        isResponder: Bool = true,
        existingPeers: [RouterOSWireGuardPeer] = []
    ) throws {
        let interfaceName = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !interfaceName.isEmpty else {
            throw RouterOSProvisioningError.missingInterface
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw RouterOSProvisioningError.missingPeerName
        }
        guard Self.isWireGuardKey(publicKey) else {
            throw RouterOSProvisioningError.invalidKey
        }
        guard (0 ... Int(UInt16.max)).contains(persistentKeepalive) else {
            throw RouterOSProvisioningError.invalidPersistentKeepalive
        }

        let parsedClientAddress: RoutePrefix
        do {
            parsedClientAddress = try RoutePrefix(clientAddress)
        } catch {
            throw RouterOSProvisioningError.invalidClientAddress
        }
        let requiredPrefixLength: UInt8 = parsedClientAddress.family == .ipv4 ? 32 : 128
        guard parsedClientAddress.prefixLength == requiredPrefixLength else {
            throw RouterOSProvisioningError.invalidClientAddress
        }

        let peersOnInterface = existingPeers.filter { $0.interfaceName == interfaceName }
        guard !peersOnInterface.contains(where: { $0.publicKey == publicKey }) else {
            throw RouterOSProvisioningError.duplicatePublicKey
        }
        for existingAddress in peersOnInterface.flatMap(\.allowedAddresses) {
            guard let existingPrefix = try? RoutePrefix(existingAddress) else { continue }
            if Self.overlaps(parsedClientAddress, existingPrefix) {
                throw RouterOSProvisioningError.overlappingClientAddress(existingPrefix.notation)
            }
        }

        self.interfaceName = interfaceName
        self.name = name
        self.comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.publicKey = publicKey
        self.clientAddress = parsedClientAddress
        self.persistentKeepalive = UInt16(persistentKeepalive)
        self.isResponder = isResponder
    }

    var requestPayload: RouterOSPeerCreateRequest {
        RouterOSPeerCreateRequest(
            interfaceName: interfaceName,
            name: name,
            comment: comment,
            publicKey: publicKey,
            allowedAddress: clientAddress.notation,
            persistentKeepalive: "\(persistentKeepalive)s",
            responder: isResponder ? "true" : "false"
        )
    }

    static func isWireGuardKey(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value), data.count == 32 else { return false }
        return data.base64EncodedString() == value
    }

    fileprivate static func overlaps(_ lhs: RoutePrefix, _ rhs: RoutePrefix) -> Bool {
        guard lhs.family == rhs.family,
              let lhsBytes = addressBytes(lhs.address, family: lhs.family),
              let rhsBytes = addressBytes(rhs.address, family: rhs.family) else {
            return false
        }
        let sharedPrefixLength = min(lhs.prefixLength, rhs.prefixLength)
        let fullBytes = Int(sharedPrefixLength / 8)
        guard lhsBytes.prefix(fullBytes).elementsEqual(rhsBytes.prefix(fullBytes)) else {
            return false
        }
        let remainingBits = Int(sharedPrefixLength % 8)
        guard remainingBits > 0 else { return true }
        let mask = UInt8.max << (8 - remainingBits)
        return lhsBytes[fullBytes] & mask == rhsBytes[fullBytes] & mask
    }

    private static func addressBytes(_ value: String, family: IPFamily) -> Data? {
        switch family {
        case .ipv4:
            return IPv4Address(value)?.rawValue
        case .ipv6:
            return IPv6Address(value)?.rawValue
        }
    }
}

public struct WireGuardClientConfiguration: Equatable, Sendable {
    public let name: String
    public let privateKey: String
    public let clientAddress: RoutePrefix
    public let dnsServers: [String]
    public let serverPublicKey: String
    public let endpointAddress: String
    public let endpointPort: UInt16
    public let allowedIPs: [RoutePrefix]
    public let persistentKeepalive: UInt16

    public init(
        name: String,
        privateKey: String,
        clientAddress: String,
        dnsServers: [String],
        serverPublicKey: String,
        endpointAddress: String,
        endpointPort: Int,
        allowedIPs: [String],
        persistentKeepalive: Int = 25
    ) throws {
        guard RouterOSPeerCreation.isWireGuardKey(privateKey),
              RouterOSPeerCreation.isWireGuardKey(serverPublicKey) else {
            throw RouterOSProvisioningError.invalidKey
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw RouterOSProvisioningError.missingPeerName
        }
        let endpointAddress = endpointAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointAddress.isEmpty else {
            throw RouterOSProvisioningError.missingEndpoint
        }
        guard let normalizedEndpointAddress = Self.normalizedEndpointAddress(endpointAddress) else {
            throw RouterOSProvisioningError.invalidEndpoint
        }
        guard (1 ... Int(UInt16.max)).contains(endpointPort) else {
            throw RouterOSProvisioningError.invalidEndpointPort
        }
        guard (0 ... Int(UInt16.max)).contains(persistentKeepalive) else {
            throw RouterOSProvisioningError.invalidPersistentKeepalive
        }

        let parsedClientAddress: RoutePrefix
        do {
            parsedClientAddress = try RoutePrefix(clientAddress)
        } catch {
            throw RouterOSProvisioningError.invalidClientAddress
        }
        let requiredPrefixLength: UInt8 = parsedClientAddress.family == .ipv4 ? 32 : 128
        guard parsedClientAddress.prefixLength == requiredPrefixLength else {
            throw RouterOSProvisioningError.invalidClientAddress
        }

        let parsedAllowedIPs: [RoutePrefix]
        do {
            parsedAllowedIPs = try allowedIPs.map(RoutePrefix.init)
        } catch {
            throw RouterOSProvisioningError.missingClientRoutes
        }
        guard !parsedAllowedIPs.isEmpty else {
            throw RouterOSProvisioningError.missingClientRoutes
        }

        var normalizedDNSServers = [String]()
        for dnsServer in dnsServers {
            guard let normalizedAddress = Self.normalizedIPAddress(dnsServer) else {
                throw RouterOSProvisioningError.invalidDNSServer(dnsServer)
            }
            normalizedDNSServers.append(normalizedAddress)
        }

        self.name = name
        self.privateKey = privateKey
        self.clientAddress = parsedClientAddress
        self.dnsServers = normalizedDNSServers
        self.serverPublicKey = serverPublicKey
        self.endpointAddress = normalizedEndpointAddress
        self.endpointPort = UInt16(endpointPort)
        self.allowedIPs = parsedAllowedIPs
        self.persistentKeepalive = UInt16(persistentKeepalive)
    }

    public var wgQuickConfiguration: String {
        var interfaceLines = [
            "[Interface]",
            "PrivateKey = \(privateKey)",
            "Address = \(clientAddress.notation)"
        ]
        if !dnsServers.isEmpty {
            interfaceLines.append("DNS = \(dnsServers.joined(separator: ", "))")
        }
        let endpoint = endpointAddress.contains(":") && !endpointAddress.hasPrefix("[")
            ? "[\(endpointAddress)]"
            : endpointAddress
        return (interfaceLines + [
            "",
            "[Peer]",
            "PublicKey = \(serverPublicKey)",
            "Endpoint = \(endpoint):\(endpointPort)",
            "AllowedIPs = \(allowedIPs.map(\.notation).joined(separator: ", "))",
            "PersistentKeepalive = \(persistentKeepalive)",
            ""
        ]).joined(separator: "\n")
    }

    fileprivate static func normalizedIPAddress(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = IPv4Address(value) {
            return address.debugDescription
        }
        if let address = IPv6Address(value) {
            return address.debugDescription
        }
        return nil
    }

    fileprivate static func normalizedEndpointAddress(_ value: String) -> String? {
        let unwrappedValue: String
        if value.hasPrefix("[") && value.hasSuffix("]") {
            unwrappedValue = String(value.dropFirst().dropLast())
        } else {
            unwrappedValue = value
        }
        if let address = IPv4Address(unwrappedValue) {
            return address.debugDescription
        }
        if let address = IPv6Address(unwrappedValue) {
            return address.debugDescription
        }
        guard !unwrappedValue.isEmpty,
              !unwrappedValue.contains(where: \.isWhitespace),
              !unwrappedValue.contains(where: { "/?#@[]:".contains($0) }),
              !unwrappedValue.hasPrefix("."),
              !unwrappedValue.hasSuffix("."),
              !unwrappedValue.contains(".."),
              unwrappedValue.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else {
            return nil
        }
        return unwrappedValue
    }
}

struct RouterOSPeerCreateRequest: Encodable {
    let interfaceName: String
    let name: String
    let comment: String?
    let publicKey: String
    let allowedAddress: String
    let persistentKeepalive: String
    let responder: String

    private enum CodingKeys: String, CodingKey {
        case interfaceName = "interface"
        case name
        case comment
        case publicKey = "public-key"
        case allowedAddress = "allowed-address"
        case persistentKeepalive = "persistent-keepalive"
        case responder
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
