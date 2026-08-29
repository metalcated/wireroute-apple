// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import RouterOSKit

final class RouterOSProvisioningTests: XCTestCase {
    private let clientPrivateKey = Data(repeating: 1, count: 32).base64EncodedString()
    private let clientPublicKey = Data(repeating: 2, count: 32).base64EncodedString()
    private let serverPublicKey = Data(repeating: 3, count: 32).base64EncodedString()

    func testRecognizesWireRouteManagedPeerComment() {
        XCTAssertTrue(RouterOSPeerCreation.isWireRouteManagedComment("Managed by WireRoute"))
        XCTAssertTrue(RouterOSPeerCreation.isWireRouteManagedComment("  managed by wireroute  "))
        XCTAssertFalse(RouterOSPeerCreation.isWireRouteManagedComment("Router1"))
        XCTAssertFalse(RouterOSPeerCreation.isWireRouteManagedComment(nil))
    }

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

    func testValidatesExistingPeerConfigurationIdentity() throws {
        let peer = try makePeer(
            interfaceName: "wg-remote",
            publicKey: clientPublicKey,
            allowedAddress: "10.255.100.10/32,192.168.0.0/16"
        )
        let interface = try makeInterface(
            name: "wg-remote",
            publicKey: serverPublicKey
        )

        XCTAssertNoThrow(
            try RouterOSExistingPeerImportValidator.validate(
                peer: peer,
                interfaces: [interface],
                clientPublicKey: clientPublicKey,
                clientAddresses: ["10.255.100.10/24"],
                serverPublicKeys: [serverPublicKey]
            )
        )
    }

    func testRejectsExistingPeerConfigurationIdentityMismatches() throws {
        let peer = try makePeer(
            interfaceName: "wg-remote",
            publicKey: clientPublicKey,
            allowedAddress: "10.255.100.10/32"
        )
        let interface = try makeInterface(
            name: "wg-remote",
            publicKey: serverPublicKey
        )

        XCTAssertThrowsError(
            try RouterOSExistingPeerImportValidator.validate(
                peer: peer,
                interfaces: [interface],
                clientPublicKey: Data(repeating: 9, count: 32).base64EncodedString(),
                clientAddresses: ["10.255.100.10/32"],
                serverPublicKeys: [serverPublicKey]
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSExistingPeerImportError, .clientPublicKeyMismatch)
        }

        XCTAssertThrowsError(
            try RouterOSExistingPeerImportValidator.validate(
                peer: peer,
                interfaces: [interface],
                clientPublicKey: clientPublicKey,
                clientAddresses: ["10.255.100.10/32"],
                serverPublicKeys: [Data(repeating: 8, count: 32).base64EncodedString()]
            )
        ) { error in
            XCTAssertEqual(
                error as? RouterOSExistingPeerImportError,
                .serverPublicKeyMismatch("wg-remote")
            )
        }

        XCTAssertThrowsError(
            try RouterOSExistingPeerImportValidator.validate(
                peer: peer,
                interfaces: [interface],
                clientPublicKey: clientPublicKey,
                clientAddresses: ["10.255.100.11/32"],
                serverPublicKeys: [serverPublicKey]
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSExistingPeerImportError, .clientAddressMismatch)
        }

        XCTAssertThrowsError(
            try RouterOSExistingPeerImportValidator.validate(
                peer: peer,
                interfaces: [],
                clientPublicKey: clientPublicKey,
                clientAddresses: ["10.255.100.10/32"],
                serverPublicKeys: [serverPublicKey]
            )
        ) { error in
            XCTAssertEqual(
                error as? RouterOSExistingPeerImportError,
                .missingInterface("wg-remote")
            )
        }

        XCTAssertThrowsError(
            try RouterOSExistingPeerImportValidator.validate(
                peer: peer,
                interfaces: [interface],
                clientPublicKey: clientPublicKey,
                clientAddresses: ["10.255.100.10/32"],
                serverPublicKeys: [serverPublicKey, serverPublicKey]
            )
        ) { error in
            XCTAssertEqual(
                error as? RouterOSExistingPeerImportError,
                .expectedSingleServerPeer
            )
        }

        XCTAssertThrowsError(
            try RouterOSExistingPeerImportValidator.validate(
                peer: peer,
                interfaces: [interface],
                clientPublicKey: clientPublicKey,
                clientAddresses: [],
                serverPublicKeys: [serverPublicKey]
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSExistingPeerImportError, .missingClientAddress)
        }
    }

    func testSuggestsNextIPv4HostAddressFromSelectedInterface() throws {
        let peers = try [
            makePeer(
                interfaceName: "wg-remote",
                publicKey: Data(repeating: 4, count: 32).base64EncodedString(),
                allowedAddress: "10.255.100.10/32,192.168.0.0/16"
            ),
            makePeer(
                interfaceName: "wg-remote",
                publicKey: Data(repeating: 5, count: 32).base64EncodedString(),
                allowedAddress: "10.255.100.12/32"
            ),
            makePeer(
                interfaceName: "wg-other",
                publicKey: Data(repeating: 6, count: 32).base64EncodedString(),
                allowedAddress: "10.255.100.250/32"
            )
        ]

        let suggestion = RouterOSClientAddressSuggestion.discover(
            for: "wg-remote",
            existingPeers: peers
        )

        XCTAssertEqual(suggestion?.address.notation, "10.255.100.13/32")
        XCTAssertEqual(suggestion?.sourceAddressCount, 2)
    }

