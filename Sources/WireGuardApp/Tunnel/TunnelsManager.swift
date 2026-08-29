// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
@preconcurrency import NetworkExtension
import os.log

private struct UncheckedTransfer<Value>: @unchecked Sendable {
    let value: Value
}

private enum TunnelConfigurationStorageError: LocalizedError {
    case keychainWriteFailed

    var errorDescription: String? {
        switch self {
        case .keychainWriteFailed:
            return tr("alertTunnelConfigurationKeychainWriteFailed")
        }
    }
}

@MainActor
protocol TunnelsManagerListDelegate: AnyObject {
    func tunnelAdded(at index: Int)
    func tunnelModified(at index: Int)
    func tunnelMoved(from oldIndex: Int, to newIndex: Int)
    func tunnelRemoved(at index: Int, tunnel: TunnelContainer)
}

@MainActor
protocol TunnelsManagerActivationDelegate: AnyObject {
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) // startTunnel wasn't called or failed
    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) // startTunnel succeeded
    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) // status didn't change to connected
    func tunnelActivationSucceeded(tunnel: TunnelContainer) // status changed to connected
}

@MainActor
class TunnelsManager {
    private var tunnels: [TunnelContainer]
    weak var tunnelsListDelegate: TunnelsManagerListDelegate?
    weak var activationDelegate: TunnelsManagerActivationDelegate?
    private var statusObservationToken: NotificationToken?
    private var waiteeObservationToken: NSKeyValueObservation?
    private var configurationsObservationToken: NotificationToken?

    init(tunnelProviders: [NETunnelProviderManager]) {
        tunnels = tunnelProviders.map { TunnelContainer(tunnel: $0) }.sorted { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
    }

    static func create(
        completionHandler: @escaping @MainActor @Sendable (Result<TunnelsManager, TunnelsManagerError>) -> Void
    ) {
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.arguments.contains("--app-store-screenshots") {
            completionHandler(.success(TunnelsManager(tunnelProviders: MockTunnels.createMockTunnels())))
            return
        }
        #endif
        #if targetEnvironment(simulator)
        completionHandler(.success(TunnelsManager(tunnelProviders: MockTunnels.createMockTunnels())))
        #else
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            let transfer = UncheckedTransfer(value: (managers, error))
            Task { @MainActor in
                let (managers, error) = transfer.value
                if let error {
                    wg_log(.error, message: "Failed to load tunnel provider managers: \(error)")
                    completionHandler(.failure(TunnelsManagerError.systemErrorOnListingTunnels(systemError: error)))
                    return
                }

                var tunnelManagers = managers ?? []
                var refs: Set<Data> = []
                var tunnelNames: Set<String> = []
                for (index, tunnelManager) in tunnelManagers.enumerated().reversed() {
                    if let tunnelName = tunnelManager.localizedDescription {
                        tunnelNames.insert(tunnelName)
                    }
                    guard let proto = tunnelManager.protocolConfiguration as? NETunnelProviderProtocol else { continue }
                    let tunnelName = tunnelManager.localizedDescription ?? "unknown"
                    let didMigrate = proto.migrateConfigurationIfNeeded(called: tunnelName)
                    let didSynchronizeRouting = proto.asTunnelConfiguration(called: tunnelName)
                        .map(proto.synchronizeWireRouteRoutingMetadata) ?? false
                    #if os(iOS)
                    let passwordRef = proto.verifyConfigurationReference() ? proto.passwordReference : nil
                    #elseif os(macOS)
                    let passwordRef: Data?
                    if proto.providerConfiguration?["UID"] as? uid_t == getuid() {
                        passwordRef = proto.verifyConfigurationReference() ? proto.passwordReference : nil
                    } else {
                        passwordRef = proto.passwordReference // To handle multiple users in macOS, we skip verifying
                    }
                    #else
                    #error("Unimplemented")
                    #endif
                    if let ref = passwordRef {
                        refs.insert(ref)
                        if didMigrate || didSynchronizeRouting {
                            try? await tunnelManager.saveToPreferences()
                        }
                    } else {
                        wg_log(.info, message: "Removing orphaned tunnel with non-verifying keychain entry: \(tunnelManager.localizedDescription ?? "<unknown>")")
                        Task { try? await tunnelManager.removeFromPreferences() }
                        tunnelManagers.remove(at: index)
                    }
                }
                Keychain.deleteReferences(except: refs)
                #if os(iOS)
                RecentTunnelsTracker.cleanupTunnels(except: tunnelNames)
                #endif
                completionHandler(.success(TunnelsManager(tunnelProviders: tunnelManagers)))
            }
        }
        #endif
    }

