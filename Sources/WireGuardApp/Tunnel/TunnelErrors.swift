// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import NetworkExtension

enum TunnelsManagerError: WireGuardAppError {
    case tunnelNameEmpty
    case tunnelAlreadyExistsWithThatName
    case tunnelConfigurationUnavailable
    case automaticProfilesEnabled
    case vpnConfigurationBusy
    case systemErrorOnListingTunnels(systemError: Error)
    case systemErrorOnAddTunnel(systemError: Error)
    case systemErrorOnModifyTunnel(systemError: Error)
    case systemErrorOnRemoveTunnel(systemError: Error)

    var alertText: AlertText {
        switch self {
        case .vpnConfigurationBusy:
            return (tr("vpnRegistrationRepairTitle"), tr("vpnRegistrationRepairBusy"))
        case .tunnelNameEmpty:
            return (tr("alertTunnelNameEmptyTitle"), tr("alertTunnelNameEmptyMessage"))
        case .tunnelAlreadyExistsWithThatName:
            return (tr("alertTunnelAlreadyExistsWithThatNameTitle"), tr("alertTunnelAlreadyExistsWithThatNameMessage"))
        case .tunnelConfigurationUnavailable:
            return (
                tr("alertTunnelConfigurationUnavailableTitle"),
                tr("alertTunnelConfigurationUnavailableMessage")
            )
        case .automaticProfilesEnabled:
            return (
                tr("automaticProfilesOnDemandUnavailableTitle"),
                tr("automaticProfilesOnDemandUnavailableMessage")
            )
        case .systemErrorOnListingTunnels(let systemError):
            return (tr("alertSystemErrorOnListingTunnelsTitle"), systemError.localizedUIString)
        case .systemErrorOnAddTunnel(let systemError):
            return (tr("alertSystemErrorOnAddTunnelTitle"), systemError.localizedUIString)
        case .systemErrorOnModifyTunnel(let systemError):
            return (tr("alertSystemErrorOnModifyTunnelTitle"), systemError.localizedUIString)
        case .systemErrorOnRemoveTunnel(let systemError):
            return (tr("alertSystemErrorOnRemoveTunnelTitle"), systemError.localizedUIString)
        }
    }
}

enum AutomaticProfilesManagementError: WireGuardAppError {
    case sharedStorageUnavailable
    case profileStorageUnavailable(String)
    case wiFiNameAccessDenied
    case saveFailed(Error)

    var alertText: AlertText {
        switch self {
        case .sharedStorageUnavailable:
            return (
                tr("automaticProfilesSaveFailureTitle"),
                tr("automaticProfilesSharedStorageUnavailable")
            )
        case .profileStorageUnavailable(let profileName):
            return (
                tr("automaticProfilesSaveFailureTitle"),
                tr(format: "automaticProfilesProfileStorageUnavailable (%@)", profileName)
            )
        case .wiFiNameAccessDenied:
            return (
                tr("automaticProfilesWiFiPermissionTitle"),
                tr("automaticProfilesWiFiPermissionMessage")
            )
        case .saveFailed(let error):
            return (
                tr("automaticProfilesSaveFailureTitle"),
                error.localizedUIString
            )
        }
    }
}

enum TunnelsManagerActivationAttemptError: WireGuardAppError {
    case tunnelIsNotInactive
    case configurationUnavailable
    case automaticProfilesUnavailable
    case failedWhileStarting(systemError: Error) // startTunnel() throwed
    case failedWhileSaving(systemError: Error) // save config after re-enabling throwed
    case failedWhileLoading(systemError: Error) // reloading config throwed
    case failedBecauseOfTooManyErrors(lastSystemError: Error) // recursion limit reached

    var alertText: AlertText {
        switch self {
        case .tunnelIsNotInactive:
            return (tr("alertTunnelActivationErrorTunnelIsNotInactiveTitle"), tr("alertTunnelActivationErrorTunnelIsNotInactiveMessage"))
        case .configurationUnavailable:
            return TunnelsManagerError.tunnelConfigurationUnavailable.alertText
        case .automaticProfilesUnavailable:
            return (
                tr("automaticProfilesActivationFailureTitle"),
                tr("automaticProfilesActivationFailureMessage")
            )
        case .failedWhileStarting(let systemError),
             .failedWhileSaving(let systemError),
             .failedWhileLoading(let systemError),
             .failedBecauseOfTooManyErrors(let systemError):
            return (tr("alertTunnelActivationSystemErrorTitle"),
                    tr(format: "alertTunnelActivationSystemErrorMessage (%@)", systemError.localizedUIString))
        }
    }
}

enum TunnelsManagerActivationError: WireGuardAppError {
    case activationFailed(wasOnDemandEnabled: Bool)
    case activationFailedWithExtensionError(title: String, message: String, wasOnDemandEnabled: Bool)
    case activationFailedWithSystemError(systemError: Error, wasOnDemandEnabled: Bool)

