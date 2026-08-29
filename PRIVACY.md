# WireRoute Privacy Policy

Effective date: August 28, 2026

This policy describes the data practices of the WireRoute applications for iOS and macOS.

## Summary

WireRoute does not require an account and does not operate a developer-controlled VPN, analytics, advertising, telemetry, or crash-reporting service. The project does not collect or sell personal data, track users, or use third-party advertising or analytics SDKs.

Under Apple's App Store privacy definition, data processed only on the device is not collected. Based on the current source and data-flow audit, neither the WireRoute project nor an integrated third-party partner receives data from the app for storage or later access.

## Data Stored on Your Device

WireRoute stores information needed to provide the features you choose:

- Tunnel profiles, routing preferences, on-demand rules, endpoints, DNS servers, public keys, and sensitive tunnel configuration material
- Sensitive tunnel configuration material in Apple Keychain and system-managed VPN preferences
- Local diagnostic logs in the shared app container
- Wi-Fi network names used for optional on-demand rules
- On macOS, optional RouterOS connection details, credentials, trusted certificate pins, peer defaults, and recoverable client configuration material

RouterOS passwords, trusted certificate data, and recoverable client configuration material are stored in Apple Keychain. Non-secret RouterOS peer defaults are stored in local application preferences.

Diagnostic logs can contain network interface names, endpoint hostnames or addresses, public keys, handshake status, and error details. Logs stay on the device unless you explicitly export or share them.

## Camera and Wi-Fi Information

On iOS, camera access is used only when you choose to scan a WireGuard configuration QR code. The QR code is processed by the app and is not uploaded to the WireRoute project.

If you configure Wi-Fi-specific on-demand behavior, WireRoute may read the currently connected Wi-Fi network name so you can create the requested rule. That information is processed and stored locally.

## Network Connections

WireRoute makes network connections only to provide user-requested functionality:

- VPN traffic is sent to the WireGuard endpoint configured in the selected profile.
- DNS requests may be sent to DNS servers configured in that profile.
- On macOS, the optional RouterOS Peer Manager connects over HTTPS to the RouterOS address you enter. It reads the selected router's WireGuard configuration and performs only peer changes that you separately review and confirm.

Those systems are selected and controlled by you or your network administrator. Their operators and network providers may process traffic according to their own policies. The WireRoute project cannot access those systems or traffic.

## Exports and Support Requests

WireRoute exports data only when you request it and choose a destination. Tunnel configuration exports can contain private keys and other sensitive network information. Protect exported files and delete them when they are no longer needed.

If you choose to contact the project through GitHub, the information you submit is handled by GitHub under its own privacy terms. Support requests are voluntary and should never contain private keys, passwords, complete configurations, or other secrets.

## Your Choices and Data Removal

- Delete tunnel profiles in WireRoute when you no longer need them.
- Delete exported configuration and log files from the destination where you saved them.
- On macOS, saved RouterOS credentials and certificate pins can be removed with Keychain Access. Search for WireRoute entries and review each item before deleting it.
- Uninstalling the app removes its ordinary app container according to Apple platform behavior. Keychain items can persist independently and may need to be removed separately.

WireRoute has no remote user account or developer-controlled data store, so there is no remote account data to request or delete.

## Changes

Material policy changes will be published in this repository with an updated effective date. App Store privacy answers should be reviewed whenever application data flows or integrated dependencies change.

## Contact

For privacy questions, use the contact methods in [SUPPORT.md](SUPPORT.md). Do not include secrets or sensitive configuration details in a public issue.

## Open-Source Notice

WireRoute is free and open-source software provided under the [MIT License](COPYING). See [LEGAL.md](LEGAL.md) for attribution and trademark information.