    func reload() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            let transfer = UncheckedTransfer(value: managers)
            Task { @MainActor [weak self] in
                guard let self else { return }

                let loadedTunnelProviders = transfer.value ?? []

                for (index, currentTunnel) in self.tunnels.enumerated().reversed() {
                    if !loadedTunnelProviders.contains(where: { $0.isEquivalentTo(currentTunnel) }) {
                        // Tunnel was deleted outside the app
                        self.tunnels.remove(at: index)
                        self.tunnelsListDelegate?.tunnelRemoved(at: index, tunnel: currentTunnel)
                    }
                }
                for loadedTunnelProvider in loadedTunnelProviders {
                    if let proto = loadedTunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
                        let tunnelName = loadedTunnelProvider.localizedDescription ?? "unknown"
                        let didMigrate = proto.migrateConfigurationIfNeeded(called: tunnelName)
                        let didSynchronizeRouting = proto.asTunnelConfiguration(called: tunnelName)
                            .map(proto.synchronizeWireRouteRoutingMetadata) ?? false
                        if didMigrate || didSynchronizeRouting {
                            try? await loadedTunnelProvider.saveToPreferences()
                        }
                    }
                    if let matchingTunnel = self.tunnels.first(where: { loadedTunnelProvider.isEquivalentTo($0) }) {
                        matchingTunnel.tunnelProvider = loadedTunnelProvider
                        matchingTunnel.refreshStatus()
                    } else {
                        // Tunnel was added outside the app
                        let tunnel = TunnelContainer(tunnel: loadedTunnelProvider)
                        self.tunnels.append(tunnel)
                        self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                        self.tunnelsListDelegate?.tunnelAdded(at: self.tunnels.firstIndex(of: tunnel)!)
                    }
                }
            }
        }
    }

    func add(
        tunnelConfiguration: TunnelConfiguration,
        onDemandOption: ActivateOnDemandOption = .off,
        completionHandler: @escaping @MainActor @Sendable (Result<TunnelContainer, TunnelsManagerError>) -> Void
    ) {
        let tunnelName = tunnelConfiguration.name ?? ""
        if tunnelName.isEmpty {
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        if tunnels.contains(where: { $0.name == tunnelName }) {
            completionHandler(.failure(TunnelsManagerError.tunnelAlreadyExistsWithThatName))
            return
        }

        let tunnelProviderManager = NETunnelProviderManager()
        guard tunnelProviderManager.setTunnelConfiguration(tunnelConfiguration) != nil else {
            completionHandler(
                .failure(
                    TunnelsManagerError.systemErrorOnAddTunnel(
                        systemError: TunnelConfigurationStorageError.keychainWriteFailed
                    )
                )
            )
            return
        }
        tunnelProviderManager.isEnabled = true

        onDemandOption.apply(on: tunnelProviderManager)

        let activeTunnel = tunnels.first { $0.status == .active || $0.status == .activating }

        Task { @MainActor [weak self] in
            do {
                try await tunnelProviderManager.saveToPreferences()
            } catch {
                wg_log(.error, message: "Add: Saving configuration failed: \(error)")
                (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
                completionHandler(.failure(TunnelsManagerError.systemErrorOnAddTunnel(systemError: error)))
                return
            }

            guard let self else { return }

            #if os(iOS)
            // HACK: In iOS, adding a tunnel causes deactivation of any currently active tunnel.
            // This is an ugly hack to reactivate the tunnel that has been deactivated like that.
            if let activeTunnel = activeTunnel {
                if activeTunnel.status == .inactive || activeTunnel.status == .deactivating {
                    self.startActivation(of: activeTunnel)
                }
                if activeTunnel.status == .active || activeTunnel.status == .activating {
                    activeTunnel.status = .restarting
                }
            }
            #endif

            let tunnel = TunnelContainer(tunnel: tunnelProviderManager)
            self.tunnels.append(tunnel)
            self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
            self.tunnelsListDelegate?.tunnelAdded(at: self.tunnels.firstIndex(of: tunnel)!)
            completionHandler(.success(tunnel))
        }
    }

    func addMultiple(
        tunnelConfigurations: [TunnelConfiguration],
        completionHandler: @escaping @MainActor @Sendable (UInt, TunnelsManagerError?) -> Void
    ) {
        // Temporarily pause observation of changes to VPN configurations to prevent the feedback
        // loop that causes `reload()` to be called on each newly added tunnel, which significantly
        // impacts performance.
        configurationsObservationToken = nil

        self.addMultiple(tunnelConfigurations: ArraySlice(tunnelConfigurations), numberSuccessful: 0, lastError: nil) { [weak self] numSucceeded, error in
            completionHandler(numSucceeded, error)

            // Restart observation of changes to VPN configrations.
            self?.startObservingTunnelConfigurations()

            // Force reload all configurations to make sure that all tunnels are up to date.
            self?.reload()
        }
    }

    private func addMultiple(
        tunnelConfigurations: ArraySlice<TunnelConfiguration>,
        numberSuccessful: UInt,
        lastError: TunnelsManagerError?,
        completionHandler: @escaping @MainActor @Sendable (UInt, TunnelsManagerError?) -> Void
    ) {
        guard let head = tunnelConfigurations.first else {
            completionHandler(numberSuccessful, lastError)
            return
        }
        let tail = tunnelConfigurations.dropFirst()
        add(tunnelConfiguration: head) { [weak self, tail] result in
            var numberSuccessfulCount = numberSuccessful
            var lastError: TunnelsManagerError?
            switch result {
            case .failure(let error):
                lastError = error
            case .success:
                numberSuccessfulCount = numberSuccessful + 1
            }
            self?.addMultiple(tunnelConfigurations: tail, numberSuccessful: numberSuccessfulCount, lastError: lastError, completionHandler: completionHandler)
        }
    }

    func modify(tunnel: TunnelContainer, tunnelConfiguration: TunnelConfiguration,
                onDemandOption: ActivateOnDemandOption,
                shouldEnsureOnDemandEnabled: Bool = false,
                completionHandler: @escaping @MainActor @Sendable (TunnelsManagerError?) -> Void) {
        let tunnelName = tunnelConfiguration.name ?? ""
        if tunnelName.isEmpty {
            completionHandler(TunnelsManagerError.tunnelNameEmpty)
            return
        }

        let tunnelProviderManager = tunnel.tunnelProvider
        let previousProtocolConfiguration = tunnelProviderManager.protocolConfiguration
        let previousLocalizedDescription = tunnelProviderManager.localizedDescription
        let previousTunnelConfiguration = tunnelProviderManager.tunnelConfiguration
        let previousIsEnabled = tunnelProviderManager.isEnabled
        let previousOnDemandRules = tunnelProviderManager.onDemandRules
        let previousIsOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled

        let isIntroducingOnDemandRules = (tunnelProviderManager.onDemandRules ?? []).isEmpty && onDemandOption != .off
        if isIntroducingOnDemandRules && tunnel.status != .inactive && tunnel.status != .deactivating {
            tunnel.onDeactivated = { [weak self] in
                self?.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfiguration,
                             onDemandOption: onDemandOption, shouldEnsureOnDemandEnabled: true,
                             completionHandler: completionHandler)
            }
            self.startDeactivation(of: tunnel)
            return
        } else {
            tunnel.onDeactivated = nil
        }

        let oldName = tunnelProviderManager.localizedDescription ?? ""
        let isNameChanged = tunnelName != oldName
        if isNameChanged {
            guard !tunnels.contains(where: { $0.name == tunnelName }) else {
                completionHandler(TunnelsManagerError.tunnelAlreadyExistsWithThatName)
                return
            }
            tunnel.name = tunnelName
        }

        let isTunnelConfigurationChanged = tunnelProviderManager.tunnelConfiguration != tunnelConfiguration
        var replacementProtocolConfiguration: NETunnelProviderProtocol?
        if isTunnelConfigurationChanged {
            guard let replacement = tunnelProviderManager.setTunnelConfiguration(tunnelConfiguration) else {
                tunnel.name = oldName
                completionHandler(
                    TunnelsManagerError.systemErrorOnModifyTunnel(
                        systemError: TunnelConfigurationStorageError.keychainWriteFailed
                    )
                )
                return
            }
            replacementProtocolConfiguration = replacement
        }
        tunnelProviderManager.isEnabled = true

        let isActivatingOnDemand = !tunnelProviderManager.isOnDemandEnabled && shouldEnsureOnDemandEnabled
        onDemandOption.apply(on: tunnelProviderManager)
        if shouldEnsureOnDemandEnabled {
            tunnelProviderManager.isOnDemandEnabled = true
        }

        Task { @MainActor [weak self] in
            do {
                try await tunnelProviderManager.saveToPreferences()
            } catch {
                replacementProtocolConfiguration?.destroyConfigurationReference()
                tunnelProviderManager.protocolConfiguration = previousProtocolConfiguration
                tunnelProviderManager.localizedDescription = previousLocalizedDescription
                tunnelProviderManager.cacheTunnelConfiguration(previousTunnelConfiguration)
                tunnelProviderManager.isEnabled = previousIsEnabled
                tunnelProviderManager.onDemandRules = previousOnDemandRules
                tunnelProviderManager.isOnDemandEnabled = previousIsOnDemandEnabled
                tunnel.name = oldName
                wg_log(.error, message: "Modify: Saving configuration failed: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                return
            }
            if isTunnelConfigurationChanged {
                (previousProtocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
            }
            guard let self else { return }
            if isNameChanged {
                let oldIndex = self.tunnels.firstIndex(of: tunnel)!
                self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                let newIndex = self.tunnels.firstIndex(of: tunnel)!
                self.tunnelsListDelegate?.tunnelMoved(from: oldIndex, to: newIndex)
                #if os(iOS)
                RecentTunnelsTracker.handleTunnelRenamed(oldName: oldName, newName: tunnelName)
                #endif
            }
            self.tunnelsListDelegate?.tunnelModified(at: self.tunnels.firstIndex(of: tunnel)!)

            if isTunnelConfigurationChanged {
                if tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
                    // Turn off the tunnel, and then turn it back on, so the changes are made effective
                    tunnel.status = .restarting
                    (tunnel.tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
                }
            }

            if isActivatingOnDemand {
                // Reload tunnel after saving.
                // Without this, the tunnel stopes getting updates on the tunnel status from iOS.
                do {
                    try await tunnelProviderManager.loadFromPreferences()
                    tunnel.isActivateOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled
                    completionHandler(nil)
                } catch {
                    wg_log(.error, message: "Modify: Re-loading after saving configuration failed: \(error)")
                    completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                }
            } else {
                completionHandler(nil)
            }
        }
    }

    func remove(
        tunnel: TunnelContainer,
        completionHandler: @escaping @MainActor @Sendable (TunnelsManagerError?) -> Void
    ) {
        let tunnelProviderManager = tunnel.tunnelProvider
        let protocolConfiguration = tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol
        #if os(macOS)
        let shouldDestroyConfigurationReference = tunnel.isTunnelAvailableToUser
        #elseif os(iOS)
        let shouldDestroyConfigurationReference = true
        #else
        #error("Unimplemented")
        #endif
        Task { @MainActor [weak self] in
            do {
                try await tunnelProviderManager.removeFromPreferences()
            } catch {
                wg_log(.error, message: "Remove: Saving configuration failed: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnRemoveTunnel(systemError: error))
                return
            }
            if shouldDestroyConfigurationReference {
                protocolConfiguration?.destroyConfigurationReference()
            }
            if let self, let index = self.tunnels.firstIndex(of: tunnel) {
                self.tunnels.remove(at: index)
                self.tunnelsListDelegate?.tunnelRemoved(at: index, tunnel: tunnel)
            }
            completionHandler(nil)

            #if os(iOS)
            RecentTunnelsTracker.handleTunnelRemoved(tunnelName: tunnel.name)
            #endif
        }
    }

    func removeMultiple(
        tunnels: [TunnelContainer],
        completionHandler: @escaping @MainActor @Sendable (TunnelsManagerError?) -> Void
    ) {
        // Temporarily pause observation of changes to VPN configurations to prevent the feedback
        // loop that causes `reload()` to be called for each removed tunnel, which significantly
        // impacts performance.
        configurationsObservationToken = nil

        removeMultiple(tunnels: ArraySlice(tunnels)) { [weak self] error in
            completionHandler(error)

            // Restart observation of changes to VPN configrations.
            self?.startObservingTunnelConfigurations()

            // Force reload all configurations to make sure that all tunnels are up to date.
            self?.reload()
        }
    }

    private func removeMultiple(
        tunnels: ArraySlice<TunnelContainer>,
        completionHandler: @escaping @MainActor @Sendable (TunnelsManagerError?) -> Void
    ) {
        guard let head = tunnels.first else {
            completionHandler(nil)
            return
        }
        let tail = tunnels.dropFirst()
        remove(tunnel: head) { [weak self, tail] error in
            if let error {
                completionHandler(error)
            } else {
                self?.removeMultiple(tunnels: tail, completionHandler: completionHandler)
            }
        }
    }

    func setOnDemandEnabled(
        _ isOnDemandEnabled: Bool,
        on tunnel: TunnelContainer,
        completionHandler: @escaping @MainActor @Sendable (TunnelsManagerError?) -> Void
    ) {
        let tunnelProviderManager = tunnel.tunnelProvider
        let isCurrentlyEnabled = (tunnelProviderManager.isOnDemandEnabled && tunnelProviderManager.isEnabled)
        guard isCurrentlyEnabled != isOnDemandEnabled else {
            completionHandler(nil)
            return
        }
        let isActivatingOnDemand = !tunnelProviderManager.isOnDemandEnabled && isOnDemandEnabled
        tunnelProviderManager.isOnDemandEnabled = isOnDemandEnabled
        tunnelProviderManager.isEnabled = true
        Task { @MainActor in
            do {
                try await tunnelProviderManager.saveToPreferences()
            } catch {
                wg_log(.error, message: "Modify On-Demand: Saving configuration failed: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                return
            }
            if isActivatingOnDemand {
                // If we're enabling on-demand, we want to make sure the tunnel is enabled.
                // If not enabled, the OS will not turn the tunnel on/off based on our rules.
                do {
                    try await tunnelProviderManager.loadFromPreferences()
                    // isActivateOnDemandEnabled will get changed in reload(), but no harm in setting it here too
                    tunnel.isActivateOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled
                    completionHandler(nil)
                } catch {
                    wg_log(.error, message: "Modify On-Demand: Re-loading after saving configuration failed: \(error)")
                    completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
                }
            } else {
                completionHandler(nil)
            }
        }
    }

    func setRoutingMode(
        _ mode: TunnelRouteMode,
        enteredSplitRoutes: String? = nil,
        on tunnel: TunnelContainer,
        completionHandler: @escaping @MainActor @Sendable (WireGuardAppError?) -> Void
    ) {
        guard let tunnelConfiguration = tunnel.tunnelConfiguration,
              let tunnelProtocol = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(TunnelRoutingError.invalidStoredRoutes)
            return
        }

        let previousProviderConfiguration = tunnelProtocol.providerConfiguration
        let update: TunnelRoutingUpdate
        do {
            update = try TunnelRoutingController.makeUpdate(
                configuration: tunnelConfiguration,
                mode: mode,
                storedSplitAllowedIPs: tunnelProtocol.wireRouteSplitAllowedIPs,
                enteredSplitRoutes: enteredSplitRoutes
            )
        } catch let error as WireGuardAppError {
            completionHandler(error)
            return
        } catch {
            completionHandler(TunnelRoutingError.invalidStoredRoutes)
            return
        }

        tunnelProtocol.setWireRouteRoutingMetadata(
            mode: mode.rawValue,
            splitAllowedIPs: update.splitAllowedIPs,
            blockedAddressFamilies: update.blockedAddressFamilies
        )
        modify(
            tunnel: tunnel,
            tunnelConfiguration: update.configuration,
            onDemandOption: tunnel.onDemandOption
        ) { error in
            if let error,
               let currentProtocol = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
                currentProtocol.providerConfiguration = previousProviderConfiguration
                completionHandler(error)
                return
            }
            completionHandler(nil)
        }
    }

    func setDNSProtectionPolicy(
        _ policy: DNSProtectionPolicy,
        on tunnel: TunnelContainer,
        completionHandler: @escaping @MainActor @Sendable (WireGuardAppError?) -> Void
    ) {
        guard let tunnelProtocol = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(TunnelDNSProtectionError.invalidStoredConfiguration)
            return
        }

        let previousProviderConfiguration = tunnelProtocol.providerConfiguration
        tunnelProtocol.setWireRouteDNSProtectionPolicy(policy)

        Task { @MainActor in
            do {
                try await tunnel.tunnelProvider.saveToPreferences()
                completionHandler(nil)
            } catch {
                tunnelProtocol.providerConfiguration = previousProviderConfiguration
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
            }
        }
    }

    func numberOfTunnels() -> Int {
        return tunnels.count
    }

    func tunnel(at index: Int) -> TunnelContainer {
        return tunnels[index]
    }

    func mapTunnels<T>(transform: (TunnelContainer) throws -> T) rethrows -> [T] {
        return try tunnels.map(transform)
    }

    func index(of tunnel: TunnelContainer) -> Int? {
        return tunnels.firstIndex(of: tunnel)
    }

    func tunnel(named tunnelName: String) -> TunnelContainer? {
        return tunnels.first { $0.name == tunnelName }
    }

    func waitingTunnel() -> TunnelContainer? {
        return tunnels.first { $0.status == .waiting }
    }

    func tunnelInOperation() -> TunnelContainer? {
        if let waitingTunnelObject = waitingTunnel() {
            return waitingTunnelObject
        }
        return tunnels.first { $0.status != .inactive }
    }

    func startActivation(of tunnel: TunnelContainer) {
        guard tunnels.contains(tunnel) else { return } // Ensure it's not deleted
        guard tunnel.status == .inactive else {
            activationDelegate?.tunnelActivationAttemptFailed(tunnel: tunnel, error: .tunnelIsNotInactive)
            return
        }

        if let alreadyWaitingTunnel = tunnels.first(where: { $0.status == .waiting }) {
            alreadyWaitingTunnel.status = .inactive
        }

        if let tunnelInOperation = tunnels.first(where: { $0.status != .inactive }) {
            wg_log(.info, message: "Tunnel '\(tunnel.name)' waiting for deactivation of '\(tunnelInOperation.name)'")
            tunnel.status = .waiting
            activateWaitingTunnelOnDeactivation(of: tunnelInOperation)
            if tunnelInOperation.status != .deactivating {
                if tunnelInOperation.isActivateOnDemandEnabled {
                    setOnDemandEnabled(false, on: tunnelInOperation) { [weak self] error in
                        guard error == nil else {
                            wg_log(.error, message: "Unable to activate tunnel '\(tunnel.name)' because on-demand could not be disabled on active tunnel '\(tunnel.name)'")
                            return
                        }
                        self?.startDeactivation(of: tunnelInOperation)
                    }
                } else {
                    startDeactivation(of: tunnelInOperation)
                }
            }
            return
        }

        #if targetEnvironment(simulator)
        tunnel.status = .active
        #else
        tunnel.startActivation(activationDelegate: activationDelegate)
        #endif

        #if os(iOS)
        RecentTunnelsTracker.handleTunnelActivated(tunnelName: tunnel.name)
        #endif
    }

    func startDeactivation(of tunnel: TunnelContainer) {
        tunnel.isAttemptingActivation = false
        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }
        #if targetEnvironment(simulator)
        tunnel.status = .inactive
        #else
        tunnel.startDeactivation()
        #endif
    }

    func refreshStatuses() {
        tunnels.forEach { $0.refreshStatus() }
    }

    private func activateWaitingTunnelOnDeactivation(of tunnel: TunnelContainer) {
        waiteeObservationToken = tunnel.observe(\.status) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if tunnel.status == .inactive {
                    if let waitingTunnel = self.tunnels.first(where: { $0.status == .waiting }) {
                        waitingTunnel.startActivation(activationDelegate: self.activationDelegate)
                    }
                    self.waiteeObservationToken = nil
                }
            }
        }
    }

    private func startObservingTunnelStatuses() {
        statusObservationToken = NotificationCenter.default.observe(name: .NEVPNStatusDidChange, object: nil, queue: OperationQueue.main) { [weak self] statusChangeNotification in
            let notificationObject = UncheckedTransfer(value: statusChangeNotification.object)
            MainActor.assumeIsolated {
                guard let self,
                    let session = notificationObject.value as? NETunnelProviderSession,
                    let tunnelProvider = session.manager as? NETunnelProviderManager,
                    let tunnel = self.tunnels.first(where: { $0.tunnelProvider == tunnelProvider }) else { return }

                wg_log(.debug, message: "Tunnel '\(tunnel.name)' connection status changed to '\(tunnel.tunnelProvider.connection.status)'")

                if tunnel.isAttemptingActivation {
                    if session.status == .connected {
                        tunnel.isAttemptingActivation = false
                        self.activationDelegate?.tunnelActivationSucceeded(tunnel: tunnel)
                    } else if session.status == .disconnected {
                        tunnel.isAttemptingActivation = false
                        if let (title, message) = lastErrorTextFromNetworkExtension(for: tunnel) {
                            self.activationDelegate?.tunnelActivationFailed(tunnel: tunnel, error: .activationFailedWithExtensionError(title: title, message: message, wasOnDemandEnabled: tunnelProvider.isOnDemandEnabled))
                        } else {
                            self.activationDelegate?.tunnelActivationFailed(tunnel: tunnel, error: .activationFailed(wasOnDemandEnabled: tunnelProvider.isOnDemandEnabled))
                        }
                    }
                }

                if session.status == .disconnected {
                    tunnel.onDeactivated?()
                    tunnel.onDeactivated = nil
                }

                if tunnel.status == .restarting && session.status == .disconnected {
                    tunnel.startActivation(activationDelegate: self.activationDelegate)
                    return
                }

                tunnel.refreshStatus()
            }
        }
    }

    func startObservingTunnelConfigurations() {
        configurationsObservationToken = NotificationCenter.default.observe(name: .NEVPNConfigurationChange, object: nil, queue: OperationQueue.main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                // We schedule reload() in a subsequent runloop to ensure that the completion handler of loadAllFromPreferences
                // (reload() calls loadAllFromPreferences) is called after the completion handler of the saveToPreferences or
                // removeFromPreferences call, if any, that caused this notification to fire. This notification can also fire
                // as a result of a tunnel getting added or removed outside of the app.
                self?.reload()
            }
        }
    }

    nonisolated static func tunnelNameIsLessThan(_ lhs: String, _ rhs: String) -> Bool {
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric]) == .orderedAscending
    }
}

