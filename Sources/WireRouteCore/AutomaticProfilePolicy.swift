// SPDX-License-Identifier: MIT

import Foundation

public enum AutomaticProfileTransport: String, Codable, CaseIterable, Sendable {
    case wiFi
    case cellular
    case ethernet
    case other
    case unavailable
}

public struct AutomaticProfileReference: Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum AutomaticProfileTarget: Codable, Equatable, Sendable {
    case useDefault
    case vpnOff
    case profile(AutomaticProfileReference)

    private enum CodingKeys: String, CodingKey {
        case kind
        case profileID
        case profileName
    }

    private enum Kind: String, Codable {
        case useDefault
        case vpnOff
        case profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .useDefault:
            self = .useDefault
        case .vpnOff:
            self = .vpnOff
        case .profile:
            let profileID = try container.decode(UUID.self, forKey: .profileID)
            let profileName = try container.decode(String.self, forKey: .profileName)
            self = .profile(AutomaticProfileReference(id: profileID, name: profileName))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .useDefault:
            try container.encode(Kind.useDefault, forKey: .kind)
        case .vpnOff:
            try container.encode(Kind.vpnOff, forKey: .kind)
        case .profile(let profile):
            try container.encode(Kind.profile, forKey: .kind)
            try container.encode(profile.id, forKey: .profileID)
            try container.encode(profile.name, forKey: .profileName)
        }
    }
}

public struct AutomaticWiFiAssignment: Codable, Equatable, Sendable {
    public var ssid: String
    public var target: AutomaticProfileTarget

    public init(ssid: String, target: AutomaticProfileTarget) {
        self.ssid = ssid
        self.target = target
    }
}

public enum AutomaticProfileDecision: Equatable, Sendable {
    case connect(UUID)
    case disconnect
    case hold(AutomaticProfileHoldReason)
}

public enum AutomaticProfileHoldReason: Equatable, Sendable {
    case disabled
    case waitingForNetwork
    case unsupportedTransport
    case wiFiNameUnavailable
    case profileUnavailable(UUID)
}

public enum AutomaticProfilePolicyError: Error, Equatable, LocalizedError, Sendable {
    case tooManyWiFiNames
    case invalidWiFiName(String)
    case duplicateWiFiName(String)

    public var errorDescription: String? {
        switch self {
        case .tooManyWiFiNames:
            return "Enter no more than 64 trusted or assigned Wi-Fi names."
        case .invalidWiFiName:
            return "Each Wi-Fi name must contain 1 to 32 UTF-8 bytes."
        case .duplicateWiFiName(let ssid):
            return "The Wi-Fi name \"\(ssid)\" can appear only once."
        }
    }
}

