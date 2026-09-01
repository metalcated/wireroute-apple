// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Security

struct KeychainRecoveryConfiguration {
    let reference: Data
    let name: String
    let configuration: String
}

struct KeychainTunnelConfiguration {
    let reference: Data
    let name: String
    let configuration: String
    let modificationDate: Date
}

struct KeychainProfileRecoveryConfiguration {
    let reference: Data
    let profileID: String
    let name: String
    let payload: String
}

class Keychain {
    static func openReference(called ref: Data) -> String? {
        let (ret, result) = copyMatching([
            kSecValuePersistentRef: ref,
            kSecReturnData: true
        ])
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
        let (ret, result) = copyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: peerID,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecReturnPersistentRef: true
        ])
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

    static func tunnelConfigurations() -> [KeychainTunnelConfiguration] {
        guard let service = serviceIdentifier(suffix: nil) else { return [] }
        return genericPasswordItems(service: service).compactMap { item in
            guard let reference = item[kSecValuePersistentRef] as? Data,
                  let label = item[kSecAttrLabel] as? String,
                  label.hasPrefix("WireGuard Tunnel: "),
                  let data = item[kSecValueData] as? Data,
                  let configuration = String(data: data, encoding: .utf8) else {
                return nil
            }
            return KeychainTunnelConfiguration(
                reference: reference,
                name: String(label.dropFirst("WireGuard Tunnel: ".count)),
                configuration: configuration,
                modificationDate: item[kSecAttrModificationDate] as? Date ?? .distantPast
            )
        }
        .sorted { $0.modificationDate > $1.modificationDate }
    }

    @discardableResult
    static func saveProfileRecoveryConfiguration(
        payload: String,
        profileID: String,
        name: String
    ) -> Bool {
        guard let service = serviceIdentifier(suffix: ".profile-recovery") else { return false }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID
        ]
        let attributes: [CFString: Any] = [
            kSecAttrLabel: name,
            kSecAttrDescription: "WireRoute profile recovery configuration",
            kSecValueData: payload.data(using: .utf8) as Any
        ]

        var modernQuery = baseQuery
        modernQuery[kSecUseDataProtectionKeychain] = true
        var status = SecItemUpdate(modernQuery as CFDictionary, attributes as CFDictionary)
        #if os(macOS)
        if status == errSecItemNotFound {
            status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        }
        #endif
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else {
            wg_log(.error, message: "Unable to update profile recovery configuration in keychain: \(status)")
            return false
        }

        return makeReference(
            containing: payload,
            label: name,
            account: profileID,
            serviceSuffix: ".profile-recovery",
            description: "WireRoute profile recovery configuration"
        ) != nil
    }

    static func profileRecoveryConfigurations() -> [KeychainProfileRecoveryConfiguration] {
        guard let service = serviceIdentifier(suffix: ".profile-recovery") else { return [] }
        return genericPasswordItems(service: service).compactMap { item in
            guard let reference = item[kSecValuePersistentRef] as? Data,
                  let profileID = item[kSecAttrAccount] as? String,
                  let name = item[kSecAttrLabel] as? String,
                  let data = item[kSecValueData] as? Data,
                  let payload = String(data: data, encoding: .utf8) else {
                return nil
            }
            return KeychainProfileRecoveryConfiguration(
                reference: reference,
                profileID: profileID,
                name: name,
                payload: payload
            )
        }
    }

    static func deleteProfileRecoveryConfiguration(profileID: String) {
        guard let service = serviceIdentifier(suffix: ".profile-recovery") else { return }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID,
            kSecUseDataProtectionKeychain: true
        ]
        var status = SecItemDelete(query as CFDictionary)
        #if os(macOS)
        if shouldTryLegacyKeychain(after: status) {
            query.removeValue(forKey: kSecUseDataProtectionKeychain)
            status = SecItemDelete(query as CFDictionary)
        }
        #endif
        if status != errSecSuccess && status != errSecItemNotFound {
            wg_log(.error, message: "Unable to delete profile recovery configuration from keychain: \(status)")
        }
    }

    static func deleteProfileRecoveryConfigurations(named name: String) {
        for configuration in profileRecoveryConfigurations() where configuration.name == name {
            deleteReference(called: configuration.reference)
        }
    }

    private static func makeReference(
        containing value: String,
        label: String,
        account: String,
        serviceSuffix: String?,
        description: String
    ) -> Data? {
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

        guard let accessGroup = FileManager.appGroupId else {
            wg_log(.error, staticMessage: "Unable to determine app group identifier")
            return nil
        }
        items[kSecAttrAccessGroup] = accessGroup
        items[kSecUseDataProtectionKeychain] = true
        #if os(iOS)
        items[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        #elseif os(macOS)
        items[kSecAttrSynchronizable] = false
        items[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        #error("Unimplemented")
        #endif

        var ref: CFTypeRef?
        let ret = SecItemAdd(items as CFDictionary, &ref)
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
        var query: [CFString: Any] = [
            kSecValuePersistentRef: ref,
            kSecUseDataProtectionKeychain: true
        ]
        var ret = SecItemDelete(query as CFDictionary)
        #if os(macOS)
        if shouldTryLegacyKeychain(after: ret) {
            query.removeValue(forKey: kSecUseDataProtectionKeychain)
            ret = SecItemDelete(query as CFDictionary)
        }
        #endif
        if ret != errSecSuccess {
            wg_log(.error, message: "Unable to delete config from keychain: \(ret)")
        }
    }

    static func deleteReferences(except whitelist: Set<Data>) {
        guard let service = serviceIdentifier(suffix: nil) else { return }
        var items = persistentReferences(service: service, useDataProtectionKeychain: true)
        #if os(macOS)
        items.append(contentsOf: persistentReferences(service: service, useDataProtectionKeychain: false))
        #endif
        for item in items {
            if !whitelist.contains(item) {
                deleteReference(called: item)
            }
        }
    }

    static func verifyReference(called ref: Data) -> Bool {
        let (ret, _) = copyMatching([kSecValuePersistentRef: ref])
        return ret != errSecItemNotFound
    }

    private static func copyMatching(
        _ attributes: [CFString: Any]
    ) -> (OSStatus, CFTypeRef?) {
        var modernAttributes = attributes
        modernAttributes[kSecUseDataProtectionKeychain] = true
        var result: CFTypeRef?
        var ret = SecItemCopyMatching(modernAttributes as CFDictionary, &result)
        #if os(macOS)
        if shouldTryLegacyKeychain(after: ret) {
            result = nil
            ret = SecItemCopyMatching(attributes as CFDictionary, &result)
        }
        #endif
        return (ret, result)
    }

    private static func shouldTryLegacyKeychain(after status: OSStatus) -> Bool {
        status == errSecItemNotFound || status == errSecParam
    }

    private static func persistentReferences(
        service: String,
        useDataProtectionKeychain: Bool
    ) -> [Data] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnPersistentRef: true
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        var result: CFTypeRef?
        let ret = SecItemCopyMatching(query as CFDictionary, &result)
        guard ret == errSecSuccess else { return [] }
        if let references = result as? [Data] {
            return references
        }
        if let reference = result as? Data {
            return [reference]
        }
        return []
    }

    private static func genericPasswordItems(service: String) -> [[CFString: Any]] {
        var items = genericPasswordItems(service: service, useDataProtectionKeychain: true)
        #if os(macOS)
        items.append(contentsOf: genericPasswordItems(service: service, useDataProtectionKeychain: false))
        #endif

        var references = Set<Data>()
        return items.filter { item in
            guard let reference = item[kSecValuePersistentRef] as? Data else { return false }
            return references.insert(reference).inserted
        }
    }

    private static func genericPasswordItems(
        service: String,
        useDataProtectionKeychain: Bool
    ) -> [[CFString: Any]] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecReturnPersistentRef: true
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        if let dictionaries = result as? [[CFString: Any]] {
            return dictionaries
        }
        if let dictionary = result as? [CFString: Any] {
            return [dictionary]
        }
        if let dictionaries = result as? [NSDictionary] {
            return dictionaries.compactMap { $0 as? [CFString: Any] }
        }
        if let dictionary = result as? NSDictionary,
           let typedDictionary = dictionary as? [CFString: Any] {
            return [typedDictionary]
        }
        return []
    }
}
