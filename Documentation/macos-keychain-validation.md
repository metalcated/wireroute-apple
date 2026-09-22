# macOS Keychain and installed-provider regression checks

## Keep failure stages separate

`NEVPNConnectionErrorDomain (14)` ("The VPN app used by the VPN configuration is not installed") can occur before the packet tunnel provider starts. A valid app/extension signature and a matching saved designated requirement do not prove that macOS can launch the installed provider. Do not diagnose this as a WireGuard UDP, handshake, or Keychain-read failure without provider logs.

`PacketTunnelProviderError.savedProtocolConfigurationIsInvalid` is a different stage: the provider has started but cannot recover its configuration. Inspect the associated Keychain status, rather than regenerating the peer or changing routing.

The App Store/TestFlight build contains an `.appex`. The Developer ID DMG contains a `.systemextension`. Only the latter uses System Keychain storage through its authenticated XPC service. Do not send an App Store user to approve a nonexistent system extension.

Apple's reference: [Network Extension Provider Packaging](https://developer.apple.com/forums/thread/800887).

## Automated coverage

Run `bash Scripts/test-macos-keychain.sh` on macOS. It compiles the production `Keychain.swift` and its dependencies under Swift 6. Its checks cover:

- Explicit generic-password class and exact persistent reference in lookup/delete queries.
- Separate login and data-protection lookup for tunnel, profile-recovery, and RouterOS credential-recovery services.
- Unknown references fail local classification without being directly dereferenced.
- Read flags do not leak into subsequent verification/deletion queries.

The runner does not read or change installed profiles or live Keychain items. These are policy/query regression tests, **not** proof of Keychain authorization, ACL behavior, extension startup, or an installed VPN handshake.

Also run `swift test` and compile macOS and iOS app/extension targets. Keep unsigned compilation results distinct from signed installation tests.

## Signed installation gate

Do not publish solely because the checks above pass. Validate the actual TestFlight/App Store build, and independently the DMG build, with user approval before changing a live VPN connection:

1. Record the app and bundled extension version/build, signature validity, packaging, and registered installed paths. Identify duplicate app copies and old system extensions without removing them automatically.
2. Open the app repeatedly; there must be no unexpected administrator or Keychain prompts. Existing profiles and private keys must be preserved.
3. Edit/save an existing profile unchanged, reopen it, manually connect, and confirm a real handshake plus increasing traffic counters. Compare saved profile binding and registration before/after saving if macOS reports error 14.
4. Test single-profile On-Demand and Automatic Profiles separately, including app-closed activation, network changes, manual pause/resume, and controller restart. Confirm the controller can read every referenced profile.
5. Test a fresh import and existing-profile migration separately. Verify RouterOS credential-recovery resume/completion and profile recovery, including denied/unavailable Keychain access and retry.
6. A migration save, readback, or provider failure must preserve the existing profile and usable credential. Do not delete peers, reset Keychains, unregister extensions, or rotate private keys as diagnostic steps.

## Build 18 validation status

The source changes correct reference query construction and align the embedded extension's lookup with its containing app, including recovery records. They do not silently reinstall or enable the installed VPN provider.

The installed build-17 app connected after the user disabled the old DMG system extension and reinstalled TestFlight. The replacement OS VPN registration retained the same WireGuard public key. Because both installation state and registration changed, this does **not** prove the old system extension alone caused the failure, nor validate build 18.

### Explicit registration repair

For an installed embedded `.appex` build, a manual activation failure with exactly `NEVPNConnectionError.pluginDisabled` (domain `NEVPNConnectionErrorDomain`, code 14) now offers **Repair VPN Setup**. Other errors keep their existing handling. DMG system-extension activation, iOS storage, WireGuard transport, and RouterOS provisioning are not replaced by this path.

- **Not Now** makes no preference changes. Repair requires confirmation and can ask macOS for VPN-configuration approval. Existing On-Demand rules can resume after repair.
- Repair targets the failed session's manager: the selected profile for direct activation, or the shared controller for Automatic Profiles. It never rotates keys, edits peers, or deletes Keychain references.
- A fresh public protocol and disabled OS registration preserve the opaque key reference, activity identity, all provider metadata (including routing and DNS), native network policy, and exact On-Demand rules. Save/readback must match before the old registration is removed.
- Pre-commit failures preserve the original and attempt to discard only the staged registration. A failed discard leaves it disabled and hidden behind the original; the next explicit repair reuses it. After the original was removed, a failed final save retains the verified replacement. Reopening exposes that replacement, so activation or another explicit repair can resume it.
- Startup only reconciles visibility; it never automatically retries registration repair. Concurrent UI settings changes and app-initiated activation are blocked during the transaction. Ambiguous ownership, per-app VPNs, and active managers are refused.
- Deleting a profile also retires any leftover staged registration before the existing profile-deletion workflow removes its credentials, preventing resurrection after an interrupted repair.

`swift test --filter MacOSVPNRegistrationRepairTests` exercises the production transaction using an in-memory preferences store. It covers direct and controller repair, key/rule/policy preservation, denied saves, readback mismatch, active/changed/foreign registrations, rollback, uncertain removal, interrupted completion, reopen, and explicit retry. It does **not** validate actual macOS authorization or provider startup. The test store never calls live preferences APIs.

### Required TestFlight checks before release

1. On a disposable test profile with the reproduced stale registration, verify **Not Now** is inert; **Repair VPN Setup** shows a working native sheet; denying macOS approval preserves the original; explicit retry works without launch-time prompts.
2. Confirm the public key, profile name, routes, DNS, and saved automatic rules are unchanged. Edit/save, reopen, activate, and verify a real WireGuard handshake and traffic counters.
3. Repeat for the Automatic Profiles controller and then single-profile On-Demand, including app-closed network transitions. Merely seeing the profile marked Active is insufficient.
4. Interrupt repair before and after old-registration removal using a development harness, reopen, retry, and delete the disposable profile. Verify there is no visible duplicate, stale resurrection, lost credential, or repeated authorization loop.
5. Re-test normal DMG and iOS paths independently. Do not infer installed behavior from unsigned compilation or replace the user's working installed copy to run these checks.
