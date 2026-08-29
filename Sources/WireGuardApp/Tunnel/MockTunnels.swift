// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import NetworkExtension

// Creates documentation-only tunnels for Simulator and debug marketing captures.
// The configurations stay in memory and never write VPN preferences or Keychain items.

#if targetEnvironment(simulator) || DEBUG
@MainActor
final class MockTunnels {
    private struct PreviewTunnel {
        let name: String
        let address: String
        let endpoint: String
        let allowedIPs: [String]
    }

    private static let dnsServers = ["1.1.1.1", "9.9.9.9"]
    private static let previewTunnels = [
        PreviewTunnel(
            name: "Home Network",
            address: "10.20.30.2/32",
            endpoint: "home.example.com:51820",
            allowedIPs: ["10.0.0.0/8", "192.168.0.0/16"]
        ),
        PreviewTunnel(
            name: "Office Gateway",
            address: "10.20.30.3/32",
            endpoint: "office.example.com:51820",
            allowedIPs: ["0.0.0.0/0", "10.0.0.0/8", "192.168.0.0/16"]
        ),
        PreviewTunnel(
            name: "Travel Secure",
            address: "10.20.30.4/32",
            endpoint: "vpn.example.net:51820",
            allowedIPs: ["0.0.0.0/0", "10.0.0.0/8", "192.168.0.0/16"]
        ),
    ]

    static func createMockTunnels() -> [NETunnelProviderManager] {
        previewTunnels.compactMap(makeTunnelProviderManager)
    }

    private static func makeTunnelProviderManager(
        for preview: PreviewTunnel
    ) -> NETunnelProviderManager? {
        guard let address = IPAddressRange(from: preview.address),
              let endpoint = Endpoint(from: preview.endpoint),
              let appIdentifier = Bundle.main.bundleIdentifier else {
            return nil
        }

        let dns = dnsServers.compactMap(DNSServer.init(from:))
        let allowedIPs = preview.allowedIPs.compactMap(IPAddressRange.init(from:))
        guard dns.count == dnsServers.count,
              allowedIPs.count == preview.allowedIPs.count else {
            return nil
        }

        var interface = InterfaceConfiguration(privateKey: PrivateKey())
        interface.addresses = [address]
        interface.dns = dns

        var peer = PeerConfiguration(publicKey: PrivateKey().publicKey)
        peer.endpoint = endpoint
        peer.allowedIPs = allowedIPs

        let tunnelConfiguration = TunnelConfiguration(
            name: preview.name,
            interface: interface,
            peers: [peer]
        )
        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = "\(appIdentifier).network-extension"
        var providerConfiguration: [String: Any] = [
            "WgQuickConfig": tunnelConfiguration.asWgQuickConfig(),
        ]
        #if os(macOS)
        providerConfiguration["UID"] = getuid()
        #endif
        protocolConfiguration.providerConfiguration = providerConfiguration
        protocolConfiguration.synchronizeWireRouteRoutingMetadata(with: tunnelConfiguration)
        protocolConfiguration.serverAddress = endpoint.stringRepresentation

        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = preview.name
        manager.isEnabled = true
        return manager
    }
}
#endif