@MainActor
private func lastErrorTextFromNetworkExtension(for tunnel: TunnelContainer) -> (title: String, message: String)? {
    guard let lastErrorFileURL = FileManager.networkExtensionLastErrorFileURL else { return nil }
    guard let lastErrorData = try? Data(contentsOf: lastErrorFileURL) else { return nil }
    guard let lastErrorStrings = String(data: lastErrorData, encoding: .utf8)?.splitToArray(separator: "\n") else { return nil }
    guard lastErrorStrings.count == 2 && tunnel.activationAttemptId == lastErrorStrings[0] else { return nil }

    if let extensionError = PacketTunnelProviderError(rawValue: lastErrorStrings[1]) {
        return extensionError.alertText
    }

    return (tr("alertTunnelActivationFailureTitle"), tr("alertTunnelActivationFailureMessage"))
}

@MainActor
class TunnelContainer: NSObject {
    @objc dynamic var name: String
    @objc dynamic var status: TunnelStatus

    @objc dynamic var isActivateOnDemandEnabled: Bool
    @objc dynamic var hasOnDemandRules: Bool

    var isAttemptingActivation = false {
        didSet {
            if isAttemptingActivation {
                self.activationTimer?.invalidate()
                let activationTimer = Timer(timeInterval: 5 /* seconds */, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        wg_log(.debug, message: "Status update notification timeout for tunnel '\(self.name)'. Tunnel status is now '\(self.tunnelProvider.connection.status)'.")
                        switch self.tunnelProvider.connection.status {
                        case .connected, .disconnected, .invalid:
                            self.activationTimer?.invalidate()
                            self.activationTimer = nil
                        default:
                            break
                        }
                        self.refreshStatus()
                    }
                }
                self.activationTimer = activationTimer
                RunLoop.main.add(activationTimer, forMode: .common)
            }
        }
    }
    var activationAttemptId: String?
    var activationTimer: Timer?
    var deactivationTimer: Timer?
    var onDeactivated: (@MainActor @Sendable () -> Void)?

    var tunnelProvider: NETunnelProviderManager {
        didSet {
            isActivateOnDemandEnabled = tunnelProvider.isOnDemandEnabled && tunnelProvider.isEnabled
            hasOnDemandRules = !(tunnelProvider.onDemandRules ?? []).isEmpty
        }
    }

    var tunnelConfiguration: TunnelConfiguration? {
        return tunnelProvider.tunnelConfiguration
    }

    var routingMode: TunnelRouteMode {
        guard let configuration = tunnelConfiguration else {
            return .split
        }
        let storedMode = (tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.wireRouteRoutingMode
        return TunnelRoutingController.detectedMode(configuration: configuration, storedMode: storedMode)
    }

    var dnsProtectionPolicy: DNSProtectionPolicy {
        guard let tunnelProtocol = tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            return .profile
        }
        return (try? tunnelProtocol.wireRouteDNSProtectionPolicy()) ?? .profile
    }

    var onDemandOption: ActivateOnDemandOption {
        return ActivateOnDemandOption(from: tunnelProvider)
    }

    #if os(macOS)
    var isTunnelAvailableToUser: Bool {
        return (tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["UID"] as? uid_t == getuid()
    }
    #endif

    init(tunnel: NETunnelProviderManager) {
        name = tunnel.localizedDescription ?? "Unnamed"
        let status = TunnelStatus(from: tunnel.connection.status)
        self.status = status
        isActivateOnDemandEnabled = tunnel.isOnDemandEnabled && tunnel.isEnabled
        hasOnDemandRules = !(tunnel.onDemandRules ?? []).isEmpty
        tunnelProvider = tunnel
        super.init()
    }

    func getRuntimeTunnelConfiguration(
        completionHandler: @escaping @MainActor @Sendable (TunnelConfiguration?) -> Void
    ) {
        guard status != .inactive, let session = tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(tunnelConfiguration)
            return
        }
        let tunnel = UncheckedTransfer(value: self)
        guard nil != (try? session.sendProviderMessage(Data([ UInt8(0) ]), responseHandler: {
            let data = $0
            Task { @MainActor in
                let tunnel = tunnel.value
                guard tunnel.status != .inactive,
                      let data,
                      let base = tunnel.tunnelConfiguration,
                      let settings = String(data: data, encoding: .utf8) else {
                    completionHandler(tunnel.tunnelConfiguration)
                    return
                }
                completionHandler(
                    (try? TunnelConfiguration(fromUapiConfig: settings, basedOn: base))
                        ?? tunnel.tunnelConfiguration
                )
            }
        })) else {
            completionHandler(tunnelConfiguration)
            return
        }
    }

    func refreshStatus() {
        if (status == .restarting) || (status == .waiting && tunnelProvider.connection.status == .disconnected) {
            return
        }
        status = TunnelStatus(from: tunnelProvider.connection.status)
    }

    fileprivate func startActivation(recursionCount: UInt = 0, lastError: Error? = nil, activationDelegate: TunnelsManagerActivationDelegate?) {
        if recursionCount >= 8 {
            wg_log(.error, message: "startActivation: Failed after 8 attempts. Giving up with \(lastError!)")
            activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedBecauseOfTooManyErrors(lastSystemError: lastError!))
            return
        }

        wg_log(.debug, message: "startActivation: Entering (tunnel: \(name))")

        status = .activating // Ensure that no other tunnel can attempt activation until this tunnel is done trying

        guard tunnelProvider.isEnabled else {
            // In case the tunnel had gotten disabled, re-enable and save it,
            // then call this function again.
            wg_log(.debug, staticMessage: "startActivation: Tunnel is disabled. Re-enabling and saving")
            tunnelProvider.isEnabled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await tunnelProvider.saveToPreferences()
                } catch {
                    wg_log(.error, message: "Error saving tunnel after re-enabling: \(error)")
                    activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileSaving(systemError: error))
                    return
                }
                wg_log(.debug, staticMessage: "startActivation: Tunnel saved after re-enabling, invoking startActivation")
                self.startActivation(recursionCount: recursionCount + 1, lastError: NEVPNError(NEVPNError.configurationUnknown), activationDelegate: activationDelegate)
            }
            return
        }

        // Start the tunnel
        do {
            wg_log(.debug, staticMessage: "startActivation: Starting tunnel")
            isAttemptingActivation = true
            let activationAttemptId = UUID().uuidString
            self.activationAttemptId = activationAttemptId
            try (tunnelProvider.connection as? NETunnelProviderSession)?.startTunnel(options: ["activationAttemptId": activationAttemptId])
            wg_log(.debug, staticMessage: "startActivation: Success")
            activationDelegate?.tunnelActivationAttemptSucceeded(tunnel: self)
        } catch let error {
            isAttemptingActivation = false
            guard let systemError = error as? NEVPNError else {
                wg_log(.error, message: "Failed to activate tunnel: Error: \(error)")
                status = .inactive
                activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileStarting(systemError: error))
                return
            }
            guard systemError.code == NEVPNError.configurationInvalid || systemError.code == NEVPNError.configurationStale else {
                wg_log(.error, message: "Failed to activate tunnel: VPN Error: \(error)")
                status = .inactive
                activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileStarting(systemError: systemError))
                return
            }
            wg_log(.debug, staticMessage: "startActivation: Will reload tunnel and then try to start it.")
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await tunnelProvider.loadFromPreferences()
                } catch {
                    wg_log(.error, message: "startActivation: Error reloading tunnel: \(error)")
                    self.status = .inactive
                    activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileLoading(systemError: error))
                    return
                }
                wg_log(.debug, staticMessage: "startActivation: Tunnel reloaded, invoking startActivation")
                self.startActivation(recursionCount: recursionCount + 1, lastError: systemError, activationDelegate: activationDelegate)
            }
        }
    }

    fileprivate func startDeactivation() {
        wg_log(.debug, message: "startDeactivation: Tunnel: \(name)")
        (tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
    }
}

