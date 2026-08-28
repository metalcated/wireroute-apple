// SPDX-License-Identifier: MIT

import Foundation
import Security

struct RouterOSStoredConnection: Codable, Sendable {
    let url: String
    let username: String
    let password: String
}

enum RouterOSCredentialStoreError: Error, LocalizedError {
    case missingBundleIdentifier
    case encodingFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return tr("macRouterOSCredentialStoreUnavailable")
        case .encodingFailed:
            return tr("macRouterOSCredentialStoreUnavailable")
        case .keychain:
            return tr("macRouterOSCredentialStoreUnavailable")
        }
    }
}

enum RouterOSCredentialStore {
    private static let account = "default-router"

    static func load() throws -> RouterOSStoredConnection? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: try service(),
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RouterOSCredentialStoreError.keychain(status)
        }
        do {
            return try JSONDecoder().decode(RouterOSStoredConnection.self, from: data)
        } catch {
            throw RouterOSCredentialStoreError.encodingFailed
        }
    }

    static func save(_ connection: RouterOSStoredConnection) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(connection)
        } catch {
            throw RouterOSCredentialStoreError.encodingFailed
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: try service(),
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw RouterOSCredentialStoreError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable] = false
        item[kSecAttrLabel] = "WireRoute RouterOS Credentials"
        item[kSecAttrDescription] = "RouterOS REST connection"

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RouterOSCredentialStoreError.keychain(addStatus)
        }
    }

    private static func service() throws -> String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw RouterOSCredentialStoreError.missingBundleIdentifier
        }
        return "\(bundleIdentifier).routeros.credentials"
    }
}
