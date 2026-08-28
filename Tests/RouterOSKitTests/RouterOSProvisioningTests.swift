// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import RouterOSKit

final class RouterOSProvisioningTests: XCTestCase {
    private let clientPrivateKey = Data(repeating: 1, count: 32).base64EncodedString()
    private let clientPublicKey = Data(repeating: 2, count: 32).base64EncodedString()
    private let serverPublicKey = Data(repeating: 3, count: 32).base64EncodedString()

    func testCreatesValidatedRouterPeerAndClientConfiguration() throws {
        let peer = try RouterOSPeerCreation(
            interfaceName: " wg-remote ",
            name: " iPhone 12 Dev ",
            comment: " WireRoute mobile ",
            publicKey: clientPublicKey,
            clientAddress: "10.255.100.10/32"
        )
        let client = try WireGuardClientConfiguration(
            name: peer.name,
            privateKey: clientPrivateKey,
            clientAddress: peer.clientAddress.notation,
            dnsServers: ["192.168.80.45", "192.168.80.46"],
            serverPublicKey: serverPublicKey,
            endpointAddress: "vpn.example.com",
            endpointPort: 51824,
            allowedIPs: ["192.168.0.0/16", "10.255.0.0/16"]
        )

        XCTAssertEqual(peer.interfaceName, "wg-remote")
        XCTAssertEqual(peer.name, "iPhone 12 Dev")
        XCTAssertEqual(peer.comment, "WireRoute mobile")
        XCTAssertEqual(peer.clientAddress.notation, "10.255.100.10/32")
        XCTAssertEqual(client.allowedIPs.map(\.notation), ["192.168.0.0/16", "10.255.0.0/16"])
        XCTAssertEqual(
            client.wgQuickConfiguration,
            """
            [Interface]
            PrivateKey = \(clientPrivateKey)
            Address = 10.255.100.10/32
            DNS = 192.168.80.45, 192.168.80.46

            [Peer]
            PublicKey = \(serverPublicKey)
            Endpoint = vpn.example.com:51824
            AllowedIPs = 192.168.0.0/16, 10.255.0.0/16
            PersistentKeepalive = 25

            """
        )
    }

    func testRejectsDuplicateKeysAndOverlappingAddressesOnSelectedInterface() throws {
        let existingPeer = try makePeer(
            interfaceName: "wg-remote",
            publicKey: clientPublicKey,
            allowedAddress: "10.255.100.0/24"
        )

        XCTAssertThrowsError(
            try RouterOSPeerCreation(
                interfaceName: "wg-remote",
                name: "Duplicate key",
                publicKey: clientPublicKey,
                clientAddress: "10.255.101.10/32",
                existingPeers: [existingPeer]
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSProvisioningError, .duplicatePublicKey)
        }

        XCTAssertThrowsError(
            try RouterOSPeerCreation(
                interfaceName: "wg-remote",
                name: "Overlap",
                publicKey: Data(repeating: 4, count: 32).base64EncodedString(),
                clientAddress: "10.255.100.10/32",
                existingPeers: [existingPeer]
            )
        ) { error in
            XCTAssertEqual(
                error as? RouterOSProvisioningError,
                .overlappingClientAddress("10.255.100.0/24")
            )
        }
    }

    func testAllowsSameClientAddressOnDifferentInterface() throws {
        let existingPeer = try makePeer(
            interfaceName: "wg-other",
            publicKey: Data(repeating: 5, count: 32).base64EncodedString(),
            allowedAddress: "10.255.100.10/32"
        )

        XCTAssertNoThrow(
            try RouterOSPeerCreation(
                interfaceName: "wg-remote",
                name: "iPhone",
                publicKey: clientPublicKey,
                clientAddress: "10.255.100.10/32",
                existingPeers: [existingPeer]
            )
        )
    }

    func testRejectsNonHostClientAddressesAndInvalidDNS() {
        XCTAssertThrowsError(
            try RouterOSPeerCreation(
                interfaceName: "wg-remote",
                name: "iPhone",
                publicKey: clientPublicKey,
                clientAddress: "10.255.100.0/24"
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSProvisioningError, .invalidClientAddress)
        }

        XCTAssertThrowsError(
            try WireGuardClientConfiguration(
                name: "iPhone",
                privateKey: clientPrivateKey,
                clientAddress: "10.255.100.10/32",
                dnsServers: ["dns.example.com"],
                serverPublicKey: serverPublicKey,
                endpointAddress: "vpn.example.com",
                endpointPort: 51824,
                allowedIPs: ["192.168.0.0/16"]
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSProvisioningError, .invalidDNSServer("dns.example.com"))
        }
    }

    func testFormatsIPv6EndpointsWithBrackets() throws {
        let client = try WireGuardClientConfiguration(
            name: "IPv6 client",
            privateKey: clientPrivateKey,
            clientAddress: "fd00::10/128",
            dnsServers: ["2001:4860:4860::8888"],
            serverPublicKey: serverPublicKey,
            endpointAddress: "2001:db8::1",
            endpointPort: 51824,
            allowedIPs: ["::/0"]
        )

        XCTAssertTrue(client.wgQuickConfiguration.contains("Endpoint = [2001:db8::1]:51824"))
    }

    func testRejectsEndpointURLsAndEmbeddedPorts() {
        for endpoint in ["https://vpn.example.com", "vpn.example.com/path", "vpn.example.com:51824", "[]"] {
            XCTAssertThrowsError(
                try WireGuardClientConfiguration(
                    name: "iPhone",
                    privateKey: clientPrivateKey,
                    clientAddress: "10.255.100.10/32",
                    dnsServers: [],
                    serverPublicKey: serverPublicKey,
                    endpointAddress: endpoint,
                    endpointPort: 51824,
                    allowedIPs: ["192.168.0.0/16"]
                )
            ) { error in
                XCTAssertEqual(error as? RouterOSProvisioningError, .invalidEndpoint)
            }
        }
    }

    private func makePeer(
        interfaceName: String,
        publicKey: String,
        allowedAddress: String
    ) throws -> RouterOSWireGuardPeer {
        let data = Data("""
        {
          ".id": "*A",
          "interface": "\(interfaceName)",
          "name": "Existing",
          "public-key": "\(publicKey)",
          "allowed-address": "\(allowedAddress)",
          "disabled": "false",
          "dynamic": "false",
          "responder": "true"
        }
        """.utf8)
        return try JSONDecoder().decode(RouterOSWireGuardPeer.self, from: data)
    }
}
