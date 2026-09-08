// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import NetworkExtension

enum ActivateOnDemandOption: Equatable {
    case off
    case wiFiInterfaceOnly(ActivateOnDemandSSIDOption)
    case nonWiFiInterfaceOnly
    case anyInterface(ActivateOnDemandSSIDOption)
}

#if os(iOS)
private let nonWiFiInterfaceType: NEOnDemandRuleInterfaceType = .cellular
#elseif os(macOS)
private let nonWiFiInterfaceType: NEOnDemandRuleInterfaceType = .ethernet
#else
#error("Unimplemented")
#endif

enum ActivateOnDemandSSIDOption: Equatable {
    case anySSID
    case onlySpecificSSIDs([String])
    case exceptSpecificSSIDs([String])
}

extension ActivateOnDemandOption {
    func apply(on tunnelProviderManager: NETunnelProviderManager) {
        let rules: [NEOnDemandRule]?
        switch self {
        case .off:
            rules = nil
        case .wiFiInterfaceOnly(let ssidOption):
            rules = ssidOnDemandRules(option: ssidOption) + [NEOnDemandRuleDisconnect(interfaceType: nonWiFiInterfaceType)]
        case .nonWiFiInterfaceOnly:
            rules = [NEOnDemandRuleConnect(interfaceType: nonWiFiInterfaceType), NEOnDemandRuleDisconnect(interfaceType: .wiFi)]
        case .anyInterface(let ssidOption):
            if case .anySSID = ssidOption {
                rules = [NEOnDemandRuleConnect(interfaceType: .any)]
            } else {
                rules = ssidOnDemandRules(option: ssidOption) + [NEOnDemandRuleConnect(interfaceType: nonWiFiInterfaceType)]
            }
        }
        tunnelProviderManager.onDemandRules = rules
        tunnelProviderManager.isOnDemandEnabled = (rules != nil) && tunnelProviderManager.isOnDemandEnabled
    }

    init(from tunnelProviderManager: NETunnelProviderManager) {
        if let onDemandRules = tunnelProviderManager.onDemandRules {
            self = ActivateOnDemandOption.create(from: onDemandRules)
        } else {
            self = .off
        }
    }

    private static func create(from rules: [NEOnDemandRule]) -> ActivateOnDemandOption {
        switch rules.count {
        case 0:
            return .off
        case 1:
            let rule = rules[0]
            guard rule.action == .connect else { return .off }
            return .anyInterface(.anySSID)
        case 2:
            guard let connectRule = rules.first(where: { $0.action == .connect }) else {
                wg_log(.error, message: "Unexpected onDemandRules set on tunnel provider manager: \(rules.count) rules found but no connect rule.")
                return .off
            }
            guard let disconnectRule = rules.first(where: { $0.action == .disconnect }) else {
                wg_log(.error, message: "Unexpected onDemandRules set on tunnel provider manager: \(rules.count) rules found but no disconnect rule.")
                return .off
            }
            if connectRule.interfaceTypeMatch == .wiFi && disconnectRule.interfaceTypeMatch == nonWiFiInterfaceType {
                return .wiFiInterfaceOnly(.anySSID)
            } else if connectRule.interfaceTypeMatch == nonWiFiInterfaceType && disconnectRule.interfaceTypeMatch == .wiFi {
                return .nonWiFiInterfaceOnly
            } else {
                wg_log(.error, message: "Unexpected onDemandRules set on tunnel provider manager: \(rules.count) rules found but interface types are inconsistent.")
                return .off
            }
        case 3:
            guard let ssidRule = rules.first(where: { $0.interfaceTypeMatch == .wiFi && $0.ssidMatch != nil }) else { return .off }
            guard let nonWiFiRule = rules.first(where: { $0.interfaceTypeMatch == nonWiFiInterfaceType }) else { return .off }
            let ssids = ssidRule.ssidMatch!
            switch (ssidRule.action, nonWiFiRule.action) {
            case (.connect, .connect):
                return .anyInterface(.onlySpecificSSIDs(ssids))
            case (.connect, .disconnect):
                return .wiFiInterfaceOnly(.onlySpecificSSIDs(ssids))
            case (.disconnect, .connect):
                return .anyInterface(.exceptSpecificSSIDs(ssids))
            case (.disconnect, .disconnect):
                return .wiFiInterfaceOnly(.exceptSpecificSSIDs(ssids))
            default:
                wg_log(.error, message: "Unexpected onDemandRules set on tunnel provider manager: \(rules.count) rules found")
                return .off
            }
        default:
            wg_log(.error, message: "Unexpected number of onDemandRules set on tunnel provider manager: \(rules.count) rules found")
            return .off
        }
    }
}

