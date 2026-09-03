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

#if os(macOS)
@objc(WireRouteSystemKeychainXPCProtocol)
protocol WireRouteSystemKeychainXPCProtocol: NSObjectProtocol {
    func storeTunnelConfiguration(
        _ configuration: String,
        name: String,
        withReply reply: @escaping (Data?, NSNumber) -> Void
    )

    func loadTunnelConfiguration(
        reference: Data,
        withReply reply: @escaping (String?, NSNumber) -> Void
    )

    func verifyTunnelConfiguration(
        reference: Data,
        withReply reply: @escaping (Bool, NSNumber) -> Void
    )

    func deleteTunnelConfiguration(
        reference: Data,
        withReply reply: @escaping (NSNumber) -> Void
    )

    func performActivityRequest(
        _ request: Data,
        withReply reply: @escaping (Data?) -> Void
    )
}

private enum WireRouteSystemKeychainIdentity {
    private static let networkExtensionSuffix = ".network-extension"

    static var isSystemExtensionProcess: Bool {
        Bundle.main.bundleURL.pathExtension == "systemextension"
            || Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "SYSX"
    }

    static var baseAppIdentifier: String? {
        guard var identifier = Bundle.main.bundleIdentifier else { return nil }
        if identifier.hasSuffix(networkExtensionSuffix) {
            identifier.removeLast(networkExtensionSuffix.count)
        }
        return identifier
    }

    static var embeddedSystemExtensionBundle: Bundle? {
        guard !isSystemExtensionProcess,
              let baseAppIdentifier else {
            return nil
        }
        let expectedIdentifier = baseAppIdentifier + networkExtensionSuffix
        let systemExtensionsURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: systemExtensionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls.lazy
            .filter { $0.pathExtension == "systemextension" }
            .compactMap(Bundle.init(url:))
            .first { $0.bundleIdentifier == expectedIdentifier }
    }

    static var machServiceName: String? {
        let bundle = isSystemExtensionProcess ? Bundle.main : embeddedSystemExtensionBundle
        guard let networkExtension = bundle?.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let name = networkExtension["NEMachServiceName"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }

    static var teamIdentifier: String? {
        guard let appGroupIdentifier = FileManager.appGroupId,
              let separatorRange = appGroupIdentifier.range(of: ".group.") else {
            return nil
        }
        let teamIdentifier = String(appGroupIdentifier[..<separatorRange.lowerBound])
        guard !teamIdentifier.isEmpty,
              teamIdentifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
              }) else {
            return nil
        }
        return teamIdentifier
    }

    static func codeSigningRequirement(identifier: String) -> String? {
        guard let teamIdentifier,
              identifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
              }) else {
            return nil
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

private final class WireRouteXPCResponse<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var completed = false

    func resolve(_ value: Value) -> Bool {
        lock.withLock {
            guard !completed else { return false }
            self.value = value
            completed = true
            return true
        }
    }

    var resolvedValue: Value? {
        lock.withLock { value }
    }
}

private final class WireRouteSystemKeychainXPCClient {
    private let machServiceName: String
    private let serverRequirement: String

    init?() {
        guard let machServiceName = WireRouteSystemKeychainIdentity.machServiceName,
              let baseAppIdentifier = WireRouteSystemKeychainIdentity.baseAppIdentifier,
              let serverRequirement = WireRouteSystemKeychainIdentity.codeSigningRequirement(
                  identifier: baseAppIdentifier + ".network-extension"
              ) else {
            return nil
        }
        self.machServiceName = machServiceName
        self.serverRequirement = serverRequirement
    }

    func store(configuration: String, name: String) -> (OSStatus, Data?) {
        perform(failure: (errSecNotAvailable, nil)) { proxy, complete in
            proxy.storeTunnelConfiguration(configuration, name: name) { reference, status in
                complete((status.int32Value, reference))
            }
        }
    }

    func load(reference: Data) -> (OSStatus, String?) {
        perform(failure: (errSecNotAvailable, nil)) { proxy, complete in
            proxy.loadTunnelConfiguration(reference: reference) { configuration, status in
                complete((status.int32Value, configuration))
            }
        }
    }