    func testDoesNotGuessWhenClientAddressPoolsAreAmbiguousOrExhausted() throws {
        let ambiguousPeers = try [
            makePeer(
                interfaceName: "wg-remote",
                publicKey: Data(repeating: 4, count: 32).base64EncodedString(),
                allowedAddress: "10.255.100.10/32"
            ),
            makePeer(
                interfaceName: "wg-remote",
                publicKey: Data(repeating: 5, count: 32).base64EncodedString(),
                allowedAddress: "10.255.101.10/32"
            )
        ]
        let exhaustedPeer = try makePeer(
            interfaceName: "wg-remote",
            publicKey: Data(repeating: 6, count: 32).base64EncodedString(),
            allowedAddress: "10.255.100.254/32"
        )

        XCTAssertNil(
            RouterOSClientAddressSuggestion.discover(
                for: "wg-remote",
                existingPeers: ambiguousPeers
            )
        )
        XCTAssertNil(
            RouterOSClientAddressSuggestion.discover(
                for: "wg-remote",
                existingPeers: [exhaustedPeer]
            )
        )
    }

    func testSuggestsOnlyOneUsablePublicRouterAddress() throws {
        let addresses = try [
            makeAddress(address: "192.168.80.33/16", interfaceName: "bridge"),
            makeAddress(address: "8.8.8.8/24", interfaceName: "ether1"),
            makeAddress(address: "8.8.8.8/32", interfaceName: "loopback", dynamic: true),
            makeAddress(address: "9.9.9.9/24", interfaceName: "ether2", disabled: true)
        ]

        let suggestion = RouterOSPublicEndpointSuggestion.discover(from: addresses)

        XCTAssertEqual(suggestion?.address, "8.8.8.8")
    }

    func testDoesNotGuessPublicEndpointFromPrivateOrMultiplePublicAddresses() throws {
        let privateAddresses = try [
            makeAddress(address: "10.0.0.1/8", interfaceName: "bridge"),
            makeAddress(address: "100.64.0.10/10", interfaceName: "lte1"),
            makeAddress(address: "203.0.113.10/24", interfaceName: "test")
        ]
        let multiplePublicAddresses = try [
            makeAddress(address: "8.8.8.8/24", interfaceName: "ether1"),
            makeAddress(address: "9.9.9.9/24", interfaceName: "ether2")
        ]

        XCTAssertNil(RouterOSPublicEndpointSuggestion.discover(from: privateAddresses))
        XCTAssertNil(RouterOSPublicEndpointSuggestion.discover(from: multiplePublicAddresses))
    }

    func testValidatesAndNormalizesPeerDefaults() throws {
        let peerDefaults = try RouterOSPeerDefaults(
            endpointAddress: " vpn.example.com ",
            dnsServers: [" 192.0.2.53 ", "2001:4860:4860::8888"],
            splitRoutes: ["192.168.0.0/16", "10.255.0.0/16"],
            persistentKeepalive: 30
        )

        XCTAssertEqual(peerDefaults.endpointAddress, "vpn.example.com")
        XCTAssertEqual(peerDefaults.dnsServers, ["192.0.2.53", "2001:4860:4860::8888"])
        XCTAssertEqual(peerDefaults.splitRoutes.map(\.notation), ["192.168.0.0/16", "10.255.0.0/16"])
        XCTAssertEqual(peerDefaults.persistentKeepalive, 30)
    }

    func testRejectsInvalidPeerDefaults() {
        XCTAssertThrowsError(
            try RouterOSPeerDefaults(
                endpointAddress: "https://vpn.example.com",
                dnsServers: [],
                splitRoutes: [],
                persistentKeepalive: 25
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSProvisioningError, .invalidEndpoint)
        }

        XCTAssertThrowsError(
            try RouterOSPeerDefaults(
                endpointAddress: nil,
                dnsServers: [],
                splitRoutes: ["not-a-route"],
                persistentKeepalive: 25
            )
        ) { error in
            XCTAssertEqual(error as? RouterOSProvisioningError, .invalidClientRoute("not-a-route"))
        }
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

    private func makeInterface(
        name: String,
        publicKey: String
    ) throws -> RouterOSWireGuardInterface {
        let data = Data("""
        {
          ".id": "*B",
          "name": "\(name)",
          "listen-port": "51824",
          "public-key": "\(publicKey)",
          "disabled": "false",
          "running": "true"
        }
        """.utf8)
        return try JSONDecoder().decode(RouterOSWireGuardInterface.self, from: data)
    }

    private func makeAddress(
        address: String,
        interfaceName: String,
        disabled: Bool = false,
        dynamic: Bool = false,
        invalid: Bool = false
    ) throws -> RouterOSIPAddress {
        let data = Data("""
        {
          ".id": "*C",
          "address": "\(address)",
          "network": "0.0.0.0",
          "interface": "\(interfaceName)",
          "actual-interface": "\(interfaceName)",
          "disabled": "\(disabled)",
          "dynamic": "\(dynamic)",
          "invalid": "\(invalid)"
        }
        """.utf8)
        return try JSONDecoder().decode(RouterOSIPAddress.self, from: data)
    }
}