extension AutomaticProfilePolicy {
    func applyAutomaticProfiles(
        on tunnelProviderManager: NETunnelProviderManager,
        availableProfileIDs _: Set<UUID>
    ) {
        guard isEnabled else {
            tunnelProviderManager.onDemandRules = nil
            tunnelProviderManager.isOnDemandEnabled = false
            return
        }

        var rules = [NEOnDemandRule]()
        let disconnectedWiFiNames = trustedWiFiNames + wiFiAssignments.compactMap {
            targetRequestsProfile($0.target) ? nil : $0.ssid
        }
        let connectedWiFiNames = wiFiAssignments.compactMap {
            targetRequestsProfile($0.target) ? $0.ssid : nil
        }
        if !disconnectedWiFiNames.isEmpty {
            rules.append(NEOnDemandRuleDisconnect(interfaceType: .wiFi, ssids: disconnectedWiFiNames))
        }
        if !connectedWiFiNames.isEmpty {
            rules.append(NEOnDemandRuleConnect(interfaceType: .wiFi, ssids: connectedWiFiNames))
        }
        rules.append(
            targetRequestsProfile(otherWiFiTarget)
                ? NEOnDemandRuleConnect(interfaceType: .wiFi)
                : NEOnDemandRuleDisconnect(interfaceType: .wiFi)
        )

        #if os(iOS)
        rules.append(
            targetRequestsProfile(cellularTarget)
                ? NEOnDemandRuleConnect(interfaceType: .cellular)
                : NEOnDemandRuleDisconnect(interfaceType: .cellular)
        )
        // iOS does not expose an Ethernet-specific On-Demand match. Because rules are ordered,
        // this final fallback covers wired adapters without overriding Wi-Fi or cellular choices.
        rules.append(
            targetRequestsProfile(ethernetTarget)
                ? NEOnDemandRuleConnect(interfaceType: .any)
                : NEOnDemandRuleDisconnect(interfaceType: .any)
        )
        #elseif os(macOS)
        rules.append(
            targetRequestsProfile(ethernetTarget)
                ? NEOnDemandRuleConnect(interfaceType: .ethernet)
                : NEOnDemandRuleDisconnect(interfaceType: .ethernet)
        )
        rules.append(NEOnDemandRuleDisconnect(interfaceType: .any))
        #else
        #error("Unimplemented")
        #endif

        tunnelProviderManager.onDemandRules = rules
        #if os(iOS)
        tunnelProviderManager.isOnDemandEnabled = true
        #elseif os(macOS)
        // macOS gates SSID access to a user-authorized app process. WireRoute's menu app stays
        // running and drives this controller, so the system extension never guesses a Wi-Fi name.
        tunnelProviderManager.isOnDemandEnabled = false
        #endif
    }

    private func targetRequestsProfile(_ target: AutomaticProfileTarget) -> Bool {
        switch target {
        case .useDefault:
            return defaultProfile != nil
        case .vpnOff:
            return false
        case .profile:
            return true
        }
    }
}

private extension NEOnDemandRuleConnect {
    convenience init(interfaceType: NEOnDemandRuleInterfaceType, ssids: [String]? = nil) {
        self.init()
        interfaceTypeMatch = interfaceType
        ssidMatch = ssids
    }
}

private extension NEOnDemandRuleDisconnect {
    convenience init(interfaceType: NEOnDemandRuleInterfaceType, ssids: [String]? = nil) {
        self.init()
        interfaceTypeMatch = interfaceType
        ssidMatch = ssids
    }
}

private func ssidOnDemandRules(option: ActivateOnDemandSSIDOption) -> [NEOnDemandRule] {
    switch option {
    case .anySSID:
        return [NEOnDemandRuleConnect(interfaceType: .wiFi)]
    case .onlySpecificSSIDs(let ssids):
        assert(!ssids.isEmpty)
        return [NEOnDemandRuleConnect(interfaceType: .wiFi, ssids: ssids),
                NEOnDemandRuleDisconnect(interfaceType: .wiFi)]
    case .exceptSpecificSSIDs(let ssids):
        return [NEOnDemandRuleDisconnect(interfaceType: .wiFi, ssids: ssids),
                NEOnDemandRuleConnect(interfaceType: .wiFi)]
    }
}