    func verify(reference: Data) -> OSStatus {
        let (status, isValid): (OSStatus, Bool) = perform(
            failure: (errSecNotAvailable, false)
        ) { proxy, complete in
            proxy.verifyTunnelConfiguration(reference: reference) { isValid, status in
                complete((status.int32Value, isValid))
            }
        }
        return status == errSecSuccess && isValid ? errSecSuccess : status
    }

    func delete(reference: Data) -> OSStatus {
        perform(failure: errSecNotAvailable) { proxy, complete in
            proxy.deleteTunnelConfiguration(reference: reference) { status in
                complete(status.int32Value)
            }
        }
    }

    func performActivityRequest(_ request: Data) -> Data? {
        let (response, succeeded): (Data?, Bool) = perform(
            failure: (nil, false)
        ) { proxy, complete in
            proxy.performActivityRequest(request) { response in
                complete((response, true))
            }
        }
        return succeeded ? response : nil
    }

    private func perform<Value: Sendable>(
        failure: Value,
        _ operation: (
            WireRouteSystemKeychainXPCProtocol,
            @escaping @Sendable (Value) -> Void
        ) -> Void
    ) -> Value {
        let connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: [.privileged]
        )
        connection.remoteObjectInterface = NSXPCInterface(with: WireRouteSystemKeychainXPCProtocol.self)
        connection.setCodeSigningRequirement(serverRequirement)

        let response = WireRouteXPCResponse<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        let complete: @Sendable (Value) -> Void = { value in
            if response.resolve(value) {
                semaphore.signal()
            }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            wg_log(.error, message: "System extension keychain XPC request failed: \(error.localizedDescription)")
            complete(failure)
        }
        connection.activate()

        guard let service = proxy as? WireRouteSystemKeychainXPCProtocol else {
            connection.invalidate()
            return failure
        }
        operation(service, complete)

        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            wg_log(.error, staticMessage: "System extension keychain XPC request timed out")
            _ = response.resolve(failure)
        }
        connection.invalidate()
        return response.resolvedValue ?? failure
    }
}

private final class WireRouteSystemKeychainXPCService: NSObject, WireRouteSystemKeychainXPCProtocol {
    private let ownerUID: uid_t

    init(ownerUID: uid_t) {
        self.ownerUID = ownerUID
    }

    func storeTunnelConfiguration(
        _ configuration: String,
        name: String,
        withReply reply: @escaping (Data?, NSNumber) -> Void
    ) {
        let (status, reference) = Keychain.addSystemTunnelReference(
            containing: configuration,
            called: name,
            ownerUID: ownerUID
        )
        reply(reference, NSNumber(value: status))
    }

    func loadTunnelConfiguration(
        reference: Data,
        withReply reply: @escaping (String?, NSNumber) -> Void
    ) {
        let (status, configuration) = Keychain.openSystemTunnelReference(
            called: reference,
            ownerUID: ownerUID
        )
        reply(configuration, NSNumber(value: status))
    }

    func verifyTunnelConfiguration(
        reference: Data,
        withReply reply: @escaping (Bool, NSNumber) -> Void
    ) {
        let status = Keychain.verifySystemTunnelReference(called: reference, ownerUID: ownerUID)
        reply(status == errSecSuccess, NSNumber(value: status))
    }

    func deleteTunnelConfiguration(
        reference: Data,
        withReply reply: @escaping (NSNumber) -> Void
    ) {
        let status = Keychain.deleteSystemTunnelReference(called: reference, ownerUID: ownerUID)
        reply(NSNumber(value: status))
    }

