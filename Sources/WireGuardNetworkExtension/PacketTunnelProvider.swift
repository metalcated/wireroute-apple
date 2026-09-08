// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network
@preconcurrency import NetworkExtension
import os

/// NetworkExtension completion blocks are Objective-C callbacks that are safe to invoke from the
/// adapter queue, but the framework does not annotate them as `Sendable` yet.
private final class NetworkExtensionCallback<Input>: @unchecked Sendable {
    private let callback: (Input) -> Void

    init(_ callback: @escaping (Input) -> Void) {
        self.callback = callback
    }

    func callAsFunction(_ input: Input) {
        callback(input)
    }
}

private final class ActivitySamplingCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var recorder: WireRouteActivityRecorder?

    func start(
        adapter: WireGuardAdapter,
        profileIdentifier: UUID,
        profileName: String,
        ownerUID: uid_t? = nil
    ) {
        stop()
        do {
            let store = try WireRouteActivityStore(
                databaseURL: FileManager.activityDatabaseURL(ownerUID: ownerUID)
            )
            let recorder = WireRouteActivityRecorder(
                store: store,
                profileIdentifier: profileIdentifier,
                ownerUID: ownerUID
            )
            try recorder.start(profileName: profileName)
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "WireRouteActivitySampler")
            )
            timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .seconds(1))
            let coordinator = self
            timer.setEventHandler {
                adapter.getRuntimeConfiguration { settings in
                    guard let settings else { return }
                    coordinator.record(settings)
                }
            }
            lock.withLock {
                self.recorder = recorder
                self.timer = timer
            }
            timer.resume()
        } catch {
            wg_log(.error, message: "Activity recording could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        let state = lock.withLock { () -> (DispatchSourceTimer?, WireRouteActivityRecorder?) in
            let state = (timer, recorder)
            timer = nil
            recorder = nil
            return state
        }
        state.0?.cancel()
        do {
            try state.1?.stop()
        } catch {
            wg_log(.error, message: "Activity recording could not close its session: \(error.localizedDescription)")
        }
    }

    private func record(_ runtimeConfiguration: String) {
        let recorder = lock.withLock { self.recorder }
        do {
            try recorder?.record(runtimeConfiguration: runtimeConfiguration)
        } catch {
            wg_log(.error, message: "Activity recording could not save a sample: \(error.localizedDescription)")
        }
    }
}