public struct AutomaticProfilePolicy: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var isEnabled: Bool
    public var defaultProfile: AutomaticProfileReference?
    public var otherWiFiTarget: AutomaticProfileTarget
    public var cellularTarget: AutomaticProfileTarget
    public var ethernetTarget: AutomaticProfileTarget
    public var trustedWiFiNames: [String]
    public var wiFiAssignments: [AutomaticWiFiAssignment]

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        defaultProfile: AutomaticProfileReference? = nil,
        otherWiFiTarget: AutomaticProfileTarget = .useDefault,
        cellularTarget: AutomaticProfileTarget = .useDefault,
        ethernetTarget: AutomaticProfileTarget = .useDefault,
        trustedWiFiNames: [String] = [],
        wiFiAssignments: [AutomaticWiFiAssignment] = []
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.defaultProfile = defaultProfile
        self.otherWiFiTarget = otherWiFiTarget
        self.cellularTarget = cellularTarget
        self.ethernetTarget = ethernetTarget
        self.trustedWiFiNames = trustedWiFiNames
        self.wiFiAssignments = wiFiAssignments
    }

    public var needsWiFiName: Bool {
        !trustedWiFiNames.isEmpty || !wiFiAssignments.isEmpty
    }

    public func validated() throws -> Self {
        let names = trustedWiFiNames + wiFiAssignments.map(\.ssid)
        guard names.count <= 64 else {
            throw AutomaticProfilePolicyError.tooManyWiFiNames
        }
        for name in names where name.isEmpty || name.lengthOfBytes(using: .utf8) > 32 {
            throw AutomaticProfilePolicyError.invalidWiFiName(name)
        }
        var seen = Set<String>()
        for name in names where !seen.insert(name).inserted {
            throw AutomaticProfilePolicyError.duplicateWiFiName(name)
        }
        return self
    }

    public func decide(
        transport: AutomaticProfileTransport,
        wiFiName: String?,
        availableProfileIDs: Set<UUID>
    ) -> AutomaticProfileDecision {
        guard isEnabled else { return .hold(.disabled) }

        let target: AutomaticProfileTarget
        switch transport {
        case .unavailable:
            return .hold(.waitingForNetwork)
        case .other:
            return .hold(.unsupportedTransport)
        case .cellular:
            target = cellularTarget
        case .ethernet:
            target = ethernetTarget
        case .wiFi:
            guard !needsWiFiName || wiFiName != nil else {
                return .hold(.wiFiNameUnavailable)
            }
            if let wiFiName, trustedWiFiNames.contains(wiFiName) {
                return .disconnect
            }
            target = wiFiName.flatMap { name in
                wiFiAssignments.first { $0.ssid == name }?.target
            } ?? otherWiFiTarget
        }

        let profileID: UUID?
        switch target {
        case .useDefault:
            profileID = defaultProfile?.id
        case .vpnOff:
            profileID = nil
        case .profile(let explicitProfile):
            profileID = explicitProfile.id
        }
        guard let profileID else { return .disconnect }
        guard availableProfileIDs.contains(profileID) else {
            return .hold(.profileUnavailable(profileID))
        }
        return .connect(profileID)
    }

    public func updatingProfile(_ profile: AutomaticProfileReference) -> Self {
        var updated = self
        if updated.defaultProfile?.id == profile.id {
            updated.defaultProfile = profile
        }
        updated.otherWiFiTarget = updated.otherWiFiTarget.updating(profile)
        updated.cellularTarget = updated.cellularTarget.updating(profile)
        updated.ethernetTarget = updated.ethernetTarget.updating(profile)
        updated.wiFiAssignments = updated.wiFiAssignments.map {
            AutomaticWiFiAssignment(
                ssid: $0.ssid,
                target: $0.target.updating(profile)
            )
        }
        return updated
    }

}

public struct AutomaticProfileRuntimeProfile: Codable, Equatable, Sendable {
    public var profile: AutomaticProfileReference
    public var keychainReference: Data
    public var providerConfiguration: Data?

    public init(
        profile: AutomaticProfileReference,
        keychainReference: Data,
        providerConfiguration: Data? = nil
    ) {
        self.profile = profile
        self.keychainReference = keychainReference
        self.providerConfiguration = providerConfiguration
    }
}

public enum AutomaticProfileRuntimeSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case duplicateProfile(UUID)
    case emptyKeychainReference(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateProfile:
            return "Each saved profile can appear only once in automatic profiles."
        case .emptyKeychainReference(let name):
            return "The saved profile \"\(name)\" is missing its protected Keychain reference."
        }
    }
}

public struct AutomaticProfileRuntimeSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var revision: UUID
    public var policyRevision: UUID
    public var policy: AutomaticProfilePolicy
    public var profiles: [AutomaticProfileRuntimeProfile]

    public init(
        version: Int = Self.currentVersion,
        revision: UUID = UUID(),
        policyRevision: UUID = UUID(),
        policy: AutomaticProfilePolicy,
        profiles: [AutomaticProfileRuntimeProfile]
    ) {
        self.version = version
        self.revision = revision
        self.policyRevision = policyRevision
        self.policy = policy
        self.profiles = profiles
    }

    public func validated() throws -> Self {
        var validated = self
        validated.policy = try policy.validated()
        var seen = Set<UUID>()
        for profile in profiles {
            guard seen.insert(profile.profile.id).inserted else {
                throw AutomaticProfileRuntimeSnapshotError.duplicateProfile(profile.profile.id)
            }
            guard !profile.keychainReference.isEmpty else {
                throw AutomaticProfileRuntimeSnapshotError.emptyKeychainReference(profile.profile.name)
            }
        }
        return validated
    }

    public var availableProfileIDs: Set<UUID> {
        Set(profiles.map(\.profile.id))
    }

    public func profile(withID id: UUID) -> AutomaticProfileRuntimeProfile? {
        profiles.first { $0.profile.id == id }
    }

    public func decision(
        transport: AutomaticProfileTransport,
        wiFiName: String?
    ) -> AutomaticProfileDecision {
        policy.decide(
            transport: transport,
            wiFiName: wiFiName,
            availableProfileIDs: availableProfileIDs
        )
    }
}

