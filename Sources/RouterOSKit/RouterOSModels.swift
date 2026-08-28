// SPDX-License-Identifier: MIT

import Foundation

public struct RouterOSCredentials: CustomDebugStringConvertible, CustomStringConvertible, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String {
        "RouterOSCredentials(username: \(username), password: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

public struct RouterOSWireGuardInterface: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mtu: Int?
    public let listenPort: Int?
    public let publicKey: String
    public let isDisabled: Bool
    public let isRunning: Bool

    private enum CodingKeys: String, CodingKey {
        case id = ".id"
        case name
        case mtu
        case listenPort = "listen-port"
        case publicKey = "public-key"
        case disabled
        case running
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mtu = container.routerOSInteger(forKey: .mtu)
        listenPort = container.routerOSInteger(forKey: .listenPort)
        publicKey = try container.decode(String.self, forKey: .publicKey)
        isDisabled = container.routerOSBoolean(forKey: .disabled) ?? false
        isRunning = container.routerOSBoolean(forKey: .running) ?? false
    }
}

public struct RouterOSWireGuardPeer: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let interfaceName: String
    public let name: String?
    public let comment: String?
    public let publicKey: String
    public let allowedAddresses: [String]
    public let endpointAddress: String?
    public let endpointPort: Int?
    public let currentEndpointAddress: String?
    public let currentEndpointPort: Int?
    public let persistentKeepalive: String?
    public let lastHandshake: String?
    public let receivedBytes: UInt64?
    public let transmittedBytes: UInt64?
    public let isDisabled: Bool
    public let isDynamic: Bool
    public let isResponder: Bool

    private enum CodingKeys: String, CodingKey {
        case id = ".id"
        case interfaceName = "interface"
        case name
        case comment
        case publicKey = "public-key"
        case allowedAddresses = "allowed-address"
        case endpointAddress = "endpoint-address"
        case endpointPort = "endpoint-port"
        case currentEndpointAddress = "current-endpoint-address"
        case currentEndpointPort = "current-endpoint-port"
        case persistentKeepalive = "persistent-keepalive"
        case lastHandshake = "last-handshake"
        case receivedBytes = "rx"
        case transmittedBytes = "tx"
        case disabled
        case dynamic
        case responder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        interfaceName = try container.decode(String.self, forKey: .interfaceName)
        name = container.routerOSString(forKey: .name)
        comment = container.routerOSString(forKey: .comment)
        publicKey = try container.decode(String.self, forKey: .publicKey)
        allowedAddresses = Self.splitList(container.routerOSString(forKey: .allowedAddresses))
        endpointAddress = container.routerOSString(forKey: .endpointAddress)
        endpointPort = container.routerOSInteger(forKey: .endpointPort)
        currentEndpointAddress = container.routerOSString(forKey: .currentEndpointAddress)
        currentEndpointPort = container.routerOSInteger(forKey: .currentEndpointPort)
        persistentKeepalive = container.routerOSString(forKey: .persistentKeepalive)
        lastHandshake = container.routerOSString(forKey: .lastHandshake)
        receivedBytes = container.routerOSUnsignedInteger(forKey: .receivedBytes)
        transmittedBytes = container.routerOSUnsignedInteger(forKey: .transmittedBytes)
        isDisabled = container.routerOSBoolean(forKey: .disabled) ?? false
        isDynamic = container.routerOSBoolean(forKey: .dynamic) ?? false
        isResponder = container.routerOSBoolean(forKey: .responder) ?? false
    }

    private static func splitList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct RouterOSIPAddress: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let address: String
    public let network: String?
    public let interfaceName: String
    public let actualInterfaceName: String?
    public let isDisabled: Bool
    public let isDynamic: Bool
    public let isInvalid: Bool

    private enum CodingKeys: String, CodingKey {
        case id = ".id"
        case address
        case network
        case interfaceName = "interface"
        case actualInterfaceName = "actual-interface"
        case disabled
        case dynamic
        case invalid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        address = try container.decode(String.self, forKey: .address)
        network = container.routerOSString(forKey: .network)
        interfaceName = try container.decode(String.self, forKey: .interfaceName)
        actualInterfaceName = container.routerOSString(forKey: .actualInterfaceName)
        isDisabled = container.routerOSBoolean(forKey: .disabled) ?? false
        isDynamic = container.routerOSBoolean(forKey: .dynamic) ?? false
        isInvalid = container.routerOSBoolean(forKey: .invalid) ?? false
    }
}

private extension KeyedDecodingContainer {
    func routerOSString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func routerOSInteger(forKey key: Key) -> Int? {
        guard let value = routerOSString(forKey: key) else { return nil }
        return Int(value)
    }

    func routerOSUnsignedInteger(forKey key: Key) -> UInt64? {
        guard let value = routerOSString(forKey: key) else { return nil }
        return UInt64(value)
    }

    func routerOSBoolean(forKey key: Key) -> Bool? {
        switch routerOSString(forKey: key)?.lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }
}
