// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network

public enum DNSProtectionMode: String, Sendable {
    case profile
    case encryptedHTTPS
}

public enum DNSProtectionPolicyError: Error, Equatable, Sendable {
    case invalidServerURL
    case invalidBootstrapServer(String)
    case invalidStoredPolicy
}

public struct DNSProtectionPolicy: Equatable, Sendable {
    public let mode: DNSProtectionMode
    public let serverURL: URL?
    public let bootstrapServers: [String]

    public static let profile = DNSProtectionPolicy(
        mode: .profile,
        serverURL: nil,
        bootstrapServers: []
    )

    private init(mode: DNSProtectionMode, serverURL: URL?, bootstrapServers: [String]) {
        self.mode = mode
        self.serverURL = serverURL
        self.bootstrapServers = bootstrapServers
    }

    public static func encryptedHTTPS(
        serverURLString: String,
        bootstrapServerStrings: [String]
    ) throws -> DNSProtectionPolicy {
        let normalizedURLString = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: normalizedURLString),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let serverURL = components.url else {
            throw DNSProtectionPolicyError.invalidServerURL
        }

        var seenServers = Set<String>()
        var bootstrapServers = [String]()
        for serverString in bootstrapServerStrings {
            let normalizedServer = serverString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedServer.isEmpty else { continue }
            guard let server = DNSServer(from: normalizedServer) else {
                throw DNSProtectionPolicyError.invalidBootstrapServer(normalizedServer)
            }
            let canonicalServer = server.stringRepresentation
            if seenServers.insert(canonicalServer).inserted {
                bootstrapServers.append(canonicalServer)
            }
        }

        return DNSProtectionPolicy(
            mode: .encryptedHTTPS,
            serverURL: serverURL,
            bootstrapServers: bootstrapServers
        )
    }
}

public struct DNSServer {
    public let address: IPAddress

    public init(address: IPAddress) {
        self.address = address
    }
}

extension DNSServer: Equatable {
    public static func == (lhs: DNSServer, rhs: DNSServer) -> Bool {
        return lhs.address.rawValue == rhs.address.rawValue
    }
}

extension DNSServer {
    public var stringRepresentation: String {
        return "\(address)"
    }

    public init?(from addressString: String) {
        if let addr = IPv4Address(addressString) {
            address = addr
        } else if let addr = IPv6Address(addressString) {
            address = addr
        } else {
            return nil
        }
    }
}