    var alertText: AlertText {
        switch self {
        case .activationFailed:
            return (tr("alertTunnelActivationFailureTitle"), tr("alertTunnelActivationFailureMessage"))
        case .activationFailedWithExtensionError(let title, let message, _):
            return (title, message)
        case .activationFailedWithSystemError(let systemError, _):
            return (
                tr("alertTunnelActivationSystemErrorTitle"),
                tr(format: "alertTunnelActivationSystemErrorMessage (%@)", systemError.localizedUIString)
            )
        }
    }
}

enum TunnelDNSProtectionError: WireGuardAppError, Sendable {
    case invalidStoredConfiguration

    var alertText: AlertText {
        return (tr("dnsProtectionInvalidTitle"), tr("dnsProtectionInvalidStoredMessage"))
    }
}

extension DNSProtectionPolicy {
    var localizedTitle: String {
        switch mode {
        case .profile:
            return tr("dnsProtectionProfileDNS")
        case .encryptedHTTPS:
            return tr("dnsProtectionEncryptedDNS")
        }
    }

    var localizedDescription: String {
        switch mode {
        case .profile:
            return tr("dnsProtectionProfileDescription")
        case .encryptedHTTPS:
            return tr("dnsProtectionEncryptedDescription")
        }
    }
}

extension DNSProtectionPreset {
    var localizedTitle: String {
        switch self {
        case .cloudflare:
            return tr("dnsPresetCloudflare")
        case .cloudflareSecurity:
            return tr("dnsPresetCloudflareSecurity")
        case .cloudflareFamily:
            return tr("dnsPresetCloudflareFamily")
        case .adGuard:
            return tr("dnsPresetAdGuard")
        case .adGuardFamily:
            return tr("dnsPresetAdGuardFamily")
        case .quad9:
            return tr("dnsPresetQuad9")
        case .google:
            return tr("dnsPresetGoogle")
        }
    }

    var localizedDescription: String {
        switch self {
        case .cloudflare:
            return tr("dnsPresetCloudflareDescription")
        case .cloudflareSecurity:
            return tr("dnsPresetCloudflareSecurityDescription")
        case .cloudflareFamily:
            return tr("dnsPresetCloudflareFamilyDescription")
        case .adGuard:
            return tr("dnsPresetAdGuardDescription")
        case .adGuardFamily:
            return tr("dnsPresetAdGuardFamilyDescription")
        case .quad9:
            return tr("dnsPresetQuad9Description")
        case .google:
            return tr("dnsPresetGoogleDescription")
        }
    }
}

extension PacketTunnelProviderError: WireGuardAppError {
    var alertText: AlertText {
        switch self {
        case .savedProtocolConfigurationIsInvalid:
            return (tr("alertTunnelActivationFailureTitle"), tr("alertTunnelActivationSavedConfigFailureMessage"))
        case .automaticProfilesUnavailable:
            return (
                tr("automaticProfilesActivationFailureTitle"),
                tr("automaticProfilesActivationFailureMessage")
            )
        case .invalidDNSProtectionConfiguration:
            return (tr("dnsProtectionInvalidTitle"), tr("dnsProtectionInvalidStoredMessage"))
        case .dnsResolutionFailure:
            return (tr("alertTunnelDNSFailureTitle"), tr("alertTunnelDNSFailureMessage"))
        case .couldNotStartBackend:
            return (tr("alertTunnelActivationFailureTitle"), tr("alertTunnelActivationBackendFailureMessage"))
        case .couldNotDetermineFileDescriptor:
            return (tr("alertTunnelActivationFailureTitle"), tr("alertTunnelActivationFileDescriptorFailureMessage"))
        case .couldNotSetNetworkSettings:
            return (tr("alertTunnelActivationFailureTitle"), tr("alertTunnelActivationSetNetworkSettingsMessage"))
        }
    }
}

extension Error {
    var localizedUIString: String {
        let bridgedError = self as NSError
        if let systemError = self as? NEVPNError {
            switch systemError {
            case NEVPNError.configurationInvalid:
                return tr("alertSystemErrorMessageTunnelConfigurationInvalid")
            case NEVPNError.configurationDisabled:
                return tr("alertSystemErrorMessageTunnelConfigurationDisabled")
            case NEVPNError.connectionFailed:
                return tr("alertSystemErrorMessageTunnelConnectionFailed")
            case NEVPNError.configurationStale:
                return tr("alertSystemErrorMessageTunnelConfigurationStale")
            case NEVPNError.configurationReadWriteFailed:
                return tr("alertSystemErrorMessageTunnelConfigurationReadWriteFailed")
            case NEVPNError.configurationUnknown:
                return tr("alertSystemErrorMessageTunnelConfigurationUnknown")
            default:
                return ""
            }
        } else if #available(macOS 13.0, iOS 16.0, *),
                  bridgedError.domain == NEVPNConnectionErrorDomain,
                  bridgedError.code == NEVPNConnectionError.pluginDisabled.rawValue {
#if DEBUG && os(macOS)
            return tr("alertSystemErrorMessageVPNPluginDisabledDevelopment")
#else
            return tr("alertSystemErrorMessageVPNPluginDisabled")
#endif
        } else {
            return localizedDescription
        }
    }
}
