// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network
@preconcurrency import NetworkExtension
import os.log
#if os(macOS)
import CoreLocation
import CoreWLAN
import Security
#endif

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

#if os(macOS)
private enum MacOSProviderBindingMigration {
    static let designatedRequirementDefaultsKey = "WireRouteProviderBindingDesignatedRequirement"

    static var currentDesignatedRequirement: String? {
        guard let appIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let providerIdentifier = "\(appIdentifier).network-extension"
        let systemExtensionsURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        guard let embeddedExtensions = try? FileManager.default.contentsOfDirectory(
            at: systemExtensionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), let providerURL = embeddedExtensions.first(where: { url in
            url.pathExtension == "systemextension"
                && Bundle(url: url)?.bundleIdentifier == providerIdentifier
        }) else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(providerURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else {
            return nil
        }
        var requirementText: CFString?
        guard SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
              let requirementText else {
            return nil
        }
        return requirementText as String
    }

    static func needsRefresh(for designatedRequirement: String) -> Bool {
        UserDefaults.standard.string(forKey: designatedRequirementDefaultsKey) != designatedRequirement
    }

    static func markComplete(for designatedRequirement: String) {
        UserDefaults.standard.set(designatedRequirement, forKey: designatedRequirementDefaultsKey)
    }
}

private struct TunnelProfileRecoveryRecord: Codable {
    static let currentVersion = 1

    let version: Int
    let profileID: String
    let name: String
    let configuration: String
    let passwordReference: Data
    let providerConfiguration: Data?
    let onDemand: TunnelProfileRecoveryOnDemand
    let isOnDemandEnabled: Bool
}

private struct TunnelProfileRecoveryOnDemand: Codable {
    enum InterfaceScope: String, Codable {
        case off
        case wiFiOnly
        case nonWiFiOnly
        case any
    }

    enum SSIDScope: String, Codable {
        case any
        case only
        case except
    }

    let interfaceScope: InterfaceScope
    let ssidScope: SSIDScope
    let ssids: [String]

    init(_ option: ActivateOnDemandOption) {
        switch option {
        case .off:
            interfaceScope = .off
            ssidScope = .any
            ssids = []
        case .wiFiInterfaceOnly(let option):
            interfaceScope = .wiFiOnly
            (ssidScope, ssids) = Self.encode(option)
        case .nonWiFiInterfaceOnly:
            interfaceScope = .nonWiFiOnly
            ssidScope = .any
            ssids = []
        case .anyInterface(let option):
            interfaceScope = .any
            (ssidScope, ssids) = Self.encode(option)
        }
    }

    var option: ActivateOnDemandOption {
        switch interfaceScope {
        case .off:
            return .off
        case .wiFiOnly:
            return .wiFiInterfaceOnly(ssidOption)
        case .nonWiFiOnly:
            return .nonWiFiInterfaceOnly
        case .any:
            return .anyInterface(ssidOption)
        }
    }

    private var ssidOption: ActivateOnDemandSSIDOption {
        switch ssidScope {
        case .any:
            return .anySSID
        case .only:
            return ssids.isEmpty ? .anySSID : .onlySpecificSSIDs(ssids)
        case .except:
            return .exceptSpecificSSIDs(ssids)
        }
    }

    private static func encode(_ option: ActivateOnDemandSSIDOption) -> (SSIDScope, [String]) {
        switch option {
        case .anySSID:
            return (.any, [])
        case .onlySpecificSSIDs(let ssids):
            return (.only, ssids)
        case .exceptSpecificSSIDs(let ssids):
            return (.except, ssids)
        }
    }
}

private struct PreparedMacOSTunnelManagers {
    let managers: [NETunnelProviderManager]
    let recoveredNames: [String]
    let failedRecoveryNames: [String]
}

@MainActor
private final class AutomaticProfilesMacNetworkObserver: NSObject,
    @preconcurrency CLLocationManagerDelegate,
    CWEventDelegate,
    @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "WireRouteAutomaticProfilesMacNetwork")
    private let locationManager = CLLocationManager()
    private let wiFiClient = CWWiFiClient.shared()
    private var monitor: NWPathMonitor?
    private var latestPath: NWPath?
    private var needsWiFiName = false
    private var authorizationCompletions = [@MainActor (AutomaticProfilesManagementError?) -> Void]()
    private let onChange: @MainActor (AutomaticProfileNetworkObservation) -> Void

    private(set) var currentObservation: AutomaticProfileNetworkObservation?

    init(onChange: @escaping @MainActor (AutomaticProfileNetworkObservation) -> Void) {
        self.onChange = onChange
        super.init()
        locationManager.delegate = self
        wiFiClient.delegate = self
    }

    func start(needsWiFiName: Bool) {
        self.needsWiFiName = needsWiFiName
        do {
            if needsWiFiName {
                try wiFiClient.startMonitoringEvent(with: .ssidDidChange)
            } else {
                try wiFiClient.stopMonitoringEvent(with: .ssidDidChange)
            }
        } catch {
            wg_log(.error, message: "Automatic Profiles could not monitor Wi-Fi name changes: \(error.localizedDescription)")
        }
        guard monitor == nil else {
            if let latestPath {
                receive(latestPath)
            }
            return
        }
        let monitor = NWPathMonitor()
        let observer = UncheckedTransfer(value: self)
        monitor.pathUpdateHandler = { path in
            let transferredPath = UncheckedTransfer(value: path)
            Task { @MainActor in
                observer.value.receive(transferredPath.value)
            }
        }
        self.monitor = monitor
        monitor.start(queue: monitorQueue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        try? wiFiClient.stopMonitoringEvent(with: .ssidDidChange)
        latestPath = nil
        currentObservation = nil
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            guard let self, let latestPath else { return }
            receive(latestPath)
        }
    }

    func requestWiFiNameAuthorization(
        completion: @escaping @MainActor (AutomaticProfilesManagementError?) -> Void
    ) {
        guard needsWiFiName else {
            completion(nil)
            return
        }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            completion(nil)
        case .denied, .restricted:
            completion(.wiFiNameAccessDenied)
        case .notDetermined:
            authorizationCompletions.append(completion)
            locationManager.requestWhenInUseAuthorization()
        @unknown default:
            completion(.wiFiNameAccessDenied)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let error: AutomaticProfilesManagementError?
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            error = nil
        case .denied, .restricted, .notDetermined:
            error = .wiFiNameAccessDenied
        @unknown default:
            error = .wiFiNameAccessDenied
        }
        let completions = authorizationCompletions
        authorizationCompletions.removeAll()
        completions.forEach { $0(error) }
        if let latestPath {
            receive(latestPath)
        }
    }

    private func receive(_ path: NWPath) {
        latestPath = path
        let transport: AutomaticProfileTransport
        if path.status != .satisfied {
            transport = .unavailable
        } else if path.usesInterfaceType(.wifi) {
            transport = .wiFi
        } else if path.usesInterfaceType(.wiredEthernet) {
            transport = .ethernet
        } else {
            transport = .other
        }

        let wiFiName: String?
        if transport == .wiFi && needsWiFiName {
            switch locationManager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                wiFiName = CWWiFiClient.shared().interface()?.ssid()
            default:
                wiFiName = nil
            }
        } else {
            wiFiName = nil
        }

        let observation = AutomaticProfileNetworkObservation(
            transport: transport,
            wiFiName: wiFiName
        )
        guard observation != currentObservation else { return }
        currentObservation = observation
        onChange(observation)
    }
}
#endif

