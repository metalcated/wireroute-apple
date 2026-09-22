// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
@preconcurrency import NetworkExtension

/// Replaces only an OS VPN registration. Never reads, creates, or deletes keys.
/// All preference operations are injected so failure paths can be tested without
/// touching an installed VPN. Call only after an explicit user confirmation.
@MainActor
enum MacOSVPNRegistrationRepair {
    static let stagingKey = "WireRouteRegistrationRepair"

    @MainActor struct Store {
        var loadAll: () async throws -> [NETunnelProviderManager]
        var load: (NETunnelProviderManager) async throws -> Void
        var save: (NETunnelProviderManager) async throws -> Void
        var remove: (NETunnelProviderManager) async throws -> Void
        var isInactive: (NETunnelProviderManager) -> Bool

        static var system: Store {
            Store(
                loadAll: { try await NETunnelProviderManager.loadAllFromPreferences() },
                load: { try await $0.loadFromPreferences() },
                save: { try await $0.saveToPreferences() },
                remove: { try await $0.removeFromPreferences() },
                isInactive: { $0.connection.status == .disconnected || $0.connection.status == .invalid }
            )
        }
    }

    enum Failure: LocalizedError {
        case unavailable, busy, changed, verification, incomplete

        var errorDescription: String? {
            switch self {
            case .unavailable: return "This VPN registration cannot be safely repaired by this copy of WireRoute."
            case .busy: return "Wait for the current VPN operation to finish, then try again."
            case .changed: return "The VPN settings changed during repair. Reopen the profile before trying again."
            case .verification: return "macOS did not return the expected VPN settings. The previous registration was not removed."
            case .incomplete: return "The replacement registration was kept, but repair could not finish. Reopen WireRoute and try Activate. Your keys and saved rules were not deleted."
            }
        }
    }