private final class AutomaticProfilesNetworkCoordinator: @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?
    private let adapter: WireGuardAdapter
    private let activitySamplingCoordinator: ActivitySamplingCoordinator
    private let ownerUID: uid_t?
    private let queue = DispatchQueue(label: "WireRouteAutomaticProfiles")
    private var monitor: NWPathMonitor?
    private var snapshot: AutomaticProfileRuntimeSnapshot
    private var activeProfileID: UUID?
    private var currentOwnership: AutomaticProfileRuntimeOwnership?
    private var currentNetworkIdentity: String?
    private var currentNetwork: AutomaticProfileNetworkObservation?
    private var requestedManualProfileID: UUID?
    private var initialCompletion: NetworkExtensionCallback<Error?>?
    private var errorNotifier: ErrorNotifier?
    private var observationGeneration = UInt64(0)
    private var hasStartedAdapter = false
    private var appliedSnapshotRevision: UUID?

    init?(
        provider: NEPacketTunnelProvider,
        adapter: WireGuardAdapter,
        activitySamplingCoordinator: ActivitySamplingCoordinator,
        ownerUID: uid_t?
    ) {
        guard let snapshotURL = FileManager.automaticProfilesSnapshotURL(ownerUID: ownerUID),
              let loadedSnapshot = try? AutomaticProfileFileStore.loadSnapshot(from: snapshotURL),
              let snapshot = try? loadedSnapshot.validated(),
              snapshot.policy.isEnabled else {
            return nil
        }
        self.provider = provider
        self.adapter = adapter
        self.activitySamplingCoordinator = activitySamplingCoordinator
        self.ownerUID = ownerUID
        self.snapshot = snapshot

        if let stateURL = FileManager.automaticProfilesStateURL(ownerUID: ownerUID),
           let state = try? AutomaticProfileFileStore.loadState(from: stateURL),
           state.policyRevision == snapshot.policyRevision,
           state.activeProfile.map({ snapshot.availableProfileIDs.contains($0.id) }) != false {
            activeProfileID = state.activeProfile?.id
            currentOwnership = state.ownership
            currentNetworkIdentity = state.networkIdentity
            currentNetwork = state.network
        }
    }

    func start(
        options: [String: NSObject]?,
        errorNotifier: ErrorNotifier,
        completion: NetworkExtensionCallback<Error?>
    ) {
        self.errorNotifier = errorNotifier
        initialCompletion = completion

        let initialCommand = (options?["automaticProfileCommand"] as? Data).flatMap {
            try? JSONDecoder().decode(AutomaticProfileProviderCommand.self, from: $0)
        }
        #if os(iOS)
        if let initialCommand,
           initialCommand.action == .activateManualProfile,
           initialCommand.network == nil,
           let profileID = initialCommand.profileID {
            requestedManualProfileID = profileID
        } else if let initialCommand {
            queue.async { [weak self] in
                self?.handleCommand(initialCommand)
            }
        } else if let requestedID = (options?["automaticProfileID"] as? String)
            .flatMap(UUID.init(uuidString:)) {
            requestedManualProfileID = requestedID
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.observe(path: path)
        }
        self.monitor = monitor
        monitor.start(queue: queue)
        #elseif os(macOS)
        if let initialCommand {
            queue.async { [weak self] in
                self?.handleCommand(initialCommand)
            }
        } else {
            failInitialStart(with: .automaticProfilesUnavailable)
        }
        #endif
    }

    func stop() {
        queue.async { [weak self] in
            self?.monitor?.cancel()
            self?.monitor = nil
        }
    }

    func reload() {
        queue.async { [weak self] in
            guard let self else { return }
            refreshSnapshot()
            if let currentNetwork {
                apply(currentNetwork)
                return
            }
            #if os(iOS)
            if let monitor {
                observe(path: monitor.currentPath)
            }
            #endif
        }
    }

    func submit(_ command: AutomaticProfileProviderCommand) {
        queue.async { [weak self] in
            self?.handleCommand(command)
        }
    }

    func runtimeStateData() -> Data? {
        guard let stateURL = FileManager.automaticProfilesStateURL(ownerUID: ownerUID),
              let state = try? AutomaticProfileFileStore.loadState(from: stateURL) else {
            return nil
        }
        return try? JSONEncoder().encode(state)
    }

    private func observe(path: NWPath) {
        refreshSnapshot()
        observationGeneration &+= 1
        let generation = observationGeneration
        let transport = Self.transport(for: path)

        guard transport == .wiFi && snapshot.policy.needsWiFiName else {
            apply(
                AutomaticProfileNetworkObservation(transport: transport),
                generation: generation
            )
            return
        }

        #if os(iOS)
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let wiFiName = network?.ssid
            guard let coordinator = self else { return }
            coordinator.queue.async {
                coordinator.apply(
                    AutomaticProfileNetworkObservation(transport: transport, wiFiName: wiFiName),
                    generation: generation
                )
            }
        }
        #else
        apply(
            AutomaticProfileNetworkObservation(transport: transport),
            generation: generation
        )
        #endif
    }

    private func refreshSnapshot() {
        guard let snapshotURL = FileManager.automaticProfilesSnapshotURL(ownerUID: ownerUID),
              let loadedSnapshot = try? AutomaticProfileFileStore.loadSnapshot(from: snapshotURL),
              let refreshedSnapshot = try? loadedSnapshot.validated(),
              refreshedSnapshot.revision != snapshot.revision else {
            return
        }
        snapshot = refreshedSnapshot
    }

    private func handleCommand(_ command: AutomaticProfileProviderCommand) {
        let previousPolicyRevision = snapshot.policyRevision
        refreshSnapshot()
        if snapshot.policyRevision != previousPolicyRevision,
           currentOwnership == .manual,
           activeProfileID == nil {
            currentOwnership = nil
            currentNetworkIdentity = nil
        }
        switch command.action {
        case .networkChanged:
            guard let network = command.network else {
                failInitialStart(with: .automaticProfilesUnavailable)
                return
            }
            observationGeneration &+= 1
            apply(network, generation: observationGeneration)
        case .activateManualProfile:
            guard let profileID = command.profileID else {
                failInitialStart(with: .automaticProfilesUnavailable)
                return
            }
            let network = command.network ?? currentNetwork
            if let network {
                currentNetwork = network
            }
            connect(
                profileID: profileID,
                ownership: .manual,
                networkIdentity: network?.identity ?? currentNetworkIdentity ?? "manual"
            )
        case .deactivateManualProfile:
            if let network = command.network ?? currentNetwork {
                currentNetwork = network
                pauseManually(networkIdentity: network.identity)
            } else {
                pauseManually(networkIdentity: currentNetworkIdentity ?? "manual")
            }
        case .reloadSnapshot:
            if let currentNetwork {
                observationGeneration &+= 1
                apply(currentNetwork, generation: observationGeneration)
            }
        }
    }

    private func apply(_ observation: AutomaticProfileNetworkObservation) {
        observationGeneration &+= 1
        apply(observation, generation: observationGeneration)
    }

    private func apply(
        _ observation: AutomaticProfileNetworkObservation,
        generation: UInt64
    ) {
        guard generation == observationGeneration else { return }
        currentNetwork = observation
        let networkIdentity = observation.identity

        if let requestedManualProfileID {
            self.requestedManualProfileID = nil
            connect(
                profileID: requestedManualProfileID,
                ownership: .manual,
                networkIdentity: networkIdentity
            )
            return
        }

        if currentOwnership == .manual {
            if let activeProfileID {
                currentNetworkIdentity = networkIdentity
                connect(
                    profileID: activeProfileID,
                    ownership: .manual,
                    networkIdentity: networkIdentity
                )
                return
            }
            if currentNetworkIdentity == networkIdentity {
                completeInitialStart(nil)
                return
            }
            currentOwnership = nil
            currentNetworkIdentity = nil
        }

        switch snapshot.decision(
            transport: observation.transport,
            wiFiName: observation.wiFiName
        ) {
        case .connect(let profileID):
            connect(profileID: profileID, ownership: .automatic, networkIdentity: networkIdentity)
        case .disconnect:
            persistState(activeProfile: nil, ownership: .automatic, networkIdentity: networkIdentity)
            disconnectWithoutError()
        case .hold(let reason):
            wg_log(.error, message: "Automatic profiles held the current tunnel: \(reason)")
            if !hasStartedAdapter {
                currentOwnership = .automatic
                currentNetworkIdentity = networkIdentity
                persistState(
                    activeProfile: nil,
                    ownership: .automatic,
                    networkIdentity: networkIdentity
                )
                completeInitialStart(nil)
            }
        }
    }

    private func connect(
        profileID: UUID,
        ownership: AutomaticProfileRuntimeOwnership,
        networkIdentity: String
    ) {
        guard activeProfileID != profileID
                || !hasStartedAdapter
                || appliedSnapshotRevision != snapshot.revision else {
            currentOwnership = ownership
            currentNetworkIdentity = networkIdentity
            persistState(
                activeProfile: snapshot.profile(withID: profileID)?.profile,
                ownership: ownership,
                networkIdentity: networkIdentity
            )
            completeInitialStart(nil)
            return
        }
        guard let runtimeProfile = snapshot.profile(withID: profileID),
              let tunnelProtocol = NETunnelProviderProtocol.wireRouteProtocol(from: runtimeProfile),
              let tunnelConfiguration = tunnelProtocol.asTunnelConfiguration(called: runtimeProfile.profile.name),
              let dnsProtectionPolicy = try? tunnelProtocol.wireRouteDNSProtectionPolicy() else {
            wg_log(.error, message: "Automatic profile '\(snapshot.profile(withID: profileID)?.profile.name ?? profileID.uuidString)' is unavailable")
            if !hasStartedAdapter {
                failInitialStart(with: .automaticProfilesUnavailable)
            }
            return
        }

        let blockedAddressFamilies = tunnelProtocol.wireRouteEffectiveBlockedAddressFamilies(
            for: tunnelConfiguration
        )
        let completion: @Sendable (WireGuardAdapterError?) -> Void = { [weak self] adapterError in
            guard let self else { return }
            self.queue.async {
                if let adapterError {
                    self.handleAdapterError(adapterError)
                    return
                }
                self.hasStartedAdapter = true
                self.activeProfileID = profileID
                self.appliedSnapshotRevision = self.snapshot.revision
                self.currentOwnership = ownership
                self.currentNetworkIdentity = networkIdentity
                self.activitySamplingCoordinator.start(
                    adapter: self.adapter,
                    profileIdentifier: runtimeProfile.profile.id,
                    profileName: runtimeProfile.profile.name,
                    ownerUID: self.ownerUID
                )
                self.persistState(
                    activeProfile: runtimeProfile.profile,
                    ownership: ownership,
                    networkIdentity: networkIdentity
                )
                self.completeInitialStart(nil)
            }
        }

        if hasStartedAdapter {
            adapter.update(
                tunnelConfiguration: tunnelConfiguration,
                blockedAddressFamilies: blockedAddressFamilies,
                dnsProtectionPolicy: dnsProtectionPolicy,
                completionHandler: completion
            )
        } else {
            adapter.start(
                tunnelConfiguration: tunnelConfiguration,
                blockedAddressFamilies: blockedAddressFamilies,
                dnsProtectionPolicy: dnsProtectionPolicy,
                completionHandler: completion
            )
        }
    }

    private func handleAdapterError(_ error: WireGuardAdapterError) {
        let providerError: PacketTunnelProviderError
        switch error {
        case .cannotLocateTunnelFileDescriptor:
            providerError = .couldNotDetermineFileDescriptor
        case .dnsResolution:
            providerError = .dnsResolutionFailure
        case .setNetworkSettings:
            providerError = .couldNotSetNetworkSettings
        case .startWireGuardBackend:
            providerError = .couldNotStartBackend
        case .invalidState:
            providerError = .automaticProfilesUnavailable
        }
        wg_log(.error, message: "Automatic profile transition failed: \(error)")
        if !hasStartedAdapter {
            failInitialStart(with: providerError)
        }
    }

    private func failInitialStart(with error: PacketTunnelProviderError) {
        errorNotifier?.notify(error)
        completeInitialStart(error)
    }

    private func completeInitialStart(_ error: Error?) {
        let completion = initialCompletion
        initialCompletion = nil
        completion?(error)
    }

    private func disconnectWithoutError() {
        completeInitialStart(nil)
        provider?.cancelTunnelWithError(nil)
    }

    private func pauseManually(networkIdentity: String) {
        currentOwnership = .manual
        currentNetworkIdentity = networkIdentity

        let finishPause: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.hasStartedAdapter = false
                self.activeProfileID = nil
                self.appliedSnapshotRevision = nil
                self.activitySamplingCoordinator.stop()
                self.persistState(
                    activeProfile: nil,
                    ownership: .manual,
                    networkIdentity: networkIdentity
                )
                self.completeInitialStart(nil)
            }
        }

        guard hasStartedAdapter else {
            finishPause()
            return
        }

        adapter.stop { [weak self] adapterError in
            guard let self else { return }
            if let adapterError {
                self.queue.async {
                    self.handleAdapterError(adapterError)
                }
                return
            }
            guard let provider = self.provider else {
                finishPause()
                return
            }
            provider.setTunnelNetworkSettings(nil) { error in
                if let error {
                    wg_log(
                        .error,
                        message: "Automatic profile pause could not clear network settings: \(error.localizedDescription)"
                    )
                    provider.cancelTunnelWithError(error)
                }
                finishPause()
            }
        }
    }

    private func persistState(
        activeProfile: AutomaticProfileReference?,
        ownership: AutomaticProfileRuntimeOwnership?,
        networkIdentity: String
    ) {
        guard let stateURL = FileManager.automaticProfilesStateURL(ownerUID: ownerUID) else { return }
        let state = AutomaticProfileRuntimeState(
            snapshotRevision: snapshot.revision,
            policyRevision: snapshot.policyRevision,
            activeProfile: activeProfile,
            ownership: ownership,
            networkIdentity: networkIdentity,
            network: currentNetwork
        )
        do {
            try AutomaticProfileFileStore.saveState(state, to: stateURL)
        } catch {
            wg_log(.error, message: "Automatic profile state could not be saved: \(error)")
        }
    }

    private static func transport(for path: NWPath) -> AutomaticProfileTransport {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wiFi }
        #if os(iOS)
        if path.usesInterfaceType(.cellular) { return .cellular }
        #endif
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .other
    }

}