#if os(iOS)
@MainActor
private final class AutomaticProfilesIOSNetworkObserver: @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "WireRouteAutomaticProfilesIOSNetwork")
    private var monitor: NWPathMonitor?
    private var latestPath: NWPath?
    private var needsWiFiName = false
    private var generation = UInt64(0)
    private(set) var currentObservation: AutomaticProfileNetworkObservation?

    func start(needsWiFiName: Bool) {
        self.needsWiFiName = needsWiFiName
        guard monitor == nil else {
            if let latestPath {
                receive(latestPath)
            }
            return
        }
        let monitor = NWPathMonitor()
        let observer = UncheckedTransfer(value: self)
        monitor.pathUpdateHandler = { path in
            let transferredPath = UncheckedTransfer(value: path)
            Task { @MainActor in
                observer.value.receive(transferredPath.value)
            }
        }
        self.monitor = monitor
        monitor.start(queue: monitorQueue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        latestPath = nil
        currentObservation = nil
        generation &+= 1
    }

    private func receive(_ path: NWPath) {
        latestPath = path
        generation &+= 1
        let observationGeneration = generation
        let transport: AutomaticProfileTransport
        if path.status != .satisfied {
            transport = .unavailable
        } else if path.usesInterfaceType(.wifi) {
            transport = .wiFi
        } else if path.usesInterfaceType(.cellular) {
            transport = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            transport = .ethernet
        } else {
            transport = .other
        }

        guard transport == .wiFi && needsWiFiName else {
            currentObservation = AutomaticProfileNetworkObservation(transport: transport)
            return
        }
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let wiFiName = network?.ssid
            Task { @MainActor [weak self] in
                guard let self, generation == observationGeneration else { return }
                currentObservation = AutomaticProfileNetworkObservation(
                    transport: transport,
                    wiFiName: wiFiName
                )
            }
        }
    }
}
#endif

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
    private var automaticProfilesController: NETunnelProviderManager?
    weak var tunnelsListDelegate: TunnelsManagerListDelegate?
    weak var activationDelegate: TunnelsManagerActivationDelegate?
    private var statusObservationToken: NotificationToken?
    private var waiteeObservationToken: NSKeyValueObservation?
    private var configurationsObservationToken: NotificationToken?
    private var automaticProfilesStatusTimer: Timer?
    private var automaticProfilesRuntimeState: AutomaticProfileRuntimeState?
    private var automaticProfilesStateRequestToken: UUID?
    private weak var pendingAutomaticProfilesActivationTunnel: TunnelContainer?
    private var pendingAutomaticProfilesActivationToken: UUID?
    private weak var pendingDirectActivationTunnel: TunnelContainer?

    private var configurationChangeBlocked: Bool {
        #if os(macOS)
        return isRepairingVPNRegistration
        #else
        return false
        #endif
    }

    #if os(macOS)
    private var automaticProfilesMacNetworkObserver: AutomaticProfilesMacNetworkObserver?
    private(set) var profileRecoveryNamesRequiringApproval: [String]
    var profileRecoveryAttentionHandler: (([String]) -> Void)?
    private var isReloadingTunnelConfigurations = false
    private(set) var isRepairingVPNRegistration = false
    private var registrationRepairTargets: [UUID: (attemptID: String?, manager: NETunnelProviderManager)] = [:]
    private var didAttemptProfileRecovery: Bool
    #elseif os(iOS)
    private var automaticProfilesIOSNetworkObserver: AutomaticProfilesIOSNetworkObserver?
    #endif

    init(
        tunnelProviders: [NETunnelProviderManager],
        automaticProfilesController: NETunnelProviderManager? = nil,
        profileRecoveryNamesRequiringApproval: [String] = [],
        didAttemptProfileRecovery: Bool = false
    ) {
        tunnels = tunnelProviders.map { TunnelContainer(tunnel: $0) }.sorted { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
        self.automaticProfilesController = automaticProfilesController
        #if os(macOS)
        self.profileRecoveryNamesRequiringApproval = profileRecoveryNamesRequiringApproval
        self.didAttemptProfileRecovery = didAttemptProfileRecovery
        #endif
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
        #if os(macOS)
        let observer = AutomaticProfilesMacNetworkObserver { [weak self] observation in
            self?.handleMacAutomaticProfilesNetworkChange(observation)
        }
        automaticProfilesMacNetworkObserver = observer
        let policy = automaticProfilePolicy
        if policy.isEnabled {
            observer.start(needsWiFiName: policy.needsWiFiName)
        }
        #elseif os(iOS)
        let observer = AutomaticProfilesIOSNetworkObserver()
        automaticProfilesIOSNetworkObserver = observer
        let policy = automaticProfilePolicy
        if policy.isEnabled {
            observer.start(needsWiFiName: policy.needsWiFiName)
        }
        #endif
        startAutomaticProfilesStatusPolling()
        refreshAutomaticProfilesSnapshotIfNeeded()
        refreshAutomaticProfilesProjection()
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

                #if os(macOS)
                let loadedManagers = MacOSVPNRegistrationRepair.visibleManagers(managers ?? [])
                #else
                let loadedManagers = managers ?? []
                #endif
                let automaticProfilesController = loadedManagers.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.isWireRouteAutomaticProfilesController == true
                }
                let profileManagers = loadedManagers.filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.isWireRouteAutomaticProfilesController != true
                }

                #if os(macOS)
                let prepared = await prepareMacOSTunnelManagers(profileManagers)
                completionHandler(
                    .success(
                        TunnelsManager(
                            tunnelProviders: prepared.managers,
                            automaticProfilesController: automaticProfilesController,
                            profileRecoveryNamesRequiringApproval: prepared.failedRecoveryNames,
                            didAttemptProfileRecovery: !prepared.recoveredNames.isEmpty
                                || !prepared.failedRecoveryNames.isEmpty
                        )
                    )
                )
                #elseif os(iOS)
                var tunnelManagers = profileManagers
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
                    let passwordRef = proto.verifyConfigurationReference() ? proto.passwordReference : nil
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
                RecentTunnelsTracker.cleanupTunnels(except: tunnelNames)
                completionHandler(.success(TunnelsManager(
                    tunnelProviders: tunnelManagers,
                    automaticProfilesController: automaticProfilesController
                )))
                #else
                #error("Unimplemented")
                #endif
            }
        }
        #endif
    }

    func reload() {
        #if os(macOS)
        guard !isReloadingTunnelConfigurations, !isRepairingVPNRegistration else { return }
        isReloadingTunnelConfigurations = true
        #endif
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            let transfer = UncheckedTransfer(value: (managers, error))
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if os(macOS)
                defer { self.isReloadingTunnelConfigurations = false }
                #endif

                let (managers, error) = transfer.value
                if let error {
                    wg_log(.error, message: "Failed to reload tunnel provider managers: \(error)")
                    return
                }
                guard let managers else {
                    wg_log(.error, staticMessage: "Tunnel provider reload returned neither configurations nor an error; preserving the current profile list")
                    return
                }

                #if os(macOS)
                let visibleManagers = MacOSVPNRegistrationRepair.visibleManagers(managers)
                #else
                let visibleManagers = managers
                #endif

                let automaticProfilesController = visibleManagers.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.isWireRouteAutomaticProfilesController == true
                }
                let profileManagers = visibleManagers.filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.isWireRouteAutomaticProfilesController != true
                }
                self.automaticProfilesController = automaticProfilesController

                let loadedTunnelProviders: [NETunnelProviderManager]
                #if os(macOS)
                let loadedNames = Set(profileManagers.compactMap(\.localizedDescription))
                let missingCurrentNames = Set(self.tunnels.map(\.name)).subtracting(loadedNames)
                if self.didAttemptProfileRecovery && !missingCurrentNames.isEmpty {
                    let names = missingCurrentNames.sorted(by: Self.tunnelNameIsLessThan)
                    self.profileRecoveryAttentionHandler?(names)
                    wg_log(.error, staticMessage: "A recovered VPN preference disappeared again; preserving the current profile list until the extension is enabled and recovery is retried")
                    return
                }
                let prepared = await Self.prepareMacOSTunnelManagers(profileManagers)
                let attemptedRecoveryNames = Array(
                    Set(prepared.recoveredNames + prepared.failedRecoveryNames)
                ).sorted(by: Self.tunnelNameIsLessThan)
                if !attemptedRecoveryNames.isEmpty {
                    self.didAttemptProfileRecovery = true
                }
                if !prepared.failedRecoveryNames.isEmpty {
                    self.profileRecoveryNamesRequiringApproval = Array(
                        Set(
                            self.profileRecoveryNamesRequiringApproval
                                + prepared.failedRecoveryNames
                        )
                    ).sorted(by: Self.tunnelNameIsLessThan)
                    self.profileRecoveryAttentionHandler?(prepared.failedRecoveryNames)
                }
                if prepared.managers.isEmpty,
                   !self.tunnels.isEmpty,
                   !prepared.failedRecoveryNames.isEmpty {
                    wg_log(.error, staticMessage: "Profile recovery could not be saved while reloading; preserving the current profile list for retry")
                    return
                }
                loadedTunnelProviders = prepared.managers
                #elseif os(iOS)
                loadedTunnelProviders = profileManagers
                #else
                #error("Unimplemented")
                #endif

                for (index, currentTunnel) in self.tunnels.enumerated().reversed() {
                    if !loadedTunnelProviders.contains(where: { $0.isEquivalentTo(currentTunnel) }) {
                        // Tunnel was deleted outside the app
                        self.tunnels.remove(at: index)
                        self.tunnelsListDelegate?.tunnelRemoved(at: index, tunnel: currentTunnel)
                    }
                }
                for loadedTunnelProvider in loadedTunnelProviders {
                    #if os(iOS)
                    if let proto = loadedTunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
                        let tunnelName = loadedTunnelProvider.localizedDescription ?? "unknown"
                        let didMigrate = proto.migrateConfigurationIfNeeded(called: tunnelName)
                        let didSynchronizeRouting = proto.asTunnelConfiguration(called: tunnelName)
                            .map(proto.synchronizeWireRouteRoutingMetadata) ?? false
                        if didMigrate || didSynchronizeRouting {
                            try? await loadedTunnelProvider.saveToPreferences()
                        }
                    }
                    #endif
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
                self.refreshAutomaticProfilesSnapshotIfNeeded()
                #if os(macOS)
                let policy = self.automaticProfilePolicy
                if policy.isEnabled {
                    self.automaticProfilesMacNetworkObserver?.start(
                        needsWiFiName: policy.needsWiFiName
                    )
                }
                #elseif os(iOS)
                let policy = self.automaticProfilePolicy
                if policy.isEnabled {
                    self.automaticProfilesIOSNetworkObserver?.start(
                        needsWiFiName: policy.needsWiFiName
                    )
                }
                #endif
                self.refreshAutomaticProfilesProjection()
            }
        }
    }

    #if os(macOS)
    func retryProfileRecovery() {
        didAttemptProfileRecovery = false
        reload()
    }

    private var embeddedProviderIdentifier: String? {
        guard let appID = Bundle.main.bundleIdentifier,
              let pluginsURL = Bundle.main.builtInPlugInsURL,
              let plugins = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil),
              plugins.contains(where: {
                  $0.pathExtension == "appex" && Bundle(url: $0)?.bundleIdentifier == appID + ".network-extension"
              }) else { return nil }
        return appID + ".network-extension"
    }

    func canRepairVPNRegistration(for tunnel: TunnelContainer) -> Bool {
        guard embeddedProviderIdentifier != nil, !isRepairingVPNRegistration,
              let target = registrationRepairTargets[tunnel.activityProfileIdentifier],
              target.attemptID == tunnel.activationAttemptId else { return false }
        return true
    }

    /// Called only by the explicit Repair action, never by startup or a retry timer.
    func repairVPNRegistration(for tunnel: TunnelContainer) async throws {
        guard canRepairVPNRegistration(for: tunnel),
              let providerID = embeddedProviderIdentifier,
              let target = registrationRepairTargets[tunnel.activityProfileIdentifier],
              tunnels.contains(tunnel) else { throw MacOSVPNRegistrationRepair.Failure.unavailable }
        guard !isReloadingTunnelConfigurations,
              tunnels.allSatisfy({ $0.status == .inactive }),
              automaticProfilesController.map({ MacOSVPNRegistrationRepair.Store.system.isInactive($0) }) ?? true else {
            throw MacOSVPNRegistrationRepair.Failure.busy
        }
        // Check accessibility without creating/replacing any credential. The
        // controller references the existing snapshot, which is left untouched.
        let isController = (target.manager.protocolConfiguration as? NETunnelProviderProtocol)?.isWireRouteAutomaticProfilesController == true
        let profiles = isController ? tunnels : [tunnel]
        guard profiles.allSatisfy({ $0.isTunnelAvailableToUser && $0.tunnelConfiguration != nil
            && ($0.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.verifyConfigurationReference() == true
        }) else { throw TunnelsManagerError.tunnelConfigurationUnavailable }

        registrationRepairTargets.removeValue(forKey: tunnel.activityProfileIdentifier)
        isRepairingVPNRegistration = true
        defer {
            isRepairingVPNRegistration = false
            reload()
        }
        let replacement: NETunnelProviderManager
        do {
            replacement = try await MacOSVPNRegistrationRepair.repair(
                target.manager, providerID: providerID, ownerUID: getuid()
            )
        } catch {
            let failure = error as NSError
            wg_log(.error, message: "User-requested VPN registration repair failed (controller=\(isController)): \(failure.domain) (\(failure.code)): \(failure.localizedDescription)")
            throw error
        }
        if isController {
            automaticProfilesController = replacement
        } else {
            tunnel.tunnelProvider = replacement
            Self.saveMacOSRecoveryConfiguration(for: replacement)
        }
        wg_log(.info, staticMessage: "User-requested VPN registration repair saved and verified; connection validation still required")
    }
    #endif

    func add(
        tunnelConfiguration: TunnelConfiguration,
        onDemandOption: ActivateOnDemandOption = .off,
        completionHandler: @escaping @MainActor @Sendable (Result<TunnelContainer, TunnelsManagerError>) -> Void
    ) {
        guard !configurationChangeBlocked else {
            completionHandler(.failure(.vpnConfigurationBusy))
            return
        }
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

            #if os(macOS)
            Self.saveMacOSRecoveryConfiguration(for: tunnelProviderManager)
            #endif

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
            self.refreshAutomaticProfilesSnapshotIfNeeded()
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
        guard !configurationChangeBlocked else {
            completionHandler(.vpnConfigurationBusy)
            return
        }
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

        let automaticProfilesEnabled = automaticProfilePolicy.isEnabled
        let isIntroducingOnDemandRules = !automaticProfilesEnabled
            && (tunnelProviderManager.onDemandRules ?? []).isEmpty
            && onDemandOption != .off
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
        if shouldEnsureOnDemandEnabled && !automaticProfilesEnabled {
            tunnelProviderManager.isOnDemandEnabled = true
        } else if automaticProfilesEnabled {
            tunnelProviderManager.isOnDemandEnabled = false
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
            #if os(macOS)
            Self.saveMacOSRecoveryConfiguration(for: tunnelProviderManager)
            #endif
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
            self.refreshAutomaticProfilesSnapshotIfNeeded()

            if isTunnelConfigurationChanged {
                if tunnel.isAutomaticProfilesProjection {
                    // The controller reload above updates this logical profile in place.
                } else if tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
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
        guard !configurationChangeBlocked else {
            completionHandler(.vpnConfigurationBusy)
            return
        }
        let tunnelProviderManager = tunnel.tunnelProvider
        let wasAutomaticProfilesProjection = tunnel.isAutomaticProfilesProjection
        let protocolConfiguration = tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol
        let activityProfileIdentifier = tunnel.activityProfileIdentifier
        #if os(macOS)
        let shouldDestroyConfigurationReference = tunnel.isTunnelAvailableToUser
        #elseif os(iOS)
        let shouldDestroyConfigurationReference = true
        #else
        #error("Unimplemented")
        #endif
        Task { @MainActor [weak self] in
            do {
                #if os(macOS)
                // An interrupted repair must not resurrect a profile the user
                // deliberately deletes. Retire staged registrations before the
                // normal deletion workflow removes any shared Keychain reference.
                if self?.embeddedProviderIdentifier != nil,
                   !MacOSVPNRegistrationRepair.isStaged(tunnelProviderManager) {
                    let installed = try await NETunnelProviderManager.loadAllFromPreferences()
                    for pending in MacOSVPNRegistrationRepair.pendingReplacements(for: tunnelProviderManager, in: installed) {
                        guard MacOSVPNRegistrationRepair.Store.system.isInactive(pending) else {
                            throw MacOSVPNRegistrationRepair.Failure.busy
                        }
                        try await pending.removeFromPreferences()
                    }
                }
                #endif
                try await tunnelProviderManager.removeFromPreferences()
            } catch {
                wg_log(.error, message: "Remove: Saving configuration failed: \(error)")
                completionHandler(TunnelsManagerError.systemErrorOnRemoveTunnel(systemError: error))
                return
            }
            if shouldDestroyConfigurationReference {
                protocolConfiguration?.destroyConfigurationReference()
            }
            #if os(macOS)
            Keychain.deleteProfileRecoveryConfiguration(profileID: activityProfileIdentifier.uuidString)
            Keychain.deleteProfileRecoveryConfigurations(named: tunnel.name)
            do {
                try await WireRouteActivityHistoryAccess().clearAll(profileIdentifier: activityProfileIdentifier)
            } catch {
                wg_log(.error, message: "Remove: Clearing activity history failed: \(error.localizedDescription)")
            }
            #else
            do {
                try WireRouteActivityStore().clearAllHistory(profileIdentifier: activityProfileIdentifier)
            } catch {
                wg_log(.error, message: "Remove: Clearing activity history failed: \(error.localizedDescription)")
            }
            #endif
            if let self, let index = self.tunnels.firstIndex(of: tunnel) {
                self.tunnels.remove(at: index)
                self.tunnelsListDelegate?.tunnelRemoved(at: index, tunnel: tunnel)
                if wasAutomaticProfilesProjection {
                    (self.automaticProfilesController?.connection as? NETunnelProviderSession)?.stopTunnel()
                }
                self.refreshAutomaticProfilesSnapshotIfNeeded()
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
        guard !configurationChangeBlocked else {
            completionHandler(.vpnConfigurationBusy)
            return
        }
        if isOnDemandEnabled && automaticProfilePolicy.isEnabled {
            completionHandler(.automaticProfilesEnabled)
            return
        }
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
            #if os(macOS)
            Self.saveMacOSRecoveryConfiguration(for: tunnelProviderManager)
            #endif
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
        guard !configurationChangeBlocked else {
            completionHandler(TunnelsManagerError.vpnConfigurationBusy)
            return
        }
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
        guard !configurationChangeBlocked else {
            completionHandler(TunnelsManagerError.vpnConfigurationBusy)
            return
        }
        guard let tunnelProtocol = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(TunnelDNSProtectionError.invalidStoredConfiguration)
            return
        }

        let previousProviderConfiguration = tunnelProtocol.providerConfiguration
        tunnelProtocol.setWireRouteDNSProtectionPolicy(policy)

        Task { @MainActor [weak self] in
            do {
                try await tunnel.tunnelProvider.saveToPreferences()
                #if os(macOS)
                Self.saveMacOSRecoveryConfiguration(for: tunnel.tunnelProvider)
                #endif
                self?.refreshAutomaticProfilesSnapshotIfNeeded()
                completionHandler(nil)
            } catch {
                tunnelProtocol.providerConfiguration = previousProviderConfiguration
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error))
            }
        }
    }

    #if os(macOS)
    private static func prepareMacOSTunnelManagers(
        _ loadedManagers: [NETunnelProviderManager]
    ) async -> PreparedMacOSTunnelManagers {
        var managers = loadedManagers
        var recoveredNames = [String]()
        var failedRecoveryNames = [String]()
        let providerDesignatedRequirement = MacOSProviderBindingMigration.currentDesignatedRequirement
        let shouldRefreshProviderBindings = providerDesignatedRequirement
            .map(MacOSProviderBindingMigration.needsRefresh) ?? false
        var didFailProviderBindingRefresh = false
        let recoveryRecords = loadMacOSRecoveryConfigurations()
        let recordsByName = Dictionary(
            recoveryRecords.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for manager in managers {
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { continue }
            let name = manager.localizedDescription ?? "unknown"
            guard proto.providerConfiguration?["UID"] as? uid_t == getuid()
                    || proto.providerConfiguration?["UID"] == nil else {
                continue
            }

            let didMigrate = proto.migrateConfigurationIfNeeded(called: name)
            let configuration = proto.asTunnelConfiguration(called: name)
            let didSynchronizeRouting = configuration
                .map(proto.synchronizeWireRouteRoutingMetadata) ?? false
            if didMigrate || didSynchronizeRouting {
                do {
                    try await manager.saveToPreferences()
                } catch {
                    wg_log(.error, message: "Unable to save migrated profile '\(name)': \(error)")
                }
            }

            if let configuration,
               let passwordReference = proto.passwordReference,
               proto.verifyConfigurationReference() {
                saveMacOSRecoveryConfiguration(for: manager)
                if Keychain.requiresEmbeddedAppKeychainMigration(called: passwordReference) {
                    if await migrateMacOSKeychainStorage(
                        manager: manager,
                        configuration: configuration,
                        oldPasswordReference: passwordReference,
                        destinationDescription: "embedded-extension Keychain storage"
                    ) {
                        saveMacOSRecoveryConfiguration(for: manager)
                    } else {
                        didFailProviderBindingRefresh = true
                    }
                } else if Keychain.requiresSystemExtensionMigration(called: passwordReference) {
                    if await migrateMacOSKeychainStorage(
                        manager: manager,
                        configuration: configuration,
                        oldPasswordReference: passwordReference,
                        destinationDescription: "system-extension-owned Keychain storage"
                    ) {
                        saveMacOSRecoveryConfiguration(for: manager)
                    } else {
                        didFailProviderBindingRefresh = true
                    }
                } else if shouldRefreshProviderBindings {
                    if await refreshMacOSProviderBinding(
                        manager: manager,
                        configuration: configuration,
                        passwordReference: passwordReference
                    ) {
                        saveMacOSRecoveryConfiguration(for: manager)
                    } else {
                        didFailProviderBindingRefresh = true
                    }
                }
                continue
            }

            guard let recoveryRecord = recordsByName[name] else {
                wg_log(.error, message: "Profile '\(name)' has an unavailable Keychain configuration; preserving the VPN preference for a later retry")
                continue
            }
            if await restoreMacOSProfile(manager: manager, from: recoveryRecord) {
                recoveredNames.append(name)
            } else {
                failedRecoveryNames.append(name)
            }
        }

        var usedNames = Set(managers.compactMap(\.localizedDescription))
        for record in recoveryRecords where !usedNames.contains(record.name) {
            let manager = NETunnelProviderManager()
            if await restoreMacOSProfile(manager: manager, from: record) {
                managers.append(manager)
                usedNames.insert(record.name)
                recoveredNames.append(record.name)
            } else {
                failedRecoveryNames.append(record.name)
            }
        }

        var referencedConfigurations = Set(
            managers.compactMap {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference
            }
        )
        for storedConfiguration in Keychain.tunnelConfigurations() {
            guard !referencedConfigurations.contains(storedConfiguration.reference),
                  !usedNames.contains(storedConfiguration.name),
                  let configuration = try? TunnelConfiguration(
                    fromWgQuickConfig: storedConfiguration.configuration,
                    called: storedConfiguration.name
                  ) else {
                continue
            }

            let manager = NETunnelProviderManager()
            let requiresKeychainMigration = Keychain.requiresSystemExtensionMigration(
                called: storedConfiguration.reference
            ) || Keychain.requiresEmbeddedAppKeychainMigration(called: storedConfiguration.reference)
            let replacementProtocol = requiresKeychainMigration
                ? manager.setTunnelConfiguration(configuration)
                : manager.setRecoveredTunnelConfiguration(
                    configuration,
                    passwordReference: storedConfiguration.reference
                )
            guard let replacementProtocol else {
                failedRecoveryNames.append(storedConfiguration.name)
                continue
            }
            if requiresKeychainMigration {
                guard let newReference = replacementProtocol.passwordReference,
                      Keychain.verifyReference(called: newReference),
                      Keychain.openReference(called: newReference) != nil else {
                    replacementProtocol.destroyConfigurationReference()
                    failedRecoveryNames.append(storedConfiguration.name)
                    wg_log(.error, message: "Unable to verify migrated Keychain storage for profile '\(storedConfiguration.name)'")
                    continue
                }
            }
            manager.isEnabled = true
            do {
                try await manager.saveToPreferences()
                managers.append(manager)
                usedNames.insert(storedConfiguration.name)
                if requiresKeychainMigration,
                   let newReference = replacementProtocol.passwordReference {
                    Keychain.deleteReference(called: storedConfiguration.reference)
                    referencedConfigurations.insert(newReference)
                } else {
                    referencedConfigurations.insert(storedConfiguration.reference)
                }
                recoveredNames.append(storedConfiguration.name)
                saveMacOSRecoveryConfiguration(for: manager)
                wg_log(.info, message: "Restored profile '\(storedConfiguration.name)' from its protected Keychain configuration")
            } catch {
                if requiresKeychainMigration {
                    replacementProtocol.destroyConfigurationReference()
                }
                wg_log(.error, message: "Unable to restore profile '\(storedConfiguration.name)' from Keychain: \(error)")
                failedRecoveryNames.append(storedConfiguration.name)
            }
        }

        if let providerDesignatedRequirement,
           shouldRefreshProviderBindings,
           !didFailProviderBindingRefresh {
            MacOSProviderBindingMigration.markComplete(for: providerDesignatedRequirement)
        }

        return PreparedMacOSTunnelManagers(
            managers: managers,
            recoveredNames: Array(Set(recoveredNames)).sorted(by: tunnelNameIsLessThan),
            failedRecoveryNames: Array(Set(failedRecoveryNames)).sorted(by: tunnelNameIsLessThan)
        )
    }

    private static func loadMacOSRecoveryConfigurations() -> [TunnelProfileRecoveryRecord] {
        let decoder = JSONDecoder()
        return Keychain.profileRecoveryConfigurations().compactMap { storedConfiguration in
            guard let data = storedConfiguration.payload.data(using: .utf8),
                  let record = try? decoder.decode(TunnelProfileRecoveryRecord.self, from: data),
                  record.version == TunnelProfileRecoveryRecord.currentVersion,
                  record.profileID == storedConfiguration.profileID else {
                wg_log(.error, message: "Ignoring invalid profile recovery record for '\(storedConfiguration.name)'")
                return nil
            }
            return record
        }
    }

    private static func saveMacOSRecoveryConfiguration(for manager: NETunnelProviderManager) {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerConfiguration?["UID"] as? uid_t == getuid(),
              let reference = proto.passwordReference,
              let configuration = manager.tunnelConfiguration,
              let name = manager.localizedDescription else {
            return
        }

        let providerConfiguration: Data?
        if let metadata = proto.providerConfiguration,
           PropertyListSerialization.propertyList(metadata, isValidFor: .binary) {
            providerConfiguration = try? PropertyListSerialization.data(
                fromPropertyList: metadata,
                format: .binary,
                options: 0
            )
        } else {
            providerConfiguration = nil
        }

        let record = TunnelProfileRecoveryRecord(
            version: TunnelProfileRecoveryRecord.currentVersion,
            profileID: proto.wireRouteActivityProfileIdentifier.uuidString,
            name: name,
            configuration: configuration.asWgQuickConfig(),
            passwordReference: reference,
            providerConfiguration: providerConfiguration,
            onDemand: TunnelProfileRecoveryOnDemand(ActivateOnDemandOption(from: manager)),
            isOnDemandEnabled: manager.isOnDemandEnabled
        )
        guard let data = try? JSONEncoder().encode(record),
              let payload = String(data: data, encoding: .utf8),
              Keychain.saveProfileRecoveryConfiguration(
                payload: payload,
                profileID: record.profileID,
                name: record.name
              ) else {
            wg_log(.error, message: "Unable to save a protected recovery record for profile '\(name)'")
            return
        }
    }

    private static func restoreMacOSProfile(
        manager: NETunnelProviderManager,
        from record: TunnelProfileRecoveryRecord
    ) async -> Bool {
        guard let configuration = try? TunnelConfiguration(
            fromWgQuickConfig: record.configuration,
            called: record.name
        ) else {
            wg_log(.error, message: "Profile recovery record for '\(record.name)' contains an invalid tunnel configuration")
            return false
        }

        let previousProtocolConfiguration = manager.protocolConfiguration
        let previousLocalizedDescription = manager.localizedDescription
        let previousConfiguration = manager.tunnelConfiguration
        let previousIsEnabled = manager.isEnabled
        let previousOnDemandRules = manager.onDemandRules
        let previousIsOnDemandEnabled = manager.isOnDemandEnabled

        let canReuseReference = Keychain.openReference(called: record.passwordReference) != nil
            && !Keychain.requiresSystemExtensionMigration(called: record.passwordReference)
            && !Keychain.requiresEmbeddedAppKeychainMigration(called: record.passwordReference)
        let replacementProtocol: NETunnelProviderProtocol?
        if canReuseReference {
            replacementProtocol = manager.setRecoveredTunnelConfiguration(
                configuration,
                passwordReference: record.passwordReference
            )
        } else {
            replacementProtocol = manager.setTunnelConfiguration(configuration)
        }
        guard let replacementProtocol else { return false }
        if !canReuseReference {
            guard let newReference = replacementProtocol.passwordReference,
                  Keychain.verifyReference(called: newReference),
                  Keychain.openReference(called: newReference) != nil else {
                replacementProtocol.destroyConfigurationReference()
                manager.protocolConfiguration = previousProtocolConfiguration
                manager.localizedDescription = previousLocalizedDescription
                manager.cacheTunnelConfiguration(previousConfiguration)
                manager.isEnabled = previousIsEnabled
                manager.onDemandRules = previousOnDemandRules
                manager.isOnDemandEnabled = previousIsOnDemandEnabled
                wg_log(.error, message: "Unable to verify replacement Keychain storage for profile '\(record.name)'")
                return false
            }
        }

        if let providerConfiguration = record.providerConfiguration,
           let propertyList = try? PropertyListSerialization.propertyList(
            from: providerConfiguration,
            options: [],
            format: nil
           ), var metadata = propertyList as? [String: Any] {
            metadata["UID"] = getuid()
            replacementProtocol.providerConfiguration = metadata
        }
        record.onDemand.option.apply(on: manager)
        manager.isOnDemandEnabled = record.isOnDemandEnabled && !(manager.onDemandRules ?? []).isEmpty
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            if !canReuseReference,
               replacementProtocol.passwordReference != record.passwordReference {
                Keychain.deleteReference(called: record.passwordReference)
            }
            saveMacOSRecoveryConfiguration(for: manager)
            wg_log(.info, message: "Restored profile '\(record.name)' from its protected recovery record")
            return true
        } catch {
            if !canReuseReference {
                replacementProtocol.destroyConfigurationReference()
            }
            manager.protocolConfiguration = previousProtocolConfiguration
            manager.localizedDescription = previousLocalizedDescription
            manager.cacheTunnelConfiguration(previousConfiguration)
            manager.isEnabled = previousIsEnabled
            manager.onDemandRules = previousOnDemandRules
            manager.isOnDemandEnabled = previousIsOnDemandEnabled
            wg_log(.error, message: "Unable to restore profile '\(record.name)': \(error)")
            return false
        }
    }

    private static func refreshMacOSProviderBinding(
        manager: NETunnelProviderManager,
        configuration: TunnelConfiguration,
        passwordReference: Data
    ) async -> Bool {
        switch manager.connection.status {
        case .connected, .connecting, .disconnecting, .reasserting:
            wg_log(.info, message: "Deferring provider signing migration for active profile '\(configuration.name ?? "unknown")'")
            return false
        case .disconnected, .invalid:
            break
        @unknown default:
            return false
        }

        let previousProtocolConfiguration = manager.protocolConfiguration
        let previousLocalizedDescription = manager.localizedDescription
        let previousConfiguration = manager.tunnelConfiguration

        guard manager.setRecoveredTunnelConfiguration(
            configuration,
            passwordReference: passwordReference
        ) != nil else {
            wg_log(.error, message: "Unable to prepare provider signing migration for profile '\(configuration.name ?? "unknown")'")
            return false
        }

        do {
            try await manager.saveToPreferences()
            wg_log(.info, message: "Refreshed provider signing requirement for profile '\(configuration.name ?? "unknown")'")
            return true
        } catch {
            manager.protocolConfiguration = previousProtocolConfiguration
            manager.localizedDescription = previousLocalizedDescription
            manager.cacheTunnelConfiguration(previousConfiguration)
            wg_log(.error, message: "Unable to refresh provider signing requirement for profile '\(configuration.name ?? "unknown")': \(error)")
            return false
        }
    }

    private static func migrateMacOSKeychainStorage(
        manager: NETunnelProviderManager,
        configuration: TunnelConfiguration,
        oldPasswordReference: Data,
        destinationDescription: String
    ) async -> Bool {
        switch manager.connection.status {
        case .connected, .connecting, .disconnecting, .reasserting:
            wg_log(.info, message: "Deferring \(destinationDescription) migration for active profile '\(configuration.name ?? "unknown")'")
            return false
        case .disconnected, .invalid:
            break
        @unknown default:
            return false
        }

        let previousProtocolConfiguration = manager.protocolConfiguration
        let previousLocalizedDescription = manager.localizedDescription
        let previousConfiguration = manager.tunnelConfiguration

        guard let replacementProtocol = manager.setTunnelConfiguration(configuration),
              let newPasswordReference = replacementProtocol.passwordReference,
              newPasswordReference != oldPasswordReference,
              Keychain.verifyReference(called: newPasswordReference),
              Keychain.openReference(called: newPasswordReference) != nil else {
            manager.protocolConfiguration = previousProtocolConfiguration
            manager.localizedDescription = previousLocalizedDescription
            manager.cacheTunnelConfiguration(previousConfiguration)
            wg_log(.error, message: "Unable to prepare \(destinationDescription) migration for profile '\(configuration.name ?? "unknown")'")
            return false
        }

        do {
            try await manager.saveToPreferences()
            Keychain.deleteReference(called: oldPasswordReference)
            wg_log(.info, message: "Migrated profile '\(configuration.name ?? "unknown")' to \(destinationDescription)")
            return true
        } catch {
            replacementProtocol.destroyConfigurationReference()
            manager.protocolConfiguration = previousProtocolConfiguration
            manager.localizedDescription = previousLocalizedDescription
            manager.cacheTunnelConfiguration(previousConfiguration)
            wg_log(.error, message: "Unable to migrate profile '\(configuration.name ?? "unknown")' to \(destinationDescription): \(error)")
            return false
        }
    }
    #endif

    var automaticProfilePolicy: AutomaticProfilePolicy {
        guard let url = FileManager.automaticProfilesSnapshotURL(),
              let snapshot = try? AutomaticProfileFileStore.loadSnapshot(from: url) else {
            return AutomaticProfilePolicy()
        }
        return snapshot.policy
    }

    var automaticProfileReferences: [AutomaticProfileReference] {
        tunnels.map {
            AutomaticProfileReference(id: $0.activityProfileIdentifier, name: $0.name)
        }
    }

    var hasEnabledSingleProfileOnDemand: Bool {
        tunnels.contains { $0.tunnelProvider.isEnabled && $0.tunnelProvider.isOnDemandEnabled }
    }

    func prepareAutomaticProfilesAuthorization(
        for policy: AutomaticProfilePolicy,
        completionHandler: @escaping @MainActor (AutomaticProfilesManagementError?) -> Void
    ) {
        #if os(macOS)
        guard policy.isEnabled && policy.needsWiFiName else {
            completionHandler(nil)
            return
        }
        automaticProfilesMacNetworkObserver?.start(needsWiFiName: true)
        automaticProfilesMacNetworkObserver?.requestWiFiNameAuthorization(
            completion: completionHandler
        )
        #else
        completionHandler(nil)
        #endif
    }

    private func makeAutomaticProfilesSnapshot(
        policy requestedPolicy: AutomaticProfilePolicy,
        revision: UUID = UUID(),
        policyRevision: UUID = UUID()
    ) throws -> AutomaticProfileRuntimeSnapshot {
        var updatedPolicy = try requestedPolicy.validated()
        // A disabled policy is configuration only. It must remain editable even if
        // one of the installed tunnel records cannot currently be read (for example,
        // when a development-signed build cannot access App Store Keychain items).
        // Runtime profile material is needed only when the controller can switch or
        // manually activate profiles.
        guard updatedPolicy.isEnabled else {
            return try AutomaticProfileRuntimeSnapshot(
                revision: revision,
                policyRevision: policyRevision,
                policy: updatedPolicy,
                profiles: []
            ).validated()
        }
        let profiles = try tunnels.map { tunnel -> AutomaticProfileRuntimeProfile in
            guard let tunnelProtocol = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
                  let profile = tunnelProtocol.wireRouteAutomaticRuntimeProfile(called: tunnel.name) else {
                throw AutomaticProfilesManagementError.profileStorageUnavailable(tunnel.name)
            }
            updatedPolicy = updatedPolicy.updatingProfile(profile.profile)
            return profile
        }
        return try AutomaticProfileRuntimeSnapshot(
            revision: revision,
            policyRevision: policyRevision,
            policy: updatedPolicy,
            profiles: profiles
        ).validated()
    }

    private func refreshAutomaticProfilesSnapshotIfNeeded() {
        #if os(macOS)
        guard !isRepairingVPNRegistration else { return }
        #endif
        guard let snapshotURL = FileManager.automaticProfilesSnapshotURL(),
              let existingSnapshot = try? AutomaticProfileFileStore.loadSnapshot(from: snapshotURL),
              existingSnapshot.policy.isEnabled else {
            return
        }
        do {
            let comparableSnapshot = try makeAutomaticProfilesSnapshot(
                policy: existingSnapshot.policy,
                revision: existingSnapshot.revision,
                policyRevision: existingSnapshot.policyRevision
            )
            guard comparableSnapshot != existingSnapshot else { return }
            var snapshot = comparableSnapshot
            snapshot.revision = UUID()
            try AutomaticProfileFileStore.saveSnapshot(snapshot, to: snapshotURL)
            guard let controller = automaticProfilesController else { return }
            snapshot.policy.applyAutomaticProfiles(
                on: controller,
                availableProfileIDs: snapshot.availableProfileIDs
            )
            Task { @MainActor [weak self] in
                do {
                    try await controller.saveToPreferences()
                    self?.sendAutomaticProfilesCommand(
                        .reloadSnapshot,
                        startIfDisconnected: false
                    )
                } catch {
                    wg_log(.error, message: "Automatic Profiles controller refresh failed: \(error.localizedDescription)")
                }
            }
        } catch {
            wg_log(.error, message: "Automatic Profiles snapshot refresh failed: \(error.localizedDescription)")
        }
    }

    func saveAutomaticProfilePolicy(
        _ requestedPolicy: AutomaticProfilePolicy,
        completionHandler: @escaping @MainActor @Sendable (AutomaticProfilesManagementError?) -> Void
    ) {
        guard !configurationChangeBlocked else {
            completionHandler(.saveFailed(TunnelsManagerError.vpnConfigurationBusy))
            return
        }
        guard let snapshotURL = FileManager.automaticProfilesSnapshotURL() else {
            completionHandler(.sharedStorageUnavailable)
            return
        }

        let previousSnapshot = try? AutomaticProfileFileStore.loadSnapshot(from: snapshotURL)
        let snapshot: AutomaticProfileRuntimeSnapshot
        do {
            snapshot = try makeAutomaticProfilesSnapshot(policy: requestedPolicy)
            try AutomaticProfileFileStore.saveSnapshot(snapshot, to: snapshotURL)
        } catch let error as AutomaticProfilesManagementError {
            completionHandler(error)
            return
        } catch {
            completionHandler(.saveFailed(error))
            return
        }

        let existingController = automaticProfilesController
        let controller = existingController ?? NETunnelProviderManager()
        let previousControllerProtocol = controller.protocolConfiguration
        let previousControllerDescription = controller.localizedDescription
        let previousControllerEnabled = controller.isEnabled
        let previousControllerOnDemandRules = controller.onDemandRules
        let previousControllerOnDemandEnabled = controller.isOnDemandEnabled
        let profileOnDemandStates = tunnels.map {
            ($0, $0.tunnelProvider.isOnDemandEnabled)
        }
        let hasDirectlyActiveTunnel = tunnels.contains {
            !$0.isAutomaticProfilesProjection
                && ($0.status == .active || $0.status == .activating)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if snapshot.policy.isEnabled {
                    guard let controllerProtocol = NETunnelProviderProtocol(
                        automaticProfilesControllerOwnerUID: {
                            #if os(macOS)
                            getuid()
                            #else
                            nil
                            #endif
                        }()
                    ) else {
                        throw AutomaticProfilesManagementError.sharedStorageUnavailable
                    }
                    controller.localizedDescription = tr("automaticProfilesControllerName")
                    controller.protocolConfiguration = controllerProtocol
                    controller.isEnabled = true
                    for (tunnel, wasOnDemandEnabled) in profileOnDemandStates where wasOnDemandEnabled {
                        tunnel.tunnelProvider.isOnDemandEnabled = false
                        try await tunnel.tunnelProvider.saveToPreferences()
                        tunnel.isActivateOnDemandEnabled = false
                    }
                    snapshot.policy.applyAutomaticProfiles(
                        on: controller,
                        availableProfileIDs: snapshot.availableProfileIDs
                    )
                    // Save the controller last. Apple only permits one enabled enterprise VPN
                    // configuration, so this prevents an older single-profile rule from winning.
                    try await controller.saveToPreferences()
                    self.automaticProfilesController = controller
                    #if os(macOS)
                    self.automaticProfilesMacNetworkObserver?.start(
                        needsWiFiName: snapshot.policy.needsWiFiName
                    )
                    #elseif os(iOS)
                    self.automaticProfilesIOSNetworkObserver?.start(
                        needsWiFiName: snapshot.policy.needsWiFiName
                    )
                    #endif
                    if !hasDirectlyActiveTunnel {
                        if controller.connection.status == .connected
                            || controller.connection.status == .reasserting {
                            self.sendAutomaticProfilesCommand(
                                .reloadSnapshot,
                                startIfDisconnected: false
                            )
                        } else {
                            #if os(macOS)
                            if let observation = self.automaticProfilesMacNetworkObserver?.currentObservation {
                                self.handleMacAutomaticProfilesNetworkChange(observation)
                            }
                            #endif
                        }
                    }
                } else if let existingController {
                    existingController.isOnDemandEnabled = false
                    try await existingController.saveToPreferences()
                    self.sendAutomaticProfilesCommand(
                        .reloadSnapshot,
                        startIfDisconnected: false
                    )
                    #if os(macOS)
                    self.automaticProfilesMacNetworkObserver?.stop()
                    #elseif os(iOS)
                    self.automaticProfilesIOSNetworkObserver?.stop()
                    #endif
                }
                self.refreshAutomaticProfilesProjection()
                completionHandler(nil)
            } catch {
                controller.protocolConfiguration = previousControllerProtocol
                controller.localizedDescription = previousControllerDescription
                controller.isEnabled = previousControllerEnabled
                controller.onDemandRules = previousControllerOnDemandRules
                controller.isOnDemandEnabled = previousControllerOnDemandEnabled
                for (tunnel, wasOnDemandEnabled) in profileOnDemandStates {
                    tunnel.tunnelProvider.isOnDemandEnabled = wasOnDemandEnabled
                    tunnel.isActivateOnDemandEnabled = wasOnDemandEnabled && tunnel.tunnelProvider.isEnabled
                    try? await tunnel.tunnelProvider.saveToPreferences()
                }
                if let previousSnapshot {
                    try? AutomaticProfileFileStore.saveSnapshot(previousSnapshot, to: snapshotURL)
                } else {
                    let disabledSnapshot = AutomaticProfileRuntimeSnapshot(
                        policy: AutomaticProfilePolicy(),
                        profiles: snapshot.profiles
                    )
                    try? AutomaticProfileFileStore.saveSnapshot(disabledSnapshot, to: snapshotURL)
                }
                completionHandler((error as? AutomaticProfilesManagementError) ?? .saveFailed(error))
            }
        }
    }

    private func sendAutomaticProfilesCommand(
        _ command: AutomaticProfileProviderCommand,
        startIfDisconnected: Bool,
        activationAttemptID: String? = nil
    ) {
        guard let controller = automaticProfilesController,
              let session = controller.connection as? NETunnelProviderSession,
              let commandData = try? JSONEncoder().encode(command) else {
            return
        }

        switch session.status {
        case .connected, .reasserting:
            do {
                try session.sendProviderMessage(commandData) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshAutomaticProfilesProjection()
                    }
                }
            } catch {
                wg_log(.error, message: "Automatic Profiles command failed: \(error.localizedDescription)")
            }
        case .disconnected where startIfDisconnected,
             .invalid where startIfDisconnected:
            var options: [String: NSObject] = [
                "automaticProfileCommand": commandData as NSData
            ]
            if let activationAttemptID {
                options["activationAttemptId"] = activationAttemptID as NSString
            }
            do {
                try session.startTunnel(options: options)
            } catch {
                wg_log(.error, message: "Automatic Profiles controller could not start: \(error.localizedDescription)")
                if let tunnel = pendingAutomaticProfilesActivationTunnel {
                    pendingAutomaticProfilesActivationTunnel = nil
                    pendingAutomaticProfilesActivationToken = nil
                    tunnel.status = .inactive
                    activationDelegate?.tunnelActivationAttemptFailed(
                        tunnel: tunnel,
                        error: .failedWhileStarting(systemError: error)
                    )
                }
            }
        case .connecting, .disconnecting, .disconnected, .invalid:
            break
        @unknown default:
            break
        }
    }

    #if os(macOS)
    private func handleMacAutomaticProfilesNetworkChange(
        _ observation: AutomaticProfileNetworkObservation
    ) {
        guard !isRepairingVPNRegistration else { return }
        let policy = automaticProfilePolicy
        guard policy.isEnabled else { return }
        guard !tunnels.contains(where: {
            !$0.isAutomaticProfilesProjection
                && ($0.status == .active || $0.status == .activating || $0.status == .reasserting)
        }) else {
            return
        }
        if let pendingTunnel = pendingAutomaticProfilesActivationTunnel {
            sendAutomaticProfilesCommand(
                .activateManually(
                    profileID: pendingTunnel.activityProfileIdentifier,
                    network: observation
                ),
                startIfDisconnected: true,
                activationAttemptID: pendingTunnel.activationAttemptId
            )
            return
        }
        if let state = automaticProfilesRuntimeState,
           state.ownership == .manual,
           state.activeProfile == nil,
           state.networkIdentity == observation.identity {
            return
        }
        let decision = policy.decide(
            transport: observation.transport,
            wiFiName: observation.wiFiName,
            availableProfileIDs: Set(automaticProfileReferences.map(\.id))
        )
        sendAutomaticProfilesCommand(
            .networkChanged(observation),
            startIfDisconnected: {
                if case .connect = decision { return true }
                return false
            }()
        )
    }
    #endif

    private func startAutomaticProfilesStatusPolling() {
        guard automaticProfilesStatusTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAutomaticProfilesProjection()
            }
        }
        automaticProfilesStatusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshAutomaticProfilesProjection() {
        guard let controller = automaticProfilesController,
              let session = controller.connection as? NETunnelProviderSession else {
            automaticProfilesRuntimeState = nil
            automaticProfilesStateRequestToken = nil
            tunnels.forEach { $0.clearAutomaticProfilesProjection() }
            return
        }

        let controllerStatus = TunnelStatus(from: session.status)
        guard session.status != .disconnected && session.status != .invalid else {
            automaticProfilesRuntimeState = nil
            automaticProfilesStateRequestToken = nil
            tunnels.forEach { $0.clearAutomaticProfilesProjection() }
            return
        }

        applyAutomaticProfilesProjection(session: session, controllerStatus: controllerStatus)
        requestAutomaticProfilesRuntimeState(from: session)
    }

    private func applyAutomaticProfilesProjection(
        session: NETunnelProviderSession,
        controllerStatus: TunnelStatus
    ) {
        let activeProfileID = automaticProfilesRuntimeState?.activeProfile?.id
            ?? pendingAutomaticProfilesActivationTunnel?.activityProfileIdentifier
        for tunnel in tunnels {
            if tunnel.activityProfileIdentifier == activeProfileID {
                tunnel.applyAutomaticProfilesProjection(
                    session: session,
                    status: controllerStatus
                )
            } else {
                tunnel.clearAutomaticProfilesProjection()
            }
        }

        if session.status == .connected,
           let pendingTunnel = pendingAutomaticProfilesActivationTunnel,
           automaticProfilesRuntimeState?.activeProfile?.id == pendingTunnel.activityProfileIdentifier {
            pendingAutomaticProfilesActivationTunnel = nil
            pendingAutomaticProfilesActivationToken = nil
            activationDelegate?.tunnelActivationSucceeded(tunnel: pendingTunnel)
        }
    }

    private func requestAutomaticProfilesRuntimeState(from session: NETunnelProviderSession) {
        guard automaticProfilesStateRequestToken == nil else { return }
        let requestToken = UUID()
        automaticProfilesStateRequestToken = requestToken
        do {
            try session.sendProviderMessage(Data([UInt8(1)])) { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.automaticProfilesStateRequestToken == requestToken else { return }
                    self.automaticProfilesStateRequestToken = nil
                    guard let data,
                          let state = try? JSONDecoder().decode(
                              AutomaticProfileRuntimeState.self,
                              from: data
                          ),
                          let currentSession = self.automaticProfilesController?.connection
                              as? NETunnelProviderSession,
                          currentSession.status != .disconnected,
                          currentSession.status != .invalid else {
                        return
                    }
                    self.automaticProfilesRuntimeState = state
                    self.applyAutomaticProfilesProjection(
                        session: currentSession,
                        controllerStatus: TunnelStatus(from: currentSession.status)
                    )
                }
            }
        } catch {
            automaticProfilesStateRequestToken = nil
            wg_log(
                .error,
                message: "Automatic Profiles runtime state request failed: \(error.localizedDescription)"
            )
        }
    }

    private var automaticProfilesCurrentNetworkObservation: AutomaticProfileNetworkObservation? {
        #if os(macOS)
        return automaticProfilesMacNetworkObserver?.currentObservation
        #else
        if let observation = automaticProfilesIOSNetworkObserver?.currentObservation {
            return observation
        }
        return automaticProfilesRuntimeState?.network
        #endif
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
        #if os(macOS)
        guard !isRepairingVPNRegistration else { return }
        registrationRepairTargets.removeValue(forKey: tunnel.activityProfileIdentifier)
        #endif
        guard tunnels.contains(tunnel) else { return } // Ensure it's not deleted
        guard tunnel.status == .inactive else {
            activationDelegate?.tunnelActivationAttemptFailed(tunnel: tunnel, error: .tunnelIsNotInactive)
            return
        }
        guard let tunnelProtocol = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol,
              tunnelProtocol.verifyConfigurationReference(),
              tunnel.tunnelConfiguration != nil else {
            wg_log(.error, message: "Tunnel '\(tunnel.name)' cannot be activated because its Keychain configuration is unavailable")
            activationDelegate?.tunnelActivationAttemptFailed(
                tunnel: tunnel,
                error: .configurationUnavailable
            )
            return
        }

        if automaticProfilePolicy.isEnabled {
            if tunnels.contains(where: {
                $0 != tunnel
                    && !$0.isAutomaticProfilesProjection
                    && $0.status != .inactive
            }) {
                activationDelegate?.tunnelActivationAttemptFailed(
                    tunnel: tunnel,
                    error: .tunnelIsNotInactive
                )
                return
            }
            startAutomaticProfilesManualActivation(of: tunnel)
            #if os(iOS)
            RecentTunnelsTracker.handleTunnelActivated(tunnelName: tunnel.name)
            #endif
            return
        }

        if let controllerSession = automaticProfilesController?.connection as? NETunnelProviderSession,
           controllerSession.status != .disconnected,
           controllerSession.status != .invalid {
            if let previousPending = pendingDirectActivationTunnel,
               previousPending != tunnel {
                previousPending.status = .inactive
            }
            pendingDirectActivationTunnel = tunnel
            tunnel.status = .waiting
            controllerSession.stopTunnel()
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
        if tunnel.isAutomaticProfilesProjection,
           automaticProfilesController != nil {
            tunnel.status = .deactivating
            if pendingAutomaticProfilesActivationTunnel == tunnel {
                pendingAutomaticProfilesActivationTunnel = nil
                pendingAutomaticProfilesActivationToken = nil
            }
            sendAutomaticProfilesCommand(
                .deactivateManually(network: automaticProfilesCurrentNetworkObservation),
                startIfDisconnected: false
            )
        } else {
            if automaticProfilePolicy.isEnabled,
               let network = automaticProfilesCurrentNetworkObservation,
               let snapshotURL = FileManager.automaticProfilesSnapshotURL(),
               let snapshot = try? AutomaticProfileFileStore.loadSnapshot(from: snapshotURL) {
                let state = AutomaticProfileRuntimeState(
                    snapshotRevision: snapshot.revision,
                    policyRevision: snapshot.policyRevision,
                    activeProfile: nil,
                    ownership: .manual,
                    networkIdentity: network.identity,
                    network: network
                )
                if let stateURL = FileManager.automaticProfilesStateURL() {
                    try? AutomaticProfileFileStore.saveState(state, to: stateURL)
                }
                automaticProfilesRuntimeState = state
            }
            tunnel.startDeactivation()
        }
        #endif
    }

    func refreshStatuses() {
        tunnels.forEach { $0.refreshStatus() }
        refreshAutomaticProfilesProjection()
    }

    private func startAutomaticProfilesManualActivation(of tunnel: TunnelContainer) {
        guard automaticProfilesController != nil else {
            activationDelegate?.tunnelActivationAttemptFailed(
                tunnel: tunnel,
                error: .automaticProfilesUnavailable
            )
            return
        }
        if let previousPending = pendingAutomaticProfilesActivationTunnel,
           previousPending != tunnel {
            previousPending.status = .inactive
        }
        pendingAutomaticProfilesActivationTunnel = tunnel
        let pendingToken = UUID()
        pendingAutomaticProfilesActivationToken = pendingToken
        tunnels.forEach {
            if $0 == tunnel {
                $0.status = .activating
            } else {
                $0.clearAutomaticProfilesProjection()
            }
        }
        let activationAttemptID = UUID().uuidString
        tunnel.activationAttemptId = activationAttemptID
        #if os(macOS)
        let network = automaticProfilesMacNetworkObserver?.currentObservation
        if network == nil {
            let policy = automaticProfilePolicy
            automaticProfilesMacNetworkObserver?.start(needsWiFiName: policy.needsWiFiName)
        }
        #else
        let network: AutomaticProfileNetworkObservation? = nil
        #endif
        #if os(macOS)
        if network != nil {
            sendAutomaticProfilesCommand(
                .activateManually(
                    profileID: tunnel.activityProfileIdentifier,
                    network: network
                ),
                startIfDisconnected: true,
                activationAttemptID: activationAttemptID
            )
        }
        #else
        sendAutomaticProfilesCommand(
            .activateManually(
                profileID: tunnel.activityProfileIdentifier,
                network: network
            ),
            startIfDisconnected: true,
            activationAttemptID: activationAttemptID
        )
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak tunnel] in
            guard let self, let tunnel,
                  self.pendingAutomaticProfilesActivationToken == pendingToken,
                  self.pendingAutomaticProfilesActivationTunnel == tunnel else { return }
            self.pendingAutomaticProfilesActivationToken = nil
            self.pendingAutomaticProfilesActivationTunnel = nil
            tunnel.status = .inactive
            if let controllerSession = self.automaticProfilesController?.connection
                as? NETunnelProviderSession {
                self.reportActivationFailure(
                    for: tunnel,
                    session: controllerSession,
                    wasOnDemandEnabled: self.automaticProfilesController?.isOnDemandEnabled == true
                )
            } else {
                self.activationDelegate?.tunnelActivationAttemptFailed(
                    tunnel: tunnel,
                    error: .automaticProfilesUnavailable
                )
            }
        }
        activationDelegate?.tunnelActivationAttemptSucceeded(tunnel: tunnel)
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
                    let tunnelProvider = session.manager as? NETunnelProviderManager else { return }

                #if os(macOS)
                guard !self.isRepairingVPNRegistration else { return }
                #endif

                if tunnelProvider == self.automaticProfilesController {
                    wg_log(.debug, message: "Automatic Profiles controller status changed to '\(session.status)'")
                    if (session.status == .disconnected || session.status == .invalid),
                       let pendingTunnel = self.pendingAutomaticProfilesActivationTunnel {
                        self.pendingAutomaticProfilesActivationTunnel = nil
                        self.pendingAutomaticProfilesActivationToken = nil
                        pendingTunnel.status = .inactive
                        self.reportActivationFailure(
                            for: pendingTunnel,
                            session: session,
                            wasOnDemandEnabled: tunnelProvider.isOnDemandEnabled
                        )
                    }
                    self.refreshAutomaticProfilesProjection()
                    if session.status == .connected,
                       let pendingTunnel = self.pendingAutomaticProfilesActivationTunnel {
                        self.sendAutomaticProfilesCommand(
                            .activateManually(
                                profileID: pendingTunnel.activityProfileIdentifier,
                                network: self.automaticProfilesCurrentNetworkObservation
                            ),
                            startIfDisconnected: false,
                            activationAttemptID: pendingTunnel.activationAttemptId
                        )
                    }
                    if session.status == .disconnected,
                       let pendingDirectTunnel = self.pendingDirectActivationTunnel {
                        self.pendingDirectActivationTunnel = nil
                        pendingDirectTunnel.status = .inactive
                        self.startActivation(of: pendingDirectTunnel)
                    }
                    #if os(macOS)
                    if session.status == .connected,
                       self.pendingAutomaticProfilesActivationTunnel == nil,
                       let observation = self.automaticProfilesMacNetworkObserver?.currentObservation {
                        self.sendAutomaticProfilesCommand(
                            .networkChanged(observation),
                            startIfDisconnected: false
                        )
                    }
                    #endif
                    return
                }

                guard let tunnel = self.tunnels.first(where: { $0.tunnelProvider == tunnelProvider }) else {
                    return
                }

                wg_log(.debug, message: "Tunnel '\(tunnel.name)' connection status changed to '\(tunnel.tunnelProvider.connection.status)'")

                if tunnel.isAttemptingActivation {
                    if session.status == .connected {
                        tunnel.isAttemptingActivation = false
                        self.activationDelegate?.tunnelActivationSucceeded(tunnel: tunnel)
                    } else if session.status == .disconnected {
                        tunnel.isAttemptingActivation = false
                        self.reportActivationFailure(
                            for: tunnel,
                            session: session,
                            wasOnDemandEnabled: tunnelProvider.isOnDemandEnabled
                        )
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
                #if os(macOS)
                if session.status == .disconnected,
                   self.automaticProfilePolicy.isEnabled,
                   let observation = self.automaticProfilesMacNetworkObserver?.currentObservation {
                    self.handleMacAutomaticProfilesNetworkChange(observation)
                }
                #endif
            }
        }
    }

    private func reportActivationFailure(
        for tunnel: TunnelContainer,
        session: NETunnelProviderSession,
        wasOnDemandEnabled: Bool
    ) {
        if let (title, message) = lastErrorTextFromNetworkExtension(for: tunnel) {
            activationDelegate?.tunnelActivationFailed(
                tunnel: tunnel,
                error: .activationFailedWithExtensionError(
                    title: title,
                    message: message,
                    wasOnDemandEnabled: wasOnDemandEnabled
                )
            )
            return
        }

        guard #available(macOS 13.0, iOS 16.0, *) else {
            activationDelegate?.tunnelActivationFailed(
                tunnel: tunnel,
                error: .activationFailed(wasOnDemandEnabled: wasOnDemandEnabled)
            )
            return
        }

        let activationAttemptId = tunnel.activationAttemptId
        #if os(macOS)
        let failedManager = UncheckedTransfer(value: session.manager as? NETunnelProviderManager)
        #endif
        session.fetchLastDisconnectError { [weak self, weak tunnel] systemError in
            let transferredError = UncheckedTransfer(value: systemError)
            Task { @MainActor [weak self, weak tunnel] in
                guard let self, let tunnel,
                      tunnel.activationAttemptId == activationAttemptId else { return }

                if let (title, message) = lastErrorTextFromNetworkExtension(for: tunnel) {
                    self.activationDelegate?.tunnelActivationFailed(
                        tunnel: tunnel,
                        error: .activationFailedWithExtensionError(
                            title: title,
                            message: message,
                            wasOnDemandEnabled: wasOnDemandEnabled
                        )
                    )
                } else if let systemError = transferredError.value {
                    let error = systemError as NSError
                    #if os(macOS)
                    if MacOSVPNRegistrationRepair.isProviderUnavailable(systemError),
                       self.embeddedProviderIdentifier != nil,
                       let manager = failedManager.value {
                        self.registrationRepairTargets[tunnel.activityProfileIdentifier] = (activationAttemptId, manager)
                    }
                    #endif
                    wg_log(
                        .error,
                        message: "Tunnel '\(tunnel.name)' activation failed with VPN disconnect error \(error.domain) (\(error.code)): \(error.localizedDescription)"
                    )
                    self.activationDelegate?.tunnelActivationFailed(
                        tunnel: tunnel,
                        error: .activationFailedWithSystemError(
                            systemError: systemError,
                            wasOnDemandEnabled: wasOnDemandEnabled
                        )
                    )
                } else {
                    self.activationDelegate?.tunnelActivationFailed(
                        tunnel: tunnel,
                        error: .activationFailed(wasOnDemandEnabled: wasOnDemandEnabled)
                    )
                }
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
    private(set) var isAutomaticProfilesProjection = false
    private weak var automaticProfilesSession: NETunnelProviderSession?

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

    var profileDNSRouteSummary: ProfileDNSRouteSummary {
        guard let configuration = tunnelConfiguration else {
            return ProfileDNSRouteSummary(
                dnsServers: [],
                searchDomains: [],
                allowedRoutes: [],
                isConfigurationAvailable: false
            )
        }
        let routedAddressRanges = configuration.interface.addresses
            + configuration.peers.flatMap(\.allowedIPs)
        let allowedRoutes = routedAddressRanges
            .compactMap { try? RoutePrefix($0.stringRepresentation) }
        return ProfileDNSRouteSummary(
            dnsServers: configuration.interface.dns.map(\.stringRepresentation),
            searchDomains: configuration.interface.dnsSearch,
            allowedRoutes: allowedRoutes
        )
    }

    var activityProfileIdentifier: UUID {
        guard let tunnelProtocol = tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol else {
            return WireRouteProfileIdentifier.derived(from: name)
        }
        return tunnelProtocol.wireRouteActivityProfileIdentifier
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
        let runtimeSession = automaticProfilesSession
            ?? (tunnelProvider.connection as? NETunnelProviderSession)
        guard status != .inactive, let session = runtimeSession else {
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
        guard !isAutomaticProfilesProjection else { return }
        if (status == .restarting) || (status == .waiting && tunnelProvider.connection.status == .disconnected) {
            return
        }
        status = TunnelStatus(from: tunnelProvider.connection.status)
    }

    func applyAutomaticProfilesProjection(
        session: NETunnelProviderSession,
        status: TunnelStatus
    ) {
        isAutomaticProfilesProjection = true
        automaticProfilesSession = session
        self.status = status
    }

    func clearAutomaticProfilesProjection() {
        guard isAutomaticProfilesProjection else { return }
        isAutomaticProfilesProjection = false
        automaticProfilesSession = nil
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

    @discardableResult
    func setRecoveredTunnelConfiguration(
        _ tunnelConfiguration: TunnelConfiguration,
        passwordReference: Data
    ) -> NETunnelProviderProtocol? {
        guard let newProtocolConfiguration = NETunnelProviderProtocol(
            recoveredTunnelConfiguration: tunnelConfiguration,
            passwordReference: passwordReference,
            previouslyFrom: protocolConfiguration
        ) else {
            return nil
        }
        protocolConfiguration = newProtocolConfiguration
        localizedDescription = tunnelConfiguration.name
        objc_setAssociatedObject(
            self,
            &NETunnelProviderManager.cachedConfigKey,
            tunnelConfiguration,
            objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
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