    func performActivityRequest(
        _ requestData: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let response: WireRouteActivityIPCResponse
        do {
            let request = try JSONDecoder().decode(WireRouteActivityIPCRequest.self, from: requestData)
            let store = try WireRouteActivityStore(
                databaseURL: FileManager.activityDatabaseURL(ownerUID: ownerUID)
            )
            let snapshot: WireRouteActivitySnapshot?
            switch request.operation {
            case .snapshot:
                guard let profileIdentifier = request.profileIdentifier,
                      let since = request.since else {
                    throw WireRouteActivityBridgeError.invalidRequest
                }
                snapshot = try store.snapshot(
                    profileIdentifier: profileIdentifier,
                    since: since,
                    pointLimit: min(max(request.pointLimit ?? 720, 1), 5_000),
                    sessionLimit: min(max(request.sessionLimit ?? 24, 1), 500)
                )
            case .clearCompleted:
                guard let profileIdentifier = request.profileIdentifier else {
                    throw WireRouteActivityBridgeError.invalidRequest
                }
                try store.clearCompletedHistory(profileIdentifier: profileIdentifier)
                snapshot = nil
            case .clearAll:
                guard let profileIdentifier = request.profileIdentifier else {
                    throw WireRouteActivityBridgeError.invalidRequest
                }
                try store.clearAllHistory(profileIdentifier: profileIdentifier)
                snapshot = nil
            case .purge:
                guard let before = request.before else {
                    throw WireRouteActivityBridgeError.invalidRequest
                }
                try store.purge(before: before)
                snapshot = nil
            case .setRetention:
                guard let rawRetention = request.retentionDays,
                      let retention = WireRouteActivityRetention(rawValue: rawRetention) else {
                    throw WireRouteActivityBridgeError.invalidRequest
                }
                WireRouteActivityPreference.saveRetention(retention, ownerUID: ownerUID)
                snapshot = nil
            }
            response = WireRouteActivityIPCResponse(snapshot: snapshot, errorDescription: nil)
        } catch {
            response = WireRouteActivityIPCResponse(
                snapshot: nil,
                errorDescription: error.localizedDescription
            )
        }
        reply(try? JSONEncoder().encode(response))
    }
}

private final class WireRouteSystemKeychainXPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener

    init?(machServiceName: String) {
        guard let baseAppIdentifier = WireRouteSystemKeychainIdentity.baseAppIdentifier,
              let clientRequirement = WireRouteSystemKeychainIdentity.codeSigningRequirement(
                  identifier: baseAppIdentifier
              ) else {
            return nil
        }
        listener = NSXPCListener(machServiceName: machServiceName)
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(clientRequirement)
    }

    func start() {
        listener.activate()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: WireRouteSystemKeychainXPCProtocol.self)
        newConnection.exportedObject = WireRouteSystemKeychainXPCService(
            ownerUID: newConnection.effectiveUserIdentifier
        )
        newConnection.activate()
        return true
    }
}

enum WireRouteActivityBridgeError: Error, LocalizedError, Sendable {
    case unavailable
    case invalidRequest
    case remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "WireRoute's system extension activity service is unavailable."
        case .invalidRequest:
            return "WireRoute received an invalid activity history request."
        case .remoteFailure(let message):
            return message
        }
    }
}

enum WireRouteSystemActivityBridge {
    static var isAvailable: Bool {
        WireRouteSystemKeychainXPCClient() != nil
    }

    static func snapshot(
        profileIdentifier: UUID,
        since: Date,
        pointLimit: Int = 720,
        sessionLimit: Int = 24
    ) async throws -> WireRouteActivitySnapshot {
        let response = try await perform(
            WireRouteActivityIPCRequest(
                operation: .snapshot,
                profileIdentifier: profileIdentifier,
                since: since,
                pointLimit: pointLimit,
                sessionLimit: sessionLimit,
                before: nil,
                retentionDays: nil
            )
        )
        guard let snapshot = response.snapshot else {
            throw WireRouteActivityBridgeError.invalidRequest
        }
        return snapshot
    }

    static func clearCompleted(profileIdentifier: UUID) async throws {
        _ = try await perform(
            WireRouteActivityIPCRequest(
                operation: .clearCompleted,
                profileIdentifier: profileIdentifier,
                since: nil,
                pointLimit: nil,
                sessionLimit: nil,
                before: nil,
                retentionDays: nil
            )
        )
    }