public enum AutomaticProfileRuntimeOwnership: String, Codable, Equatable, Sendable {
    case automatic
    case manual
}

public struct AutomaticProfileNetworkObservation: Codable, Equatable, Sendable {
    public var transport: AutomaticProfileTransport
    public var wiFiName: String?

    public init(transport: AutomaticProfileTransport, wiFiName: String? = nil) {
        self.transport = transport
        self.wiFiName = wiFiName
    }

    public var identity: String {
        if transport == .wiFi {
            return "wiFi:\(wiFiName ?? "unknown")"
        }
        return transport.rawValue
    }
}

public struct AutomaticProfileProviderCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case networkChanged
        case activateManualProfile
        case deactivateManualProfile
        case reloadSnapshot
    }

    public var action: Action
    public var profileID: UUID?
    public var network: AutomaticProfileNetworkObservation?

    public init(
        action: Action,
        profileID: UUID? = nil,
        network: AutomaticProfileNetworkObservation? = nil
    ) {
        self.action = action
        self.profileID = profileID
        self.network = network
    }

    public static func networkChanged(_ observation: AutomaticProfileNetworkObservation) -> Self {
        Self(action: .networkChanged, network: observation)
    }

    public static func activateManually(
        profileID: UUID,
        network: AutomaticProfileNetworkObservation? = nil
    ) -> Self {
        Self(action: .activateManualProfile, profileID: profileID, network: network)
    }

    public static func deactivateManually(
        network: AutomaticProfileNetworkObservation? = nil
    ) -> Self {
        Self(action: .deactivateManualProfile, network: network)
    }

    public static var reloadSnapshot: Self {
        Self(action: .reloadSnapshot)
    }
}

public struct AutomaticProfileRuntimeState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var snapshotRevision: UUID
    public var policyRevision: UUID
    public var activeProfile: AutomaticProfileReference?
    public var ownership: AutomaticProfileRuntimeOwnership?
    public var networkIdentity: String?
    public var network: AutomaticProfileNetworkObservation?

    public init(
        version: Int = Self.currentVersion,
        snapshotRevision: UUID,
        policyRevision: UUID,
        activeProfile: AutomaticProfileReference?,
        ownership: AutomaticProfileRuntimeOwnership?,
        networkIdentity: String?,
        network: AutomaticProfileNetworkObservation? = nil
    ) {
        self.version = version
        self.snapshotRevision = snapshotRevision
        self.policyRevision = policyRevision
        self.activeProfile = activeProfile
        self.ownership = ownership
        self.networkIdentity = networkIdentity
        self.network = network
    }
}

public enum AutomaticProfileFileStore {
    public static func loadSnapshot(from url: URL) throws -> AutomaticProfileRuntimeSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(
            AutomaticProfileRuntimeSnapshot.self,
            from: Data(contentsOf: url)
        )
    }

    public static func saveSnapshot(_ snapshot: AutomaticProfileRuntimeSnapshot, to url: URL) throws {
        let validated = try snapshot.validated()
        let data = try JSONEncoder().encode(validated)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public static func loadState(from url: URL) throws -> AutomaticProfileRuntimeState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(
            AutomaticProfileRuntimeState.self,
            from: Data(contentsOf: url)
        )
    }

    public static func saveState(_ state: AutomaticProfileRuntimeState, to url: URL) throws {
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private extension AutomaticProfileTarget {
    func updating(_ profile: AutomaticProfileReference) -> Self {
        guard case .profile(let existing) = self, existing.id == profile.id else { return self }
        return .profile(profile)
    }
}