    static func isProviderUnavailable(_ error: Error) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        let error = error as NSError
        return error.domain == NEVPNConnectionErrorDomain
            && error.code == NEVPNConnectionError.pluginDisabled.rawValue
    }

    private static func identity(_ manager: NETunnelProviderManager) -> String? {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let bundleID = proto.providerBundleIdentifier,
              let uid = proto.providerConfiguration?["UID"] as? NSNumber else { return nil }
        let component: String
        if proto.providerConfiguration?["WireRouteAutomaticProfilesController"] as? Bool == true {
            component = "controller"
        } else if let value = proto.providerConfiguration?["WireRouteActivityProfileIdentifier"] as? String,
                  let uuid = UUID(uuidString: value) {
            component = uuid.uuidString
        } else {
            return nil
        }
        return "\(bundleID):\(uid):\(component)"
    }

    static func isStaged(_ manager: NETunnelProviderManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?[stagingKey] as? Bool == true
    }

    /// After interruption, prefer the untouched original. If it was already
    /// retired, expose the disabled replacement so Activate can resume it.
    /// This is read-only: launching the app never retries a repair or prompts.
    static func visibleManagers(_ managers: [NETunnelProviderManager]) -> [NETunnelProviderManager] {
        let originals = Set(managers.filter { !isStaged($0) }.compactMap(identity))
        return managers.filter { manager in
            guard isStaged(manager), let id = identity(manager) else { return true }
            return !originals.contains(id)
        }
    }

    static func pendingReplacements(for original: NETunnelProviderManager,
                                    in managers: [NETunnelProviderManager]) -> [NETunnelProviderManager] {
        guard let id = identity(original) else { return [] }
        return managers.filter { $0 !== original && isStaged($0) && identity($0) == id }
    }

    /// Public properties only: do not copy macOS's private provider binding from
    /// the old protocol. Preserve routing, DNS metadata, opaque references, and
    /// native network policy instead of constructing a new WireGuard profile.
    static func freshProtocol(from old: NETunnelProviderProtocol) -> NETunnelProviderProtocol {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = old.providerBundleIdentifier
        proto.providerConfiguration = old.providerConfiguration
        proto.serverAddress = old.serverAddress
        proto.username = old.username
        proto.passwordReference = old.passwordReference
        proto.identityReference = old.identityReference
        proto.identityData = old.identityData
        proto.identityDataPassword = old.identityDataPassword
        proto.disconnectOnSleep = old.disconnectOnSleep
        proto.proxySettings = old.proxySettings
        proto.includeAllNetworks = old.includeAllNetworks
        proto.excludeLocalNetworks = old.excludeLocalNetworks
        proto.enforceRoutes = old.enforceRoutes
        if #available(macOS 13.3, *) {
            proto.excludeCellularServices = old.excludeCellularServices
            proto.excludeAPNs = old.excludeAPNs
        }
        if #available(macOS 14.4, *) {
            proto.excludeDeviceCommunication = old.excludeDeviceCommunication
        }
        return proto
    }

    // Compare only public settings; macOS may add a private designated requirement
    // on save. NSObject equality of the complete protocol would include it.
    private static func payload(_ proto: NETunnelProviderProtocol) -> NSDictionary {
        var metadata = proto.providerConfiguration ?? [:]
        metadata.removeValue(forKey: stagingKey)
        var value: [String: Any] = [
            "metadata": metadata, "sleep": proto.disconnectOnSleep,
            "includeAll": proto.includeAllNetworks, "excludeLocal": proto.excludeLocalNetworks,
            "enforce": proto.enforceRoutes
        ]
        value["bundle"] = proto.providerBundleIdentifier
        value["server"] = proto.serverAddress
        value["username"] = proto.username
        value["passwordRef"] = proto.passwordReference
        value["identityRef"] = proto.identityReference
        value["identityData"] = proto.identityData
        value["identityPassword"] = proto.identityDataPassword
        value["proxy"] = proto.proxySettings.map(proxyPayload)
        if #available(macOS 13.3, *) {
            value["excludeCellular"] = proto.excludeCellularServices
            value["excludeAPNs"] = proto.excludeAPNs
        }
        if #available(macOS 14.4, *) {
            value["excludeDevices"] = proto.excludeDeviceCommunication
        }
        return value as NSDictionary
    }

    private static func proxyPayload(_ proxy: NEProxySettings) -> [String: Any] {
        var value: [String: Any] = ["auto": proxy.autoProxyConfigurationEnabled,
                                    "http": proxy.httpEnabled, "https": proxy.httpsEnabled,
                                    "excludeSimple": proxy.excludeSimpleHostnames]
        value["url"] = proxy.proxyAutoConfigurationURL
        value["script"] = proxy.proxyAutoConfigurationJavaScript
        value["exceptions"] = proxy.exceptionList
        value["domains"] = proxy.matchDomains
        func server(_ item: NEProxyServer) -> [String: Any] {
            var value: [String: Any] = ["address": item.address, "port": item.port,
                                        "auth": item.authenticationRequired]
            value["username"] = item.username
            value["password"] = item.password
            return value
        }
        value["httpServer"] = proxy.httpServer.map(server)
        value["httpsServer"] = proxy.httpsServer.map(server)
        return value
    }

    @MainActor struct Settings {
        let name: String?
        let proto: NETunnelProviderProtocol
        let onDemand: Bool
        let rules: [NEOnDemandRule]?

        init(_ manager: NETunnelProviderManager) throws {
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                  manager.routingMethod == .destinationIP else { throw Failure.unavailable }
            self.proto = freshProtocol(from: proto)
            name = manager.localizedDescription
            onDemand = manager.isOnDemandEnabled
            rules = manager.onDemandRules?.map { $0.copy() as! NEOnDemandRule }
        }

        func apply(to manager: NETunnelProviderManager, staged: Bool) {
            let replacement = freshProtocol(from: proto)
            replacement.providerConfiguration?[stagingKey] = staged ? true : nil
            manager.protocolConfiguration = replacement
            manager.localizedDescription = name
            manager.onDemandRules = rules
            manager.isOnDemandEnabled = onDemand
            manager.isEnabled = !staged
        }

        func matches(_ manager: NETunnelProviderManager) -> Bool {
            guard let actual = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
            return manager.routingMethod == .destinationIP
                && manager.localizedDescription == name
                && manager.isOnDemandEnabled == onDemand
                && NSArray(array: manager.onDemandRules ?? []).isEqual(to: rules ?? [])
                && payload(actual).isEqual(payload(proto))
        }
    }

    static func repair(_ original: NETunnelProviderManager, providerID: String, ownerUID: UInt32,
                       store: Store = .system) async throws -> NETunnelProviderManager {
        try await store.load(original)
        guard let proto = original.protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerBundleIdentifier == providerID,
              (proto.providerConfiguration?["UID"] as? NSNumber)?.uint32Value == ownerUID,
              identity(original) != nil else { throw Failure.unavailable }
        guard store.isInactive(original) else { throw Failure.busy }
        let settings = try Settings(original)
        let wasEnabled = original.isEnabled
        let loaded = try await store.loadAll()
        // Imported copies can share an activity identifier. Never guess which
        // registration a pending repair belongs to in that case.
        let originals = loaded.filter { !isStaged($0) && identity($0) == identity(original) }
        guard originals.count <= 1 else { throw Failure.unavailable }
        // A prior interruption after retiring the old registration can be completed
        // explicitly without replacing the surviving registration a second time.
        if isStaged(original) {
            guard originals.isEmpty else {
                throw Failure.changed
            }
            return try await finish(original, settings: settings, store: store)
        }
        let pending = pendingReplacements(for: original, in: loaded)
        guard pending.count <= 1 else { throw Failure.unavailable }
        let replacement = pending.first ?? NETunnelProviderManager()
        guard store.isInactive(replacement) else { throw Failure.busy }
        var originalRemoved = false
        do {
            settings.apply(to: replacement, staged: true)
            try await store.save(replacement)
            try await store.load(replacement)
            guard !replacement.isEnabled, isStaged(replacement), settings.matches(replacement) else {
                throw Failure.verification
            }
            try await store.load(original)
            guard store.isInactive(original), store.isInactive(replacement) else { throw Failure.busy }
            guard original.isEnabled == wasEnabled, settings.matches(original) else { throw Failure.changed }
            try await store.remove(original)
            originalRemoved = true
            return try await finish(replacement, settings: settings, store: store)
        } catch {
            if !originalRemoved,
               let current = try? await store.loadAll(),
               current.contains(where: { !isStaged($0) && identity($0) == identity(original) }) {
                // Only the staged registration may be discarded. Never invoke the
                // app's profile deletion API, which also deletes private keys.
                // If removal is denied it stays disabled and hidden behind the
                // original; the next explicit repair reuses it.
                if store.isInactive(replacement) { try? await store.remove(replacement) }
                throw error
            }
            // The verified replacement still holds the original opaque key ref.
            throw Failure.incomplete
        }
    }

    private static func finish(_ replacement: NETunnelProviderManager, settings: Settings,
                               store: Store) async throws -> NETunnelProviderManager {
        settings.apply(to: replacement, staged: false)
        try await store.save(replacement)
        try await store.load(replacement)
        guard replacement.isEnabled, !isStaged(replacement), settings.matches(replacement) else {
            throw Failure.incomplete
        }
        return replacement
    }
}
#endif