    static func clearAll(profileIdentifier: UUID) async throws {
        _ = try await perform(
            WireRouteActivityIPCRequest(
                operation: .clearAll,
                profileIdentifier: profileIdentifier,
                since: nil,
                pointLimit: nil,
                sessionLimit: nil,
                before: nil,
                retentionDays: nil
            )
        )
    }

    static func purge(before: Date) async throws {
        _ = try await perform(
            WireRouteActivityIPCRequest(
                operation: .purge,
                profileIdentifier: nil,
                since: nil,
                pointLimit: nil,
                sessionLimit: nil,
                before: before,
                retentionDays: nil
            )
        )
    }

    static func setRetention(_ retention: WireRouteActivityRetention) async throws {
        _ = try await perform(
            WireRouteActivityIPCRequest(
                operation: .setRetention,
                profileIdentifier: nil,
                since: nil,
                pointLimit: nil,
                sessionLimit: nil,
                before: nil,
                retentionDays: retention.rawValue
            )
        )
    }

    private static func perform(
        _ request: WireRouteActivityIPCRequest
    ) async throws -> WireRouteActivityIPCResponse {
        let requestData = try JSONEncoder().encode(request)
        let responseData = await Task.detached(priority: .utility) {
            WireRouteSystemKeychainXPCClient()?.performActivityRequest(requestData)
        }.value
        guard let responseData else {
            throw WireRouteActivityBridgeError.unavailable
        }
        let response = try JSONDecoder().decode(WireRouteActivityIPCResponse.self, from: responseData)
        if let errorDescription = response.errorDescription {
            throw WireRouteActivityBridgeError.remoteFailure(errorDescription)
        }
        return response
    }
}
#endif

class Keychain {
    #if os(macOS)
    private static let systemKeychainXPCServer: WireRouteSystemKeychainXPCServer? = {
        guard WireRouteSystemKeychainIdentity.isSystemExtensionProcess,
              let machServiceName = WireRouteSystemKeychainIdentity.machServiceName else {
            return nil
        }
        return WireRouteSystemKeychainXPCServer(machServiceName: machServiceName)
    }()

    static func startSystemExtensionKeychainService() {
        guard let server = systemKeychainXPCServer else {
            wg_log(.error, staticMessage: "Unable to initialize the system extension keychain XPC service")
            return
        }
        server.start()
        wg_log(.info, staticMessage: "System extension keychain XPC service started")
    }
    #endif

    static func openReference(called ref: Data) -> String? {
        #if os(macOS)
        if !WireRouteSystemKeychainIdentity.isSystemExtensionProcess,
           let client = WireRouteSystemKeychainXPCClient() {
            let (systemStatus, configuration) = client.load(reference: ref)
            if systemStatus == errSecSuccess {
                return configuration
            }
            if systemStatus != errSecItemNotFound,
               systemStatus != errSecNotAvailable {
                wg_log(.error, message: "Unable to open config from system extension keychain: \(systemStatus)")
            }
        }
        #endif
        let (ret, result) = copyMatching([
            kSecValuePersistentRef: ref,
            kSecReturnData: true
        ])
        if ret == errSecSuccess,
           let data = result as? Data {
            return String(data: data, encoding: String.Encoding.utf8)
        }
        wg_log(.error, message: "Unable to open config from keychain: \(ret)")
        return nil
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
        connectionID: UUID,
        peerID: String
    ) -> Data? {
        let account = recoveryAccount(connectionID: connectionID, peerID: peerID)
        guard recoveryConfiguration(account: account) == nil else { return nil }
        return makeReference(
            containing: value,
            label: name,
            account: account,
            serviceSuffix: ".credential-recovery",
            description: "WireRoute pending RouterOS credential replacement"
        )
    }

    static func recoveryConfiguration(
        connectionID: UUID,
        peerID: String
    ) -> KeychainRecoveryConfiguration? {
        recoveryConfiguration(account: recoveryAccount(connectionID: connectionID, peerID: peerID))
    }

    static func legacyRecoveryConfiguration(for peerID: String) -> KeychainRecoveryConfiguration? {
        recoveryConfiguration(account: peerID)
    }

