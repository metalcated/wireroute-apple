// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Security

struct KeychainRecoveryConfiguration {
    let reference: Data
    let name: String
    let configuration: String
}

class Keychain {
    static func openReference(called ref: Data) -> String? {
        var result: CFTypeRef?
        let ret = SecItemCopyMatching([kSecValuePersistentRef: ref,
                                        kSecReturnData: true] as CFDictionary,
                                       &result)
        if ret != errSecSuccess || result == nil {
            wg_log(.error, message: "Unable to open config from keychain: \(ret)")
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: String.Encoding.utf8)
    }

    static func makeReference(containing value: String, called name: String) -> Data? {
        makeReference(
            containing: value,
            label: "WireGuard Tunnel: \(name)",
            account: name + ": " + UUID().uuidString,
            serviceSuffix: nil,
            description: "wg-quick(8) config"
        )
    }

    static func makeRecoveryReference(
        containing value: String,
        called name: String,
        peerID: String
    ) -> Data? {
        guard recoveryConfiguration(for: peerID) == nil else { return nil }
        return makeReference(
            containing: value,
            label: name,
            account: peerID,
            serviceSuffix: ".credential-recovery",
            description: "WireRoute pending RouterOS credential replacement"
        )
    }

    static func recoveryConfiguration(for peerID: String) -> KeychainRecoveryConfiguration? {
        guard let service = serviceIdentifier(suffix: ".credential-recovery") else { return nil }
        var result: CFTypeRef?
        let ret = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: peerID,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecReturnPersistentRef: true
        ] as CFDictionary, &result)
        guard ret == errSecSuccess,
              let item = result as? NSDictionary,
              let reference = item[kSecValuePersistentRef] as? Data,
              let name = item[kSecAttrLabel] as? String,
              let data = item[kSecValueData] as? Data,
              let configuration = String(data: data, encoding: .utf8) else {
            return nil
        }
        return KeychainRecoveryConfiguration(
            reference: reference,
            name: name,
            configuration: configuration
        )
    }

    private static func makeReference(
        containing value: String,
        label: String,
        account: String,
        serviceSuffix: String?,
        description: String
    ) -> Data? {
        var ret: OSStatus
        guard let service = serviceIdentifier(suffix: serviceSuffix) else {
            wg_log(.error, staticMessage: "Unable to determine bundle identifier")
            return nil
        }
        var items: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                    kSecAttrLabel: label,
                                    kSecAttrAccount: account,
                                    kSecAttrDescription: description,
                                    kSecAttrService: service,
                                    kSecValueData: value.data(using: .utf8) as Any,
                                    kSecReturnPersistentRef: true]

        #if os(iOS)
        items[kSecAttrAccessGroup] = FileManager.appGroupId
        items[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        #elseif os(macOS)
        items[kSecAttrSynchronizable] = false
        items[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        guard let extensionPath = Bundle.main.builtInPlugInsURL?.appendingPathComponent("WireRouteNetworkExtension.appex", isDirectory: true).path else {
            wg_log(.error, staticMessage: "Unable to determine app extension path")
            return nil
        }
        var extensionApp: SecTrustedApplication?
        var mainApp: SecTrustedApplication?
        ret = SecTrustedApplicationCreateFromPath(extensionPath, &extensionApp)
        if ret != kOSReturnSuccess || extensionApp == nil {
            wg_log(.error, message: "Unable to create keychain extension trusted application object: \(ret)")
            return nil
        }
        ret = SecTrustedApplicationCreateFromPath(nil, &mainApp)
        if ret != errSecSuccess || mainApp == nil {
            wg_log(.error, message: "Unable to create keychain local trusted application object: \(ret)")
            return nil
        }
        var access: SecAccess?
        ret = SecAccessCreate(label as CFString, [extensionApp!, mainApp!] as CFArray, &access)
        if ret != errSecSuccess || access == nil {
            wg_log(.error, message: "Unable to create keychain ACL object: \(ret)")
            return nil
        }
        items[kSecAttrAccess] = access!
        #else
        #error("Unimplemented")
        #endif

        var ref: CFTypeRef?
        ret = SecItemAdd(items as CFDictionary, &ref)
        if ret != errSecSuccess || ref == nil {
            wg_log(.error, message: "Unable to add config to keychain: \(ret)")
            return nil
        }
        return ref as? Data
    }

    private static func serviceIdentifier(suffix: String?) -> String? {
        guard var bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        if bundleIdentifier.hasSuffix(".network-extension") {
            bundleIdentifier.removeLast(".network-extension".count)
        }
        return bundleIdentifier + (suffix ?? "")
    }

    static func deleteReference(called ref: Data) {
        let ret = SecItemDelete([kSecValuePersistentRef: ref] as CFDictionary)
        if ret != errSecSuccess {
            wg_log(.error, message: "Unable to delete config from keychain: \(ret)")
        }
    }

    static func deleteReferences(except whitelist: Set<Data>) {
        var result: CFTypeRef?
        let ret = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
                                       kSecAttrService: Bundle.main.bundleIdentifier as Any,
                                       kSecMatchLimit: kSecMatchLimitAll,
                                       kSecReturnPersistentRef: true] as CFDictionary,
                                      &result)
        if ret != errSecSuccess || result == nil {
            return
        }
        guard let items = result as? [Data] else { return }
        for item in items {
            if !whitelist.contains(item) {
                deleteReference(called: item)
            }
        }
    }

    static func verifyReference(called ref: Data) -> Bool {
        return SecItemCopyMatching([kSecValuePersistentRef: ref] as CFDictionary,
                                   nil) != errSecItemNotFound
    }
}
