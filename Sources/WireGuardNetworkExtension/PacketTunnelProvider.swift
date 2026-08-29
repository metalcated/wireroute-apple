// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import NetworkExtension
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
        profileName: String
    ) {
        stop()
        do {
            let store = try WireRouteActivityStore()
            let recorder = WireRouteActivityRecorder(
                store: store,
                profileIdentifier: profileIdentifier
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

class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { logLevel, message in
            wg_log(logLevel.osLogLevel, message: message)
        }
    }()
    private let activitySamplingCoordinator = ActivitySamplingCoordinator()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = NetworkExtensionCallback(completionHandler)
        let activationAttemptId = options?["activationAttemptId"] as? String
        let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId)

        Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path)

        wg_log(.info, message: "Starting tunnel from the " + (activationAttemptId == nil ? "OS directly, rather than the app" : "app"))

        guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol,
              let tunnelConfiguration = tunnelProviderProtocol.asTunnelConfiguration() else {
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
                    profileName: activityProfileName
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