@MainActor
extension NETunnelProviderManager {
    // The address of this byte is the Objective-C associated-object key. All access is confined to
    // the main-actor tunnel model.
    private static var cachedConfigKey: UInt8 = 0

    var tunnelConfiguration: TunnelConfiguration? {
        if let cached = objc_getAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey) as? TunnelConfiguration {
            return cached
        }
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.asTunnelConfiguration(called: localizedDescription)
        if config != nil {
            objc_setAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey, config, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return config
    }

    @discardableResult
    func setTunnelConfiguration(_ tunnelConfiguration: TunnelConfiguration) -> NETunnelProviderProtocol? {
        guard let newProtocolConfiguration = NETunnelProviderProtocol(
            tunnelConfiguration: tunnelConfiguration,
            previouslyFrom: protocolConfiguration
        ) else {
            return nil
        }
        protocolConfiguration = newProtocolConfiguration
        localizedDescription = tunnelConfiguration.name
        objc_setAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey, tunnelConfiguration, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return newProtocolConfiguration
    }

    func cacheTunnelConfiguration(_ tunnelConfiguration: TunnelConfiguration?) {
        objc_setAssociatedObject(
            self,
            &NETunnelProviderManager.cachedConfigKey,
            tunnelConfiguration,
            objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func isEquivalentTo(_ tunnel: TunnelContainer) -> Bool {
        return localizedDescription == tunnel.name && tunnelConfiguration == tunnel.tunnelConfiguration
    }
}