class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { logLevel, message in
            wg_log(logLevel.osLogLevel, message: message)
        }
    }()
    private let activitySamplingCoordinator = ActivitySamplingCoordinator()
    private var automaticProfilesCoordinator: AutomaticProfilesNetworkCoordinator?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = NetworkExtensionCallback(completionHandler)
        let activationAttemptId = options?["activationAttemptId"] as? String
        let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId)

        Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path)

        wg_log(.info, message: "Starting tunnel from the " + (activationAttemptId == nil ? "OS directly, rather than the app" : "app"))

        guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol else {
            errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            completion(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        if tunnelProviderProtocol.isWireRouteAutomaticProfilesController {
            guard let coordinator = AutomaticProfilesNetworkCoordinator(
                provider: self,
                adapter: adapter,
                activitySamplingCoordinator: activitySamplingCoordinator,
                ownerUID: tunnelProviderProtocol.wireRouteOwnerUID
            ) else {
                errorNotifier.notify(PacketTunnelProviderError.automaticProfilesUnavailable)
                completion(PacketTunnelProviderError.automaticProfilesUnavailable)
                return
            }
            automaticProfilesCoordinator = coordinator
            coordinator.start(options: options, errorNotifier: errorNotifier, completion: completion)
            return
        }

        guard let tunnelConfiguration = tunnelProviderProtocol.asTunnelConfiguration() else {
            errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            completion(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        let dnsProtectionPolicy: DNSProtectionPolicy
        do {
            dnsProtectionPolicy = try tunnelProviderProtocol.wireRouteDNSProtectionPolicy()
        } catch {
            wg_log(.error, message: "Saved DNS protection configuration is invalid: \(error)")
            errorNotifier.notify(PacketTunnelProviderError.invalidDNSProtectionConfiguration)
            completion(PacketTunnelProviderError.invalidDNSProtectionConfiguration)
            return
        }

        // Start the tunnel
        let adapter = self.adapter
        let activitySamplingCoordinator = self.activitySamplingCoordinator
        let activityProfileIdentifier = tunnelProviderProtocol.wireRouteActivityProfileIdentifier
        let activityProfileName = tunnelProviderProtocol.wireRouteActivityProfileName
        #if os(macOS)
        let activityOwnerUID = (tunnelProviderProtocol.providerConfiguration?["UID"] as? NSNumber)
            .map { uid_t($0.uint32Value) }
        #else
        let activityOwnerUID: uid_t? = nil
        #endif
        let blockedAddressFamilies = tunnelProviderProtocol.wireRouteEffectiveBlockedAddressFamilies(
            for: tunnelConfiguration
        )
        adapter.start(
            tunnelConfiguration: tunnelConfiguration,
            blockedAddressFamilies: blockedAddressFamilies,
            dnsProtectionPolicy: dnsProtectionPolicy
        ) { adapterError in
            guard let adapterError = adapterError else {
                let interfaceName = adapter.interfaceName ?? "unknown"

                wg_log(.info, message: "Tunnel interface is \(interfaceName)")

                activitySamplingCoordinator.start(
                    adapter: adapter,
                    profileIdentifier: activityProfileIdentifier,
                    profileName: activityProfileName,
                    ownerUID: activityOwnerUID
                )

                completion(nil)
                return
            }

            switch adapterError {
            case .cannotLocateTunnelFileDescriptor:
                wg_log(.error, staticMessage: "Starting tunnel failed: could not determine file descriptor")
                errorNotifier.notify(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
                completion(PacketTunnelProviderError.couldNotDetermineFileDescriptor)

            case .dnsResolution(let dnsErrors):
                let hostnamesWithDnsResolutionFailure = dnsErrors.map { $0.address }
                    .joined(separator: ", ")
                wg_log(.error, message: "DNS resolution failed for the following hostnames: \(hostnamesWithDnsResolutionFailure)")
                errorNotifier.notify(PacketTunnelProviderError.dnsResolutionFailure)
                completion(PacketTunnelProviderError.dnsResolutionFailure)

            case .setNetworkSettings(let error):
                wg_log(.error, message: "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotSetNetworkSettings)
                completion(PacketTunnelProviderError.couldNotSetNetworkSettings)

            case .startWireGuardBackend(let errorCode):
                wg_log(.error, message: "Starting tunnel failed with wgTurnOn returning \(errorCode)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
                completion(PacketTunnelProviderError.couldNotStartBackend)

            case .invalidState:
                // Must never happen
                fatalError()
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = NetworkExtensionCallback<Void> { completionHandler() }
        wg_log(.info, staticMessage: "Stopping tunnel")
        automaticProfilesCoordinator?.stop()
        automaticProfilesCoordinator = nil
        activitySamplingCoordinator.stop()

        adapter.stop { error in
            ErrorNotifier.removeLastErrorFile()

            if let error = error {
                wg_log(.error, message: "Failed to stop WireGuard adapter: \(error.localizedDescription)")
            }
            completion(())

            #if os(macOS)
            // HACK: This is a filthy hack to work around Apple bug 32073323 (dup'd by us as 47526107).
            // Remove it when they finally fix this upstream and the fix has been rolled out to
            // sufficient quantities of users.
            exit(0)
            #endif
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler = completionHandler else { return }
        let completion = NetworkExtensionCallback(completionHandler)

        if messageData.count == 1 && messageData[0] == 0 {
            adapter.getRuntimeConfiguration { settings in
                var data: Data?
                if let settings = settings {
                    data = settings.data(using: .utf8)!
                }
                completion(data)
            }
        } else if messageData.count == 1 && messageData[0] == 1 {
            completion(automaticProfilesCoordinator?.runtimeStateData())
        } else if messageData.count == 1 && messageData[0] == 2 {
            automaticProfilesCoordinator?.reload()
            completion(Data())
        } else if let command = try? JSONDecoder().decode(
            AutomaticProfileProviderCommand.self,
            from: messageData
        ), let automaticProfilesCoordinator {
            automaticProfilesCoordinator.submit(command)
            completion(Data())
        } else {
            completion(nil)
        }
    }
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}
