// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import NetworkExtension
import Network

private enum WireRouteProviderMetadataKey {
    static let routingMode = "WireRouteRoutingMode"
    static let splitAllowedIPs = "WireRouteSplitAllowedIPs"
    static let blockedAddressFamilies = "WireRouteBlockedAddressFamilies"
    static let dnsProtection = "WireRouteDNSProtection"
}

private enum WireRouteDNSProtectionMetadataKey {
    static let version = "version"
    static let mode = "mode"
    static let serverURL = "serverURL"
    static let bootstrapServers = "bootstrapServers"
}

private enum WireRouteProviderRoutingMode: String {
    case split
    case full
}

enum PacketTunnelProviderError: String, Error {
    case savedProtocolConfigurationIsInvalid
    case invalidDNSProtectionConfiguration
    case dnsResolutionFailure
    case couldNotStartBackend
    case couldNotDetermineFileDescriptor
    case couldNotSetNetworkSettings
}

extension NETunnelProviderProtocol {
    convenience init?(tunnelConfiguration: TunnelConfiguration, previouslyFrom old: NEVPNProtocol? = nil) {
        self.init()

        guard let name = tunnelConfiguration.name else { return nil }
        guard let appId = Bundle.main.bundleIdentifier else { return nil }
        providerBundleIdentifier = "\(appId).network-extension"
        passwordReference = Keychain.makeReference(
            containing: tunnelConfiguration.asWgQuickConfig(),
            called: name
        )
        if passwordReference == nil {
            return nil
        }
        providerConfiguration = (old as? NETunnelProviderProtocol)?.providerConfiguration
        #if os(macOS)
        var metadata = providerConfiguration ?? [:]
        metadata["UID"] = getuid()
        providerConfiguration = metadata
        #endif

        synchronizeWireRouteRoutingMetadata(with: tunnelConfiguration)

        let endpoints = tunnelConfiguration.peers.compactMap { $0.endpoint }
        if endpoints.count == 1 {
            serverAddress = endpoints[0].stringRepresentation
        } else if endpoints.isEmpty {
            serverAddress = "Unspecified"
        } else {
            serverAddress = "Multiple endpoints"
        }
    }

    func asTunnelConfiguration(called name: String? = nil) -> TunnelConfiguration? {
        if let passwordReference = passwordReference,
            let config = Keychain.openReference(called: passwordReference) {
            return try? TunnelConfiguration(fromWgQuickConfig: config, called: name)
        }
        if let oldConfig = providerConfiguration?["WgQuickConfig"] as? String {
            return try? TunnelConfiguration(fromWgQuickConfig: oldConfig, called: name)
        }
        return nil
    }

    func destroyConfigurationReference() {
        guard let ref = passwordReference else { return }
        Keychain.deleteReference(called: ref)
    }

    func verifyConfigurationReference() -> Bool {
        guard let ref = passwordReference else { return false }
        return Keychain.verifyReference(called: ref)
    }

    var wireRouteRoutingMode: String? {
        providerConfiguration?[WireRouteProviderMetadataKey.routingMode] as? String
    }

    var wireRouteSplitAllowedIPs: [String: [String]]? {
        providerConfiguration?[WireRouteProviderMetadataKey.splitAllowedIPs] as? [String: [String]]
    }

    var wireRouteBlockedAddressFamilies: BlockedAddressFamilies {
        let rawFamilies = providerConfiguration?[WireRouteProviderMetadataKey.blockedAddressFamilies] as? [String] ?? []
        var families: BlockedAddressFamilies = []
        if rawFamilies.contains("ipv4") {
            families.insert(.ipv4)
        }
        if rawFamilies.contains("ipv6") {
            families.insert(.ipv6)
        }
        return families
    }

    func wireRouteDNSProtectionPolicy() throws -> DNSProtectionPolicy {
        guard let metadata = providerConfiguration?[WireRouteProviderMetadataKey.dnsProtection] else {
            return .profile
        }
        guard let metadata = metadata as? [String: Any],
              let version = metadata[WireRouteDNSProtectionMetadataKey.version] as? Int,
              version == 1,
              let modeString = metadata[WireRouteDNSProtectionMetadataKey.mode] as? String,
              let mode = DNSProtectionMode(rawValue: modeString) else {
            throw DNSProtectionPolicyError.invalidStoredPolicy
        }

        switch mode {
        case .profile:
            return .profile
        case .encryptedHTTPS:
            guard let serverURL = metadata[WireRouteDNSProtectionMetadataKey.serverURL] as? String else {
                throw DNSProtectionPolicyError.invalidStoredPolicy
            }
            let bootstrapServers = metadata[WireRouteDNSProtectionMetadataKey.bootstrapServers] as? [String] ?? []
            return try DNSProtectionPolicy.encryptedHTTPS(
                serverURLString: serverURL,
                bootstrapServerStrings: bootstrapServers
            )
        }
    }

    func setWireRouteDNSProtectionPolicy(_ policy: DNSProtectionPolicy) {
        var metadata = providerConfiguration ?? [:]
        switch policy.mode {
        case .profile:
            metadata.removeValue(forKey: WireRouteProviderMetadataKey.dnsProtection)
        case .encryptedHTTPS:
            guard let serverURL = policy.serverURL else { return }
            metadata[WireRouteProviderMetadataKey.dnsProtection] = [
                WireRouteDNSProtectionMetadataKey.version: 1,
                WireRouteDNSProtectionMetadataKey.mode: policy.mode.rawValue,
                WireRouteDNSProtectionMetadataKey.serverURL: serverURL.absoluteString,
                WireRouteDNSProtectionMetadataKey.bootstrapServers: policy.bootstrapServers
            ]
        }
        providerConfiguration = metadata
    }