    static func migrateLegacyRecoveryConfiguration(
        _ legacyConfiguration: KeychainRecoveryConfiguration,
        connectionID: UUID,
        peerID: String
    ) -> KeychainRecoveryConfiguration? {
        if let scopedConfiguration = recoveryConfiguration(connectionID: connectionID, peerID: peerID) {
            return scopedConfiguration
        }
        guard let reference = makeRecoveryReference(
            containing: legacyConfiguration.configuration,
            called: legacyConfiguration.name,
            connectionID: connectionID,
            peerID: peerID
        ) else {
            return nil
        }
        deleteReference(called: legacyConfiguration.reference)
        return KeychainRecoveryConfiguration(
            reference: reference,
            name: legacyConfiguration.name,
            configuration: legacyConfiguration.configuration
        )
    }

    private static func recoveryConfiguration(account: String) -> KeychainRecoveryConfiguration? {
        guard let service = serviceIdentifier(suffix: ".credential-recovery") else { return nil }
        let (ret, result) = copyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
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

    private static func recoveryAccount(connectionID: UUID, peerID: String) -> String {
        "v2:\(connectionID.uuidString.lowercased()):\(peerID)"
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
        #if os(macOS)
        if serviceSuffix == nil,
           !WireRouteSystemKeychainIdentity.isSystemExtensionProcess,
           let client = WireRouteSystemKeychainXPCClient() {
            let (status, reference) = client.store(configuration: value, name: label)
            if status != errSecSuccess || reference == nil {
                wg_log(.error, message: "Unable to add config to system extension keychain: \(status)")
                return nil
            }
            return reference
        }
        #endif
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
        #if os(macOS)
        var systemStatus = errSecItemNotFound
        if !WireRouteSystemKeychainIdentity.isSystemExtensionProcess,
           let client = WireRouteSystemKeychainXPCClient() {
            systemStatus = client.delete(reference: ref)
            if systemStatus == errSecSuccess {
                return
            }
        }
        #endif
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
        #if os(macOS)
        if ret != errSecSuccess,
           ret != errSecItemNotFound,
           systemStatus != errSecSuccess,
           systemStatus != errSecItemNotFound {
            wg_log(.error, message: "Unable to delete config from keychains: local=\(ret), system=\(systemStatus)")
        }
        #else
        if ret != errSecSuccess && ret != errSecItemNotFound {
            wg_log(.error, message: "Unable to delete config from keychain: \(ret)")
        }
        #endif
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
        #if os(macOS)
        if !WireRouteSystemKeychainIdentity.isSystemExtensionProcess,
           let client = WireRouteSystemKeychainXPCClient(),
           client.verify(reference: ref) == errSecSuccess {
            return true
        }
        #endif
        let (ret, _) = copyMatching([kSecValuePersistentRef: ref])
        return ret == errSecSuccess
    }

    #if os(macOS)
    static func requiresSystemExtensionMigration(called ref: Data) -> Bool {
        guard !WireRouteSystemKeychainIdentity.isSystemExtensionProcess,
              let client = WireRouteSystemKeychainXPCClient(),
              client.verify(reference: ref) != errSecSuccess else {
            return false
        }
        let (localStatus, _) = copyMatching([kSecValuePersistentRef: ref])
        return localStatus == errSecSuccess
    }
    #endif

    private static func copyMatching(
        _ attributes: [CFString: Any]
    ) -> (OSStatus, CFTypeRef?) {
        #if os(macOS)
        if WireRouteSystemKeychainIdentity.isSystemExtensionProcess {
            guard let systemKeychain = openSystemKeychain() else {
                return (errSecNotAvailable, nil)
            }
            var systemAttributes = attributes
            systemAttributes[kSecUseKeychain] = systemKeychain
            var result: CFTypeRef?
            let status = SecItemCopyMatching(systemAttributes as CFDictionary, &result)
            return (status, result)
        }
        #endif
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
        status == errSecItemNotFound || status == errSecParam || status == errSecNotAvailable
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

    #if os(macOS)
    fileprivate static func addSystemTunnelReference(
        containing value: String,
        called label: String,
        ownerUID: uid_t
    ) -> (OSStatus, Data?) {
        guard WireRouteSystemKeychainIdentity.isSystemExtensionProcess else {
            return (errSecNotAvailable, nil)
        }
        guard value.utf8.count <= 1_048_576 else {
            return (errSecDataTooLarge, nil)
        }
        guard let service = serviceIdentifier(suffix: nil) else {
            return (errSecParam, nil)
        }

        var systemKeychain: SecKeychain?
        var status = SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain)
        guard status == errSecSuccess,
              let systemKeychain else {
            return (status, nil)
        }

        var trustedApplication: SecTrustedApplication?
        status = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard status == errSecSuccess,
              let trustedApplication else {
            return (status, nil)
        }

        var access: SecAccess?
        status = SecAccessCreate(label as CFString, [trustedApplication] as CFArray, &access)
        guard status == errSecSuccess,
              let access else {
            return (status, nil)
        }

        let account = "system:\(ownerUID):\(UUID().uuidString)"
        let items: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrLabel: label,
            kSecAttrAccount: account,
            kSecAttrDescription: "wg-quick(8) config",
            kSecAttrService: service,
            kSecAttrGeneric: systemOwnerData(ownerUID),
            kSecAttrAccess: access,
            kSecUseKeychain: systemKeychain,
            kSecValueData: value.data(using: .utf8) as Any,
            kSecReturnPersistentRef: true
        ]

        var reference: CFTypeRef?
        status = SecItemAdd(items as CFDictionary, &reference)
        return (status, reference as? Data)
    }

