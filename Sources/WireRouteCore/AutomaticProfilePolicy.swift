// SPDX-License-Identifier: MIT

import Foundation

public enum AutomaticProfileTransport: String, Codable, CaseIterable, Sendable {
    case wiFi
    case cellular
    case ethernet
    case other
    case unavailable
}

public enum AutomaticProfileTarget: Codable, Equatable, Sendable {
    case useDefault
    case vpnOff
    case profile(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case profileID
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
            self = .profile(try container.decode(UUID.self, forKey: .profileID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .useDefault:
            try container.encode(Kind.useDefault, forKey: .kind)
        case .vpnOff:
            try container.encode(Kind.vpnOff, forKey: .kind)
        case .profile(let profileID):
            try container.encode(Kind.profile, forKey: .kind)
            try container.encode(profileID, forKey: .profileID)
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
    public var defaultProfileID: UUID?
    public var otherWiFiTarget: AutomaticProfileTarget
    public var cellularTarget: AutomaticProfileTarget
    public var ethernetTarget: AutomaticProfileTarget
    public var trustedWiFiNames: [String]
    public var wiFiAssignments: [AutomaticWiFiAssignment]

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        defaultProfileID: UUID? = nil,
        otherWiFiTarget: AutomaticProfileTarget = .useDefault,
        cellularTarget: AutomaticProfileTarget = .useDefault,
        ethernetTarget: AutomaticProfileTarget = .useDefault,
        trustedWiFiNames: [String] = [],
        wiFiAssignments: [AutomaticWiFiAssignment] = []
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.defaultProfileID = defaultProfileID
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
        let trustedNames = trustedWiFiNames.map(Self.normalizedSSID)
        let assignments = wiFiAssignments.map {
            AutomaticWiFiAssignment(ssid: Self.normalizedSSID($0.ssid), target: $0.target)
        }
        let names = trustedNames + assignments.map(\.ssid)
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
        var normalized = self
        normalized.trustedWiFiNames = trustedNames
        normalized.wiFiAssignments = assignments
        return normalized
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
            profileID = defaultProfileID
        case .vpnOff:
            profileID = nil
        case .profile(let explicitProfileID):
            profileID = explicitProfileID
        }
        guard let profileID else { return .disconnect }
        guard availableProfileIDs.contains(profileID) else {
            return .hold(.profileUnavailable(profileID))
        }
        return .connect(profileID)
    }

    public func replacingProfileID(_ oldProfileID: UUID, with newProfileID: UUID) -> Self {
        var updated = self
        if updated.defaultProfileID == oldProfileID {
            updated.defaultProfileID = newProfileID
        }
        updated.otherWiFiTarget = updated.otherWiFiTarget.replacing(oldProfileID, with: newProfileID)
        updated.cellularTarget = updated.cellularTarget.replacing(oldProfileID, with: newProfileID)
        updated.ethernetTarget = updated.ethernetTarget.replacing(oldProfileID, with: newProfileID)
        updated.wiFiAssignments = updated.wiFiAssignments.map {
            AutomaticWiFiAssignment(
                ssid: $0.ssid,
                target: $0.target.replacing(oldProfileID, with: newProfileID)
            )
        }
        return updated
    }

    private static func normalizedSSID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension AutomaticProfileTarget {
    func replacing(_ oldProfileID: UUID, with newProfileID: UUID) -> Self {
        guard case .profile(oldProfileID) = self else { return self }
        return .profile(newProfileID)
    }
}