    func wireRouteEffectiveBlockedAddressFamilies(
        for tunnelConfiguration: TunnelConfiguration
    ) -> BlockedAddressFamilies {
        let isFullTunnel = tunnelConfiguration.peers
            .flatMap(\.allowedIPs)
            .contains { $0.networkPrefixLength == 0 }
        guard isFullTunnel else { return [] }

        var families: BlockedAddressFamilies = []
        if !tunnelConfiguration.interface.addresses.contains(where: { $0.address is IPv4Address }) {
            families.insert(.ipv4)
        }
        if !tunnelConfiguration.interface.addresses.contains(where: { $0.address is IPv6Address }) {
            families.insert(.ipv6)
        }
        return families
    }

    func setWireRouteRoutingMetadata(
        mode: String,
        splitAllowedIPs: [String: [String]],
        blockedAddressFamilies: BlockedAddressFamilies
    ) {
        var metadata = providerConfiguration ?? [:]
        metadata[WireRouteProviderMetadataKey.routingMode] = mode
        metadata[WireRouteProviderMetadataKey.splitAllowedIPs] = splitAllowedIPs
        var blockedFamilies = [String]()
        if blockedAddressFamilies.contains(.ipv4) {
            blockedFamilies.append("ipv4")
        }
        if blockedAddressFamilies.contains(.ipv6) {
            blockedFamilies.append("ipv6")
        }
        metadata[WireRouteProviderMetadataKey.blockedAddressFamilies] = blockedFamilies
        providerConfiguration = metadata
    }

    @discardableResult
    func synchronizeWireRouteRoutingMetadata(with tunnelConfiguration: TunnelConfiguration) -> Bool {
        let containsDefaultRoute = tunnelConfiguration.peers
            .flatMap(\.allowedIPs)
            .contains { $0.networkPrefixLength == 0 }
        let mode: WireRouteProviderRoutingMode = containsDefaultRoute ? .full : .split

        let previousSplitRoutes = wireRouteSplitAllowedIPs ?? [:]
        let currentPeerKeys = Set(tunnelConfiguration.peers.map { $0.publicKey.base64Key })
        var splitRoutes = [String: [String]]()
        for peer in tunnelConfiguration.peers {
            let publicKey = peer.publicKey.base64Key
            let specificRoutes = stableUnique(
                peer.allowedIPs
                    .filter { $0.networkPrefixLength != 0 }
                    .map(\.stringRepresentation)
            )
            if mode == .full && specificRoutes.isEmpty {
                splitRoutes[publicKey] = previousSplitRoutes[publicKey] ?? []
            } else {
                splitRoutes[publicKey] = specificRoutes
            }
        }
        splitRoutes = splitRoutes.filter { currentPeerKeys.contains($0.key) }

        let blockedAddressFamilies = wireRouteEffectiveBlockedAddressFamilies(for: tunnelConfiguration)

        guard wireRouteRoutingMode != mode.rawValue
                || wireRouteSplitAllowedIPs != splitRoutes
                || wireRouteBlockedAddressFamilies != blockedAddressFamilies else {
            return false
        }
        setWireRouteRoutingMetadata(
            mode: mode.rawValue,
            splitAllowedIPs: splitRoutes,
            blockedAddressFamilies: blockedAddressFamilies
        )
        return true
    }

    private func stableUnique(_ routes: [String]) -> [String] {
        var seen = Set<String>()
        return routes.filter { seen.insert($0).inserted }
    }

    @discardableResult
    func migrateConfigurationIfNeeded(called name: String) -> Bool {
        /* This is how we did things before we switched to putting items
         * in the keychain. But it's still useful to keep the migration
         * around so that .mobileconfig files are easier.
         */
        if let oldConfig = providerConfiguration?["WgQuickConfig"] as? String {
            #if os(macOS)
            providerConfiguration = ["UID": getuid()]
            #elseif os(iOS)
            providerConfiguration = nil
            #else
            #error("Unimplemented")
            #endif
            guard passwordReference == nil else { return true }
            wg_log(.info, message: "Migrating tunnel configuration '\(name)'")
            passwordReference = Keychain.makeReference(containing: oldConfig, called: name)
            return true
        }
        #if os(macOS)
        if passwordReference != nil && providerConfiguration?["UID"] == nil && verifyConfigurationReference() {
            providerConfiguration = ["UID": getuid()]
            return true
        }
        #elseif os(iOS)
        /* Update the stored reference from the old iOS 14 one to the canonical iOS 15 one.
         * The iOS 14 ones are 96 bits, while the iOS 15 ones are 160 bits. We do this so
         * that we can have fast set exclusion in deleteReferences safely. */
        if passwordReference != nil && passwordReference!.count == 12 {
            var result: CFTypeRef?
            let ret = SecItemCopyMatching([kSecValuePersistentRef: passwordReference!,
                                           kSecReturnPersistentRef: true] as CFDictionary,
                                           &result)
            if ret != errSecSuccess || result == nil {
                return false
            }
            guard let newReference = result as? Data else { return false }
            if !newReference.elementsEqual(passwordReference!) {
                wg_log(.info, message: "Migrating iOS 14-style keychain reference to iOS 15-style keychain reference for '\(name)'")
                passwordReference = newReference
                return true
            }
        }
        #endif
        return false
    }
}
