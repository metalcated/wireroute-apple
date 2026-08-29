// SPDX-License-Identifier: MIT

import Foundation
import Security

struct RouterOSStoredConnection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var url: String
    var username: String
    var password: String
}

private struct LegacyRouterOSStoredConnection: Codable {
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
        case .missingBundleIdentifier, .encodingFailed, .keychain:
            return tr("macRouterOSCredentialStoreUnavailable")
        }
    }
}

enum RouterOSCredentialStore {
    static let connectionsDidChange = Notification.Name("WireRouteRouterOSConnectionsDidChange")

    private static let connectionsAccount = "saved-connections-v2"
    private static let legacyAccount = "default-router"
    private static let migrationCompletedKey = "WireRoute.RouterOSConnectionsMigrationCompleted"

    static func loadAll(defaults: UserDefaults = .standard) throws -> [RouterOSStoredConnection] {
        if let data = try loadData(account: connectionsAccount) {
            do {
                let connections = try JSONDecoder().decode([RouterOSStoredConnection].self, from: data)
                finishLegacyMigrationIfNeeded(defaults: defaults)
                return connections
            } catch {
                throw RouterOSCredentialStoreError.encodingFailed
            }
        }

        guard !defaults.bool(forKey: migrationCompletedKey) else { return [] }
        let migratedConnections: [RouterOSStoredConnection]
        if let legacyData = try loadData(account: legacyAccount) {
            do {
                let legacy = try JSONDecoder().decode(LegacyRouterOSStoredConnection.self, from: legacyData)
                migratedConnections = [RouterOSStoredConnection(
                    id: UUID(),
                    name: suggestedName(for: legacy.url),
                    url: legacy.url,
                    username: legacy.username,
                    password: legacy.password
                )]
            } catch {
                throw RouterOSCredentialStoreError.encodingFailed
            }
        } else {
            migratedConnections = []
        }

        if !migratedConnections.isEmpty {
            try saveAll(migratedConnections)
        }
        finishLegacyMigrationIfNeeded(defaults: defaults)
        return migratedConnections
    }

    static func save(_ connection: RouterOSStoredConnection) throws {
        var connections = try loadAll()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        try saveAll(connections)
        NotificationCenter.default.post(name: connectionsDidChange, object: connection.id)
    }

    static func delete(id: UUID) throws {
        var connections = try loadAll()
        connections.removeAll { $0.id == id }
        try saveAll(connections)
        NotificationCenter.default.post(name: connectionsDidChange, object: id)
    }

    private static func suggestedName(for urlString: String) -> String {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else {
            return "RouterOS"
        }
        return host
    }

    private static func loadData(account: String) throws -> Data? {
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
        return data
    }

    private static func finishLegacyMigrationIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationCompletedKey) else { return }
        guard let legacyQuery = try? query(account: legacyAccount) else { return }
        let status = SecItemDelete(legacyQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return }
        defaults.set(true, forKey: migrationCompletedKey)
    }

    private static func saveAll(_ connections: [RouterOSStoredConnection]) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(connections)
        } catch {
            throw RouterOSCredentialStoreError.encodingFailed
        }

        let query = try query(account: connectionsAccount)
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
        item[kSecAttrLabel] = "WireRoute RouterOS Connections"
        item[kSecAttrDescription] = "Saved RouterOS REST connections"

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

    private static func query(account: String) throws -> [CFString: Any] {
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: try service(),
            kSecAttrAccount: account
        ]
    }
}