    fileprivate static func openSystemTunnelReference(
        called reference: Data,
        ownerUID: uid_t
    ) -> (OSStatus, String?) {
        let (status, item) = systemTunnelItem(
            called: reference,
            ownerUID: ownerUID,
            returnData: true
        )
        guard status == errSecSuccess,
              let data = item?[kSecValueData] as? Data,
              let configuration = String(data: data, encoding: .utf8) else {
            return (status == errSecSuccess ? errSecDecode : status, nil)
        }
        return (errSecSuccess, configuration)
    }

    fileprivate static func verifySystemTunnelReference(
        called reference: Data,
        ownerUID: uid_t
    ) -> OSStatus {
        systemTunnelItem(
            called: reference,
            ownerUID: ownerUID,
            returnData: false
        ).0
    }

    fileprivate static func deleteSystemTunnelReference(
        called reference: Data,
        ownerUID: uid_t
    ) -> OSStatus {
        let status = verifySystemTunnelReference(called: reference, ownerUID: ownerUID)
        guard status == errSecSuccess else { return status }
        guard let systemKeychain = openSystemKeychain() else { return errSecNotAvailable }
        return SecItemDelete([
            kSecValuePersistentRef: reference,
            kSecUseKeychain: systemKeychain
        ] as CFDictionary)
    }

    private static func systemTunnelItem(
        called reference: Data,
        ownerUID: uid_t,
        returnData: Bool
    ) -> (OSStatus, NSDictionary?) {
        guard let systemKeychain = openSystemKeychain() else {
            return (errSecNotAvailable, nil)
        }
        var query: [CFString: Any] = [
            kSecValuePersistentRef: reference,
            kSecReturnAttributes: true,
            kSecUseKeychain: systemKeychain
        ]
        if returnData {
            query[kSecReturnData] = true
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = result as? NSDictionary else {
            return (status, nil)
        }
        guard let ownerData = item[kSecAttrGeneric] as? Data,
              ownerData == systemOwnerData(ownerUID) else {
            return (errSecAuthFailed, nil)
        }
        return (errSecSuccess, item)
    }

    private static func openSystemKeychain() -> SecKeychain? {
        var systemKeychain: SecKeychain?
        guard SecKeychainOpen("/Library/Keychains/System.keychain", &systemKeychain) == errSecSuccess else {
            return nil
        }
        return systemKeychain
    }

    private static func systemOwnerData(_ ownerUID: uid_t) -> Data {
        Data("WireRoute owner UID: \(ownerUID)".utf8)
    }
    #endif
}
