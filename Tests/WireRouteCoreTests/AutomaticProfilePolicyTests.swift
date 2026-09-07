// SPDX-License-Identifier: MIT

import XCTest
@testable import WireRouteCore

final class AutomaticProfilePolicyTests: XCTestCase {
    private let home = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let mobile = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let office = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private var homeProfile: AutomaticProfileReference { .init(id: home, name: "Home") }
    private var mobileProfile: AutomaticProfileReference { .init(id: mobile, name: "Mobile") }
    private var officeProfile: AutomaticProfileReference { .init(id: office, name: "Office") }

    func testTrustedWiFiTakesPriorityOverAssignmentAndFallback() {
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfile: homeProfile,
            otherWiFiTarget: .profile(mobileProfile),
            trustedWiFiNames: ["Trusted"],
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Trusted", target: .profile(officeProfile))]
        )

        XCTAssertEqual(
            policy.decide(transport: .wiFi, wiFiName: "Trusted", availableProfileIDs: [home, mobile, office]),
            .disconnect
        )
    }

    func testSpecificWiFiAssignmentTakesPriorityOverOtherWiFi() {
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfile: homeProfile,
            otherWiFiTarget: .profile(mobileProfile),
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Office", target: .profile(officeProfile))]
        )

        XCTAssertEqual(
            policy.decide(transport: .wiFi, wiFiName: "Office", availableProfileIDs: [home, mobile, office]),
            .connect(office)
        )
        XCTAssertEqual(
            policy.decide(transport: .wiFi, wiFiName: "Cafe", availableProfileIDs: [home, mobile, office]),
            .connect(mobile)
        )
    }

    func testUseDefaultResolvesToDefaultProfileOrVPNOff() {
        let enabled = AutomaticProfilePolicy(isEnabled: true, defaultProfile: homeProfile)
        let off = AutomaticProfilePolicy(isEnabled: true, defaultProfile: nil)

        XCTAssertEqual(
            enabled.decide(transport: .cellular, wiFiName: nil, availableProfileIDs: [home]),
            .connect(home)
        )
        XCTAssertEqual(
            off.decide(transport: .ethernet, wiFiName: nil, availableProfileIDs: [home]),
            .disconnect
        )
    }

    func testMissingProfileHoldsInsteadOfDisconnectingCurrentTunnel() {
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfile: homeProfile,
            cellularTarget: .profile(mobileProfile)
        )

        XCTAssertEqual(
            policy.decide(transport: .cellular, wiFiName: nil, availableProfileIDs: [home]),
            .hold(.profileUnavailable(mobile))
        )
    }

    func testWiFiNameIsRequiredOnlyWhenRulesUseIt() {
        let basic = AutomaticProfilePolicy(isEnabled: true, defaultProfile: homeProfile)
        let named = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfile: homeProfile,
            trustedWiFiNames: ["Home"]
        )

        XCTAssertEqual(
            basic.decide(transport: .wiFi, wiFiName: nil, availableProfileIDs: [home]),
            .connect(home)
        )
        XCTAssertEqual(
            named.decide(transport: .wiFi, wiFiName: nil, availableProfileIDs: [home]),
            .hold(.wiFiNameUnavailable)
        )
    }

    func testValidationNormalizesNamesAndRejectsDuplicatesAcrossRuleTypes() throws {
        let normalized = try AutomaticProfilePolicy(
                trustedWiFiNames: ["  Home  "],
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Office\n", target: .profile(officeProfile))]
        ).validated()

        XCTAssertEqual(normalized.trustedWiFiNames, ["Home"])
        XCTAssertEqual(normalized.wiFiAssignments.map(\.ssid), ["Office"])

        XCTAssertThrowsError(
            try AutomaticProfilePolicy(
                trustedWiFiNames: ["Home"],
                wiFiAssignments: [AutomaticWiFiAssignment(ssid: " Home ", target: .profile(officeProfile))]
            ).validated()
        ) { error in
            XCTAssertEqual(error as? AutomaticProfilePolicyError, .duplicateWiFiName("Home"))
        }
    }

    func testPolicyRoundTripsWithStableProfileReferences() throws {
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfile: homeProfile,
            otherWiFiTarget: .profile(mobileProfile),
            cellularTarget: .vpnOff,
            ethernetTarget: .useDefault,
            trustedWiFiNames: ["Home"],
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Office", target: .profile(officeProfile))]
        )

        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(AutomaticProfilePolicy.self, from: data), policy)
    }

    func testRuntimeSnapshotValidatesReferencesAndResolvesProfiles() throws {
        let snapshot = try AutomaticProfileRuntimeSnapshot(
            revision: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            policy: AutomaticProfilePolicy(isEnabled: true, defaultProfile: homeProfile),
            profiles: [
                AutomaticProfileRuntimeProfile(
                    profile: homeProfile,
                    keychainReference: Data([0x01, 0x02]),
                    providerConfiguration: Data([0x03])
                )
            ]
        ).validated()

        XCTAssertEqual(snapshot.availableProfileIDs, [home])
        XCTAssertEqual(snapshot.profile(withID: home)?.profile, homeProfile)
        XCTAssertEqual(snapshot.decision(transport: .cellular, wiFiName: nil), .connect(home))
        XCTAssertEqual(
            try JSONDecoder().decode(
                AutomaticProfileRuntimeSnapshot.self,
                from: JSONEncoder().encode(snapshot)
            ),
            snapshot
        )
    }

    func testRuntimeSnapshotRejectsDuplicateAndUnprotectedProfiles() {
        XCTAssertThrowsError(
            try AutomaticProfileRuntimeSnapshot(
                policy: AutomaticProfilePolicy(),
                profiles: [
                    AutomaticProfileRuntimeProfile(profile: homeProfile, keychainReference: Data([0x01])),
                    AutomaticProfileRuntimeProfile(profile: homeProfile, keychainReference: Data([0x02]))
                ]
            ).validated()
        ) { error in
            XCTAssertEqual(error as? AutomaticProfileRuntimeSnapshotError, .duplicateProfile(home))
        }

        XCTAssertThrowsError(
            try AutomaticProfileRuntimeSnapshot(
                policy: AutomaticProfilePolicy(),
                profiles: [AutomaticProfileRuntimeProfile(profile: homeProfile, keychainReference: Data())]
            ).validated()
        ) { error in
            XCTAssertEqual(
                error as? AutomaticProfileRuntimeSnapshotError,
                .emptyKeychainReference(homeProfile.name)
            )
        }
    }

    func testUpdatingProfileRefreshesEveryStoredNameWithoutChangingIdentity() {
        let renamedHome = AutomaticProfileReference(id: home, name: "Renamed Home")
        let policy = AutomaticProfilePolicy(
            isEnabled: true,
            defaultProfile: homeProfile,
            otherWiFiTarget: .profile(homeProfile),
            cellularTarget: .profile(homeProfile),
            ethernetTarget: .profile(homeProfile),
            wiFiAssignments: [AutomaticWiFiAssignment(ssid: "Office", target: .profile(homeProfile))]
        ).updatingProfile(renamedHome)

        XCTAssertEqual(policy.defaultProfile, renamedHome)
        XCTAssertEqual(policy.otherWiFiTarget, .profile(renamedHome))
        XCTAssertEqual(policy.cellularTarget, .profile(renamedHome))
        XCTAssertEqual(policy.ethernetTarget, .profile(renamedHome))
        XCTAssertEqual(policy.wiFiAssignments.first?.target, .profile(renamedHome))
    }
}
