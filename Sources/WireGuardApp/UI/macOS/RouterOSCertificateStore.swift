// SPDX-License-Identifier: MIT

import Foundation
import Security

enum RouterOSCertificateStoreError: Error, LocalizedError {
    case missingBundleIdentifier
    case invalidRouterURL
    case certificateEndpointMismatch
    case keychain(OSStatus)

    var errorDescription: String? {
        tr("macRouterOSCertificateStoreUnavailable")
    }
}

enum RouterOSCertificateStore {
    private struct Endpoint {
        let host: String
        let port: Int

        var account: String {
            "\(host.utf8.count):\(host):\(port)"
        }
    }

    static func load(for routerURL: URL) throws -> RouterOSServerCertificate? {
        let endpoint = try endpoint(for: routerURL)
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: try service(),
            kSecAttrAccount: endpoint.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RouterOSCertificateStoreError.keychain(status)
        }
        return RouterOSServerCertificate(
            host: endpoint.host,
            port: endpoint.port,
            derEncodedCertificate: data
        )
    }

    static func save(_ certificate: RouterOSServerCertificate, for routerURL: URL) throws {
        let endpoint = try endpoint(for: routerURL)
        guard certificate.host == endpoint.host, certificate.port == endpoint.port else {
            throw RouterOSCertificateStoreError.certificateEndpointMismatch
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: try service(),
            kSecAttrAccount: endpoint.account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: certificate.derEncodedCertificate
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw RouterOSCertificateStoreError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData] = certificate.derEncodedCertificate
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable] = false
        item[kSecAttrLabel] = "WireRoute RouterOS Certificate"
        item[kSecAttrDescription] = "Trusted RouterOS HTTPS certificate for \(endpoint.host):\(endpoint.port)"

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RouterOSCertificateStoreError.keychain(addStatus)
        }
    }

    private static func endpoint(for routerURL: URL) throws -> Endpoint {
        guard let components = URLComponents(url: routerURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw RouterOSCertificateStoreError.invalidRouterURL
        }
        return Endpoint(host: host, port: components.port ?? 443)
    }

    private static func service() throws -> String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw RouterOSCertificateStoreError.missingBundleIdentifier
        }
        return "\(bundleIdentifier).routeros.certificates"
    }
}
