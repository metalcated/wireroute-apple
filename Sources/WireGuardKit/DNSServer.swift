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

public enum DNSProtectionPreset: String, CaseIterable, Sendable {
    case cloudflare
    case cloudflareSecurity
    case cloudflareFamily
    case adGuard
    case adGuardFamily
    case quad9
    case google

    public var serverURLString: String {
        switch self {
        case .cloudflare:
            return "https://cloudflare-dns.com/dns-query"
        case .cloudflareSecurity:
            return "https://security.cloudflare-dns.com/dns-query"
        case .cloudflareFamily:
            return "https://family.cloudflare-dns.com/dns-query"
        case .adGuard:
            return "https://dns.adguard-dns.com/dns-query"
        case .adGuardFamily:
            return "https://family.adguard-dns.com/dns-query"
        case .quad9:
            return "https://dns.quad9.net/dns-query"
        case .google:
            return "https://dns.google/dns-query"
        }
    }

    public var bootstrapServers: [String] {
        switch self {
        case .cloudflare:
            return ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
        case .cloudflareSecurity:
            return ["1.1.1.2", "1.0.0.2", "2606:4700:4700::1112", "2606:4700:4700::1002"]
        case .cloudflareFamily:
            return ["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"]
        case .adGuard:
            return ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"]
        case .adGuardFamily:
            return ["94.140.14.15", "94.140.15.16", "2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff"]
        case .quad9:
            return ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
        case .google:
            return ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]
        }
    }

    public func makePolicy() throws -> DNSProtectionPolicy {
        return try DNSProtectionPolicy.encryptedHTTPS(
            serverURLString: serverURLString,
            bootstrapServerStrings: bootstrapServers
        )
    }

    public static func matching(_ policy: DNSProtectionPolicy) -> DNSProtectionPreset? {
        guard policy.mode == .encryptedHTTPS else { return nil }
        return allCases.first { preset in
            policy.serverURL?.absoluteString == preset.serverURLString &&
                policy.bootstrapServers == preset.bootstrapServers
        }
    }
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
