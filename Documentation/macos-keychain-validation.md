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

The source changes correct reference query construction and align the embedded extension's lookup with its containing app, including recovery records. They do not silently reinstall, unregister, or rewrite the installed VPN provider. The installed build-17 error-14 failure still requires the signed installation gate above; it is not demonstrated fixed by these source tests.
